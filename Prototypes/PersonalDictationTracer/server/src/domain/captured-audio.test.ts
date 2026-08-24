import assert from "node:assert/strict"
import test from "node:test"

import { Effect, Either } from "effect"

import {
  MaxAudioBytes,
  MaxAudioDurationSeconds,
  parseCapturedAudio
} from "./captured-audio.js"

interface Chunk {
  readonly name: string
  readonly payload: Uint8Array
  readonly paddingByte?: number
}

interface FormatOptions {
  readonly audioFormat?: number
  readonly channels?: number
  readonly sampleRate?: number
  readonly byteRate?: number
  readonly blockAlign?: number
  readonly bitsPerSample?: number
  readonly extensionSize?: number
}

const encoder = new TextEncoder()

const makeFormat = (options: FormatOptions = {}): Uint8Array => {
  const extensionSize = options.extensionSize
  const payload = new Uint8Array(extensionSize === undefined ? 16 : 18)
  const view = new DataView(payload.buffer)
  const channels = options.channels ?? 1
  const sampleRate = options.sampleRate ?? 16_000
  const bitsPerSample = options.bitsPerSample ?? 32
  const blockAlign =
    options.blockAlign ?? channels * (bitsPerSample / 8)
  const byteRate = options.byteRate ?? sampleRate * blockAlign

  view.setUint16(0, options.audioFormat ?? 3, true)
  view.setUint16(2, channels, true)
  view.setUint32(4, sampleRate, true)
  view.setUint32(8, byteRate, true)
  view.setUint16(12, blockAlign, true)
  view.setUint16(14, bitsPerSample, true)
  if (extensionSize !== undefined) {
    view.setUint16(16, extensionSize, true)
  }
  return payload
}

const makeWave = (chunks: ReadonlyArray<Chunk>): Uint8Array => {
  const byteLength =
    12 +
    chunks.reduce(
      (total, chunk) =>
        total +
        8 +
        chunk.payload.byteLength +
        (chunk.payload.byteLength % 2),
      0
    )
  const bytes = new Uint8Array(byteLength)
  const view = new DataView(bytes.buffer)
  bytes.set(encoder.encode("RIFF"), 0)
  view.setUint32(4, byteLength - 8, true)
  bytes.set(encoder.encode("WAVE"), 8)

  let offset = 12
  for (const chunk of chunks) {
    bytes.set(encoder.encode(chunk.name), offset)
    view.setUint32(offset + 4, chunk.payload.byteLength, true)
    bytes.set(chunk.payload, offset + 8)
    offset += 8 + chunk.payload.byteLength
    if (chunk.payload.byteLength % 2 === 1) {
      bytes[offset] = chunk.paddingByte ?? 0
      offset += 1
    }
  }
  return bytes
}

const makeAudio = (
  data = new Uint8Array(4),
  format = makeFormat()
): Uint8Array =>
  makeWave([
    { name: "fmt ", payload: format },
    { name: "data", payload: data }
  ])

const expectInvalid = async (bytes: Uint8Array): Promise<void> => {
  const result = await Effect.runPromise(
    Effect.either(parseCapturedAudio(bytes))
  )
  assert.equal(Either.isLeft(result), true)
  if (Either.isLeft(result)) {
    assert.equal(result.left._tag, "InvalidAudioError")
  }
}

test("accepts exactly framed mono 16 kHz Float32 WAV audio", async () => {
  const result = await Effect.runPromise(parseCapturedAudio(makeAudio()))

  assert.equal(result.byteLength, 48)
  assert.equal(result.sampleFrameCount, 1)
  assert.equal(result.durationMilliseconds, 1 / 16)
})

test("accepts a sane WAVEFORMATEX chunk and padded unknown chunks", async () => {
  const result = await Effect.runPromise(
    parseCapturedAudio(
      makeWave([
        { name: "JUNK", payload: new Uint8Array([1, 2, 3]) },
        { name: "fmt ", payload: makeFormat({ extensionSize: 0 }) },
        { name: "data", payload: new Uint8Array(4) }
      ])
    )
  )

  assert.equal(result.sampleFrameCount, 1)
})

test("keeps parsed Captured Audio immutable across byte projections", async () => {
  const source = makeAudio(new Uint8Array([1, 2, 3, 4]))
  const result = await Effect.runPromise(parseCapturedAudio(source))
  source[44] = 9

  const firstProjection = result.toUint8Array()
  assert.equal(firstProjection[44], 1)
  firstProjection[44] = 8
  assert.equal(result.toUint8Array()[44], 1)
})

test("rejects trailing bytes and mismatched RIFF declarations", async () => {
  const valid = makeAudio()
  const trailing = new Uint8Array(valid.byteLength + 1)
  trailing.set(valid)

  const declaredTooLarge = valid.slice()
  new DataView(declaredTooLarge.buffer).setUint32(
    4,
    declaredTooLarge.byteLength - 7,
    true
  )
  const declaredTooSmall = valid.slice()
  new DataView(declaredTooSmall.buffer).setUint32(
    4,
    declaredTooSmall.byteLength - 9,
    true
  )

  await expectInvalid(trailing)
  await expectInvalid(declaredTooLarge)
  await expectInvalid(declaredTooSmall)
})

test("rejects chunks that cross the RIFF boundary or have invalid padding", async () => {
  const oversizedDataChunk = makeAudio()
  new DataView(oversizedDataChunk.buffer).setUint32(40, 8, true)
  const partialChunkHeader = new Uint8Array(makeAudio().byteLength + 4)
  partialChunkHeader.set(makeAudio())
  new DataView(partialChunkHeader.buffer).setUint32(
    4,
    partialChunkHeader.byteLength - 8,
    true
  )
  const nonzeroPadding = makeWave([
    {
      name: "JUNK",
      payload: new Uint8Array([1]),
      paddingByte: 7
    },
    { name: "fmt ", payload: makeFormat() },
    { name: "data", payload: new Uint8Array(4) }
  ])

  await expectInvalid(oversizedDataChunk)
  await expectInvalid(partialChunkHeader)
  await expectInvalid(nonzeroPadding)
})

test("bounds WAV container metadata independently of audio duration", async () => {
  const largestAcceptedMetadataPayload = 64 * 1_024 - 52
  const accepted = await Effect.runPromise(
    parseCapturedAudio(
      makeWave([
        {
          name: "JUNK",
          payload: new Uint8Array(largestAcceptedMetadataPayload)
        },
        { name: "fmt ", payload: makeFormat() },
        { name: "data", payload: new Uint8Array(4) }
      ])
    )
  )
  assert.equal(accepted.sampleFrameCount, 1)

  await expectInvalid(
    makeWave([
      {
        name: "JUNK",
        payload: new Uint8Array(largestAcceptedMetadataPayload + 2)
      },
      { name: "fmt ", payload: makeFormat() },
      { name: "data", payload: new Uint8Array(4) }
    ])
  )
})

test("rejects missing and duplicate required chunks", async () => {
  await expectInvalid(
    makeWave([
      { name: "JUNK", payload: new Uint8Array(16) },
      { name: "data", payload: new Uint8Array(4) }
    ])
  )
  await expectInvalid(
    makeWave([
      { name: "fmt ", payload: makeFormat() },
      { name: "JUNK", payload: new Uint8Array(4) }
    ])
  )
  await expectInvalid(
    makeWave([
      { name: "fmt ", payload: makeFormat() },
      { name: "fmt ", payload: makeFormat() },
      { name: "data", payload: new Uint8Array(4) }
    ])
  )
  await expectInvalid(
    makeWave([
      { name: "fmt ", payload: makeFormat() },
      { name: "data", payload: new Uint8Array(4) },
      { name: "data", payload: new Uint8Array(4) }
    ])
  )
})

test("rejects short and inconsistent format chunks", async () => {
  await expectInvalid(makeAudio(new Uint8Array(4), new Uint8Array(15)))
  await expectInvalid(makeAudio(new Uint8Array(4), new Uint8Array(17)))
  await expectInvalid(
    makeAudio(new Uint8Array(4), makeFormat({ extensionSize: 1 }))
  )
  await expectInvalid(
    makeAudio(new Uint8Array(4), makeFormat({ byteRate: 63_999 }))
  )
  await expectInvalid(
    makeAudio(new Uint8Array(4), makeFormat({ blockAlign: 2 }))
  )
})

test("rejects audio outside the Float32 mono 16 kHz boundary", async () => {
  await expectInvalid(
    makeAudio(new Uint8Array(4), makeFormat({ audioFormat: 1 }))
  )
  await expectInvalid(
    makeAudio(new Uint8Array(8), makeFormat({ channels: 2 }))
  )
  await expectInvalid(
    makeAudio(new Uint8Array(4), makeFormat({ sampleRate: 48_000 }))
  )
  await expectInvalid(
    makeAudio(new Uint8Array(2), makeFormat({ bitsPerSample: 16 }))
  )
})

test("rejects empty, short, and partial Float32 data", async () => {
  await expectInvalid(
    makeWave([
      { name: "fmt ", payload: makeFormat() },
      { name: "JUNK", payload: new Uint8Array(4) },
      { name: "data", payload: new Uint8Array(0) }
    ])
  )
  await expectInvalid(makeAudio(new Uint8Array(3)))
  await expectInvalid(makeAudio(new Uint8Array(5)))
})

test("accepts the five-minute duration boundary and rejects one extra frame", async () => {
  const maximumDataBytes = MaxAudioDurationSeconds * 16_000 * 4
  assert.equal(MaxAudioBytes, maximumDataBytes + 64 * 1024)
  const accepted = await Effect.runPromise(
    parseCapturedAudio(makeAudio(new Uint8Array(maximumDataBytes)))
  )
  assert.equal(accepted.durationMilliseconds, 5 * 60 * 1_000)

  await expectInvalid(
    makeAudio(new Uint8Array(maximumDataBytes + 4))
  )
})
