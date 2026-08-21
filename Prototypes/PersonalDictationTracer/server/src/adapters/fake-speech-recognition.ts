import { Effect, Layer } from "effect"

import { SpeechRecognition } from "../application/speech-recognition.js"

/** Builds a deterministic recognition adapter for local contract tests. */
export const fakeSpeechRecognitionLayer = (
  transcript: string
): Layer.Layer<SpeechRecognition> =>
  Layer.succeed(SpeechRecognition, {
    transcribe: () =>
      Effect.succeed({ transcript, upstreamMilliseconds: 0 }),
    isReady: Effect.succeed(true),
    runtime: "fake",
    model: "nvidia/parakeet-tdt-0.6b-v2"
  })
