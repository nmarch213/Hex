import {
  HttpClient,
  HttpClientRequest,
  HttpClientResponse,
  HttpServer
} from "@effect/platform"
import { NodeHttpServer } from "@effect/platform-node"
import assert from "node:assert/strict"
import test from "node:test"

import { Effect, Layer, Redacted, Schema } from "effect"

import { Transcription } from "../application/transcription.js"
import { bearerAuthenticatorLayer } from "./bearer-authenticator.js"
import { fakeSpeechRecognitionLayer } from "./fake-speech-recognition.js"
import { httpApi } from "./http-api.js"

const ResponseSchema = Schema.Struct({
  requestID: Schema.String,
  transcript: Schema.String,
  timings: Schema.Struct({ upstreamMS: Schema.Number, totalMS: Schema.Number })
})

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

const makeTranscriptionRequest = (audio: Uint8Array) =>
  HttpClientRequest.post("/v1/transcribe").pipe(
    HttpClientRequest.setHeaders({
      authorization: "Bearer prototype",
      "x-hex-request-id": requestID
    }),
    HttpClientRequest.bodyUint8Array(audio, "audio/wav")
  )

test("serves the authenticated transcription contract end to end", async () => {
  const transcriptionLayer = Transcription.Default.pipe(
    Layer.provide(fakeSpeechRecognitionLayer("Hello from Effect."))
  )
  const services = Layer.merge(
    transcriptionLayer,
    bearerAuthenticatorLayer(Redacted.make("prototype"))
  )
  const testLayer = Layer.merge(NodeHttpServer.layerTest, services)

  await Effect.runPromise(
    Effect.gen(function* () {
      yield* HttpServer.serveEffect(httpApi)
      const client = yield* HttpClient.HttpClient

      const unauthorized = yield* client.execute(
        HttpClientRequest.get("/health").pipe(
          HttpClientRequest.setHeader("authorization", "Bearer wrong")
        )
      )
      assert.equal(unauthorized.status, 401)

      const health = yield* client.execute(
        HttpClientRequest.get("/health").pipe(
          HttpClientRequest.setHeader("authorization", "Bearer prototype")
        )
      )
      assert.equal(health.status, 200)

      const first = yield* client.execute(makeTranscriptionRequest(makeAudio()))
      const firstBody = yield* HttpClientResponse.schemaBodyJson(ResponseSchema)(
        first
      )
      assert.equal(first.status, 200)
      assert.equal(
        firstBody.requestID,
        "8d758ae5-705c-4e1b-a62f-0defe5b830a5"
      )
      assert.equal(firstBody.transcript, "Hello from Effect.")

      const replay = yield* client.execute(makeTranscriptionRequest(makeAudio()))
      const replayBody = yield* HttpClientResponse.schemaBodyJson(ResponseSchema)(
        replay
      )
      assert.equal(replay.status, 200)
      assert.equal(replay.headers["x-hex-idempotent-replay"], "true")
      assert.deepEqual(replayBody, firstBody)

      const conflict = yield* client.execute(
        makeTranscriptionRequest(makeAudio(1))
      )
      assert.equal(conflict.status, 409)
    }).pipe(Effect.provide(testLayer), Effect.scoped)
  )
})
