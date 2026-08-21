import assert from "node:assert/strict"
import test from "node:test"

import { Effect, Either } from "effect"

import { parseCapturedAudio } from "./captured-audio.js"

const makeAudio = (channels: number, sampleRate: number) => {
  const bytes = new Uint8Array(48)
  const view = new DataView(bytes.buffer)
  bytes.set(new TextEncoder().encode("RIFF"), 0)
  view.setUint32(4, 40, true)
  bytes.set(new TextEncoder().encode("WAVE"), 8)
  bytes.set(new TextEncoder().encode("fmt "), 12)
  view.setUint32(16, 16, true)
  view.setUint16(20, 3, true)
  view.setUint16(22, channels, true)
  view.setUint32(24, sampleRate, true)
  view.setUint32(28, sampleRate * channels * 4, true)
  view.setUint16(32, channels * 4, true)
  view.setUint16(34, 32, true)
  bytes.set(new TextEncoder().encode("data"), 36)
  view.setUint32(40, 4, true)
  return bytes
}

test("accepts mono 16 kHz Float32 WAV audio", async () => {
  const result = await Effect.runPromise(parseCapturedAudio(makeAudio(1, 16_000)))
  assert.equal(result.bytes.byteLength, 48)
})

test("rejects WAV audio outside the recognition boundary", async () => {
  const stereo = await Effect.runPromise(
    Effect.either(parseCapturedAudio(makeAudio(2, 16_000)))
  )
  const wrongRate = await Effect.runPromise(
    Effect.either(parseCapturedAudio(makeAudio(1, 48_000)))
  )

  assert.equal(Either.isLeft(stereo), true)
  assert.equal(Either.isLeft(wrongRate), true)
})
