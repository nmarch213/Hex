import { NodeHttpClient, NodeRuntime } from "@effect/platform-node"
import { Effect, Layer, Logger } from "effect"

import { parakeetSpeechRecognitionLayer } from "./adapters/parakeet-speech-recognition.js"
import { launchNodeServer } from "./node-server.js"
import { productionConfiguration } from "./runtime-config.js"
import { observabilityLayer } from "./observability.js"

const program = Effect.gen(function* () {
  const config = yield* productionConfiguration
  const recognitionLayer = parakeetSpeechRecognitionLayer(
    config.upstreamURL
  ).pipe(
    Layer.provide(NodeHttpClient.layer)
  )
  // Runtime-modifying layers must be composed sequentially. Concurrently
  // merging them isolates their fiber-local logger and telemetry patches.
  const runtimeLayer = observabilityLayer(
    config.observability,
    config.serviceBuildRevision
  ).pipe(Layer.provide(Logger.json))
  return yield* launchNodeServer(config, recognitionLayer, runtimeLayer)
})

NodeRuntime.runMain(program, { disablePrettyLogger: true })
