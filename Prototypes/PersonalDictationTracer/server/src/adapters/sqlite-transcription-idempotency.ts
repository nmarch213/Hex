import Database, { type Statement } from "better-sqlite3"
import { randomUUID } from "node:crypto"
import { chmodSync, lstatSync, mkdirSync, statSync } from "node:fs"
import { dirname, join } from "node:path"
import { Clock, Duration, Effect, Layer, Schedule, Schema } from "effect"

import {
  TranscriptionClaimLostError,
  TranscriptionClaimTokenSchema,
  TranscriptionIdempotency,
  TranscriptionIdempotencyUnavailableError,
  UpstreamProcessEpochSchema,
  type BeginTranscriptionClaim,
  type CompleteTranscriptionClaim,
  type InferenceLease,
  type InferenceLeaseDecision,
  type TranscriptionClaimDecision,
  type TranscriptionIdempotencyService,
  type UpstreamProcessEpoch
} from "../application/transcription-idempotency.js"
import { TranscriptionResponseSchema } from "../application/transcription.js"
import { StorageRestoreMarkerName } from "../storage-layout.js"

const SchemaVersion = 5
const LegacySharedCredentialNamespace = "legacy-shared-bearer"
const MaximumCompletedRetentionMilliseconds = 24 * 60 * 60 * 1_000
const CleanupIntervalMilliseconds = 15 * 60 * 1_000
const CompletedRetentionMilliseconds =
  MaximumCompletedRetentionMilliseconds - CleanupIntervalMilliseconds
const AbandonedClaimRetentionMilliseconds = 24 * 60 * 60 * 1_000
const MaximumCompletedResponses = 256
const CleanupInterval = "15 minutes"
const DatabaseBusyTimeoutMilliseconds = 1_000

const StoredClaimSchema = Schema.Struct({
  audio_digest: Schema.String,
  state: Schema.Literal("in_progress", "completed"),
  generation: Schema.Number,
  claim_token: TranscriptionClaimTokenSchema,
  claimed_at_ms: Schema.Number,
  response_json: Schema.NullOr(Schema.String)
})
const StoredInferenceLeaseSchema = Schema.Struct({
  claim_token: TranscriptionClaimTokenSchema,
  upstream_epoch: UpstreamProcessEpochSchema
})

interface PreparedStatements {
  readonly selectClaim: Statement
  readonly insertClaim: Statement
  readonly reclaimClaim: Statement
  readonly completeClaim: Statement
  readonly abandonClaim: Statement
  readonly deleteExpiredCompleted: Statement
  readonly deleteAbandonedClaims: Statement
  readonly trimCompleted: Statement
  readonly selectInferenceLease: Statement
  readonly upsertInferenceLease: Statement
  readonly releaseInferenceLease: Statement
  readonly updateStorageReadinessProbe: Statement
}

interface DatabaseResource {
  readonly database: Database.Database
  readonly statements: PreparedStatements
  readonly health: {
    storageHealthy: boolean
    maintenanceHealthy: boolean
  }
  readonly service: TranscriptionIdempotencyService
}

const decodeStoredClaim = Schema.decodeUnknownSync(StoredClaimSchema)
const decodeStoredInferenceLease = Schema.decodeUnknownSync(
  StoredInferenceLeaseSchema
)
const decodeClaimToken = Schema.decodeUnknownSync(TranscriptionClaimTokenSchema)
const decodeStoredResponse = Schema.decodeUnknownSync(
  Schema.parseJson(TranscriptionResponseSchema)
)

const transaction = <Output>(
  database: Database.Database,
  operation: () => Output
): Output => {
  database.exec("BEGIN IMMEDIATE")
  try {
    const output = operation()
    database.exec("COMMIT")
    return output
  } catch (cause) {
    if (database.inTransaction) {
      try {
        database.exec("ROLLBACK")
      } catch {
        // Preserve the operation failure; reopening the scoped adapter is the
        // only safe recovery if rollback itself cannot complete.
      }
    }
    throw cause
  }
}

const migrateLegacyClaims = (database: Database.Database) => {
  database.exec(`
    DROP INDEX IF EXISTS transcription_idempotency_completed_at;
    ALTER TABLE transcription_idempotency
      RENAME TO transcription_idempotency_legacy;
    CREATE TABLE transcription_idempotency (
      device_principal_id TEXT NOT NULL,
      request_id TEXT NOT NULL,
      audio_digest TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('in_progress', 'completed')),
      generation INTEGER NOT NULL CHECK (generation >= 1),
      claim_token TEXT NOT NULL,
      claimed_at_ms INTEGER NOT NULL CHECK (claimed_at_ms >= 0),
      completed_at_ms INTEGER,
      response_json TEXT,
      PRIMARY KEY (device_principal_id, request_id),
      CHECK (
        (state = 'in_progress' AND completed_at_ms IS NULL AND response_json IS NULL)
        OR
        (state = 'completed' AND completed_at_ms IS NOT NULL AND response_json IS NOT NULL)
      )
    ) STRICT;
    INSERT INTO transcription_idempotency (
      device_principal_id,
      request_id,
      audio_digest,
      state,
      generation,
      claim_token,
      claimed_at_ms,
      completed_at_ms,
      response_json
    )
    SELECT
      '${LegacySharedCredentialNamespace}',
      request_id,
      audio_digest,
      state,
      generation,
      claim_token,
      claimed_at_ms,
      completed_at_ms,
      response_json
    FROM transcription_idempotency_legacy;
    DROP TABLE transcription_idempotency_legacy;
    CREATE INDEX transcription_idempotency_completed_at
      ON transcription_idempotency (completed_at_ms)
      WHERE state = 'completed';
  `)
}

const initializeDatabase = (database: Database.Database) => {
  database.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = FULL;
    PRAGMA foreign_keys = ON;
    PRAGMA secure_delete = ON;
    PRAGMA temp_store = MEMORY;
    PRAGMA wal_autocheckpoint = 100;
  `)

  const versionRow = database.prepare("PRAGMA user_version").get()
  const version = Schema.decodeUnknownSync(
    Schema.Struct({ user_version: Schema.Number })
  )(versionRow).user_version

  if (version === 0) {
    transaction(database, () => {
      database.exec(`
        CREATE TABLE transcription_idempotency (
          device_principal_id TEXT NOT NULL,
          request_id TEXT NOT NULL,
          audio_digest TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN ('in_progress', 'completed')),
          generation INTEGER NOT NULL CHECK (generation >= 1),
          claim_token TEXT NOT NULL,
          claimed_at_ms INTEGER NOT NULL CHECK (claimed_at_ms >= 0),
          completed_at_ms INTEGER,
          response_json TEXT,
          PRIMARY KEY (device_principal_id, request_id),
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
        PRAGMA user_version = ${SchemaVersion};
      `)
    })
    return
  }

  if (version === 1) {
    transaction(database, () => {
      migrateLegacyClaims(database)
      database.exec(`
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
        PRAGMA user_version = ${SchemaVersion};
      `)
    })
    return
  }

  if (version === 2) {
    transaction(database, () => {
      migrateLegacyClaims(database)
      // Version 2 used a guessed wall-clock lease. The supported deployment
      // path stops Parakeet before starting this migration, so no native work
      // can survive removal of that obsolete fence.
      database.exec(`
        DROP TABLE inference_admission;
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
        PRAGMA user_version = ${SchemaVersion};
      `)
    })
    return
  }

  if (version === 3) {
    transaction(database, () => {
      migrateLegacyClaims(database)
      database.exec(`
        CREATE TABLE storage_readiness_probe (
          slot INTEGER PRIMARY KEY NOT NULL CHECK (slot = 1),
          nonce INTEGER NOT NULL CHECK (nonce IN (0, 1))
        ) STRICT;
        INSERT INTO storage_readiness_probe (slot, nonce) VALUES (1, 0);
        PRAGMA user_version = ${SchemaVersion};
      `)
    })
    return
  }

  if (version === 4) {
    transaction(database, () => {
      migrateLegacyClaims(database)
      database.exec(`PRAGMA user_version = ${SchemaVersion};`)
    })
    return
  }

  if (version !== SchemaVersion) {
    throw new Error("unsupported transcription idempotency schema")
  }
}

const prepareStatements = (
  database: Database.Database
): PreparedStatements => ({
  selectClaim: database.prepare(`
    SELECT
      audio_digest,
      state,
      generation,
      claim_token,
      claimed_at_ms,
      response_json
    FROM transcription_idempotency
    WHERE device_principal_id = ? AND request_id = ?
  `),
  insertClaim: database.prepare(`
    INSERT INTO transcription_idempotency (
      device_principal_id,
      request_id,
      audio_digest,
      state,
      generation,
      claim_token,
      claimed_at_ms,
      completed_at_ms,
      response_json
    ) VALUES (?, ?, ?, 'in_progress', 1, ?, ?, NULL, NULL)
  `),
  reclaimClaim: database.prepare(`
    UPDATE transcription_idempotency
    SET generation = generation + 1, claim_token = ?, claimed_at_ms = ?
    WHERE device_principal_id = ?
      AND request_id = ?
      AND state = 'in_progress'
      AND generation = ?
  `),
  completeClaim: database.prepare(`
    UPDATE transcription_idempotency
    SET state = 'completed', completed_at_ms = ?, response_json = ?
    WHERE device_principal_id = ?
      AND request_id = ?
      AND audio_digest = ?
      AND state = 'in_progress'
      AND generation = ?
      AND claim_token = ?
  `),
  abandonClaim: database.prepare(`
    DELETE FROM transcription_idempotency
    WHERE device_principal_id = ?
      AND request_id = ?
      AND audio_digest = ?
      AND state = 'in_progress'
      AND generation = ?
      AND claim_token = ?
  `),
  deleteExpiredCompleted: database.prepare(`
    DELETE FROM transcription_idempotency
    WHERE state = 'completed' AND completed_at_ms <= ?
  `),
  deleteAbandonedClaims: database.prepare(`
    DELETE FROM transcription_idempotency
    WHERE state = 'in_progress' AND claimed_at_ms < ?
  `),
  trimCompleted: database.prepare(`
    DELETE FROM transcription_idempotency
    WHERE rowid IN (
      SELECT rowid
      FROM transcription_idempotency
      WHERE state = 'completed'
      ORDER BY completed_at_ms DESC, device_principal_id DESC, request_id DESC
      LIMIT -1 OFFSET ?
    )
  `),
  selectInferenceLease: database.prepare(`
    SELECT claim_token, upstream_epoch
    FROM inference_admission
    WHERE slot = 1
  `),
  upsertInferenceLease: database.prepare(`
    INSERT INTO inference_admission (slot, claim_token, upstream_epoch)
    VALUES (1, ?, ?)
    ON CONFLICT(slot) DO UPDATE SET
      claim_token = excluded.claim_token,
      upstream_epoch = excluded.upstream_epoch
  `),
  releaseInferenceLease: database.prepare(`
    DELETE FROM inference_admission
    WHERE slot = 1 AND claim_token = ? AND upstream_epoch = ?
  `),
  updateStorageReadinessProbe: database.prepare(`
    UPDATE storage_readiness_probe
    SET nonce = 1 - nonce
    WHERE slot = 1
  `)
})

const cleanup = (
  statements: PreparedStatements,
  nowEpochMilliseconds: number
) => {
  statements.deleteExpiredCompleted.run(
    Math.max(0, nowEpochMilliseconds - CompletedRetentionMilliseconds)
  )
  statements.deleteAbandonedClaims.run(
    Math.max(0, nowEpochMilliseconds - AbandonedClaimRetentionMilliseconds)
  )
  statements.trimCompleted.run(MaximumCompletedResponses)
}

const makeBegin = (
  database: Database.Database,
  statements: PreparedStatements
) =>
  (input: BeginTranscriptionClaim): TranscriptionClaimDecision =>
    transaction(database, () => {
      cleanup(statements, input.nowEpochMilliseconds)
      const unknownRow = statements.selectClaim.get(
        input.devicePrincipalID,
        input.requestID
      )
      if (unknownRow === undefined) {
        const token = decodeClaimToken(randomUUID())
        statements.insertClaim.run(
          input.devicePrincipalID,
          input.requestID,
          input.audioDigest,
          token,
          input.nowEpochMilliseconds
        )
        return {
          _tag: "Claimed",
          claim: {
            devicePrincipalID: input.devicePrincipalID,
            requestID: input.requestID,
            audioDigest: input.audioDigest,
            generation: 1,
            token
          }
        }
      }

      const row = decodeStoredClaim(unknownRow)
      if (row.audio_digest !== input.audioDigest) {
        return { _tag: "Conflict" }
      }

      if (row.state === "completed") {
        if (row.response_json === null) {
          throw new Error("completed response is missing")
        }
        const response = decodeStoredResponse(row.response_json)
        if (response.requestID !== input.requestID) {
          throw new Error("completed response request ID mismatch")
        }
        return { _tag: "Replay", response }
      }

      const claimAge = Math.max(
        0,
        input.nowEpochMilliseconds - row.claimed_at_ms
      )
      if (claimAge < input.staleAfterMilliseconds) {
        return {
          _tag: "InProgress",
          retryAfterSeconds: 1
        }
      }

      const token = decodeClaimToken(randomUUID())
      const reclaimed = statements.reclaimClaim.run(
        token,
        input.nowEpochMilliseconds,
        input.devicePrincipalID,
        input.requestID,
        row.generation
      )
      if (reclaimed.changes !== 1) {
        throw new Error("stale claim changed during transaction")
      }
      return {
        _tag: "Claimed",
        claim: {
          devicePrincipalID: input.devicePrincipalID,
          requestID: input.requestID,
          audioDigest: input.audioDigest,
          generation: row.generation + 1,
          token
        }
      }
    })

const makeComplete = (
  database: Database.Database,
  statements: PreparedStatements
) =>
  (input: CompleteTranscriptionClaim) =>
    transaction(database, () => {
      const responseJSON = JSON.stringify(input.response)
      const completed = statements.completeClaim.run(
        input.nowEpochMilliseconds,
        responseJSON,
        input.claim.devicePrincipalID,
        input.claim.requestID,
        input.claim.audioDigest,
        input.claim.generation,
        input.claim.token
      )
      if (completed.changes !== 1) {
        // Claim identity is intentionally absent from this error. The failure
        // crosses a traced boundary and Effect exports tagged error details.
        throw new TranscriptionClaimLostError({})
      }
      cleanup(statements, input.nowEpochMilliseconds)
    })

const makeAcquireInference = (
  database: Database.Database,
  statements: PreparedStatements,
  upstreamEpoch: UpstreamProcessEpoch
) =>
  (): InferenceLeaseDecision =>
    transaction(database, () => {
      const unknownLease = statements.selectInferenceLease.get()
      if (unknownLease !== undefined) {
        const lease = decodeStoredInferenceLease(unknownLease)
        if (lease.upstream_epoch === upstreamEpoch) {
          return {
            _tag: "Busy",
            retryAfterSeconds: 1
          }
        }
      }

      const token = decodeClaimToken(randomUUID())
      statements.upsertInferenceLease.run(token, upstreamEpoch)
      return {
        _tag: "Acquired",
        lease: { token, upstreamEpoch }
      }
    })

const releaseInference = (
  database: Database.Database,
  statements: PreparedStatements,
  lease: InferenceLease
) => {
  transaction(database, () => {
    statements.releaseInferenceLease.run(lease.token, lease.upstreamEpoch)
  })
}

const makeService = (
  database: Database.Database,
  statements: PreparedStatements,
  upstreamEpoch: UpstreamProcessEpoch,
  health: DatabaseResource["health"]
): TranscriptionIdempotencyService => {
  const beginSync = makeBegin(database, statements)
  const completeSync = makeComplete(database, statements)
  const acquireInferenceSync = makeAcquireInference(
    database,
    statements,
    upstreamEpoch
  )

  return {
    isReady: Effect.sync(() => {
      if (!health.maintenanceHealthy) {
        return false
      }
      try {
        // The bounded probe mutation must commit in the same write domain as
        // claims and leases. BEGIN IMMEDIATE plus reads can still succeed when
        // the filesystem has no capacity for a real write.
        const unknownLease = transaction(database, () => {
          const probe = statements.updateStorageReadinessProbe.run()
          if (probe.changes !== 1) {
            throw new Error("storage readiness probe row is missing")
          }
          statements.selectClaim.get(
            "00000000-0000-4000-8000-000000000000",
            "00000000-0000-4000-8000-000000000000"
          )
          return statements.selectInferenceLease.get()
        })
        health.storageHealthy = true
        if (unknownLease === undefined) {
          return true
        }
        const lease = decodeStoredInferenceLease(unknownLease)
        return lease.upstream_epoch !== upstreamEpoch
      } catch {
        health.storageHealthy = false
        return false
      }
    }),
    acquireInference:
      Effect.try({
        try: () => acquireInferenceSync(),
        catch: () =>
          new TranscriptionIdempotencyUnavailableError({
            operation: "acquire_inference"
          })
      }).pipe(
        Effect.tap(() =>
          Effect.sync(() => {
            health.storageHealthy = true
          })
        ),
        Effect.tapError(() =>
          Effect.sync(() => {
            health.storageHealthy = false
          })
        )
      ),
    releaseInference: (lease) =>
      Effect.try({
        try: () => releaseInference(database, statements, lease),
        catch: () =>
          new TranscriptionIdempotencyUnavailableError({
            operation: "release_inference"
          })
      }).pipe(
        Effect.tap(() =>
          Effect.sync(() => {
            health.storageHealthy = true
          })
        ),
        Effect.tapError(() =>
          Effect.sync(() => {
            health.storageHealthy = false
          })
        )
      ),
    begin: (input) =>
      Effect.try({
        try: () => beginSync(input),
        catch: () =>
          new TranscriptionIdempotencyUnavailableError({
            operation: "begin"
          })
      }).pipe(
        Effect.tap(() =>
          Effect.sync(() => {
            health.storageHealthy = true
          })
        ),
        Effect.tapError((error) =>
          error instanceof TranscriptionIdempotencyUnavailableError
            ? Effect.sync(() => {
                health.storageHealthy = false
              })
            : Effect.void
        )
      ),
    complete: (input) =>
      Effect.try({
        try: () => completeSync(input),
        catch: (cause) =>
          cause instanceof TranscriptionClaimLostError
            ? cause
            : new TranscriptionIdempotencyUnavailableError({
                operation: "complete"
              })
      }).pipe(
        Effect.tap(() =>
          Effect.sync(() => {
            health.storageHealthy = true
          })
        ),
        Effect.tapError((error) =>
          error instanceof TranscriptionIdempotencyUnavailableError
            ? Effect.sync(() => {
                health.storageHealthy = false
              })
            : Effect.void
        )
      ),
    abandon: (claim) =>
      Effect.try({
        try: () => {
          transaction(database, () => {
            statements.abandonClaim.run(
              claim.devicePrincipalID,
              claim.requestID,
              claim.audioDigest,
              claim.generation,
              claim.token
            )
          })
        },
        catch: () =>
          new TranscriptionIdempotencyUnavailableError({
            operation: "abandon"
          })
      }).pipe(
        Effect.tap(() =>
          Effect.sync(() => {
            health.storageHealthy = true
          })
        ),
        Effect.tapError(() =>
          Effect.sync(() => {
            health.storageHealthy = false
          })
        )
      )
  }
}

const openDatabaseResource = (
  databasePath: string,
  upstreamEpoch: UpstreamProcessEpoch,
  maximumPageCount: number | undefined
): DatabaseResource => {
  if (databasePath !== ":memory:") {
    const parentDirectory = dirname(databasePath)
    mkdirSync(parentDirectory, { recursive: true, mode: 0o700 })
    const parent = statSync(parentDirectory)
    if (!parent.isDirectory() || (parent.mode & 0o077) !== 0) {
      throw new Error("idempotency database directory is not owner-only")
    }
    try {
      lstatSync(join(parentDirectory, StorageRestoreMarkerName))
      throw new Error("storage restore is incomplete")
    } catch (cause) {
      const code =
        typeof cause === "object" && cause !== null && "code" in cause
          ? cause.code
          : undefined
      if (code !== "ENOENT") {
        throw cause
      }
    }
  }

  let database: Database.Database | undefined
  try {
    database = new Database(databasePath, {
      timeout: DatabaseBusyTimeoutMilliseconds
    })
    initializeDatabase(database)
    if (maximumPageCount !== undefined) {
      if (!Number.isSafeInteger(maximumPageCount) || maximumPageCount <= 0) {
        throw new Error("maximum page count must be a positive safe integer")
      }
      const appliedMaximumPageCount = database.pragma(
        `max_page_count = ${maximumPageCount}`,
        { simple: true }
      )
      if (appliedMaximumPageCount !== maximumPageCount) {
        throw new Error("maximum page count could not be applied")
      }
    }
    if (databasePath !== ":memory:") {
      chmodSync(databasePath, 0o600)
    }
    const statements = prepareStatements(database)
    const health = {
      storageHealthy: true,
      maintenanceHealthy: true
    }
    return {
      database,
      statements,
      health,
      service: makeService(database, statements, upstreamEpoch, health)
    }
  } catch (cause) {
    if (database?.open === true) {
      try {
        database.close()
      } catch {
        // Preserve the initialization failure translated at the Effect seam.
      }
    }
    throw cause
  }
}

const cleanupResource = (resource: DatabaseResource) =>
  Clock.currentTimeMillis.pipe(
    Effect.flatMap((nowEpochMilliseconds) =>
      Effect.try({
        try: () => {
          transaction(resource.database, () =>
            cleanup(resource.statements, nowEpochMilliseconds)
          )
          resource.database.pragma("wal_checkpoint(TRUNCATE)")
        },
        catch: () =>
          new TranscriptionIdempotencyUnavailableError({
            operation: "cleanup"
          })
      })
    )
  ).pipe(
    Effect.tap(() =>
      Effect.sync(() => {
        resource.health.maintenanceHealthy = true
      })
    ),
    Effect.tapError(() =>
      Effect.sync(() => {
        resource.health.maintenanceHealthy = false
      })
    )
  )

/**
 * Builds the scoped better-sqlite3 adapter for durable idempotency on Node 24.
 *
 * The database uses WAL plus FULL synchronous commits. Claims and completions
 * use separate immediate transactions so inference never holds a database
 * transaction open.
 */
export const sqliteTranscriptionIdempotencyLayer = (
  databasePath: string,
  upstreamEpoch: UpstreamProcessEpoch,
  cleanupInterval: Duration.DurationInput = CleanupInterval,
  maximumPageCount?: number
): Layer.Layer<
  TranscriptionIdempotency,
  TranscriptionIdempotencyUnavailableError
> =>
  Layer.scoped(
    TranscriptionIdempotency,
    Effect.acquireRelease(
      Effect.try({
        try: () =>
          openDatabaseResource(databasePath, upstreamEpoch, maximumPageCount),
        catch: () =>
          new TranscriptionIdempotencyUnavailableError({
            operation: "initialize"
          })
      }),
      (resource) => Effect.sync(() => resource.database.close())
    ).pipe(
      Effect.tap(cleanupResource),
      Effect.tap((resource) =>
        cleanupResource(resource).pipe(
          Effect.catchAll((error) =>
            Effect.annotateLogs(
              Effect.logError("transcription_idempotency_cleanup_failed"),
              {
                event: "transcription_idempotency_cleanup_failed",
                error_type: error._tag,
                operation: error.operation
              }
            )
          ),
          Effect.scheduleForked(Schedule.spaced(cleanupInterval))
        )
      ),
      Effect.map((resource) => resource.service)
    )
  )
