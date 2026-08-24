import { HttpServerRequest } from "@effect/platform"
import assert from "node:assert/strict"
import test from "node:test"

import {
  Deferred,
  Effect,
  Fiber,
  HashMap,
  Layer,
  Logger,
  Schema
} from "effect"

import { fakeSpeechRecognitionLayer } from "./fake-speech-recognition.js"
import { requestCompletionLogging } from "./request-completion-logging.js"
import { sqliteTranscriptionIdempotencyLayer } from "./sqlite-transcription-idempotency.js"
import { UpstreamProcessEpochSchema } from "../application/transcription-idempotency.js"
import { Transcription } from "../application/transcription.js"

interface CapturedLog {
  readonly annotations: Readonly<Record<string, unknown>>
}

const TestUpstreamProcessEpoch = Schema.decodeUnknownSync(
  UpstreamProcessEpochSchema
)("03".repeat(32))

const capturingLoggerLayer = (logs: Array<CapturedLog>) =>
  Logger.replace(
    Logger.defaultLogger,
    Logger.make<unknown, void>(({ annotations }) => {
      logs.push({
        annotations: Object.fromEntries(HashMap.toEntries(annotations))
      })
    })
  )

test("emits one bounded completion event when a request is interrupted", async () => {
  const logs: Array<CapturedLog> = []
  const transcriptionLayer = Transcription.Default.pipe(
    Layer.provide(
      Layer.merge(
        fakeSpeechRecognitionLayer("must-not-appear"),
        sqliteTranscriptionIdempotencyLayer(
          ":memory:",
          TestUpstreamProcessEpoch
        )
      )
    )
  )

  await Effect.runPromise(
    Effect.gen(function* () {
      const requestStarted = yield* Deferred.make<void>()
      const request = HttpServerRequest.fromWeb(
        new Request("http://localhost/v1/transcribe?secret=must-not-appear", {
          method: "POST",
          headers: {
            authorization: "Bearer must-not-appear",
            "content-length": "48",
            "x-hex-request-id": "8D758AE5-705C-4E1B-A62F-0DEFE5B830A5"
          }
        })
      )
      const application = requestCompletionLogging("development")(
        Deferred.succeed(requestStarted, undefined).pipe(
          Effect.zipRight(Effect.never)
        )
      )
      const requestFiber = yield* application.pipe(
        Effect.provideService(HttpServerRequest.HttpServerRequest, request),
        Effect.fork
      )

      yield* Deferred.await(requestStarted)
      yield* Fiber.interrupt(requestFiber)
    }).pipe(
      Effect.provide(transcriptionLayer),
      Effect.provide(capturingLoggerLayer(logs)),
      Effect.scoped
    )
  )

  const completionEvents = logs
    .map((log) => log.annotations)
    .filter((annotations) => annotations.event === "http_request_completed")
  assert.equal(completionEvents.length, 1)
  assert.equal(completionEvents[0]?.method, "POST")
  assert.equal(completionEvents[0]?.route, "/v1/transcribe")
  assert.equal(completionEvents[0]?.status, 499)
  assert.equal(completionEvents[0]?.outcome, "interrupted")
  assert.equal(completionEvents[0]?.request_id, undefined)
  assert.equal(completionEvents[0]?.content_length, 48)
  assert.equal(JSON.stringify(completionEvents).includes("must-not-appear"), false)
  assert.equal(
    JSON.stringify(completionEvents).includes(
      "8d758ae5-705c-4e1b-a62f-0defe5b830a5"
    ),
    false
  )
})
