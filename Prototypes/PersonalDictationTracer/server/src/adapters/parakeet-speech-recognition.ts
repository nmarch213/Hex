import {
  HttpClient,
  HttpClientRequest,
  HttpClientResponse
} from "@effect/platform"
import { Clock, Effect, Layer, Schema } from "effect"

import {
  SpeechRecognition,
  SpeechRecognitionUnavailableError
} from "../application/speech-recognition.js"
import type { CapturedAudio } from "../domain/captured-audio.js"

const UpstreamResponseSchema = Schema.Struct({ text: Schema.String })
const UpstreamHealthSchema = Schema.Struct({ status: Schema.Literal("ok") })

const healthURLFor = (upstreamURL: string | URL): string | URL =>
  typeof upstreamURL === "string" && upstreamURL.startsWith("/")
    ? "/health"
    : new URL("/health", upstreamURL)

/** Builds the outbound HTTP adapter for the parakeet.cpp transcription endpoint. */
export const parakeetSpeechRecognitionLayer = (
  upstreamURL: string | URL
): Layer.Layer<SpeechRecognition, never, HttpClient.HttpClient> =>
  Layer.effect(
    SpeechRecognition,
    Effect.gen(function* () {
      const client = yield* HttpClient.HttpClient
      const healthURL = healthURLFor(upstreamURL)

      const runTranscription =
        Effect.fn("ParakeetSpeechRecognition.transcribe")(function* (
          audio: CapturedAudio
        ) {
          const startedAt = yield* Clock.currentTimeMillis
          const formData = new FormData()
          formData.append(
            "file",
            new Blob([new Uint8Array(audio.bytes)], { type: "audio/wav" }),
            "audio.wav"
          )
          formData.append("response_format", "json")

          const request = HttpClientRequest.post(upstreamURL).pipe(
            HttpClientRequest.bodyFormData(formData)
          )
          const response = yield* client.execute(request)
          const successfulResponse = yield* HttpClientResponse.filterStatusOk(
            response
          )
          const payload = yield* HttpClientResponse.schemaBodyJson(
            UpstreamResponseSchema
          )(successfulResponse)
          const finishedAt = yield* Clock.currentTimeMillis

          return {
            transcript: payload.text,
            upstreamMilliseconds: Math.max(
              0,
              Math.round(finishedAt - startedAt)
            )
          }
        })

      const transcribe = (audio: CapturedAudio) =>
        runTranscription(audio).pipe(
          Effect.timeout("80 seconds"),
          Effect.mapError(
            () =>
              new SpeechRecognitionUnavailableError({
                reason: "parakeet.cpp transcription endpoint unavailable"
              })
          )
        )

      const isReady = client.get(healthURL).pipe(
        Effect.timeout("1 second"),
        Effect.flatMap(HttpClientResponse.filterStatusOk),
        Effect.flatMap(HttpClientResponse.schemaBodyJson(UpstreamHealthSchema)),
        Effect.as(true),
        Effect.catchAll(() => Effect.succeed(false))
      )

      return {
        transcribe,
        isReady,
        runtime: "parakeet.cpp",
        model: "nvidia/parakeet-tdt-0.6b-v2"
      }
    })
  )
