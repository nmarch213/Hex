import { HttpServer } from "@effect/platform"
import {
  NodeHttpClient,
  NodeHttpServer,
  NodeRuntime
} from "@effect/platform-node"
import { Config, Effect, Layer, Option } from "effect"
import { createServer } from "node:http"

import { Transcription } from "./application/transcription.js"
import { bearerAuthenticatorLayer } from "./adapters/bearer-authenticator.js"
import { fakeSpeechRecognitionLayer } from "./adapters/fake-speech-recognition.js"
import { httpApi } from "./adapters/http-api.js"
import { parakeetSpeechRecognitionLayer } from "./adapters/parakeet-speech-recognition.js"

const configuration = Config.all({
  host: Config.nonEmptyString("HEX_LISTEN_HOST").pipe(
    Config.withDefault("0.0.0.0")
  ),
  port: Config.port("HEX_LISTEN_PORT").pipe(Config.withDefault(8787)),
  token: Config.redacted(Config.nonEmptyString("HEX_PROXY_TOKEN")),
  upstreamURL: Config.url("HEX_UPSTREAM_URL").pipe(
    Config.withDefault(
      new URL("http://127.0.0.1:8080/v1/audio/transcriptions")
    )
  ),
  fakeTranscript: Config.string("HEX_FAKE_TRANSCRIPT").pipe(Config.option)
})

const program = Effect.gen(function* () {
  const config = yield* configuration
  const recognitionLayer = Option.match(config.fakeTranscript, {
    onNone: () =>
      parakeetSpeechRecognitionLayer(config.upstreamURL).pipe(
        Layer.provide(NodeHttpClient.layer)
      ),
    onSome: fakeSpeechRecognitionLayer
  })
  const transcriptionLayer = Transcription.Default.pipe(
    Layer.provide(recognitionLayer)
  )
  const applicationServices = Layer.merge(
    transcriptionLayer,
    bearerAuthenticatorLayer(config.token)
  )
  const serverLayer = NodeHttpServer.layer(() => createServer(), {
    host: config.host,
    port: config.port
  })
  const application = httpApi.pipe(
    HttpServer.serve(),
    HttpServer.withLogAddress,
    Layer.provide(applicationServices),
    Layer.provide(serverLayer)
  )

  return yield* Layer.launch(application)
})

NodeRuntime.runMain(program)
