import { Context, Effect, Schema } from "effect"

import type { CapturedAudio } from "../domain/captured-audio.js"

/** A successful result returned by a speech-recognition runtime. */
export interface SpeechRecognitionResult {
  readonly transcript: string
  readonly upstreamMilliseconds: number
}

/** Reports that the configured recognition runtime could not serve a request. */
export class SpeechRecognitionUnavailableError extends Schema.TaggedError<SpeechRecognitionUnavailableError>()(
  "SpeechRecognitionUnavailableError",
  {
    reason: Schema.String,
    completion: Schema.Literal("settled", "unknown")
  }
) {}

/** Operations supplied by a concrete speech-recognition adapter. */
export interface SpeechRecognitionService {
  readonly transcribe: (
    audio: CapturedAudio
  ) => Effect.Effect<SpeechRecognitionResult, SpeechRecognitionUnavailableError>
  readonly isReady: Effect.Effect<boolean>
  readonly runtime: string
  readonly model: string
  readonly runtimeRevision: string
  readonly modelRevision: string
  readonly modelSHA256: string
}

/** The application-owned port for whichever speech-recognition runtime is selected. */
export class SpeechRecognition extends Context.Tag("@hex/personal-dictation/SpeechRecognition")<
  SpeechRecognition,
  SpeechRecognitionService
>() {}
