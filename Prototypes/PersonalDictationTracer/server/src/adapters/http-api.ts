import {
  HttpRouter,
  HttpServerRequest,
  HttpServerResponse
} from "@effect/platform"
import { createHash } from "node:crypto"
import { Duration, Effect, Option, Schema } from "effect"

import { DeviceAuthentication } from "../application/device-authentication.js"
import { Transcription } from "../application/transcription.js"
import { parseAudioDigest } from "../domain/audio-digest.js"
import {
  MaxAudioBytes,
  MinAudioBytes,
  parseCapturedAudio
} from "../domain/captured-audio.js"
import { parseRequestId } from "../domain/request-id.js"
import type { DeviceCapability } from "../domain/device-principal.js"
import { InboundAudioAdmission } from "./inbound-audio-admission.js"
import { requestCompletionLogging } from "./request-completion-logging.js"
import { ServiceVersion, type ServiceRevision } from "../service-metadata.js"
import {
  observeStage,
  recordValidatedAudio,
  setRequestAudioDurationBucket,
  withContentFreeSpan
} from "../observability.js"

const RequestBodyDeadline = Duration.seconds(30)
// Leave room for the 80-second upstream ceiling while responding before the
// iOS client's 90-second request deadline.
const RequestHandlerDeadline = Duration.seconds(85)

class InvalidRequestError extends Schema.TaggedError<InvalidRequestError>()(
  "InvalidRequestError",
  { reason: Schema.String }
) {}

class UnsupportedMediaTypeError extends Schema.TaggedError<UnsupportedMediaTypeError>()(
  "UnsupportedMediaTypeError",
  { reason: Schema.String }
) {}

class LengthRequiredError extends Schema.TaggedError<LengthRequiredError>()(
  "LengthRequiredError",
  { reason: Schema.String }
) {}

class RequestDeadlineExceededError extends Schema.TaggedError<RequestDeadlineExceededError>()(
  "RequestDeadlineExceededError",
  { phase: Schema.Literal("body", "handler") }
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

const errorResponse = (
  status: number,
  error: string,
  headers?: Readonly<Record<string, string>>
) => jsonResponse(status, { error }, headers)

const authorizeRequest = (requiredCapability: DeviceCapability) =>
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest
    const authentication = yield* DeviceAuthentication
    return yield* observeStage(
      "authentication",
      authentication.authenticate(
        request.headers.authorization ?? "",
        requiredCapability
      ).pipe((effect) =>
        withContentFreeSpan(
          "hex.authentication.resolve",
          effect,
          { "hex.required_capability": requiredCapability }
        )
      )
    )
  })

const parseContentLength = (header: string | undefined) => {
  if (header === undefined) {
    return Effect.fail(
      new LengthRequiredError({ reason: "Content-Length is required" })
    )
  }
  const length = Number(header)
  return /^(0|[1-9][0-9]*)$/.test(header) &&
    Number.isSafeInteger(length) &&
    length >= MinAudioBytes &&
    length <= MaxAudioBytes
    ? Effect.succeed(length)
    : Effect.fail(
        new InvalidRequestError({ reason: "invalid WAV body size" })
      )
}

const healthHandler = (serviceBuildRevision: ServiceRevision) =>
  Effect.gen(function* () {
    yield* authorizeRequest("service:health")
    const transcription = yield* Transcription
    const ready = yield* transcription.isReady
    return yield* jsonResponse(ready ? 200 : 503, {
      status: ready ? "ready" : "starting",
      runtime: transcription.runtime,
      model: transcription.model,
      serviceVersion: ServiceVersion,
      serviceRevision: serviceBuildRevision,
      runtimeRevision: transcription.runtimeRevision,
      modelRevision: transcription.modelRevision,
      modelSHA256: transcription.modelSHA256
    })
  })

const transcribeHandler = Effect.gen(function* () {
  const authenticatedDevice = yield* authorizeRequest("dictation:write")
  const request = yield* HttpServerRequest.HttpServerRequest
  const transcription = yield* Transcription
  const inboundAdmission = yield* InboundAudioAdmission

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
  return yield* inboundAdmission.run(
    Effect.gen(function* () {
      const body = yield* observeStage(
        "audio_body_read",
        request.arrayBuffer.pipe(
          HttpServerRequest.withMaxBodySize(Option.some(MaxAudioBytes)),
          Effect.mapError(
            () => new InvalidRequestError({ reason: "malformed WAV body" })
          ),
          Effect.timeoutFail({
            duration: RequestBodyDeadline,
            onTimeout: () =>
              new RequestDeadlineExceededError({ phase: "body" })
          })
        )
      )
      const bytes = new Uint8Array(body)
      if (bytes.byteLength !== expectedLength) {
        return yield* new InvalidRequestError({
          reason: "malformed WAV body"
        })
      }

      const audio = yield* observeStage(
        "audio_parse",
        parseCapturedAudio(bytes)
      )
      yield* Effect.annotateCurrentSpan({
        "hex.audio.bytes": audio.byteLength,
        "hex.audio.duration_ms": audio.durationMilliseconds
      })
      yield* recordValidatedAudio(audio)
      yield* setRequestAudioDurationBucket(audio)
      // Node's SHA-256 hex projection is lowercase and exactly 64 characters. A
      // schema failure here would therefore indicate a broken runtime invariant.
      const audioDigest = yield* observeStage(
        "audio_digest",
        parseAudioDigest(
          createHash("sha256").update(bytes).digest("hex")
        ).pipe(Effect.orDie)
      )
      const result = yield* transcription.transcribe({
        devicePrincipalID: authenticatedDevice.principal.id,
        requestID,
        audio,
        audioDigest
      }).pipe((effect) =>
        withContentFreeSpan("hex.dictation.process", effect)
      )
      const replayHeaders = {
        "x-hex-idempotent-replay": String(result.replayed)
      }
      return yield* jsonResponse(200, result.response, replayHeaders)
    })
  )
}).pipe(
  Effect.timeoutFail({
    duration: RequestHandlerDeadline,
    onTimeout: () => new RequestDeadlineExceededError({ phase: "handler" })
  })
)

const busyResponse = (retryAfterSeconds: number) =>
  errorResponse(503, "transcription busy", {
    "retry-after": String(retryAfterSeconds)
  })

/** The authenticated HTTP API consumed by the personal iOS keyboard app. */
const routes = (serviceBuildRevision: ServiceRevision) =>
  HttpRouter.empty.pipe(
    HttpRouter.get("/health", healthHandler(serviceBuildRevision)),
    HttpRouter.post("/v1/transcribe", transcribeHandler),
    HttpRouter.catchTags({
      UnauthorizedError: () =>
        errorResponse(401, "unauthorized", {
          "www-authenticate": "Bearer realm=\"hex-personal-dictation\""
        }),
      DeviceAuthenticationUnavailableError: () =>
        errorResponse(503, "device authentication unavailable"),
      InvalidRequestError: (error) => errorResponse(400, error.reason),
      InvalidAudioError: (error) => errorResponse(400, error.reason),
      UnsupportedMediaTypeError: (error) =>
        errorResponse(415, error.reason),
      LengthRequiredError: (error) => errorResponse(411, error.reason),
      RequestIdConflictError: (error) => errorResponse(409, error.reason),
      InboundAudioBusyError: (error) =>
        busyResponse(error.retryAfterSeconds),
      TranscriptionBusyError: (error) =>
        busyResponse(error.retryAfterSeconds),
      TranscriptionNotReadyError: () =>
        errorResponse(503, "transcription runtime not ready"),
      TranscriptionClaimLostError: () => busyResponse(1),
      TranscriptionIdempotencyUnavailableError: () =>
        errorResponse(503, "idempotency storage unavailable"),
      RequestDeadlineExceededError: () =>
        errorResponse(504, "request deadline exceeded"),
      EmptyTranscriptError: () =>
        errorResponse(502, "transcription runtime returned no transcript"),
      TranscriptTooLargeError: () =>
        errorResponse(502, "transcription runtime returned too much text"),
      SpeechRecognitionUnavailableError: () =>
        errorResponse(502, "transcription runtime unavailable")
    })
  )

/** The authenticated and completion-logged HTTP application. */
export const httpApi = (serviceBuildRevision: ServiceRevision) =>
  requestCompletionLogging(serviceBuildRevision)(
    routes(serviceBuildRevision)
  )
