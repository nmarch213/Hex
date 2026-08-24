import { Context, Effect, Schema } from "effect"

import type { CapturedAudio } from "../domain/captured-audio.js"
import type { RecognitionArtifactIdentity } from "../service-metadata.js"

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
export interface SpeechRecognitionService extends RecognitionArtifactIdentity {
  readonly transcribe: (
    audio: CapturedAudio
  ) => Effect.Effect<SpeechRecognitionResult, SpeechRecognitionUnavailableError>
  readonly isReady: Effect.Effect<boolean>
}

/** The application-owned port for whichever speech-recognition runtime is selected. */
export class SpeechRecognition extends Context.Tag("@hex/personal-dictation/SpeechRecognition")<
  SpeechRecognition,
  SpeechRecognitionService
>() {}
