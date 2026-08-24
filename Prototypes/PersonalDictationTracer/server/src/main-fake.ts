import { NodeRuntime } from "@effect/platform-node"
import { Effect, Layer, Logger } from "effect"

import { fakeSpeechRecognitionLayer } from "./adapters/fake-speech-recognition.js"
import { launchNodeServer } from "./node-server.js"
import { fakeConfiguration } from "./runtime-config.js"
import { observabilityLayer } from "./observability.js"

const program = Effect.gen(function* () {
  const config = yield* fakeConfiguration
  const runtimeLayer = observabilityLayer(
    config.observability,
    config.serviceBuildRevision
  ).pipe(Layer.provide(Logger.json))
  return yield* launchNodeServer(
    config,
    fakeSpeechRecognitionLayer(config.fakeTranscript),
    runtimeLayer
  )
})

NodeRuntime.runMain(program, { disablePrettyLogger: true })
