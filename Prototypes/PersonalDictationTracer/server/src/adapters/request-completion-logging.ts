import {
  HttpMiddleware,
  HttpServerError,
  HttpServerRequest
} from "@effect/platform"
import { Cause, Clock, Effect, Exit, Option } from "effect"

import { Transcription } from "../application/transcription.js"
import { MaxAudioBytes } from "../domain/captured-audio.js"
import { elapsedMilliseconds } from "../monotonic-timing.js"
import {
  recordRequestCompletion,
  type RequestOutcome,
  withContentFreeSpan
} from "../observability.js"
import { ServiceVersion, type ServiceRevision } from "../service-metadata.js"

type BoundedRoute = "/health" | "/v1/transcribe" | "unmatched"
type BoundedMethod = "GET" | "POST" | "other"

// Diagnostic-only status for a request that ended before any response existed.
const InterruptedRequestStatus = 499

const methodFor = (method: string): BoundedMethod => {
  switch (method) {
    case "GET":
    case "POST":
      return method
    default:
      return "other"
  }
}

const routeFor = (requestURL: string): BoundedRoute => {
  const delimiterIndex = requestURL.search(/[?#]/)
  const path =
    delimiterIndex === -1 ? requestURL : requestURL.slice(0, delimiterIndex)
  switch (path) {
    case "/health":
    case "/v1/transcribe":
      return path
    default:
      return "unmatched"
  }
}

const safeContentLength = (header: string | undefined): number | undefined => {
  if (header === undefined) {
    return undefined
  }
  const value = Number(header)
  return Number.isSafeInteger(value) && value >= 0 && value <= MaxAudioBytes
    ? value
    : undefined
}

const outcomeFor = (
  status: number,
  retryAfter: string | undefined
): RequestOutcome => {
  if (status >= 200 && status < 300) {
    return "success"
  }
  switch (status) {
    case 400:
      return "invalid_request"
    case 401:
      return "unauthorized"
    case 404:
      return "not_found"
    case 409:
      return "request_conflict"
    case 415:
      return "unsupported_media_type"
    case InterruptedRequestStatus:
      return "interrupted"
    case 502:
      return "recognition_unavailable"
    case 503:
      return retryAfter === undefined ? "unavailable" : "busy"
    case 504:
      return "deadline_exceeded"
    default:
      return status >= 500 ? "internal_error" : "request_rejected"
  }
}

const statusClassFor = (
  status: number
): "2xx" | "4xx" | "5xx" | "other" => {
  if (status >= 200 && status < 300) return "2xx"
  if (status >= 400 && status < 500) return "4xx"
  if (status >= 500 && status < 600) return "5xx"
  return "other"
}

/** Emits one safe, bounded Effect completion event for every HTTP request. */
export const requestCompletionLogging = (
  serviceBuildRevision: ServiceRevision
) => HttpMiddleware.make((httpApp) =>
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest
    const transcription = yield* Transcription
    const startedAt = yield* Clock.currentTimeNanos
    const route = routeFor(request.url)
    const method = methodFor(request.method)
    const observedRequest = httpApp.pipe(
      Effect.onExit((result) =>
        Effect.gen(function* () {
          const finishedAt = yield* Clock.currentTimeNanos
          const response = Exit.isSuccess(result)
            ? Option.some(result.value)
            : Cause.isInterrupted(result.cause)
              ? Option.none()
              : Option.some(
                  yield* HttpServerError.causeResponse(result.cause).pipe(
                    Effect.map(([failureResponse]) => failureResponse)
                  )
                )
          const status = Option.isSome(response)
            ? response.value.status
            : InterruptedRequestStatus
          const retryAfter = Option.isSome(response)
            ? response.value.headers["retry-after"]
            : undefined
          const replayHeader = Option.isSome(response)
            ? response.value.headers["x-hex-idempotent-replay"]
            : undefined
          const replayed =
            replayHeader === "true"
              ? true
              : replayHeader === "false"
                ? false
                : undefined
          const contentLength = safeContentLength(
            request.headers["content-length"]
          )
          const annotations = {
            event: "http_request_completed",
            method,
            route,
            status,
            outcome: outcomeFor(status, retryAfter),
            duration_ms: elapsedMilliseconds(startedAt, finishedAt),
            runtime: transcription.runtime,
            model: transcription.model,
            service_version: ServiceVersion,
            service_revision: serviceBuildRevision,
            runtime_revision: transcription.runtimeRevision,
            model_revision: transcription.modelRevision,
            model_sha256: transcription.modelSHA256,
            ...(contentLength === undefined
              ? {}
              : { content_length: contentLength }),
            ...(replayed === undefined ? {} : { replayed })
          }
          const completionLog = Effect.annotateLogs(
            status >= 500
              ? Effect.logError("http_request_completed")
              : Effect.logInfo("http_request_completed"),
            annotations
          )

          yield* Effect.annotateCurrentSpan({
            "http.response.status_code": status,
            "hex.outcome": annotations.outcome,
            "hex.replayed": replayed ?? "unknown",
            "hex.duration_ms": annotations.duration_ms
          })
          yield* recordRequestCompletion({
            route,
            method,
            outcome: annotations.outcome,
            statusClass: statusClassFor(status),
            replayed,
            durationMilliseconds: annotations.duration_ms
          })
          yield* completionLog
        })
      )
    )
    return yield* withContentFreeSpan(
      "hex.http.request",
      observedRequest,
      {
        "http.request.method": method,
        "http.route": route,
        "service.version": ServiceVersion,
        "service.revision": serviceBuildRevision
      },
      "server"
    )
  })
)
