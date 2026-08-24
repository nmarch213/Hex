import {
  HttpClient,
  HttpClientRequest,
  HttpClientResponse,
  HttpIncomingMessage
} from "@effect/platform"
import { Clock, Effect, Layer, Option, Schema } from "effect"

import {
  SpeechRecognition,
  SpeechRecognitionUnavailableError
} from "../application/speech-recognition.js"
import type { CapturedAudio } from "../domain/captured-audio.js"
import { elapsedMilliseconds } from "../monotonic-timing.js"
import { observeStage } from "../observability.js"
import {
  ParakeetModelRevision,
  ParakeetModelSHA256,
  ParakeetRuntimeImageDigest
} from "../service-metadata.js"

const UpstreamResponseSchema = Schema.Struct({ text: Schema.String })
const UpstreamHealthSchema = Schema.Struct({ status: Schema.Literal("ok") })
const MaximumUpstreamResponseBytes = 1_048_576
const MaximumUpstreamHealthResponseBytes = 4_096

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
      // The default platform client span records full URLs and headers. The
      // adapter emits bounded spans that never contain transport metadata.
      const client = HttpClient.withTracerDisabledWhen(
        yield* HttpClient.HttpClient,
        () => true
      )
      const healthURL = healthURLFor(upstreamURL)

      const runTranscription =
        Effect.fnUntraced(function* (
          audio: CapturedAudio
        ) {
          const startedAt = yield* Clock.currentTimeNanos
          const formData = yield* observeStage(
            "recognition_prepare",
            Effect.sync(() => {
              const prepared = new FormData()
              prepared.append(
                "file",
                new Blob([audio.toUint8Array()], {
                  type: "audio/wav"
                }),
                "audio.wav"
              )
              prepared.append("response_format", "json")
              return prepared
            })
          )

          const request = HttpClientRequest.post(upstreamURL).pipe(
            HttpClientRequest.bodyFormData(formData)
          )
          const unknownCompletion = () =>
            new SpeechRecognitionUnavailableError({
              reason: "parakeet.cpp completion is unknown",
              completion: "unknown"
            })
          const settledFailure = () =>
            new SpeechRecognitionUnavailableError({
              reason: "parakeet.cpp returned an unusable response",
              completion: "settled"
            })
          const response = yield* observeStage(
            "recognition_upstream",
            client.execute(request).pipe(
              Effect.timeoutFail({
                duration: "80 seconds",
                onTimeout: unknownCompletion
              }),
              Effect.mapError(unknownCompletion)
            )
          )
          // parakeet.cpp constructs its response only after synchronous
          // inference returns. From this point forward the native call is known
          // to have settled, even if status/body validation fails.
          const payload = yield* observeStage(
            "recognition_decode",
            HttpClientResponse.filterStatusOk(response).pipe(
              Effect.flatMap((successfulResponse) =>
                HttpClientResponse.schemaBodyJson(UpstreamResponseSchema)(
                  successfulResponse
                ).pipe(
                  HttpIncomingMessage.withMaxBodySize(
                    Option.some(MaximumUpstreamResponseBytes)
                  )
                )
              ),
              Effect.timeoutFail({
                duration: "4 seconds",
                onTimeout: settledFailure
              }),
              Effect.mapError(settledFailure)
            )
          )
          const finishedAt = yield* Clock.currentTimeNanos

          return {
            transcript: payload.text,
            upstreamMilliseconds: elapsedMilliseconds(startedAt, finishedAt)
          }
        })

      const transcribe = (audio: CapturedAudio) => runTranscription(audio)

      const isReady = client.get(healthURL).pipe(
        Effect.flatMap(HttpClientResponse.filterStatusOk),
        Effect.flatMap((response) =>
          HttpClientResponse.schemaBodyJson(UpstreamHealthSchema)(response).pipe(
            HttpIncomingMessage.withMaxBodySize(
              Option.some(MaximumUpstreamHealthResponseBytes)
            )
          )
        ),
        Effect.timeout("1 second"),
        Effect.as(true),
        Effect.catchAll(() => Effect.succeed(false))
      )

      return {
        transcribe,
        isReady,
        runtime: "parakeet.cpp",
        model: "nvidia/parakeet-tdt-0.6b-v2",
        runtimeRevision: ParakeetRuntimeImageDigest,
        modelRevision: ParakeetModelRevision,
        modelSHA256: ParakeetModelSHA256
      }
    })
  )
