import assert from "node:assert/strict"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import {
  Deferred,
  Effect,
  Either,
  Fiber,
  Layer,
  Ref,
  Schedule,
  Schema
} from "effect"

import {
  SpeechRecognition,
  SpeechRecognitionUnavailableError
} from "./speech-recognition.js"
import { Transcription } from "./transcription.js"
import {
  TranscriptionIdempotency,
  TranscriptionIdempotencyUnavailableError,
  UpstreamProcessEpochSchema
} from "./transcription-idempotency.js"
import { sqliteTranscriptionIdempotencyLayer } from "../adapters/sqlite-transcription-idempotency.js"
import { parseAudioDigest } from "../domain/audio-digest.js"
import { parseCapturedAudio } from "../domain/captured-audio.js"
import { DevicePrincipalIdSchema } from "../domain/device-principal.js"
import { parseRequestId } from "../domain/request-id.js"

const TestUpstreamProcessEpoch = Schema.decodeUnknownSync(
  UpstreamProcessEpochSchema
)("01".repeat(32))
const TestDevicePrincipalID = Schema.decodeUnknownSync(
  DevicePrincipalIdSchema
)("00000000-0000-4000-8000-00000000d001")
const TestRecognitionArtifacts = {
  runtimeRevision: "test-runtime-v1",
  modelRevision: "test-model-v1",
  modelSHA256: "0".repeat(64)
}

const makeAudio = (lastByte = 0): Uint8Array => {
  const bytes = new Uint8Array(48)
  const view = new DataView(bytes.buffer)
  bytes.set(new TextEncoder().encode("RIFF"), 0)
  view.setUint32(4, 40, true)
  bytes.set(new TextEncoder().encode("WAVE"), 8)
  bytes.set(new TextEncoder().encode("fmt "), 12)
  view.setUint32(16, 16, true)
  view.setUint16(20, 3, true)
  view.setUint16(22, 1, true)
  view.setUint32(24, 16_000, true)
  view.setUint32(28, 64_000, true)
  view.setUint16(32, 4, true)
  view.setUint16(34, 32, true)
  bytes.set(new TextEncoder().encode("data"), 36)
  view.setUint32(40, 4, true)
  bytes[47] = lastByte
  return bytes
}

const withTemporaryDatabase = async (
  run: (databasePath: string) => Promise<void>
) => {
  const directory = mkdtempSync(join(tmpdir(), "hex-transcription-"))
  try {
    await run(join(directory, "idempotency.sqlite"))
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

test("replays identical requests and rejects request ID reuse", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Ref.updateAndGet(calls, (count) => count + 1).pipe(
            Effect.as({ transcript: "hello", upstreamMilliseconds: 7 })
          ),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const layer = Transcription.Default.pipe(
        Layer.provide(
          Layer.merge(
            recognitionLayer,
            sqliteTranscriptionIdempotencyLayer(
              ":memory:",
              TestUpstreamProcessEpoch
            )
          )
        )
      )
      const requestID = yield* parseRequestId(
        "8D758AE5-705C-4E1B-A62F-0DEFE5B830A5"
      )
      const audio = yield* parseCapturedAudio(makeAudio())
      const differentAudio = yield* parseCapturedAudio(makeAudio(1))
      const audioDigest = yield* parseAudioDigest("00".repeat(32))
      const differentAudioDigest = yield* parseAudioDigest("01".repeat(32))

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const request = {
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audio,
          audioDigest
        }
        const first = yield* transcription.transcribe(request)
        const replay = yield* transcription.transcribe(request)
        const conflict = yield* Effect.either(
          transcription.transcribe({
            ...request,
            audio: differentAudio,
            audioDigest: differentAudioDigest
          })
        )

        assert.equal(first.replayed, false)
        assert.equal(first.response.timings.queueMS, 0)
        assert.equal(first.response.timings.upstreamMS, 7)
        assert.equal(
          first.response.timings.totalMS,
          first.response.timings.serviceMS
        )
        assert.equal(
          first.response.timings.serviceMS >=
            first.response.timings.recognitionMS,
          true
        )
        assert.equal(replay.replayed, true)
        assert.deepEqual(replay.response, first.response)
        assert.equal(yield* Ref.get(calls), 1)
        assert.equal(Either.isLeft(conflict), true)
        if (Either.isLeft(conflict)) {
          assert.equal(conflict.left._tag, "RequestIdConflictError")
        }
      }).pipe(Effect.provide(layer))
    })
  )
})

test("rejects overlapping inference without retaining a waiter", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const active = yield* Ref.make(0)
      const maximumActive = yield* Ref.make(0)
      const inferenceStarted = yield* Deferred.make<void>()
      const releaseInference = yield* Deferred.make<void>()
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Effect.gen(function* () {
            const current = yield* Ref.updateAndGet(
              active,
              (count) => count + 1
            )
            yield* Ref.update(maximumActive, (maximum) =>
              Math.max(maximum, current)
            )
            yield* Deferred.succeed(inferenceStarted, undefined)
            yield* Deferred.await(releaseInference)
            return { transcript: "hello", upstreamMilliseconds: 10 }
          }).pipe(
            Effect.ensuring(Ref.update(active, (count) => count - 1))
          ),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const layer = Transcription.Default.pipe(
        Layer.provide(
          Layer.merge(
            recognitionLayer,
            sqliteTranscriptionIdempotencyLayer(
              ":memory:",
              TestUpstreamProcessEpoch
            )
          )
        )
      )
      const requestIDs = yield* Effect.all([
        parseRequestId("00000000-0000-4000-8000-000000000001"),
        parseRequestId("00000000-0000-4000-8000-000000000002"),
        parseRequestId("00000000-0000-4000-8000-000000000003")
      ])
      const audio = yield* parseCapturedAudio(makeAudio())
      const digests = yield* Effect.all([
        parseAudioDigest("00".repeat(32)),
        parseAudioDigest("01".repeat(32)),
        parseAudioDigest("02".repeat(32))
      ])

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const firstRequestID = requestIDs[0]
        const secondRequestID = requestIDs[1]
        const thirdRequestID = requestIDs[2]
        const firstDigest = digests[0]
        const secondDigest = digests[1]
        const thirdDigest = digests[2]
        assert.notEqual(firstRequestID, undefined)
        assert.notEqual(secondRequestID, undefined)
        assert.notEqual(thirdRequestID, undefined)
        assert.notEqual(firstDigest, undefined)
        assert.notEqual(secondDigest, undefined)
        assert.notEqual(thirdDigest, undefined)

        const firstFiber = yield* transcription
          .transcribe({
            devicePrincipalID: TestDevicePrincipalID,
            requestID: firstRequestID,
            audio,
            audioDigest: firstDigest
          })
          .pipe(Effect.fork)
        yield* Deferred.await(inferenceStarted)

        const overlap = yield* transcription
          .transcribe({
            devicePrincipalID: TestDevicePrincipalID,
            requestID: secondRequestID,
            audio,
            audioDigest: secondDigest
          })
          .pipe(Effect.either, Effect.timeout("1 second"))
        assert.equal(Either.isLeft(overlap), true)
        if (Either.isLeft(overlap)) {
          assert.equal(overlap.left._tag, "TranscriptionBusyError")
          assert.equal(overlap.left.retryAfterSeconds, 1)
        }

        yield* Deferred.succeed(releaseInference, undefined)
        yield* Fiber.join(firstFiber)
        assert.equal(yield* Ref.get(maximumActive), 1)

        const admittedAfterRelease = yield* transcription.transcribe({
          devicePrincipalID: TestDevicePrincipalID,
          requestID: thirdRequestID,
          audio,
          audioDigest: thirdDigest
        })
        assert.equal(admittedAfterRelease.replayed, false)
      }).pipe(Effect.provide(layer))
    })
  )
})

test("does not strand admission when interruption races lease acquisition", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const acquisitionEntered = yield* Deferred.make<void>()
      const permitAcquisition = yield* Deferred.make<void>()
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Ref.updateAndGet(calls, (count) => count + 1).pipe(
            Effect.as({ transcript: "completed", upstreamMilliseconds: 1 })
          ),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const controlledIdempotencyLayer = Layer.effect(
        TranscriptionIdempotency,
        Effect.gen(function* () {
          const delegate = yield* TranscriptionIdempotency
          return {
            ...delegate,
            acquireInference: Deferred.succeed(
              acquisitionEntered,
              undefined
            ).pipe(
              Effect.zipRight(Deferred.await(permitAcquisition)),
              Effect.zipRight(delegate.acquireInference),
              Effect.uninterruptible
            )
          }
        })
      ).pipe(
        Layer.provide(
          sqliteTranscriptionIdempotencyLayer(
            ":memory:",
            TestUpstreamProcessEpoch
          )
        )
      )
      const layer = Transcription.Default.pipe(
        Layer.provide(
          Layer.merge(recognitionLayer, controlledIdempotencyLayer)
        )
      )
      const requestID = yield* parseRequestId(
        "00000000-0000-4000-8000-000000000031"
      )
      const audio = yield* parseCapturedAudio(makeAudio())
      const audioDigest = yield* parseAudioDigest("31".repeat(32))

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const request = {
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audio,
          audioDigest
        }
        const interruptedWaiter = yield* transcription
          .transcribe(request)
          .pipe(Effect.fork)
        yield* Deferred.await(acquisitionEntered)
        yield* Fiber.interruptFork(interruptedWaiter)
        yield* Deferred.succeed(permitAcquisition, undefined)
        yield* Fiber.await(interruptedWaiter)

        const replay = yield* transcription.transcribe(request).pipe(
          Effect.retry(
            Schedule.spaced("1 millis").pipe(
              Schedule.intersect(Schedule.recurs(100))
            )
          ),
          Effect.timeout("1 second")
        )
        assert.equal(replay.replayed, true)
        assert.equal(replay.response.transcript, "completed")
        assert.equal(yield* Ref.get(calls), 1)
      }).pipe(Effect.provide(layer))
    })
  )
})

test("releases the request claim when lease storage fails before inference", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const acquisitionAttempts = yield* Ref.make(0)
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Ref.updateAndGet(calls, (count) => count + 1).pipe(
            Effect.as({ transcript: "recovered", upstreamMilliseconds: 1 })
          ),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const controlledIdempotencyLayer = Layer.effect(
        TranscriptionIdempotency,
        Effect.gen(function* () {
          const delegate = yield* TranscriptionIdempotency
          return {
            ...delegate,
            acquireInference: Ref.updateAndGet(
              acquisitionAttempts,
              (attempt) => attempt + 1
            ).pipe(
              Effect.flatMap((attempt) =>
                attempt === 1
                  ? Effect.fail(
                      new TranscriptionIdempotencyUnavailableError({
                        operation: "acquire_inference"
                      })
                    )
                  : delegate.acquireInference
              )
            )
          }
        })
      ).pipe(
        Layer.provide(
          sqliteTranscriptionIdempotencyLayer(
            ":memory:",
            TestUpstreamProcessEpoch
          )
        )
      )
      const layer = Transcription.Default.pipe(
        Layer.provide(
          Layer.merge(recognitionLayer, controlledIdempotencyLayer)
        )
      )
      const requestID = yield* parseRequestId(
        "00000000-0000-4000-8000-000000000032"
      )
      const audio = yield* parseCapturedAudio(makeAudio())
      const audioDigest = yield* parseAudioDigest("32".repeat(32))

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const request = {
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audio,
          audioDigest
        }
        const unavailable = yield* transcription
          .transcribe(request)
          .pipe(Effect.either)
        assert.equal(Either.isLeft(unavailable), true)
        if (Either.isLeft(unavailable)) {
          assert.equal(
            unavailable.left._tag,
            "TranscriptionIdempotencyUnavailableError"
          )
        }

        const recovered = yield* transcription.transcribe(request)
        assert.equal(recovered.replayed, false)
        assert.equal(recovered.response.transcript, "recovered")
        assert.equal(yield* Ref.get(calls), 1)
      }).pipe(Effect.provide(layer))
    })
  )
})

test("rejects a new request before claiming when recognition is not ready", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const ready = yield* Ref.make(false)
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Ref.updateAndGet(calls, (count) => count + 1).pipe(
            Effect.as({ transcript: "ready", upstreamMilliseconds: 1 })
          ),
        isReady: Ref.get(ready),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const layer = Transcription.Default.pipe(
        Layer.provide(
          Layer.merge(
            recognitionLayer,
            sqliteTranscriptionIdempotencyLayer(
              ":memory:",
              TestUpstreamProcessEpoch
            )
          )
        )
      )
      const requestID = yield* parseRequestId(
        "00000000-0000-4000-8000-000000000033"
      )
      const audio = yield* parseCapturedAudio(makeAudio())
      const audioDigest = yield* parseAudioDigest("33".repeat(32))

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const request = {
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audio,
          audioDigest
        }
        const notReady = yield* transcription.transcribe(request).pipe(
          Effect.either
        )
        assert.equal(Either.isLeft(notReady), true)
        if (Either.isLeft(notReady)) {
          assert.equal(notReady.left._tag, "TranscriptionNotReadyError")
        }
        assert.equal(yield* Ref.get(calls), 0)

        yield* Ref.set(ready, true)
        const admitted = yield* transcription.transcribe(request)
        assert.equal(admitted.replayed, false)
        assert.equal(admitted.response.transcript, "ready")
        assert.equal(yield* Ref.get(calls), 1)
      }).pipe(Effect.provide(layer))
    })
  )
})

test("continues accepted inference after its client waiter is cancelled", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const inferenceStarted = yield* Deferred.make<void>()
      const releaseInference = yield* Deferred.make<void>()
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Ref.updateAndGet(calls, (count) => count + 1).pipe(
            Effect.tap(() => Deferred.succeed(inferenceStarted, undefined)),
            Effect.zipRight(Deferred.await(releaseInference)),
            Effect.as({ transcript: "durable", upstreamMilliseconds: 1 })
          ),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const layer = Transcription.Default.pipe(
        Layer.provide(
          Layer.merge(
            recognitionLayer,
            sqliteTranscriptionIdempotencyLayer(
              ":memory:",
              TestUpstreamProcessEpoch
            )
          )
        )
      )
      const requestIDs = yield* Effect.all([
        parseRequestId("00000000-0000-4000-8000-000000000034"),
        parseRequestId("00000000-0000-4000-8000-000000000035")
      ])
      const audio = yield* parseCapturedAudio(makeAudio())
      const audioDigest = yield* parseAudioDigest("34".repeat(32))
      const firstRequestID = requestIDs[0]
      const secondRequestID = requestIDs[1]
      assert.notEqual(firstRequestID, undefined)
      assert.notEqual(secondRequestID, undefined)

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const firstRequest = {
          devicePrincipalID: TestDevicePrincipalID,
          requestID: firstRequestID,
          audio,
          audioDigest
        }
        const waiter = yield* transcription
          .transcribe(firstRequest)
          .pipe(Effect.fork)
        yield* Deferred.await(inferenceStarted)
        yield* Fiber.interrupt(waiter)
        yield* Deferred.succeed(releaseInference, undefined)

        const replay = yield* transcription.transcribe(firstRequest).pipe(
          Effect.retry(
            Schedule.spaced("1 millis").pipe(
              Schedule.intersect(Schedule.recurs(100))
            )
          ),
          Effect.timeout("1 second")
        )
        assert.equal(replay.replayed, true)
        assert.equal(replay.response.transcript, "durable")
        assert.equal(yield* Ref.get(calls), 1)

        const next = yield* transcription.transcribe({
          ...firstRequest,
          requestID: secondRequestID
        })
        assert.equal(next.replayed, false)
        assert.equal(next.response.transcript, "durable")
        assert.equal(yield* Ref.get(calls), 2)
      }).pipe(Effect.provide(layer))
    })
  )
})

test("retains the process-epoch fence when the service stops during inference", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    await Effect.runPromise(
      Effect.gen(function* () {
        const inferenceStarted = yield* Deferred.make<void>()
        const callsAfterRestart = yield* Ref.make(0)
        const firstRecognitionLayer = Layer.succeed(SpeechRecognition, {
          transcribe: () =>
            Deferred.succeed(inferenceStarted, undefined).pipe(
              Effect.zipRight(Effect.never)
            ),
          isReady: Effect.succeed(true),
          runtime: "test",
          model: "test-model",
          ...TestRecognitionArtifacts
        })
        const firstLayer = Transcription.Default.pipe(
          Layer.provide(
            Layer.merge(
              firstRecognitionLayer,
              sqliteTranscriptionIdempotencyLayer(
                databasePath,
                TestUpstreamProcessEpoch
              )
            )
          )
        )
        const requestIDs = yield* Effect.all([
          parseRequestId("00000000-0000-4000-8000-000000000037"),
          parseRequestId("00000000-0000-4000-8000-000000000038")
        ])
        const audio = yield* parseCapturedAudio(makeAudio())
        const digests = yield* Effect.all([
          parseAudioDigest("37".repeat(32)),
          parseAudioDigest("38".repeat(32))
        ])
        const firstRequestID = requestIDs[0]
        const secondRequestID = requestIDs[1]
        const firstDigest = digests[0]
        const secondDigest = digests[1]
        assert.notEqual(firstRequestID, undefined)
        assert.notEqual(secondRequestID, undefined)
        assert.notEqual(firstDigest, undefined)
        assert.notEqual(secondDigest, undefined)

        yield* Effect.gen(function* () {
          const transcription = yield* Transcription
          yield* transcription
            .transcribe({
              devicePrincipalID: TestDevicePrincipalID,
              requestID: firstRequestID,
              audio,
              audioDigest: firstDigest
            })
            .pipe(Effect.fork)
          yield* Deferred.await(inferenceStarted)
        }).pipe(Effect.provide(firstLayer), Effect.scoped)

        const restartedRecognitionLayer = Layer.succeed(
          SpeechRecognition,
          {
            transcribe: () =>
              Ref.updateAndGet(
                callsAfterRestart,
                (count) => count + 1
              ).pipe(
                Effect.as({
                  transcript: "must remain fenced",
                  upstreamMilliseconds: 1
                })
              ),
            isReady: Effect.succeed(true),
            runtime: "test",
            model: "test-model",
            ...TestRecognitionArtifacts
          }
        )
        const restartedLayer = Transcription.Default.pipe(
          Layer.provide(
            Layer.merge(
              restartedRecognitionLayer,
              sqliteTranscriptionIdempotencyLayer(
                databasePath,
                TestUpstreamProcessEpoch
              )
            )
          )
        )

        yield* Effect.gen(function* () {
          const transcription = yield* Transcription
          assert.equal(yield* transcription.isReady, false)
          const blocked = yield* transcription
            .transcribe({
              devicePrincipalID: TestDevicePrincipalID,
              requestID: secondRequestID,
              audio,
              audioDigest: secondDigest
            })
            .pipe(Effect.either)
          assert.equal(Either.isLeft(blocked), true)
          if (Either.isLeft(blocked)) {
            assert.equal(blocked.left._tag, "TranscriptionBusyError")
          }
          assert.equal(yield* Ref.get(callsAfterRestart), 0)
        }).pipe(Effect.provide(restartedLayer), Effect.scoped)
      })
    )
  })
})

test("records settlement when waiter cancellation races recognition completion", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const recognitionReturning = yield* Deferred.make<void>()
      const permitRecognitionReturn = yield* Deferred.make<void>()
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Ref.updateAndGet(calls, (count) => count + 1).pipe(
            Effect.tap(() =>
              Deferred.succeed(recognitionReturning, undefined)
            ),
            Effect.zipRight(Deferred.await(permitRecognitionReturn)),
            Effect.as({ transcript: "settled", upstreamMilliseconds: 1 }),
            Effect.uninterruptible
          ),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const layer = Transcription.Default.pipe(
        Layer.provide(
          Layer.merge(
            recognitionLayer,
            sqliteTranscriptionIdempotencyLayer(
              ":memory:",
              TestUpstreamProcessEpoch
            )
          )
        )
      )
      const requestID = yield* parseRequestId(
        "00000000-0000-4000-8000-000000000036"
      )
      const audio = yield* parseCapturedAudio(makeAudio())
      const audioDigest = yield* parseAudioDigest("36".repeat(32))

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const request = {
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audio,
          audioDigest
        }
        const waiter = yield* transcription
          .transcribe(request)
          .pipe(Effect.fork)
        yield* Deferred.await(recognitionReturning)
        yield* Fiber.interruptFork(waiter)
        yield* Deferred.succeed(permitRecognitionReturn, undefined)
        yield* Fiber.await(waiter)

        const replay = yield* transcription.transcribe(request).pipe(
          Effect.retry(
            Schedule.spaced("1 millis").pipe(
              Schedule.intersect(Schedule.recurs(100))
            )
          ),
          Effect.timeout("1 second")
        )
        assert.equal(replay.replayed, true)
        assert.equal(replay.response.transcript, "settled")
        assert.equal(yield* Ref.get(calls), 1)
      }).pipe(Effect.provide(layer))
    })
  )
})

test("holds durable inference admission after an uncertain recognition failure", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Ref.updateAndGet(calls, (count) => count + 1).pipe(
            Effect.flatMap((call) =>
              call === 1
                ? Effect.fail(
                    new SpeechRecognitionUnavailableError({
                      reason: "test recognition failure",
                      completion: "unknown"
                    })
                  )
                : Effect.succeed({
                    transcript: "recovered",
                    upstreamMilliseconds: 1
                  })
            )
          ),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const layer = Transcription.Default.pipe(
        Layer.provide(
          Layer.merge(
            recognitionLayer,
            sqliteTranscriptionIdempotencyLayer(
              ":memory:",
              TestUpstreamProcessEpoch
            )
          )
        )
      )
      const requestIDs = yield* Effect.all([
        parseRequestId("00000000-0000-4000-8000-000000000011"),
        parseRequestId("00000000-0000-4000-8000-000000000012")
      ])
      const audio = yield* parseCapturedAudio(makeAudio())
      const digests = yield* Effect.all([
        parseAudioDigest("11".repeat(32)),
        parseAudioDigest("12".repeat(32))
      ])
      const firstRequestID = requestIDs[0]
      const secondRequestID = requestIDs[1]
      const firstDigest = digests[0]
      const secondDigest = digests[1]
      assert.notEqual(firstRequestID, undefined)
      assert.notEqual(secondRequestID, undefined)
      assert.notEqual(firstDigest, undefined)
      assert.notEqual(secondDigest, undefined)

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const failed = yield* Effect.either(
          transcription.transcribe({
            devicePrincipalID: TestDevicePrincipalID,
            requestID: firstRequestID,
            audio,
            audioDigest: firstDigest
          })
        )
        assert.equal(Either.isLeft(failed), true)
        assert.equal(yield* transcription.isReady, false)

        const blocked = yield* Effect.either(
          transcription.transcribe({
            devicePrincipalID: TestDevicePrincipalID,
            requestID: secondRequestID,
            audio,
            audioDigest: secondDigest
          })
        )
        assert.equal(Either.isLeft(blocked), true)
        if (Either.isLeft(blocked)) {
          assert.equal(blocked.left._tag, "TranscriptionBusyError")
        }
        assert.equal(yield* Ref.get(calls), 1)
      }).pipe(Effect.provide(layer))
    })
  )
})

test("releases durable admission after a known-settled recognition failure", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Ref.updateAndGet(calls, (count) => count + 1).pipe(
            Effect.flatMap((call) =>
              call === 1
                ? Effect.fail(
                    new SpeechRecognitionUnavailableError({
                      reason: "upstream returned HTTP 500",
                      completion: "settled"
                    })
                  )
                : Effect.succeed({
                    transcript: "recovered",
                    upstreamMilliseconds: 1
                  })
            )
          ),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const layer = Transcription.Default.pipe(
        Layer.provide(
          Layer.merge(
            recognitionLayer,
            sqliteTranscriptionIdempotencyLayer(
              ":memory:",
              TestUpstreamProcessEpoch
            )
          )
        )
      )
      const requestID = yield* parseRequestId(
        "00000000-0000-4000-8000-000000000021"
      )
      const audio = yield* parseCapturedAudio(makeAudio())
      const audioDigest = yield* parseAudioDigest("21".repeat(32))

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const request = {
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audio,
          audioDigest
        }
        const failed = yield* Effect.either(
          transcription.transcribe(request)
        )
        assert.equal(Either.isLeft(failed), true)

        const recovered = yield* transcription.transcribe(request)
        assert.equal(recovered.response.transcript, "recovered")
        assert.equal(yield* Ref.get(calls), 2)
      }).pipe(Effect.provide(layer))
    })
  )
})

test("bounds retained transcripts and releases the rejected claim", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Ref.updateAndGet(calls, (count) => count + 1).pipe(
            Effect.map((call) => ({
              transcript: call === 1 ? "x".repeat(100_001) : "recovered",
              upstreamMilliseconds: 1
            }))
          ),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const layer = Transcription.Default.pipe(
        Layer.provide(
          Layer.merge(
            recognitionLayer,
            sqliteTranscriptionIdempotencyLayer(
              ":memory:",
              TestUpstreamProcessEpoch
            )
          )
        )
      )
      const requestID = yield* parseRequestId(
        "00000000-0000-4000-8000-000000000013"
      )
      const audio = yield* parseCapturedAudio(makeAudio())
      const audioDigest = yield* parseAudioDigest("13".repeat(32))

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const request = {
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audio,
          audioDigest
        }
        const oversized = yield* Effect.either(
          transcription.transcribe(request)
        )
        assert.equal(Either.isLeft(oversized), true)
        if (Either.isLeft(oversized)) {
          assert.equal(oversized.left._tag, "TranscriptTooLargeError")
        }

        const recovered = yield* transcription.transcribe(request)
        assert.equal(recovered.replayed, false)
        assert.equal(recovered.response.transcript, "recovered")
        assert.equal(yield* Ref.get(calls), 2)
      }).pipe(Effect.provide(layer))
    })
  )
})
