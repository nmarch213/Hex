import {
  Cause,
  Clock,
  Effect,
  Exit,
  Fiber,
  FiberSet,
  Option,
  Ref,
  Schema
} from "effect"

import {
  SpeechRecognition,
  SpeechRecognitionUnavailableError
} from "./speech-recognition.js"
import {
  TranscriptionIdempotency,
  type TranscriptionClaim
} from "./transcription-idempotency.js"
import type { AudioDigest } from "../domain/audio-digest.js"
import type { CapturedAudio } from "../domain/captured-audio.js"
import type { DevicePrincipalId } from "../domain/device-principal.js"
import { RequestIdSchema, type RequestId } from "../domain/request-id.js"
import { elapsedMilliseconds } from "../monotonic-timing.js"
import {
  observeStage,
  recordRecognitionPerformance
} from "../observability.js"

const MaximumTranscriptCharacters = 100_000

/** A transcription request after transport-level parsing. */
export interface TranscriptionRequest {
  readonly devicePrincipalID: DevicePrincipalId
  readonly requestID: RequestId
  readonly audio: CapturedAudio
  readonly audioDigest: AudioDigest
}

/** Schema for stable timing fields returned to the iOS client. */
export const TranscriptionTimingsSchema = Schema.Struct({
  queueMS: Schema.Number,
  recognitionMS: Schema.Number,
  // Time from application entry through recognition and response preparation.
  // The durable completion transaction follows this measurement and is
  // captured by the idempotency_complete span plus end-to-end HTTP metrics.
  serviceMS: Schema.Number,
  upstreamMS: Schema.Number,
  // Compatibility alias for serviceMS; this is not transport-level latency.
  totalMS: Schema.Number
})

/** Stable timing fields returned to the iOS client. */
export type TranscriptionTimings = Schema.Schema.Type<
  typeof TranscriptionTimingsSchema
>

/** Schema used to verify durable transcription responses when they are read. */
export const TranscriptionResponseSchema = Schema.Struct({
  requestID: RequestIdSchema,
  transcript: Schema.String.pipe(
    Schema.maxLength(MaximumTranscriptCharacters)
  ),
  timings: TranscriptionTimingsSchema
})

/** The stable JSON body returned for a successful transcription. */
export type TranscriptionResponse = Schema.Schema.Type<
  typeof TranscriptionResponseSchema
>

/** A successful response plus transport metadata that is not part of its JSON body. */
export interface TranscriptionResult {
  readonly response: TranscriptionResponse
  readonly replayed: boolean
}

/** Reports an attempt to reuse a request ID for different audio. */
export class RequestIdConflictError extends Schema.TaggedError<RequestIdConflictError>()(
  "RequestIdConflictError",
  { reason: Schema.String }
) {}

/** Reports a runtime response that contained no usable transcript. */
export class EmptyTranscriptError extends Schema.TaggedError<EmptyTranscriptError>()(
  "EmptyTranscriptError",
  { reason: Schema.String }
) {}

/** Reports a runtime response too large for bounded durable retention. */
export class TranscriptTooLargeError extends Schema.TaggedError<TranscriptTooLargeError>()(
  "TranscriptTooLargeError",
  { maximumCharacters: Schema.Number }
) {}

/** Reports that the sole inference slot is already serving another request. */
export class TranscriptionBusyError extends Schema.TaggedError<TranscriptionBusyError>()(
  "TranscriptionBusyError",
  { retryAfterSeconds: Schema.Number }
) {}

/** Reports that the selected recognition runtime cannot accept new work. */
export class TranscriptionNotReadyError extends Schema.TaggedError<TranscriptionNotReadyError>()(
  "TranscriptionNotReadyError",
  { reason: Schema.Literal("recognition_not_ready") }
) {}

// This is longer than the 85-second HTTP waiter deadline and fences request-ID
// takeover. Native inference itself is fenced by a non-expiring process epoch
// because a proxy timeout does not prove Parakeet stopped.
const StaleClaimMilliseconds = 120_000

/** Owns single-inference admission and durable retry/idempotency policy. */
export class Transcription extends Effect.Service<Transcription>()(
  "@hex/personal-dictation/Transcription",
  {
    scoped: Effect.gen(function* () {
      const recognition = yield* SpeechRecognition
      const idempotency = yield* TranscriptionIdempotency
      const workers = yield* FiberSet.make()

      const abandonAfterFailure = (claim: TranscriptionClaim) =>
        observeStage("idempotency_abandon", idempotency.abandon(claim)).pipe(
          Effect.catchAll((error) =>
            Effect.annotateLogs(
              Effect.logError("transcription_claim_cleanup_failed"),
              {
                event: "transcription_claim_cleanup_failed",
                error_type: error._tag,
                operation: error.operation
              }
            )
          )
        )

      const releaseSettledInference = (
        lease: Parameters<
          typeof idempotency.releaseInference
        >[0]
      ) =>
        observeStage(
          "inference_release",
          idempotency.releaseInference(lease)
        ).pipe(
          Effect.catchAll((error) =>
            Effect.annotateLogs(
              Effect.logError("inference_lease_release_failed"),
              {
                event: "inference_lease_release_failed",
                error_type: error._tag,
                operation: error.operation
              }
            )
          )
        )

      const runClaimedTranscription = (
        claim: TranscriptionClaim,
        request: TranscriptionRequest,
        serviceStartedAt: bigint
      ) =>
        Effect.gen(function* () {
          const upstreamSettled = yield* Ref.make(false)
          const lease = observeStage(
            "inference_admission",
            idempotency.acquireInference
          ).pipe(
            Effect.flatMap((decision) =>
              decision._tag === "Acquired"
                ? Effect.succeed(decision.lease)
                : Effect.zipRight(
                    abandonAfterFailure(claim),
                    Effect.fail(
                      new TranscriptionBusyError({
                        retryAfterSeconds: decision.retryAfterSeconds
                      })
                    )
                  )
            ),
            Effect.tapErrorTag(
              "TranscriptionIdempotencyUnavailableError",
              () => abandonAfterFailure(claim)
            )
          )

          return yield* Effect.acquireUseRelease(
            lease,
            () =>
              Effect.gen(function* () {
                const recognitionStartedAt = yield* Clock.currentTimeNanos
                const recognized = yield* observeStage(
                  "recognition_request",
                  Effect.uninterruptibleMask((restore) =>
                    restore(recognition.transcribe(request.audio)).pipe(
                      Effect.onExit((exit) => {
                        const settled =
                          Exit.isSuccess(exit) ||
                          Option.exists(
                            Cause.failureOption(exit.cause),
                            (error) =>
                              error instanceof
                                SpeechRecognitionUnavailableError &&
                              error.completion === "settled"
                          )
                        return settled
                          ? Ref.set(upstreamSettled, true)
                          : Effect.void
                      })
                    )
                  )
                )
                if (recognized.transcript.trim().length === 0) {
                  return yield* new EmptyTranscriptError({
                    reason:
                      "speech-recognition runtime returned an empty transcript"
                  })
                }
                if (
                  recognized.transcript.length > MaximumTranscriptCharacters
                ) {
                  return yield* new TranscriptTooLargeError({
                    maximumCharacters: MaximumTranscriptCharacters
                  })
                }
                const recognitionFinishedAt = yield* Clock.currentTimeNanos
                const recognitionMS = elapsedMilliseconds(
                  recognitionStartedAt,
                  recognitionFinishedAt
                )
                const serviceMS = elapsedMilliseconds(
                  serviceStartedAt,
                  recognitionFinishedAt
                )
                const response: TranscriptionResponse = {
                  requestID: request.requestID,
                  transcript: recognized.transcript,
                  timings: {
                    queueMS: 0,
                    recognitionMS,
                    serviceMS,
                    upstreamMS: recognized.upstreamMilliseconds,
                    totalMS: serviceMS
                  }
                }
                const completedAt = yield* Clock.currentTimeMillis
                yield* observeStage(
                  "idempotency_complete",
                  idempotency.complete({
                    claim,
                    response,
                    nowEpochMilliseconds: completedAt
                  })
                )
                yield* recordRecognitionPerformance({
                  audioDurationMilliseconds:
                    request.audio.durationMilliseconds,
                  recognitionMilliseconds: recognitionMS,
                  serviceMilliseconds: serviceMS
                })
                return { response, replayed: false }
              }).pipe(
                Effect.tapErrorTag(
                  "SpeechRecognitionUnavailableError",
                  (error) =>
                    error.completion === "settled"
                      ? abandonAfterFailure(claim)
                      : Effect.void
                ),
                Effect.tapErrorTag(
                  "EmptyTranscriptError",
                  () => abandonAfterFailure(claim)
                ),
                Effect.tapErrorTag(
                  "TranscriptTooLargeError",
                  () => abandonAfterFailure(claim)
                )
              ),
            (inferenceLease, exit) =>
              Ref.get(upstreamSettled).pipe(
                Effect.flatMap((settled) =>
                  Exit.isSuccess(exit) || settled
                    ? releaseSettledInference(inferenceLease)
                    : Effect.void
                )
              )
          )
        })

      const transcribe = Effect.fnUntraced(
        function* (request: TranscriptionRequest) {
          const serviceStartedAt = yield* Clock.currentTimeNanos
          const recognitionReady = yield* observeStage(
            "runtime_readiness",
            recognition.isReady
          )
          if (!recognitionReady) {
            return yield* new TranscriptionNotReadyError({
              reason: "recognition_not_ready"
            })
          }
          const claimStartedAt = yield* Clock.currentTimeMillis
          return yield* Effect.uninterruptibleMask((restore) =>
            Effect.gen(function* () {
              const decision = yield* observeStage(
                "idempotency_begin",
                idempotency.begin({
                  devicePrincipalID: request.devicePrincipalID,
                  requestID: request.requestID,
                  audioDigest: request.audioDigest,
                  nowEpochMilliseconds: claimStartedAt,
                  staleAfterMilliseconds: StaleClaimMilliseconds
                })
              )
              yield* Effect.annotateCurrentSpan(
                "hex.idempotency.decision",
                decision._tag.toLowerCase()
              )
              switch (decision._tag) {
                case "Conflict":
                  return yield* new RequestIdConflictError({
                    reason: "request ID was already used for different audio"
                  })
                case "Replay":
                  return { response: decision.response, replayed: true }
                case "InProgress":
                  return yield* new TranscriptionBusyError({
                    retryAfterSeconds: decision.retryAfterSeconds
                  })
                case "Claimed": {
                  const worker = yield* FiberSet.run(
                    workers,
                    runClaimedTranscription(
                      decision.claim,
                      request,
                      serviceStartedAt
                    ).pipe(Effect.interruptible)
                  )
                  return yield* restore(Fiber.join(worker))
                }
              }
            })
          )
        }
      )

      return {
        transcribe,
        isReady: Effect.zipWith(
          recognition.isReady,
          idempotency.isReady,
          (recognitionReady, idempotencyReady) =>
            recognitionReady && idempotencyReady
        ),
        runtime: recognition.runtime,
        model: recognition.model,
        runtimeRevision: recognition.runtimeRevision,
        modelRevision: recognition.modelRevision,
        modelSHA256: recognition.modelSHA256
      }
    })
  }
) {}
