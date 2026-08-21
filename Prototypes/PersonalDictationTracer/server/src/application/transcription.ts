import { Clock, Effect, Ref, Schema } from "effect"

import { SpeechRecognition } from "./speech-recognition.js"
import type { CapturedAudio } from "../domain/captured-audio.js"
import type { RequestId } from "../domain/request-id.js"

/** A transcription request after transport-level parsing. */
export interface TranscriptionRequest {
  readonly requestID: RequestId
  readonly audio: CapturedAudio
  readonly audioDigest: string
}

/** Stable timing fields returned to the iOS client. */
export interface TranscriptionTimings {
  readonly upstreamMS: number
  readonly totalMS: number
}

/** The stable JSON body returned for a successful transcription. */
export interface TranscriptionResponse {
  readonly requestID: RequestId
  readonly transcript: string
  readonly timings: TranscriptionTimings
}

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

interface CacheEntry {
  readonly requestID: RequestId
  readonly audioDigest: string
  readonly response: TranscriptionResponse
}

const CacheLimit = 32

const moveToNewest = (
  entries: ReadonlyArray<CacheEntry>,
  index: number
): ReadonlyArray<CacheEntry> => {
  const entry = entries[index]
  if (entry === undefined) {
    return entries
  }
  return [...entries.slice(0, index), ...entries.slice(index + 1), entry]
}

/** Serializes inference and owns the process-local retry/idempotency policy. */
export class Transcription extends Effect.Service<Transcription>()(
  "@hex/personal-dictation/Transcription",
  {
    effect: Effect.gen(function* () {
      const recognition = yield* SpeechRecognition
      const cache = yield* Ref.make<ReadonlyArray<CacheEntry>>([])
      const inferencePermit = yield* Effect.makeSemaphore(1)

      const transcribe = Effect.fn("Transcription.transcribe")(
        function* (request: TranscriptionRequest) {
          const entries = yield* Ref.get(cache)
          const cachedIndex = entries.findIndex(
            (entry) => entry.requestID === request.requestID
          )
          const cached = entries[cachedIndex]

          if (cached !== undefined) {
            if (cached.audioDigest !== request.audioDigest) {
              return yield* new RequestIdConflictError({
                reason: "request ID was already used for different audio"
              })
            }
            yield* Ref.set(cache, moveToNewest(entries, cachedIndex))
            return { response: cached.response, replayed: true }
          }

          const startedAt = yield* Clock.currentTimeMillis
          const recognized = yield* recognition.transcribe(request.audio)
          if (recognized.transcript.trim().length === 0) {
            return yield* new EmptyTranscriptError({
              reason: "speech-recognition runtime returned an empty transcript"
            })
          }
          const finishedAt = yield* Clock.currentTimeMillis
          const response: TranscriptionResponse = {
            requestID: request.requestID,
            transcript: recognized.transcript,
            timings: {
              upstreamMS: recognized.upstreamMilliseconds,
              totalMS: Math.max(0, Math.round(finishedAt - startedAt))
            }
          }
          const nextEntry: CacheEntry = {
            requestID: request.requestID,
            audioDigest: request.audioDigest,
            response
          }
          yield* Ref.update(cache, (current) =>
            [...current, nextEntry].slice(-CacheLimit)
          )
          return { response, replayed: false }
        }
      )

      return {
        transcribe: (request: TranscriptionRequest) =>
          inferencePermit.withPermits(1)(transcribe(request)),
        isReady: recognition.isReady,
        runtime: recognition.runtime,
        model: recognition.model
      }
    })
  }
) {}
