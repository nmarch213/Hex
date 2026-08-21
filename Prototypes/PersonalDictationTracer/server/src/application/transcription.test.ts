import assert from "node:assert/strict"
import test from "node:test"

import { Effect, Either, Layer, Ref } from "effect"

import { SpeechRecognition } from "./speech-recognition.js"
import { Transcription } from "./transcription.js"
import { parseRequestId } from "../domain/request-id.js"

const makeAudio = (lastByte = 0) => {
  const bytes = new Uint8Array(44)
  bytes.set(new TextEncoder().encode("RIFF"), 0)
  bytes.set(new TextEncoder().encode("WAVE"), 8)
  bytes[43] = lastByte
  return { bytes }
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
        model: "test-model"
      })
      const layer = Transcription.Default.pipe(
        Layer.provide(recognitionLayer)
      )
      const requestID = yield* parseRequestId(
        "8D758AE5-705C-4E1B-A62F-0DEFE5B830A5"
      )

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        const request = {
          requestID,
          audio: makeAudio(),
          audioDigest: "same-audio"
        }
        const first = yield* transcription.transcribe(request)
        const replay = yield* transcription.transcribe(request)
        const conflict = yield* Effect.either(
          transcription.transcribe({
            ...request,
            audio: makeAudio(1),
            audioDigest: "different-audio"
          })
        )

        assert.equal(first.replayed, false)
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

test("runs at most one inference at a time", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const active = yield* Ref.make(0)
      const maximumActive = yield* Ref.make(0)
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
            yield* Effect.sleep("10 millis")
            return { transcript: "hello", upstreamMilliseconds: 10 }
          }).pipe(
            Effect.ensuring(Ref.update(active, (count) => count - 1))
          ),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model"
      })
      const layer = Transcription.Default.pipe(
        Layer.provide(recognitionLayer)
      )
      const requestIDs = yield* Effect.all([
        parseRequestId("00000000-0000-4000-8000-000000000001"),
        parseRequestId("00000000-0000-4000-8000-000000000002"),
        parseRequestId("00000000-0000-4000-8000-000000000003")
      ])

      yield* Effect.gen(function* () {
        const transcription = yield* Transcription
        yield* Effect.all(
          requestIDs.map((requestID, index) =>
            transcription.transcribe({
              requestID,
              audio: makeAudio(index),
              audioDigest: `audio-${index}`
            })
          ),
          { concurrency: "unbounded" }
        )
        assert.equal(yield* Ref.get(maximumActive), 1)
      }).pipe(Effect.provide(layer))
    })
  )
})
