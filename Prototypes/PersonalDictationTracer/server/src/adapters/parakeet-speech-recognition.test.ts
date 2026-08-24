import {
  HttpRouter,
  HttpServer,
  HttpServerResponse
} from "@effect/platform"
import { NodeHttpClient, NodeHttpServer } from "@effect/platform-node"
import assert from "node:assert/strict"
import { createServer } from "node:http"
import test from "node:test"

import { Effect, Layer } from "effect"

import { SpeechRecognition } from "../application/speech-recognition.js"
import { parseCapturedAudio } from "../domain/captured-audio.js"
import { parakeetSpeechRecognitionLayer } from "./parakeet-speech-recognition.js"

const makeAudio = (): Uint8Array => {
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
  return bytes
}

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
      const audio = yield* parseCapturedAudio(makeAudio())
      const result = yield* recognition.transcribe(audio)

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

test("bounds the upstream transcription response before JSON parsing", async () => {
  const oversizedUpstream = HttpRouter.empty.pipe(
    HttpRouter.post(
      "/v1/audio/transcriptions",
      HttpServerResponse.json({ text: "x".repeat(1_100_000) }).pipe(
        Effect.orDie
      )
    )
  )
  const testLayer = parakeetSpeechRecognitionLayer(
    "/v1/audio/transcriptions"
  ).pipe(Layer.provideMerge(NodeHttpServer.layerTest))

  await Effect.runPromise(
    Effect.gen(function* () {
      yield* HttpServer.serveEffect(oversizedUpstream)
      const recognition = yield* SpeechRecognition
      const audio = yield* parseCapturedAudio(makeAudio())
      const result = yield* recognition.transcribe(audio).pipe(Effect.either)

      assert.equal(result._tag, "Left")
      if (result._tag === "Left") {
        assert.equal(result.left._tag, "SpeechRecognitionUnavailableError")
        assert.equal(result.left.completion, "settled")
      }
    }).pipe(Effect.provide(testLayer), Effect.scoped)
  )
})

test("marks an upstream HTTP failure as known settled", async () => {
  const failingUpstream = HttpRouter.empty.pipe(
    HttpRouter.post(
      "/v1/audio/transcriptions",
      HttpServerResponse.json(
        { error: "inference failed" },
        { status: 500 }
      ).pipe(Effect.orDie)
    )
  )
  const testLayer = parakeetSpeechRecognitionLayer(
    "/v1/audio/transcriptions"
  ).pipe(Layer.provideMerge(NodeHttpServer.layerTest))

  await Effect.runPromise(
    Effect.gen(function* () {
      yield* HttpServer.serveEffect(failingUpstream)
      const recognition = yield* SpeechRecognition
      const audio = yield* parseCapturedAudio(makeAudio())
      const result = yield* recognition.transcribe(audio).pipe(Effect.either)

      assert.equal(result._tag, "Left")
      if (result._tag === "Left") {
        assert.equal(result.left.completion, "settled")
      }
    }).pipe(Effect.provide(testLayer), Effect.scoped)
  )
})

test("reports not ready when the upstream health response exceeds its bound", async () => {
  const oversizedHealthUpstream = HttpRouter.empty.pipe(
    HttpRouter.get(
      "/health",
      HttpServerResponse.json({
        status: "ok",
        padding: "x".repeat(10_000)
      }).pipe(Effect.orDie)
    )
  )
  const testLayer = parakeetSpeechRecognitionLayer(
    "/v1/audio/transcriptions"
  ).pipe(Layer.provideMerge(NodeHttpServer.layerTest))

  await Effect.runPromise(
    Effect.gen(function* () {
      yield* HttpServer.serveEffect(oversizedHealthUpstream)
      const recognition = yield* SpeechRecognition

      assert.equal(yield* recognition.isReady, false)
    }).pipe(Effect.provide(testLayer), Effect.scoped)
  )
})

test("bounds a partial upstream health response that never ends", async () => {
  const partialHealthServer = createServer((_request, response) => {
    response.writeHead(200, { "content-type": "application/json" })
    response.write('{"status":"')
  })
  await new Promise<void>((resolve, reject) => {
    partialHealthServer.once("error", reject)
    partialHealthServer.listen(0, "127.0.0.1", resolve)
  })

  try {
    const address = partialHealthServer.address()
    assert.notEqual(address, null)
    assert.equal(typeof address, "object")
    if (address === null || typeof address === "string") {
      throw new Error("expected an IP socket address")
    }
    const testLayer = parakeetSpeechRecognitionLayer(
      `http://127.0.0.1:${address.port}/v1/audio/transcriptions`
    ).pipe(Layer.provide(NodeHttpClient.layer))

    await Effect.runPromise(
      Effect.gen(function* () {
        const recognition = yield* SpeechRecognition
        assert.equal(yield* recognition.isReady, false)
      }).pipe(
        Effect.provide(testLayer),
        Effect.timeoutFail({
          duration: "2 seconds",
          onTimeout: () => new Error("upstream health body remained unbounded")
        })
      )
    )
  } finally {
    partialHealthServer.closeAllConnections()
    await new Promise<void>((resolve, reject) => {
      partialHealthServer.close((error) => {
        if (error === undefined) {
          resolve()
        } else {
          reject(error)
        }
      })
    })
  }
})
