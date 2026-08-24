import { NodeHttpClient } from "@effect/platform-node"
import * as Otlp from "@effect/opentelemetry/Otlp"
import {
  Duration,
  Effect,
  Exit,
  Layer,
  Metric,
  MetricBoundaries,
  Option,
  type Tracer
} from "effect"

import type { CapturedAudio } from "./domain/captured-audio.js"
import { ServiceVersion, type ServiceRevision } from "./service-metadata.js"

const MillisecondBoundaryValues = [
  1,
  2,
  5,
  10,
  20,
  50,
  100,
  200,
  500,
  1_000,
  2_000,
  5_000,
  10_000,
  20_000,
  40_000,
  80_000,
  90_000
] as const
const MillisecondBoundaries = MetricBoundaries.fromIterable(
  MillisecondBoundaryValues
)

const AudioByteBoundaries = MetricBoundaries.fromIterable([
  64 * 1_024,
  256 * 1_024,
  1 * 1_024 * 1_024,
  4 * 1_024 * 1_024,
  8 * 1_024 * 1_024,
  16 * 1_024 * 1_024,
  20 * 1_024 * 1_024
])
const AudioDurationBoundaries = MetricBoundaries.fromIterable([
  ...MillisecondBoundaryValues,
  120_000,
  180_000,
  240_000,
  300_000
])

const requestCount = Metric.counter("hex_http_server_requests_total", {
  description: "Completed personal dictation HTTP requests",
  incremental: true
})
const requestDuration = Metric.histogram(
  "hex_http_server_duration_ms",
  MillisecondBoundaries,
  "End-to-end server request latency in milliseconds"
).pipe(Metric.tagged("unit", "ms"))
const stageDuration = Metric.histogram(
  "hex_dictation_stage_duration_ms",
  MillisecondBoundaries,
  "Latency of bounded dictation processing stages in milliseconds"
).pipe(Metric.tagged("unit", "ms"))
const audioBytes = Metric.histogram(
  "hex_dictation_audio_bytes",
  AudioByteBoundaries,
  "Validated inbound WAV size in bytes"
).pipe(Metric.tagged("unit", "By"))
const audioDuration = Metric.histogram(
  "hex_dictation_audio_duration_ms",
  AudioDurationBoundaries,
  "Validated inbound recording duration in milliseconds"
).pipe(Metric.tagged("unit", "ms"))

export type RequestOutcome =
  | "success"
  | "invalid_request"
  | "unauthorized"
  | "not_found"
  | "request_conflict"
  | "unsupported_media_type"
  | "interrupted"
  | "recognition_unavailable"
  | "unavailable"
  | "busy"
  | "deadline_exceeded"
  | "internal_error"
  | "request_rejected"

export type TelemetryStage =
  | "authentication"
  | "runtime_readiness"
  | "audio_body_read"
  | "audio_parse"
  | "audio_digest"
  | "idempotency_begin"
  | "inference_admission"
  | "recognition_prepare"
  | "recognition_request"
  | "recognition_upstream"
  | "recognition_decode"
  | "idempotency_complete"
  | "idempotency_abandon"
  | "inference_release"

/** Traces a boundary without exporting its typed failure fields or stack. */
export const withContentFreeSpan = <A, E, R>(
  name: string,
  effect: Effect.Effect<A, E, R>,
  attributes: Readonly<Record<string, string>> = {},
  kind: Tracer.SpanKind = "internal"
): Effect.Effect<A, E, R> =>
  Effect.exit(effect).pipe(
    Effect.tap((exit) =>
      Effect.annotateCurrentSpan(
        "hex.span.outcome",
        Exit.isSuccess(exit) ? "success" : "failure"
      )
    ),
    Effect.withSpan(name, { attributes, kind }),
    Effect.flatMap(
      Exit.matchEffect({
        onFailure: Effect.failCause,
        onSuccess: Effect.succeed
      })
    )
  )

/** Wraps one bounded processing stage in a span and latency histogram. */
export const observeStage = <A, E, R>(
  stage: TelemetryStage,
  effect: Effect.Effect<A, E, R>
): Effect.Effect<A, E, R> =>
  withContentFreeSpan(`hex.dictation.${stage}`, effect, {
    "hex.stage": stage
  }).pipe(
    Metric.trackDurationWith(
      Metric.tagged(stageDuration, "stage", stage),
      Duration.toMillis
    )
  )

/** Records bounded, content-free dimensions for one completed request. */
export const recordRequestCompletion = (input: {
  readonly route: "/health" | "/v1/transcribe" | "unmatched"
  readonly method: "GET" | "POST" | "other"
  readonly outcome: RequestOutcome
  readonly statusClass: "2xx" | "4xx" | "5xx" | "other"
  readonly replayed: boolean | undefined
  readonly durationMilliseconds: number
}) => {
  const replayed =
    input.replayed === undefined ? "unknown" : String(input.replayed)
  const labels = [
    ["route", input.route],
    ["method", input.method],
    ["outcome", input.outcome],
    ["status_class", input.statusClass],
    ["replayed", replayed]
  ] as const
  const taggedCount = labels.reduce(
    (metric, [key, value]) => Metric.tagged(metric, key, value),
    requestCount
  )
  const taggedDuration = labels.reduce(
    (metric, [key, value]) => Metric.tagged(metric, key, value),
    requestDuration
  )
  return Effect.all(
    [
      Metric.increment(taggedCount),
      Metric.update(taggedDuration, input.durationMilliseconds)
    ],
    { discard: true }
  )
}

/** Records numeric recording shape without retaining audio or transcript content. */
export const recordValidatedAudio = (audio: CapturedAudio) =>
  Effect.all(
    [
      Metric.update(audioBytes, audio.byteLength),
      Metric.update(audioDuration, audio.durationMilliseconds)
    ],
    { discard: true }
  )

/** Optional OTLP export configuration selected by the composition root. */
export interface ObservabilityConfiguration {
  readonly otlpBaseURL: Option.Option<URL>
  readonly environment: "production" | "development"
}

/**
 * Adds the Effect-native OTLP exporter without making request handling depend
 * on collector availability. The exporter batches in background and drops
 * while its circuit breaker is open.
 */
export const observabilityLayer = (
  config: ObservabilityConfiguration,
  serviceRevision: ServiceRevision
): Layer.Layer<never> =>
  Option.match(config.otlpBaseURL, {
    onNone: () => Layer.empty,
    onSome: (baseURL) =>
      Otlp.layerProtobuf({
        baseUrl: baseURL.toString().replace(/\/$/, ""),
        resource: {
          serviceName: "hex-personal-dictation",
          serviceVersion: ServiceVersion,
          attributes: {
            "deployment.environment.name": config.environment,
            "service.revision": serviceRevision
          }
        },
        maxBatchSize: 256,
        loggerExcludeLogSpans: true,
        loggerExportInterval: "1 second",
        metricsExportInterval: "5 seconds",
        tracerExportInterval: "1 second",
        shutdownTimeout: "3 seconds"
      }).pipe(Layer.provide(NodeHttpClient.layer))
  })
