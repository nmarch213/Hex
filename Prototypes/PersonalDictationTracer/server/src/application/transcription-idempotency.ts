import { Context, Effect, Schema } from "effect"

import type { TranscriptionResponse } from "./transcription.js"
import type { AudioDigest } from "../domain/audio-digest.js"
import type { DevicePrincipalId } from "../domain/device-principal.js"
import type { RequestId } from "../domain/request-id.js"

/** Schema for an internal random token fencing one claim attempt. */
export const TranscriptionClaimTokenSchema = Schema.UUID.pipe(
  Schema.brand("TranscriptionClaimToken")
)

/** An internal random token fencing one claim attempt. */
export type TranscriptionClaimToken = Schema.Schema.Type<
  typeof TranscriptionClaimTokenSchema
>

/** Schema for one verified lifetime of the native recognition process. */
export const UpstreamProcessEpochSchema = Schema.String.pipe(
  Schema.pattern(/^[0-9a-f]{64}$/),
  Schema.brand("UpstreamProcessEpoch")
)

/** Changes only after deployment has proved the previous native process stopped. */
export type UpstreamProcessEpoch = Schema.Schema.Type<
  typeof UpstreamProcessEpochSchema
>

/** A durable lease proving which attempt may complete one transcription. */
export interface TranscriptionClaim {
  readonly devicePrincipalID: DevicePrincipalId
  readonly requestID: RequestId
  readonly audioDigest: AudioDigest
  readonly generation: number
  readonly token: TranscriptionClaimToken
}

/** Input for atomically claiming or replaying a transcription request. */
export interface BeginTranscriptionClaim {
  readonly devicePrincipalID: DevicePrincipalId
  readonly requestID: RequestId
  readonly audioDigest: AudioDigest
  readonly nowEpochMilliseconds: number
  readonly staleAfterMilliseconds: number
}

/** The durable disposition of a caller request ID and audio digest pair. */
export type TranscriptionClaimDecision =
  | { readonly _tag: "Claimed"; readonly claim: TranscriptionClaim }
  | { readonly _tag: "Replay"; readonly response: TranscriptionResponse }
  | { readonly _tag: "Conflict" }
  | { readonly _tag: "InProgress"; readonly retryAfterSeconds: number }

/** Input for atomically recording the response produced by a leased attempt. */
export interface CompleteTranscriptionClaim {
  readonly claim: TranscriptionClaim
  readonly response: TranscriptionResponse
  readonly nowEpochMilliseconds: number
}

/** A durable single-engine lease shared across proxy processes and restarts. */
export interface InferenceLease {
  readonly token: TranscriptionClaimToken
  readonly upstreamEpoch: UpstreamProcessEpoch
}

/** Result of trying to reserve the sole upstream recognition engine. */
export type InferenceLeaseDecision =
  | { readonly _tag: "Acquired"; readonly lease: InferenceLease }
  | { readonly _tag: "Busy"; readonly retryAfterSeconds: number }

/** Reports that durable idempotency storage could not perform an operation. */
export class TranscriptionIdempotencyUnavailableError extends Schema.TaggedError<TranscriptionIdempotencyUnavailableError>()(
  "TranscriptionIdempotencyUnavailableError",
  {
    operation: Schema.Literal(
      "initialize",
      "begin",
      "complete",
      "abandon",
      "cleanup",
      "acquire_inference",
      "release_inference"
    )
  }
) {}

/** Reports that a stale-attempt takeover invalidated an older claim. */
export class TranscriptionClaimLostError extends Schema.TaggedError<TranscriptionClaimLostError>()(
  "TranscriptionClaimLostError",
  {}
) {}

/** Durable operations required by the transcription application service. */
export interface TranscriptionIdempotencyService {
  /** False after a storage failure or while the current native process is fenced. */
  readonly isReady: Effect.Effect<boolean>

  /** Atomically reserves the sole engine across process restarts. */
  readonly acquireInference: Effect.Effect<
    InferenceLeaseDecision,
    TranscriptionIdempotencyUnavailableError
  >

  /** Releases only the lease owned by this completed attempt. */
  readonly releaseInference: (
    lease: InferenceLease
  ) => Effect.Effect<void, TranscriptionIdempotencyUnavailableError>

  /** Atomically claims, replays, or rejects one caller request ID. */
  readonly begin: (
    input: BeginTranscriptionClaim
  ) => Effect.Effect<
    TranscriptionClaimDecision,
    TranscriptionIdempotencyUnavailableError
  >

  /** Saves a completed response only when the caller still owns its claim. */
  readonly complete: (
    input: CompleteTranscriptionClaim
  ) => Effect.Effect<
    void,
    TranscriptionIdempotencyUnavailableError | TranscriptionClaimLostError
  >

  /** Releases an unfinished claim only after native inference is known settled. */
  readonly abandon: (
    claim: TranscriptionClaim
  ) => Effect.Effect<void, TranscriptionIdempotencyUnavailableError>
}

/** Application-owned persistence port for transcription retry semantics. */
export class TranscriptionIdempotency extends Context.Tag(
  "@hex/personal-dictation/TranscriptionIdempotency"
)<TranscriptionIdempotency, TranscriptionIdempotencyService>() {}
