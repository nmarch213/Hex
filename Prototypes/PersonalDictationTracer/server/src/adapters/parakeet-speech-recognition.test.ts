import {
  HttpRouter,
  HttpServer,
  HttpServerResponse
} from "@effect/platform"
import { NodeHttpServer } from "@effect/platform-node"
import assert from "node:assert/strict"
import test from "node:test"

import { Effect, Layer } from "effect"

import { SpeechRecognition } from "../application/speech-recognition.js"
import { parakeetSpeechRecognitionLayer } from "./parakeet-speech-recognition.js"

const upstream = HttpRouter.empty.pipe(
  HttpRouter.get(
    "/health",
    HttpServerResponse.json({ status: "ok" }).pipe(Effect.orDie)
  ),
  HttpRouter.post(
    "/v1/audio/transcriptions",
    HttpServerResponse.json({ text: "Recognized upstream." }).pipe(Effect.orDie)
  )
)

test("translates the parakeet.cpp HTTP response through the recognition port", async () => {
  const testLayer = parakeetSpeechRecognitionLayer(
    "/v1/audio/transcriptions"
  ).pipe(
    Layer.provideMerge(NodeHttpServer.layerTest)
  )

  await Effect.runPromise(
    Effect.gen(function* () {
      yield* HttpServer.serveEffect(upstream)
      const recognition = yield* SpeechRecognition
      const result = yield* recognition.transcribe({
        bytes: new TextEncoder().encode("test audio")
      })

      assert.equal(result.transcript, "Recognized upstream.")
      assert.equal(result.upstreamMilliseconds >= 0, true)
      assert.equal(yield* recognition.isReady, true)
    }).pipe(Effect.provide(testLayer), Effect.scoped)
  )
})

test("reports not ready when the upstream health contract is absent", async () => {
  const testLayer = parakeetSpeechRecognitionLayer(
    "/v1/audio/transcriptions"
  ).pipe(Layer.provideMerge(NodeHttpServer.layerTest))

  await Effect.runPromise(
    Effect.gen(function* () {
      yield* HttpServer.serveEffect(HttpRouter.empty)
      const recognition = yield* SpeechRecognition

      assert.equal(yield* recognition.isReady, false)
    }).pipe(Effect.provide(testLayer), Effect.scoped)
  )
})
