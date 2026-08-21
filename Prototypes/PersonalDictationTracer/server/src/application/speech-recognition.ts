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
  { reason: Schema.String }
) {}

/** Operations supplied by a concrete speech-recognition adapter. */
export interface SpeechRecognitionService {
  readonly transcribe: (
    audio: CapturedAudio
  ) => Effect.Effect<SpeechRecognitionResult, SpeechRecognitionUnavailableError>
  readonly isReady: Effect.Effect<boolean>
  readonly runtime: string
  readonly model: string
}

/** The application-owned port for whichever speech-recognition runtime is selected. */
export class SpeechRecognition extends Context.Tag("@hex/personal-dictation/SpeechRecognition")<
  SpeechRecognition,
  SpeechRecognitionService
>() {}
