import {
  HttpRouter,
  HttpServerRequest,
  HttpServerResponse
} from "@effect/platform"
import { createHash } from "node:crypto"
import { Effect, Option, Schema } from "effect"

import { Transcription } from "../application/transcription.js"
import { MaxAudioBytes, parseCapturedAudio } from "../domain/captured-audio.js"
import { parseRequestId } from "../domain/request-id.js"
import { BearerAuthenticator } from "./bearer-authenticator.js"

class InvalidRequestError extends Schema.TaggedError<InvalidRequestError>()(
  "InvalidRequestError",
  { reason: Schema.String }
) {}

class UnsupportedMediaTypeError extends Schema.TaggedError<UnsupportedMediaTypeError>()(
  "UnsupportedMediaTypeError",
  { reason: Schema.String }
) {}

const jsonResponse = (
  status: number,
  body: unknown,
  headers?: Readonly<Record<string, string>>
) =>
  HttpServerResponse.json(body, {
    status,
    headers: { "cache-control": "no-store", ...headers }
  }).pipe(Effect.orDie)

const errorResponse = (status: number, error: string) =>
  jsonResponse(status, { error })

const authorizeRequest = Effect.gen(function* () {
  const request = yield* HttpServerRequest.HttpServerRequest
  const authenticator = yield* BearerAuthenticator
  yield* authenticator.authorize(request.headers.authorization ?? "")
})

const parseContentLength = (header: string | undefined) => {
  if (header === undefined) {
    return Effect.succeed(undefined)
  }
  const length = Number(header)
  return Number.isInteger(length) && length >= 44 && length <= MaxAudioBytes
    ? Effect.succeed(length)
    : Effect.fail(
        new InvalidRequestError({ reason: "invalid WAV body size" })
      )
}

const healthHandler = Effect.gen(function* () {
  yield* authorizeRequest
  const transcription = yield* Transcription
  const ready = yield* transcription.isReady
  return yield* jsonResponse(ready ? 200 : 503, {
    status: ready ? "ready" : "starting",
    runtime: transcription.runtime,
    model: transcription.model
  })
})

const transcribeHandler = Effect.gen(function* () {
  yield* authorizeRequest
  const request = yield* HttpServerRequest.HttpServerRequest
  const transcription = yield* Transcription

  const requestID = yield* parseRequestId(
    request.headers["x-hex-request-id"] ?? ""
  ).pipe(
    Effect.mapError(
      () =>
        new InvalidRequestError({
          reason: "X-Hex-Request-ID must be a UUID"
        })
    )
  )

  const mediaType = (request.headers["content-type"] ?? "")
    .split(";", 1)[0]
    ?.trim()
    .toLowerCase()
  if (mediaType !== "audio/wav") {
    return yield* new UnsupportedMediaTypeError({
      reason: "audio/wav required"
    })
  }

  const expectedLength = yield* parseContentLength(
    request.headers["content-length"]
  )
  const body = yield* request.arrayBuffer.pipe(
    HttpServerRequest.withMaxBodySize(Option.some(MaxAudioBytes)),
    Effect.mapError(
      () => new InvalidRequestError({ reason: "malformed WAV body" })
    )
  )
  const bytes = new Uint8Array(body)
  if (expectedLength !== undefined && bytes.byteLength !== expectedLength) {
    return yield* new InvalidRequestError({ reason: "malformed WAV body" })
  }

  const audio = yield* parseCapturedAudio(bytes)
  const audioDigest = createHash("sha256").update(bytes).digest("hex")
  const result = yield* transcription.transcribe({
    requestID,
    audio,
    audioDigest
  })
  const replayHeaders = result.replayed
    ? { "x-hex-idempotent-replay": "true" }
    : undefined
  return yield* jsonResponse(200, result.response, replayHeaders)
})

/** The authenticated HTTP API consumed by the personal iOS keyboard app. */
export const httpApi = HttpRouter.empty.pipe(
  HttpRouter.get("/health", healthHandler),
  HttpRouter.post("/v1/transcribe", transcribeHandler),
  HttpRouter.catchTags({
    UnauthorizedError: () => errorResponse(401, "unauthorized"),
    InvalidRequestError: (error) => errorResponse(400, error.reason),
    InvalidAudioError: (error) => errorResponse(400, error.reason),
    UnsupportedMediaTypeError: (error) => errorResponse(415, error.reason),
    RequestIdConflictError: (error) => errorResponse(409, error.reason),
    EmptyTranscriptError: () =>
      errorResponse(502, "transcription runtime returned no transcript"),
    SpeechRecognitionUnavailableError: () =>
      errorResponse(502, "transcription runtime unavailable")
  })
)
