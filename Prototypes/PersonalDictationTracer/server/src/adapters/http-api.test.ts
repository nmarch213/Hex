import {
  HttpClient,
  HttpClientRequest,
  HttpClientResponse,
  HttpServer
} from "@effect/platform"
import { NodeHttpServer } from "@effect/platform-node"
import assert from "node:assert/strict"
import test from "node:test"

import {
  Deferred,
  Effect,
  Fiber,
  HashMap,
  Layer,
  Logger,
  Redacted,
  Ref,
  Schema,
  TestClock,
  TestContext
} from "effect"

import { DeviceAuthentication } from "../application/device-authentication.js"
import { DeviceRegistry } from "../application/device-registry.js"
import { SpeechRecognition } from "../application/speech-recognition.js"
import {
  TranscriptionIdempotency,
  TranscriptionIdempotencyUnavailableError,
  UpstreamProcessEpochSchema
} from "../application/transcription-idempotency.js"
import { Transcription } from "../application/transcription.js"
import {
  DeviceDisplayNameSchema,
  DevicePlatformSchema
} from "../domain/device-principal.js"
import { fakeSpeechRecognitionLayer } from "./fake-speech-recognition.js"
import { httpApi } from "./http-api.js"
import { InboundAudioAdmission } from "./inbound-audio-admission.js"
import { sqliteDeviceRegistryLayer } from "./sqlite-device-registry.js"
import { sqliteTranscriptionIdempotencyLayer } from "./sqlite-transcription-idempotency.js"

const ResponseSchema = Schema.Struct({
  requestID: Schema.String,
  transcript: Schema.String,
  timings: Schema.Struct({
    queueMS: Schema.Number,
    recognitionMS: Schema.Number,
    serviceMS: Schema.Number,
    upstreamMS: Schema.Number,
    totalMS: Schema.Number
  })
})

interface CapturedLog {
  readonly annotations: Readonly<Record<string, unknown>>
}

const capturingLoggerLayer = (logs: Array<CapturedLog>) =>
  Logger.replace(
    Logger.defaultLogger,
    Logger.make<unknown, void>(({ annotations }) => {
      logs.push({
        annotations: Object.fromEntries(HashMap.toEntries(annotations))
      })
    })
  )

const silentLoggerLayer = Logger.replace(
  Logger.defaultLogger,
  Logger.none
)

const makeAudio = (lastByte = 0) => {
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

const requestID = "8D758AE5-705C-4E1B-A62F-0DEFE5B830A5"
const TestUpstreamProcessEpoch = Schema.decodeUnknownSync(
  UpstreamProcessEpochSchema
)("02".repeat(32))
const testHttpApi = httpApi("development")
const TestRecognitionArtifacts = {
  runtimeRevision: "test-runtime-v1",
  modelRevision: "test-model-v1",
  modelSHA256: "0".repeat(64)
}

const deviceAuthenticationAndRegistryLayer = () =>
  DeviceAuthentication.Default.pipe(
    Layer.provideMerge(sqliteDeviceRegistryLayer(":memory:"))
  )

const enrollTestDevice = Effect.gen(function* () {
  const registry = yield* DeviceRegistry
  const enrollment = yield* registry.enroll({
    displayName: Schema.decodeUnknownSync(DeviceDisplayNameSchema)(
      "HTTP API test device"
    ),
    platform: Schema.decodeUnknownSync(DevicePlatformSchema)("ios"),
    capabilities: ["dictation:write", "service:health"]
  })
  return Redacted.value(enrollment.credential)
})

const makeTranscriptionRequest = (
  audio: Uint8Array,
  credential: string,
  id = requestID
) =>
  HttpClientRequest.post("/v1/transcribe").pipe(
    HttpClientRequest.setHeaders({
      authorization: `Bearer ${credential}`,
      "x-hex-request-id": id
    }),
    HttpClientRequest.bodyUint8Array(audio, "audio/wav")
  )

test("serves the authenticated transcription contract end to end", async () => {
  const logs: Array<CapturedLog> = []
  const credentialsForLogInspection: Array<string> = []
  const transcriptionLayer = Transcription.Default.pipe(
    Layer.provide(
      Layer.merge(
        fakeSpeechRecognitionLayer("Hello from Effect."),
        sqliteTranscriptionIdempotencyLayer(
          ":memory:",
          TestUpstreamProcessEpoch
        )
      )
    )
  )
  const services = Layer.mergeAll(
    transcriptionLayer,
    deviceAuthenticationAndRegistryLayer(),
    InboundAudioAdmission.Default
  )
  const testLayer = Layer.merge(NodeHttpServer.layerTest, services)

  await Effect.runPromise(
    Effect.gen(function* () {
      const credential = yield* enrollTestDevice
      credentialsForLogInspection.push(credential)
      const registry = yield* DeviceRegistry
      const healthOnlyEnrollment = yield* registry.enroll({
        displayName: Schema.decodeUnknownSync(DeviceDisplayNameSchema)(
          "HTTP health probe"
        ),
        platform: Schema.decodeUnknownSync(DevicePlatformSchema)("service"),
        capabilities: ["service:health"]
      })
      const healthOnlyCredential = Redacted.value(
        healthOnlyEnrollment.credential
      )
      credentialsForLogInspection.push(healthOnlyCredential)
      yield* HttpServer.serveEffect(testHttpApi)
      const client = yield* HttpClient.HttpClient

      const unauthorized = yield* client.execute(
        HttpClientRequest.get("/health").pipe(
          HttpClientRequest.setHeader("authorization", "Bearer wrong")
        )
      )
      assert.equal(unauthorized.status, 401)
      assert.equal(
        unauthorized.headers["www-authenticate"],
        "Bearer realm=\"hex-personal-dictation\""
      )

      const health = yield* client.execute(
        HttpClientRequest.get("/health").pipe(
          HttpClientRequest.setHeader(
            "authorization",
            `bEaReR ${credential}`
          )
        )
      )
      assert.equal(health.status, 200)

      const healthOnly = yield* client.execute(
        HttpClientRequest.get("/health").pipe(
          HttpClientRequest.setHeader(
            "authorization",
            `Bearer ${healthOnlyCredential}`
          )
        )
      )
      assert.equal(healthOnly.status, 200)
      const healthProbeTranscription = yield* client.execute(
        makeTranscriptionRequest(makeAudio(), healthOnlyCredential)
      )
      assert.equal(healthProbeTranscription.status, 401)

      const unmatched = yield* client.execute(
        HttpClientRequest.get("/private-name?secret=must-not-appear")
      )
      assert.equal(unmatched.status, 404)

      const unsupportedMethod = yield* client.execute(
        HttpClientRequest.put("/health")
      )
      assert.equal(unsupportedMethod.status, 404)

      const emptyBody = yield* client.execute(
        HttpClientRequest.post("/v1/transcribe").pipe(
          HttpClientRequest.setHeaders({
            authorization: `Bearer ${credential}`,
            "content-type": "audio/wav",
            "x-hex-request-id": "00000000-0000-4000-8000-000000000009"
          })
        )
      )
      // The Node test transport supplies Content-Length: 0 for an empty request,
      // so this reaches the strict size check rather than the missing-header branch.
      assert.equal(emptyBody.status, 400)

      const first = yield* client.execute(
        makeTranscriptionRequest(makeAudio(), credential)
      )
      const firstBody = yield* HttpClientResponse.schemaBodyJson(ResponseSchema)(
        first
      )
      assert.equal(first.status, 200)
      assert.equal(
        firstBody.requestID,
        "8d758ae5-705c-4e1b-a62f-0defe5b830a5"
      )
      assert.equal(firstBody.transcript, "Hello from Effect.")
      assert.equal(firstBody.timings.queueMS, 0)
      assert.equal(
        firstBody.timings.totalMS,
        firstBody.timings.serviceMS
      )
      assert.equal(firstBody.timings.recognitionMS >= 0, true)

      const replay = yield* client.execute(
        makeTranscriptionRequest(makeAudio(), credential)
      )
      const replayBody = yield* HttpClientResponse.schemaBodyJson(ResponseSchema)(
        replay
      )
      assert.equal(replay.status, 200)
      assert.equal(replay.headers["x-hex-idempotent-replay"], "true")
      assert.deepEqual(replayBody, firstBody)

      const conflict = yield* client.execute(
        makeTranscriptionRequest(makeAudio(1), credential)
      )
      assert.equal(conflict.status, 409)
    }).pipe(
      Effect.provide(testLayer),
      Effect.provide(capturingLoggerLayer(logs)),
      Effect.scoped
    )
  )

  const completionEvents = logs
    .map((log) => log.annotations)
    .filter((annotations) => annotations.event === "http_request_completed")
  assert.equal(completionEvents.length, 10)

  const firstCompletion = completionEvents.find(
    (event) =>
      event.route === "/v1/transcribe" &&
      event.status === 200 &&
      event.replayed === false
  )
  assert.ok(firstCompletion)
  assert.equal(firstCompletion.method, "POST")
  assert.equal(firstCompletion.outcome, "success")
  assert.equal(firstCompletion.request_id, undefined)
  assert.equal(firstCompletion.content_length, 48)
  assert.equal(firstCompletion.runtime, "fake")
  assert.equal(firstCompletion.model, "nvidia/parakeet-tdt-0.6b-v2")
  assert.equal(firstCompletion.service_version, "0.0.1")
  assert.equal(firstCompletion.service_revision, "development")
  assert.equal(
    typeof firstCompletion.duration_ms === "number" &&
      firstCompletion.duration_ms >= 0,
    true
  )

  const replayCompletion = completionEvents.find(
    (event) => event.replayed === true
  )
  assert.ok(replayCompletion)
  assert.equal(replayCompletion.status, 200)

  const unauthorizedCompletion = completionEvents.find(
    (event) => event.status === 401
  )
  assert.ok(unauthorizedCompletion)
  assert.equal(unauthorizedCompletion.route, "/health")
  assert.equal(unauthorizedCompletion.outcome, "unauthorized")

  const unmatchedCompletion = completionEvents.find(
    (event) => event.status === 404
  )
  assert.ok(unmatchedCompletion)
  assert.equal(unmatchedCompletion.route, "unmatched")
  assert.equal(unmatchedCompletion.outcome, "not_found")

  const boundedMethodCompletion = completionEvents.find(
    (event) => event.route === "/health" && event.method === "other"
  )
  assert.ok(boundedMethodCompletion)

  const conflictCompletion = completionEvents.find(
    (event) => event.status === 409
  )
  assert.ok(conflictCompletion)
  assert.equal(conflictCompletion.outcome, "request_conflict")

  const serializedEvents = JSON.stringify(completionEvents)
  for (const forbidden of [
    ...credentialsForLogInspection,
    "Hello from Effect.",
    "authorization",
    "transcript",
    "audioDigest",
    "private-name",
    "must-not-appear",
    "request ID was already used for different audio"
  ]) {
    assert.equal(serializedEvents.includes(forbidden), false)
  }
})

test("rejects an overlapping body before parsing and releases admission", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const inferenceStarted = yield* Deferred.make<void>()
      const releaseInference = yield* Deferred.make<void>()
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Effect.gen(function* () {
            yield* Ref.update(calls, (count) => count + 1)
            yield* Deferred.succeed(inferenceStarted, undefined)
            yield* Deferred.await(releaseInference)
            return {
              transcript: "Hello after admission.",
              upstreamMilliseconds: 1
            }
          }),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const transcriptionLayer = Transcription.Default.pipe(
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
      const services = Layer.mergeAll(
        transcriptionLayer,
        deviceAuthenticationAndRegistryLayer(),
        InboundAudioAdmission.Default
      )
      const testLayer = Layer.merge(NodeHttpServer.layerTest, services)

      yield* Effect.gen(function* () {
        const credential = yield* enrollTestDevice
        yield* HttpServer.serveEffect(testHttpApi)
        const client = yield* HttpClient.HttpClient
        const firstRequest = makeTranscriptionRequest(
          makeAudio(),
          credential,
          "00000000-0000-4000-8000-000000000001"
        )
        const firstFiber = yield* client.execute(firstRequest).pipe(Effect.fork)
        yield* Deferred.await(inferenceStarted)

        const busy = yield* client.execute(
          makeTranscriptionRequest(
            new Uint8Array(48),
            credential,
            "00000000-0000-4000-8000-000000000002"
          )
        )
        assert.equal(busy.status, 503)
        assert.equal(busy.headers["retry-after"], "1")
        assert.equal(yield* Ref.get(calls), 1)

        yield* Deferred.succeed(releaseInference, undefined)
        const first = yield* Fiber.join(firstFiber)
        assert.equal(first.status, 200)

        const malformedAfterRelease = yield* client.execute(
          makeTranscriptionRequest(
            new Uint8Array(48),
            credential,
            "00000000-0000-4000-8000-000000000003"
          )
        )
        assert.equal(malformedAfterRelease.status, 400)

        const admittedAfterMalformedBody = yield* client.execute(
          makeTranscriptionRequest(
            makeAudio(2),
            credential,
            "00000000-0000-4000-8000-000000000004"
          )
        )
        assert.equal(admittedAfterMalformedBody.status, 200)
        assert.equal(yield* Ref.get(calls), 2)
      }).pipe(
        Effect.provide(testLayer),
        Effect.provide(silentLoggerLayer),
        Effect.scoped
      )
    })
  )
})

test("completes accepted inference after the HTTP waiter deadline", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const inferenceStarted = yield* Deferred.make<void>()
      const releaseInference = yield* Deferred.make<void>()
      const inferenceReturned = yield* Deferred.make<void>()
      const calls = yield* Ref.make(0)
      const recognitionLayer = Layer.succeed(SpeechRecognition, {
        transcribe: () =>
          Effect.gen(function* () {
            yield* Ref.update(calls, (count) => count + 1)
            yield* Deferred.succeed(inferenceStarted, undefined)
            yield* Deferred.await(releaseInference)
            yield* Deferred.succeed(inferenceReturned, undefined)
            return {
              transcript: "Completed after HTTP timeout.",
              upstreamMilliseconds: 86_000
            }
          }),
        isReady: Effect.succeed(true),
        runtime: "test",
        model: "test-model",
        ...TestRecognitionArtifacts
      })
      const transcriptionLayer = Transcription.Default.pipe(
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
      const services = Layer.mergeAll(
        transcriptionLayer,
        deviceAuthenticationAndRegistryLayer(),
        InboundAudioAdmission.Default
      )
      const testLayer = Layer.merge(NodeHttpServer.layerTest, services)

      yield* Effect.gen(function* () {
        const credential = yield* enrollTestDevice
        yield* HttpServer.serveEffect(testHttpApi)
        const client = yield* HttpClient.HttpClient
        const responseFiber = yield* client
          .execute(
            makeTranscriptionRequest(
              makeAudio(),
              credential,
              "00000000-0000-4000-8000-000000000004"
            )
          )
          .pipe(Effect.fork)
        yield* Deferred.await(inferenceStarted)
        yield* TestClock.adjust("86 seconds")

        const response = yield* Fiber.join(responseFiber)
        assert.equal(response.status, 504)
        const body = yield* HttpClientResponse.schemaBodyJson(
          Schema.Struct({ error: Schema.String })
        )(response)
        assert.equal(body.error, "request deadline exceeded")

        yield* Deferred.succeed(releaseInference, undefined)
        yield* Deferred.await(inferenceReturned)

        const replay = yield* client
          .execute(
            makeTranscriptionRequest(
              makeAudio(),
              credential,
              "00000000-0000-4000-8000-000000000004"
            )
          )
          .pipe(
            Effect.flatMap((response) =>
              response.status === 503
                ? Effect.fail(new Error("accepted inference still running"))
                : Effect.succeed(response)
            ),
            Effect.retry({ times: 100 }),
            Effect.orDie
          )
        assert.equal(replay.status, 200)
        assert.equal(replay.headers["x-hex-idempotent-replay"], "true")
        const replayBody = yield* HttpClientResponse.schemaBodyJson(
          ResponseSchema
        )(replay)
        assert.equal(
          replayBody.transcript,
          "Completed after HTTP timeout."
        )
        assert.equal(yield* Ref.get(calls), 1)

        const admittedAfterLateCompletion = yield* client.execute(
          makeTranscriptionRequest(
            makeAudio(1),
            credential,
            "00000000-0000-4000-8000-000000000005"
          )
        )
        assert.equal(admittedAfterLateCompletion.status, 200)
        assert.equal(yield* Ref.get(calls), 2)
      }).pipe(
        Effect.provide(testLayer),
        Effect.provide(silentLoggerLayer),
        Effect.scoped
      )
    }).pipe(Effect.provide(TestContext.TestContext))
  )
})

test("maps a cold recognition runtime to 503 before durable admission", async () => {
  const recognitionLayer = Layer.succeed(SpeechRecognition, {
    transcribe: () => Effect.die("cold recognition must not run"),
    isReady: Effect.succeed(false),
    runtime: "test",
    model: "test-model",
    ...TestRecognitionArtifacts
  })
  const transcriptionLayer = Transcription.Default.pipe(
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
  const services = Layer.mergeAll(
    transcriptionLayer,
    deviceAuthenticationAndRegistryLayer(),
    InboundAudioAdmission.Default
  )
  const testLayer = Layer.merge(NodeHttpServer.layerTest, services)

  await Effect.runPromise(
    Effect.gen(function* () {
      const credential = yield* enrollTestDevice
      yield* HttpServer.serveEffect(testHttpApi)
      const client = yield* HttpClient.HttpClient

      const health = yield* client.execute(
        HttpClientRequest.get("/health").pipe(
          HttpClientRequest.setHeader(
            "authorization",
            `Bearer ${credential}`
          )
        )
      )
      assert.equal(health.status, 503)

      const response = yield* client.execute(
        makeTranscriptionRequest(makeAudio(), credential)
      )
      assert.equal(response.status, 503)
      assert.equal(response.headers["retry-after"], undefined)
      const body = yield* HttpClientResponse.schemaBodyJson(
        Schema.Struct({ error: Schema.String })
      )(response)
      assert.equal(body.error, "transcription runtime not ready")
    }).pipe(
      Effect.provide(testLayer),
      Effect.provide(silentLoggerLayer),
      Effect.scoped
    )
  )
})

test("maps durable idempotency unavailability to 503", async () => {
  const unavailableIdempotencyLayer = Layer.succeed(
    TranscriptionIdempotency,
    {
      isReady: Effect.succeed(false),
      acquireInference: Effect.fail(
        new TranscriptionIdempotencyUnavailableError({
          operation: "acquire_inference"
        })
      ),
      releaseInference: () => Effect.void,
      begin: () =>
        Effect.fail(
          new TranscriptionIdempotencyUnavailableError({
            operation: "begin"
          })
        ),
      complete: () => Effect.void,
      abandon: () => Effect.void
    }
  )
  const transcriptionLayer = Transcription.Default.pipe(
    Layer.provide(
      Layer.merge(
        fakeSpeechRecognitionLayer("must not run"),
        unavailableIdempotencyLayer
      )
    )
  )
  const services = Layer.mergeAll(
    transcriptionLayer,
    deviceAuthenticationAndRegistryLayer(),
    InboundAudioAdmission.Default
  )
  const testLayer = Layer.merge(NodeHttpServer.layerTest, services)

  await Effect.runPromise(
    Effect.gen(function* () {
      const credential = yield* enrollTestDevice
      yield* HttpServer.serveEffect(testHttpApi)
      const client = yield* HttpClient.HttpClient
      const health = yield* client.execute(
        HttpClientRequest.get("/health").pipe(
          HttpClientRequest.setHeader(
            "authorization",
            `Bearer ${credential}`
          )
        )
      )
      assert.equal(health.status, 503)
      const response = yield* client.execute(
        makeTranscriptionRequest(makeAudio(), credential)
      )
      assert.equal(response.status, 503)
      assert.equal(response.headers["retry-after"], undefined)
      const body = yield* HttpClientResponse.schemaBodyJson(
        Schema.Struct({ error: Schema.String })
      )(response)
      assert.equal(body.error, "idempotency storage unavailable")
    }).pipe(
      Effect.provide(testLayer),
      Effect.provide(silentLoggerLayer),
      Effect.scoped
    )
  )
})
