import { Effect, Schema } from "effect"

/** The largest WAV body accepted by the personal dictation service. */
export const MaxAudioBytes = 50 * 1024 * 1024

/** A complete WAV recording that is safe to pass to speech recognition. */
export interface CapturedAudio {
  readonly bytes: Uint8Array
}

/** Describes why an inbound recording could not be accepted. */
export class InvalidAudioError extends Schema.TaggedError<InvalidAudioError>()(
  "InvalidAudioError",
  { reason: Schema.String }
) {}

const textDecoder = new TextDecoder("ascii")

const readChunkName = (bytes: Uint8Array, offset: number): string =>
  textDecoder.decode(bytes.subarray(offset, offset + 4))

const invalidAudio = (reason: string) =>
  Effect.fail(new InvalidAudioError({ reason }))

/** Parses an untrusted request body into a validated WAV recording. */
export const parseCapturedAudio = (
  bytes: Uint8Array
): Effect.Effect<CapturedAudio, InvalidAudioError> => {
  if (bytes.byteLength < 44 || bytes.byteLength > MaxAudioBytes) {
    return invalidAudio("invalid WAV body size")
  }

  const riff = readChunkName(bytes, 0)
  const wave = readChunkName(bytes, 8)
  if (riff !== "RIFF" || wave !== "WAVE") {
    return invalidAudio("malformed WAV body")
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const declaredFileSize = view.getUint32(4, true) + 8
  if (declaredFileSize > bytes.byteLength) {
    return invalidAudio("malformed WAV body")
  }

  let offset = 12
  let hasRequiredFormat = false
  let hasAudioData = false
  while (offset + 8 <= bytes.byteLength) {
    const chunkName = readChunkName(bytes, offset)
    const chunkSize = view.getUint32(offset + 4, true)
    const payloadOffset = offset + 8
    const chunkEnd = payloadOffset + chunkSize
    if (chunkEnd > bytes.byteLength) {
      return invalidAudio("malformed WAV body")
    }

    if (chunkName === "fmt ") {
      if (chunkSize < 16) {
        return invalidAudio("malformed WAV body")
      }
      const audioFormat = view.getUint16(payloadOffset, true)
      const channelCount = view.getUint16(payloadOffset + 2, true)
      const sampleRate = view.getUint32(payloadOffset + 4, true)
      const bitsPerSample = view.getUint16(payloadOffset + 14, true)
      hasRequiredFormat =
        audioFormat === 3 &&
        channelCount === 1 &&
        sampleRate === 16_000 &&
        bitsPerSample === 32
    }
    if (chunkName === "data" && chunkSize > 0) {
      hasAudioData = true
    }

    offset = chunkEnd + (chunkSize % 2)
  }

  if (!hasRequiredFormat || !hasAudioData) {
    return invalidAudio("audio/wav must contain mono 16 kHz Float32 audio")
  }

  return Effect.succeed({ bytes })
}
