import { Effect, Schema } from "effect"

/** The smallest complete WAV body accepted by the personal dictation service. */
export const MinAudioBytes = 48

/** The longest Recording Session accepted by the personal dictation service. */
export const MaxAudioDurationSeconds = 5 * 60

const RequiredChannelCount = 1
const RequiredSampleRate = 16_000
const RequiredBitsPerSample = 32
const RequiredBlockAlign =
  RequiredChannelCount * (RequiredBitsPerSample / 8)
const RequiredByteRate = RequiredSampleRate * RequiredBlockAlign
const MaximumSampleFrameCount =
  RequiredSampleRate * MaxAudioDurationSeconds
const MaximumCanonicalDataBytes =
  MaximumSampleFrameCount * RequiredBlockAlign
const MaximumWaveContainerOverheadBytes = 64 * 1024

/** The largest canonical five-minute WAV plus bounded container metadata. */
export const MaxAudioBytes =
  MaximumCanonicalDataBytes + MaximumWaveContainerOverheadBytes

const CapturedAudioTypeId: unique symbol = Symbol(
  "@hex/personal-dictation/CapturedAudio"
)

/** A complete immutable WAV recording that is safe to pass to speech recognition. */
export interface CapturedAudio {
  readonly [CapturedAudioTypeId]: true

  /** Total bytes in the validated WAV container. */
  readonly byteLength: number

  /** Number of mono Float32 sample frames in the data chunk. */
  readonly sampleFrameCount: number

  /** Duration derived from the validated sample rate and data chunk. */
  readonly durationMilliseconds: number

  /** Returns a defensive copy of the validated WAV bytes. */
  readonly toUint8Array: () => Uint8Array<ArrayBuffer>
}

/** Describes why an inbound recording could not be accepted. */
export class InvalidAudioError extends Schema.TaggedError<InvalidAudioError>()(
  "InvalidAudioError",
  { reason: Schema.String }
) {}

interface ParsedFormat {
  readonly blockAlign: number
}

const textDecoder = new TextDecoder("ascii")

const readChunkName = (bytes: Uint8Array, offset: number): string =>
  textDecoder.decode(bytes.subarray(offset, offset + 4))

const invalidAudio = (reason: string) =>
  Effect.fail(new InvalidAudioError({ reason }))

const parseFormatChunk = (
  view: DataView,
  payloadOffset: number,
  chunkSize: number
): ParsedFormat | undefined => {
  if (chunkSize < 16 || chunkSize === 17) {
    return undefined
  }

  if (chunkSize >= 18) {
    const extensionSize = view.getUint16(payloadOffset + 16, true)
    if (18 + extensionSize !== chunkSize) {
      return undefined
    }
  }

  const audioFormat = view.getUint16(payloadOffset, true)
  const channelCount = view.getUint16(payloadOffset + 2, true)
  const sampleRate = view.getUint32(payloadOffset + 4, true)
  const byteRate = view.getUint32(payloadOffset + 8, true)
  const blockAlign = view.getUint16(payloadOffset + 12, true)
  const bitsPerSample = view.getUint16(payloadOffset + 14, true)

  if (
    audioFormat !== 3 ||
    channelCount !== RequiredChannelCount ||
    sampleRate !== RequiredSampleRate ||
    bitsPerSample !== RequiredBitsPerSample ||
    blockAlign !== RequiredBlockAlign ||
    byteRate !== RequiredByteRate ||
    byteRate !== sampleRate * blockAlign
  ) {
    return undefined
  }

  return { blockAlign }
}

const makeCapturedAudio = (
  sourceBytes: Uint8Array,
  sampleFrameCount: number
): CapturedAudio => {
  const storedBytes = sourceBytes.slice()
  return Object.freeze({
    [CapturedAudioTypeId]: true as const,
    byteLength: storedBytes.byteLength,
    sampleFrameCount,
    durationMilliseconds:
      (sampleFrameCount * 1_000) / RequiredSampleRate,
    toUint8Array: () => storedBytes.slice()
  })
}

/** Parses an untrusted request body into an immutable WAV recording. */
export const parseCapturedAudio = (
  bytes: Uint8Array
): Effect.Effect<CapturedAudio, InvalidAudioError> => {
  if (bytes.byteLength < MinAudioBytes || bytes.byteLength > MaxAudioBytes) {
    return invalidAudio("invalid WAV body size")
  }

  if (readChunkName(bytes, 0) !== "RIFF" || readChunkName(bytes, 8) !== "WAVE") {
    return invalidAudio("malformed WAV body")
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const declaredFileSize = view.getUint32(4, true) + 8
  if (declaredFileSize !== bytes.byteLength) {
    return invalidAudio("malformed WAV body")
  }

  let offset = 12
  let format: ParsedFormat | undefined
  let dataSize: number | undefined

  while (offset < declaredFileSize) {
    if (offset + 8 > declaredFileSize) {
      return invalidAudio("malformed WAV body")
    }

    const chunkName = readChunkName(bytes, offset)
    const chunkSize = view.getUint32(offset + 4, true)
    const payloadOffset = offset + 8
    const chunkEnd = payloadOffset + chunkSize
    const paddingSize = chunkSize % 2
    const paddedChunkEnd = chunkEnd + paddingSize

    if (paddedChunkEnd > declaredFileSize) {
      return invalidAudio("malformed WAV body")
    }
    if (paddingSize === 1 && bytes[chunkEnd] !== 0) {
      return invalidAudio("malformed WAV chunk padding")
    }

    if (chunkName === "fmt ") {
      if (format !== undefined) {
        return invalidAudio("WAV body contains duplicate fmt chunks")
      }
      format = parseFormatChunk(view, payloadOffset, chunkSize)
      if (format === undefined) {
        return invalidAudio(
          "audio/wav must contain mono 16 kHz Float32 audio"
        )
      }
    } else if (chunkName === "data") {
      if (dataSize !== undefined) {
        return invalidAudio("WAV body contains duplicate data chunks")
      }
      dataSize = chunkSize
    }

    offset = paddedChunkEnd
  }

  if (format === undefined || dataSize === undefined) {
    return invalidAudio("WAV body must contain one fmt and one data chunk")
  }
  if (
    bytes.byteLength - dataSize >
    MaximumWaveContainerOverheadBytes
  ) {
    return invalidAudio("WAV container metadata is too large")
  }
  if (dataSize === 0 || dataSize % format.blockAlign !== 0) {
    return invalidAudio("WAV data must contain complete Float32 sample frames")
  }

  const sampleFrameCount = dataSize / format.blockAlign
  if (sampleFrameCount > MaximumSampleFrameCount) {
    return invalidAudio(
      `WAV audio must not exceed ${MaxAudioDurationSeconds} seconds`
    )
  }

  return Effect.succeed(makeCapturedAudio(bytes, sampleFrameCount))
}
