import assert from "node:assert/strict"
import { mkdtempSync, rmSync, statSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import Database from "better-sqlite3"
import { Effect, Either, Schema } from "effect"

import {
  TranscriptionIdempotency,
  UpstreamProcessEpochSchema,
  type UpstreamProcessEpoch
} from "../application/transcription-idempotency.js"
import type { TranscriptionResponse } from "../application/transcription.js"
import { parseAudioDigest } from "../domain/audio-digest.js"
import { DevicePrincipalIdSchema } from "../domain/device-principal.js"
import { parseRequestId } from "../domain/request-id.js"
import { sqliteTranscriptionIdempotencyLayer } from "./sqlite-transcription-idempotency.js"

const StaleAfterMilliseconds = 120_000
const OneDayMilliseconds = 24 * 60 * 60 * 1_000
const BaseEpochMilliseconds = Date.now()
const FirstUpstreamEpoch = Schema.decodeUnknownSync(
  UpstreamProcessEpochSchema
)("03".repeat(32))
const ReplacementUpstreamEpoch = Schema.decodeUnknownSync(
  UpstreamProcessEpochSchema
)("04".repeat(32))
const TestDevicePrincipalID = Schema.decodeUnknownSync(
  DevicePrincipalIdSchema
)("00000000-0000-4000-8000-00000000d001")
const OtherDevicePrincipalID = Schema.decodeUnknownSync(
  DevicePrincipalIdSchema
)("00000000-0000-4000-8000-00000000d002")

const withTemporaryDatabase = async (
  operation: (databasePath: string) => Promise<void>
) => {
  const directory = mkdtempSync(join(tmpdir(), "hex-idempotency-"))
  try {
    await operation(join(directory, "idempotency.sqlite"))
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

const runWithStore = <Output, Error>(
  databasePath: string,
  effect: Effect.Effect<Output, Error, TranscriptionIdempotency>,
  upstreamEpoch: UpstreamProcessEpoch = FirstUpstreamEpoch
) =>
  Effect.runPromise(
    effect.pipe(
      Effect.provide(
        sqliteTranscriptionIdempotencyLayer(databasePath, upstreamEpoch)
      ),
      Effect.scoped
    )
  )

const makeResponse = (
  requestID: TranscriptionResponse["requestID"],
  transcript: string
): TranscriptionResponse => ({
  requestID,
  transcript,
  timings: {
    queueMS: 0,
    recognitionMS: 17,
    serviceMS: 19,
    upstreamMS: 17,
    totalMS: 19
  }
})

test("reports healthy after startup maintenance succeeds", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    const ready = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* store.isReady
      })
    )
    assert.equal(ready, true)
  })
})

test("readiness requires the durable write domain to be available", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    await Effect.runPromise(
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        const competingWriter = yield* Effect.acquireRelease(
          Effect.sync(() => new Database(databasePath)),
          (database) =>
            Effect.sync(() => {
              if (database.inTransaction) {
                database.exec("ROLLBACK")
              }
              database.close()
            })
        )

        yield* Effect.sync(() => competingWriter.exec("BEGIN IMMEDIATE"))
        assert.equal(yield* store.isReady, false)

        yield* Effect.sync(() => competingWriter.exec("ROLLBACK"))
        assert.equal(yield* store.isReady, true)
      }).pipe(
        Effect.provide(
          sqliteTranscriptionIdempotencyLayer(
            databasePath,
            FirstUpstreamEpoch,
            "1 hour"
          )
        ),
        Effect.scoped
      )
    )
  })
})

test("readiness commits a real mutation before clearing a write failure", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        assert.equal(yield* store.isReady, true)
      })
    )

    const metadata = new Database(databasePath, { readonly: true })
    const pageCount = Schema.decodeUnknownSync(Schema.Number)(
      metadata.pragma("page_count", { simple: true })
    )
    metadata.close()

    await Effect.runPromise(
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        yield* Effect.sync(() => {
          const sabotage = new Database(databasePath)
          try {
            sabotage.exec(`
              CREATE TABLE IF NOT EXISTS storage_readiness_probe (
                slot INTEGER PRIMARY KEY NOT NULL CHECK (slot = 1),
                nonce INTEGER NOT NULL CHECK (nonce IN (0, 1))
              ) STRICT;
              INSERT OR IGNORE INTO storage_readiness_probe (slot, nonce)
              VALUES (1, 0);
              CREATE TABLE readiness_pressure (payload BLOB NOT NULL);
              CREATE TRIGGER exhaust_readiness_probe
              AFTER UPDATE ON storage_readiness_probe
              BEGIN
                INSERT INTO readiness_pressure (payload)
                VALUES (zeroblob(1048576));
              END;
            `)
          } finally {
            sabotage.close()
          }
        })

        assert.equal(yield* store.isReady, false)
      }).pipe(
        Effect.provide(
          sqliteTranscriptionIdempotencyLayer(
            databasePath,
            FirstUpstreamEpoch,
            "1 hour",
            pageCount
          )
        ),
        Effect.scoped
      )
    )
  })
})

test("migrates the obsolete timed engine lease after a verified process restart", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    const legacy = new Database(databasePath)
    try {
      legacy.exec(`
        CREATE TABLE transcription_idempotency (
          request_id TEXT PRIMARY KEY NOT NULL,
          audio_digest TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN ('in_progress', 'completed')),
          generation INTEGER NOT NULL CHECK (generation >= 1),
          claim_token TEXT NOT NULL,
          claimed_at_ms INTEGER NOT NULL CHECK (claimed_at_ms >= 0),
          completed_at_ms INTEGER,
          response_json TEXT,
          CHECK (
            (state = 'in_progress' AND completed_at_ms IS NULL AND response_json IS NULL)
            OR
            (state = 'completed' AND completed_at_ms IS NOT NULL AND response_json IS NOT NULL)
          )
        ) STRICT;
        CREATE INDEX transcription_idempotency_completed_at
          ON transcription_idempotency (completed_at_ms)
          WHERE state = 'completed';
        CREATE TABLE inference_admission (
          slot INTEGER PRIMARY KEY NOT NULL CHECK (slot = 1),
          claim_token TEXT NOT NULL,
          expires_at_ms INTEGER NOT NULL CHECK (expires_at_ms >= 0)
        ) STRICT;
        INSERT INTO inference_admission (slot, claim_token, expires_at_ms)
        VALUES (1, '00000000-0000-4000-8000-000000000001', 9999999999999);
        PRAGMA user_version = 2;
      `)
    } finally {
      legacy.close()
    }

    const decision = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* store.acquireInference
      }),
      ReplacementUpstreamEpoch
    )
    assert.equal(decision._tag, "Acquired")

    const migrated = new Database(databasePath, { readonly: true })
    try {
      const version = Schema.decodeUnknownSync(
        Schema.Struct({ user_version: Schema.Number })
      )(migrated.prepare("PRAGMA user_version").get()).user_version
      assert.equal(version, 5)
      const columns = migrated
        .prepare("PRAGMA table_info(inference_admission)")
        .all()
        .map((column) =>
          Schema.decodeUnknownSync(Schema.Struct({ name: Schema.String }))(
            column
          ).name
        )
      assert.deepEqual(columns, ["slot", "claim_token", "upstream_epoch"])
      assert.deepEqual(
        migrated.prepare("SELECT slot, nonce FROM storage_readiness_probe").get(),
        { slot: 1, nonce: 0 }
      )
    } finally {
      migrated.close()
    }
  })
})

test("migrates version-four shared request IDs into an isolated legacy namespace", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    const requestID = await Effect.runPromise(
      parseRequestId("00000000-0000-4000-8000-000000000044")
    )
    const audioDigest = await Effect.runPromise(
      parseAudioDigest("44".repeat(32))
    )
    const legacy = new Database(databasePath)
    try {
      legacy.exec(`
        CREATE TABLE transcription_idempotency (
          request_id TEXT PRIMARY KEY NOT NULL,
          audio_digest TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN ('in_progress', 'completed')),
          generation INTEGER NOT NULL CHECK (generation >= 1),
          claim_token TEXT NOT NULL,
          claimed_at_ms INTEGER NOT NULL CHECK (claimed_at_ms >= 0),
          completed_at_ms INTEGER,
          response_json TEXT,
          CHECK (
            (state = 'in_progress' AND completed_at_ms IS NULL AND response_json IS NULL)
            OR
            (state = 'completed' AND completed_at_ms IS NOT NULL AND response_json IS NOT NULL)
          )
        ) STRICT;
        CREATE INDEX transcription_idempotency_completed_at
          ON transcription_idempotency (completed_at_ms)
          WHERE state = 'completed';
        CREATE TABLE inference_admission (
          slot INTEGER PRIMARY KEY NOT NULL CHECK (slot = 1),
          claim_token TEXT NOT NULL,
          upstream_epoch TEXT NOT NULL
        ) STRICT;
        CREATE TABLE storage_readiness_probe (
          slot INTEGER PRIMARY KEY NOT NULL CHECK (slot = 1),
          nonce INTEGER NOT NULL CHECK (nonce IN (0, 1))
        ) STRICT;
        INSERT INTO storage_readiness_probe (slot, nonce) VALUES (1, 0);
        PRAGMA user_version = 4;
      `)
      legacy
        .prepare(`
          INSERT INTO transcription_idempotency (
            request_id,
            audio_digest,
            state,
            generation,
            claim_token,
            claimed_at_ms,
            completed_at_ms,
            response_json
          ) VALUES (?, ?, 'completed', 1, ?, ?, ?, ?)
        `)
        .run(
          requestID,
          audioDigest,
          "00000000-0000-4000-8000-000000000044",
          BaseEpochMilliseconds,
          BaseEpochMilliseconds + 1,
          JSON.stringify(makeResponse(requestID, "legacy response"))
        )
    } finally {
      legacy.close()
    }

    const deviceDecision = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds + 2,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
      })
    )
    assert.equal(deviceDecision._tag, "Claimed")

    const migrated = new Database(databasePath, { readonly: true })
    try {
      assert.equal(migrated.pragma("user_version", { simple: true }), 5)
      const namespaces = migrated
        .prepare(`
          SELECT device_principal_id
          FROM transcription_idempotency
          ORDER BY device_principal_id
        `)
        .all()
        .map((row) =>
          Schema.decodeUnknownSync(
            Schema.Struct({ device_principal_id: Schema.String })
          )(row).device_principal_id
        )
      assert.deepEqual(namespaces, [
        TestDevicePrincipalID,
        "legacy-shared-bearer"
      ].sort())
    } finally {
      migrated.close()
    }
  })
})

test("migrates the version-three database before serving readiness", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    await runWithStore(
      databasePath,
      Effect.gen(function* () {
        yield* TranscriptionIdempotency
      })
    )

    const versionThree = new Database(databasePath)
    try {
      versionThree.exec(`
        DROP TABLE storage_readiness_probe;
        PRAGMA user_version = 3;
      `)
    } finally {
      versionThree.close()
    }

    const ready = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* store.isReady
      })
    )
    assert.equal(ready, true)

    const migrated = new Database(databasePath, { readonly: true })
    try {
      const version = Schema.decodeUnknownSync(
        Schema.Struct({ user_version: Schema.Number })
      )(migrated.prepare("PRAGMA user_version").get()).user_version
      assert.equal(version, 5)
      assert.deepEqual(
        migrated.prepare("SELECT slot, nonce FROM storage_readiness_probe").get(),
        { slot: 1, nonce: 1 }
      )
    } finally {
      migrated.close()
    }
  })
})

test("does not mask a retention failure with an unrelated storage success", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    await Effect.runPromise(
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        yield* Effect.sync(() => {
          const sabotage = new Database(databasePath)
          try {
            sabotage.exec("DROP TABLE transcription_idempotency")
          } finally {
            sabotage.close()
          }
        })
        yield* Effect.sleep("75 millis")
        assert.equal(yield* store.isReady, false)

        const lease = yield* store.acquireInference
        assert.equal(lease._tag, "Acquired")
        assert.equal(yield* store.isReady, false)
      }).pipe(
        Effect.provide(
          sqliteTranscriptionIdempotencyLayer(
            databasePath,
            FirstUpstreamEpoch,
            "10 millis"
          )
        ),
        Effect.scoped
      )
    )
  })
})

test("does not mask failed claim storage after inference release succeeds", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    await Effect.runPromise(
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        const requestID = yield* parseRequestId(
          "00000000-0000-4000-8000-000000000020"
        )
        const audioDigest = yield* parseAudioDigest("20".repeat(32))
        const decision = yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
        assert.equal(decision._tag, "Claimed")
        if (decision._tag !== "Claimed") {
          return yield* Effect.die("expected an initial claim")
        }
        const inference = yield* store.acquireInference
        assert.equal(inference._tag, "Acquired")
        if (inference._tag !== "Acquired") {
          return yield* Effect.die("expected an inference lease")
        }

        yield* Effect.sync(() => {
          const sabotage = new Database(databasePath)
          try {
            sabotage.exec("DROP TABLE transcription_idempotency")
          } finally {
            sabotage.close()
          }
        })
        const completion = yield* Effect.either(
          store.complete({
            claim: decision.claim,
            response: makeResponse(requestID, "must not persist"),
            nowEpochMilliseconds: BaseEpochMilliseconds + 1
          })
        )
        assert.equal(Either.isLeft(completion), true)

        yield* store.releaseInference(inference.lease)
        assert.equal(yield* store.isReady, false)
      }).pipe(
        Effect.provide(
          sqliteTranscriptionIdempotencyLayer(
            databasePath,
            FirstUpstreamEpoch,
            "1 hour"
          )
        ),
        Effect.scoped
      )
    )
  })
})

test("holds an uncertain inference until the upstream process epoch changes", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    const first = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        const lease = yield* store.acquireInference
        assert.equal(yield* store.isReady, false)
        return lease
      })
    )
    assert.equal(first._tag, "Acquired")
    if (first._tag !== "Acquired") {
      return
    }

    const blockedAfterRestart = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        assert.equal(yield* store.isReady, false)
        return yield* store.acquireInference
      })
    )
    assert.deepEqual(blockedAfterRestart, {
      _tag: "Busy",
      retryAfterSeconds: 1
    })

    const stillBlockedLongAfterTheOldDeadline = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* store.acquireInference
      })
    )
    assert.deepEqual(stillBlockedLongAfterTheOldDeadline, {
      _tag: "Busy",
      retryAfterSeconds: 1
    })

    const replacement = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        assert.equal(yield* store.isReady, true)
        return yield* store.acquireInference
      }),
      ReplacementUpstreamEpoch
    )
    assert.equal(replacement._tag, "Acquired")
    if (replacement._tag !== "Acquired") {
      return
    }
    assert.notEqual(replacement.lease.token, first.lease.token)
    assert.equal(
      replacement.lease.upstreamEpoch,
      ReplacementUpstreamEpoch
    )

    await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        yield* store.releaseInference(first.lease)
        const stillFenced = yield* store.acquireInference
        assert.equal(stillFenced._tag, "Busy")
        yield* store.releaseInference(replacement.lease)
        assert.equal(yield* store.isReady, true)
        const released = yield* store.acquireInference
        assert.equal(released._tag, "Acquired")
      }),
      ReplacementUpstreamEpoch
    )
  })
})

test("namespaces caller request IDs by authenticated device principal", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    const requestID = await Effect.runPromise(
      parseRequestId("00000000-0000-4000-8000-000000000077")
    )
    const firstDigest = await Effect.runPromise(
      parseAudioDigest("77".repeat(32))
    )
    const otherDigest = await Effect.runPromise(
      parseAudioDigest("78".repeat(32))
    )

    await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        const first = yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest: firstDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
        const second = yield* store.begin({
          devicePrincipalID: OtherDevicePrincipalID,
          requestID,
          audioDigest: otherDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds + 1,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
        assert.equal(first._tag, "Claimed")
        assert.equal(second._tag, "Claimed")
        if (first._tag !== "Claimed" || second._tag !== "Claimed") {
          return yield* Effect.die("expected independent device claims")
        }
        yield* store.complete({
          claim: first.claim,
          response: makeResponse(requestID, "first device"),
          nowEpochMilliseconds: BaseEpochMilliseconds + 2
        })
        yield* store.complete({
          claim: second.claim,
          response: makeResponse(requestID, "second device"),
          nowEpochMilliseconds: BaseEpochMilliseconds + 3
        })

        const firstReplay = yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest: firstDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds + 4,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
        const secondReplay = yield* store.begin({
          devicePrincipalID: OtherDevicePrincipalID,
          requestID,
          audioDigest: otherDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds + 5,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
        assert.equal(firstReplay._tag, "Replay")
        assert.equal(secondReplay._tag, "Replay")
        if (firstReplay._tag === "Replay") {
          assert.equal(firstReplay.response.transcript, "first device")
        }
        if (secondReplay._tag === "Replay") {
          assert.equal(secondReplay.response.transcript, "second device")
        }
      })
    )
  })
})

test("recovers stale claims and rejects completion by the old generation", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    const requestID = await Effect.runPromise(
      parseRequestId("00000000-0000-4000-8000-000000000001")
    )
    const audioDigest = await Effect.runPromise(
      parseAudioDigest("01".repeat(32))
    )
    const otherDigest = await Effect.runPromise(
      parseAudioDigest("02".repeat(32))
    )

    const originalClaim = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        const decision = yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
        assert.equal(decision._tag, "Claimed")
        if (decision._tag !== "Claimed") {
          return yield* Effect.die("expected an initial claim")
        }
        return decision.claim
      })
    )
    assert.equal(statSync(databasePath).mode & 0o777, 0o600)

    const freshRetry = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds + 119_999,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
      })
    )
    assert.deepEqual(freshRetry, {
      _tag: "InProgress",
      retryAfterSeconds: 1
    })

    const conflict = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest: otherDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds + 120_000,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
      })
    )
    assert.deepEqual(conflict, { _tag: "Conflict" })

    const replacementClaim = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        const decision = yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds + 120_000,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
        assert.equal(decision._tag, "Claimed")
        if (decision._tag !== "Claimed") {
          return yield* Effect.die("expected a stale-claim takeover")
        }
        return decision.claim
      })
    )
    assert.equal(replacementClaim.generation, originalClaim.generation + 1)
    assert.notEqual(replacementClaim.token, originalClaim.token)

    const oldCompletion = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* Effect.either(
          store.complete({
            claim: originalClaim,
            response: makeResponse(requestID, "obsolete"),
            nowEpochMilliseconds: BaseEpochMilliseconds + 120_001
          })
        )
      })
    )
    assert.equal(Either.isLeft(oldCompletion), true)
    if (Either.isLeft(oldCompletion)) {
      assert.equal(oldCompletion.left._tag, "TranscriptionClaimLostError")
    }

    const expectedResponse = makeResponse(requestID, "durably saved")
    await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        yield* store.complete({
          claim: replacementClaim,
          response: expectedResponse,
          nowEpochMilliseconds: BaseEpochMilliseconds + 120_002
        })
      })
    )

    const replay = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds + 120_003,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
      })
    )
    assert.deepEqual(replay, {
      _tag: "Replay",
      response: expectedResponse
    })
  })
})

test("fences an old attempt after abandoned-claim cleanup reuses its ID", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    const requestID = await Effect.runPromise(
      parseRequestId("00000000-0000-4000-8000-000000000099")
    )
    const audioDigest = await Effect.runPromise(
      parseAudioDigest("99".repeat(32))
    )
    const claimAt = (nowEpochMilliseconds: number) =>
      runWithStore(
        databasePath,
        Effect.gen(function* () {
          const store = yield* TranscriptionIdempotency
          const decision = yield* store.begin({
            devicePrincipalID: TestDevicePrincipalID,
            requestID,
            audioDigest,
            nowEpochMilliseconds,
            staleAfterMilliseconds: StaleAfterMilliseconds
          })
          assert.equal(decision._tag, "Claimed")
          if (decision._tag !== "Claimed") {
            return yield* Effect.die("expected a claim")
          }
          return decision.claim
        })
      )

    const abandoned = await claimAt(BaseEpochMilliseconds)
    const replacement = await claimAt(BaseEpochMilliseconds + OneDayMilliseconds + 1)
    assert.notEqual(replacement.token, abandoned.token)

    const oldCompletion = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* Effect.either(
          store.complete({
            claim: abandoned,
            response: makeResponse(requestID, "must not be saved"),
            nowEpochMilliseconds: BaseEpochMilliseconds + OneDayMilliseconds + 2
          })
        )
      })
    )
    assert.equal(Either.isLeft(oldCompletion), true)
    if (Either.isLeft(oldCompletion)) {
      assert.equal(oldCompletion.left._tag, "TranscriptionClaimLostError")
    }
  })
})

test("bounds completed response retention by count and age", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        yield* Effect.forEach(
          Array.from({ length: 257 }, (_, index) => index + 1),
          (index) =>
            Effect.gen(function* () {
              const suffix = index.toString().padStart(12, "0")
              const requestID = yield* parseRequestId(
                `00000000-0000-4000-8000-${suffix}`
              )
              const audioDigest = yield* parseAudioDigest(
                index.toString(16).padStart(64, "0")
              )
              const decision = yield* store.begin({
                devicePrincipalID: TestDevicePrincipalID,
                requestID,
                audioDigest,
                nowEpochMilliseconds: BaseEpochMilliseconds + index,
                staleAfterMilliseconds: StaleAfterMilliseconds
              })
              assert.equal(decision._tag, "Claimed")
              if (decision._tag !== "Claimed") {
                return yield* Effect.die("expected a unique claim")
              }
              yield* store.complete({
                claim: decision.claim,
                response: makeResponse(requestID, `saved ${index}`),
                nowEpochMilliseconds: BaseEpochMilliseconds + index
              })
            }),
          { concurrency: 1, discard: true }
        )
      })
    )

    const database = new Database(databasePath, { readonly: true })
    try {
      const row = Schema.decodeUnknownSync(
        Schema.Struct({ count: Schema.Number })
      )(
        database
          .prepare(
            "SELECT COUNT(*) AS count FROM transcription_idempotency WHERE state = 'completed'"
          )
          .get()
      )
      assert.equal(row.count, 256)
    } finally {
      database.close()
    }

    const oldestRequestID = await Effect.runPromise(
      parseRequestId("00000000-0000-4000-8000-000000000001")
    )
    const oldestDigest = await Effect.runPromise(
      parseAudioDigest("1".padStart(64, "0"))
    )
    const trimmed = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID: oldestRequestID,
          audioDigest: oldestDigest,
          nowEpochMilliseconds: BaseEpochMilliseconds + 258,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
      })
    )
    assert.equal(trimmed._tag, "Claimed")

    const newestRequestID = await Effect.runPromise(
      parseRequestId("00000000-0000-4000-8000-000000000257")
    )
    const newestDigest = await Effect.runPromise(
      parseAudioDigest("101".padStart(64, "0"))
    )
    const expired = await runWithStore(
      databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        return yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID: newestRequestID,
          audioDigest: newestDigest,
          nowEpochMilliseconds:
            BaseEpochMilliseconds + OneDayMilliseconds + 258,
          staleAfterMilliseconds: StaleAfterMilliseconds
        })
      })
    )
    assert.equal(expired._tag, "Claimed")
  })
})
