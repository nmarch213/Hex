import assert from "node:assert/strict"
import test from "node:test"

import { Effect, Either } from "effect"

import { parseAudioDigest } from "./audio-digest.js"

test("parses exactly one lowercase SHA-256 digest", async () => {
  const digest = await Effect.runPromise(parseAudioDigest("ab".repeat(32)))
  assert.equal(digest, "ab".repeat(32))
})

test("rejects malformed, truncated, and uppercase digests", async () => {
  const malformed = await Effect.runPromise(
    Effect.either(parseAudioDigest("not-a-digest"))
  )
  const truncated = await Effect.runPromise(
    Effect.either(parseAudioDigest("ab".repeat(31)))
  )
  const uppercase = await Effect.runPromise(
    Effect.either(parseAudioDigest("AB".repeat(32)))
  )

  assert.equal(Either.isLeft(malformed), true)
  assert.equal(Either.isLeft(truncated), true)
  assert.equal(Either.isLeft(uppercase), true)
})
