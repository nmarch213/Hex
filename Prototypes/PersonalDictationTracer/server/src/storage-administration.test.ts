import assert from "node:assert/strict"
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmdirSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import Database from "better-sqlite3"
import { Effect, Schema } from "effect"

import {
  TranscriptionIdempotency,
  UpstreamProcessEpochSchema
} from "./application/transcription-idempotency.js"
import { DeviceRegistry } from "./application/device-registry.js"
import type { TranscriptionResponse } from "./application/transcription.js"
import { parseAudioDigest } from "./domain/audio-digest.js"
import { DevicePrincipalIdSchema } from "./domain/device-principal.js"
import { parseRequestId } from "./domain/request-id.js"
import { sqliteTranscriptionIdempotencyLayer } from "./adapters/sqlite-transcription-idempotency.js"
import { sqliteDeviceRegistryLayer } from "./adapters/sqlite-device-registry.js"
import {
  createStorageBackup,
  finalizeRestoreRecovery,
  restoreStorageBackup,
  type CreatedStorageBackup
} from "./storage-administration.js"
import {
  DeviceReauthorizationMarkerName,
  DeviceRevocationCompleteMarkerName,
  StorageRestoreMarkerName
} from "./storage-layout.js"

const TestUpstreamEpoch = Schema.decodeUnknownSync(
  UpstreamProcessEpochSchema
)("09".repeat(32))
const TestBuildRevision = "development"
const RequestIDText = "00000000-0000-4000-8000-000000000090"
const AudioDigestText = "90".repeat(32)
const TestDevicePrincipalID = Schema.decodeUnknownSync(
  DevicePrincipalIdSchema
)("00000000-0000-4000-8000-000000000091")

const IdempotencyRegistry = {
  format: "hex-personal-dictation-storage-registry",
  version: 1,
  databases: [
    {
      databaseID: "transcription-idempotency",
      fileName: "idempotency.sqlite",
      schemaUserVersion: 5,
      expectedSchemaFingerprintSHA256:
        "19a64bebf33273f527578822b769ae8ddb126a6b05a0275cef5364841da85201",
      maximumBytes: 268_435_456,
      containsAudio: false,
      allowedSchemaObjects: [
        {
          type: "index",
          name: "transcription_idempotency_completed_at"
        },
        { type: "table", name: "inference_admission" },
        { type: "table", name: "storage_readiness_probe" },
        { type: "table", name: "transcription_idempotency" }
      ]
    }
  ]
} as const

interface TemporaryStorage {
  readonly root: string
  readonly dataDirectory: string
  readonly backupDirectory: string
  readonly registryPath: string
  readonly databasePath: string
}

const makeTemporaryStorage = (): TemporaryStorage => {
  const root = mkdtempSync(join(tmpdir(), "hex-storage-admin-"))
  chmodSync(root, 0o700)
  const dataDirectory = join(root, "data")
  const backupDirectory = join(root, "backups")
  mkdirSync(dataDirectory, { mode: 0o700 })
  mkdirSync(backupDirectory, { mode: 0o700 })
  const registryPath = join(root, "storage-databases.json")
  writeFileSync(
    registryPath,
    `${JSON.stringify(IdempotencyRegistry, null, 2)}\n`,
    { mode: 0o600 }
  )
  return {
    root,
    dataDirectory,
    backupDirectory,
    registryPath,
    databasePath: join(dataDirectory, "idempotency.sqlite")
  }
}

const removeDatabaseFiles = (databasePath: string) => {
  for (const suffix of ["", "-wal", "-shm"]) {
    try {
      unlinkSync(`${databasePath}${suffix}`)
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
}

const withStore = <Output, Error>(
  databasePath: string,
  effect: Effect.Effect<Output, Error, TranscriptionIdempotency>
) =>
  Effect.runPromise(
    effect.pipe(
      Effect.provide(
        sqliteTranscriptionIdempotencyLayer(
          databasePath,
          TestUpstreamEpoch
        )
      ),
      Effect.scoped
    )
  )

const requireBackupSuccess = (
  result: Awaited<ReturnType<typeof createStorageBackup>>
): CreatedStorageBackup => {
  if (result._tag !== "Success") {
    throw result.error
  }
  assert.equal(result._tag, "Success")
  return result.value
}

test("online backup restores and replays a retained response", async () => {
  const storage = makeTemporaryStorage()
  try {
    let created: CreatedStorageBackup | undefined
    const response = await withStore(
      storage.databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        const requestID = yield* parseRequestId(RequestIDText)
        const audioDigest = yield* parseAudioDigest(AudioDigestText)
        const decision = yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest,
          nowEpochMilliseconds: Date.now(),
          staleAfterMilliseconds: 120_000
        })
        assert.equal(decision._tag, "Claimed")
        if (decision._tag !== "Claimed") {
          return yield* Effect.die("expected claim")
        }
        const retainedResponse: TranscriptionResponse = {
          requestID,
          transcript: "retained backup response",
          timings: {
            queueMS: 0,
            recognitionMS: 10,
            serviceMS: 12,
            upstreamMS: 10,
            totalMS: 12
          }
        }
        yield* store.complete({
          claim: decision.claim,
          response: retainedResponse,
          nowEpochMilliseconds: Date.now()
        })

        const backupResult = yield* Effect.promise(() =>
          createStorageBackup({
            registryPath: storage.registryPath,
            dataDirectory: storage.dataDirectory,
            backupDirectory: storage.backupDirectory,
            sourceBuildRevision: TestBuildRevision
          })
        )
        created = requireBackupSuccess(backupResult)
        return retainedResponse
      })
    )
    assert.notEqual(created, undefined)
    if (created === undefined) {
      throw new Error("backup result was not retained")
    }

    const artifactDirectory = join(
      storage.backupDirectory,
      created.artifactName
    )
    assert.deepEqual(readdirSync(artifactDirectory).sort(), [
      "databases",
      "manifest.json"
    ])
    assert.deepEqual(
      readdirSync(join(artifactDirectory, "databases")),
      ["transcription-idempotency.sqlite"]
    )
    assert.equal(statSync(artifactDirectory).mode & 0o077, 0)
    assert.equal(
      statSync(join(artifactDirectory, "manifest.json")).mode & 0o077,
      0
    )
    assert.equal(
      statSync(
        join(
          artifactDirectory,
          "databases",
          "transcription-idempotency.sqlite"
        )
      ).mode & 0o077,
      0
    )

    removeDatabaseFiles(storage.databasePath)
    await withStore(
      storage.databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        assert.equal(yield* store.isReady, true)
      })
    )

    const restoreResult = await restoreStorageBackup({
      registryPath: storage.registryPath,
      dataDirectory: storage.dataDirectory,
      backupDirectory: storage.backupDirectory,
      artifactName: created.artifactName,
      sourceBuildRevision: TestBuildRevision
    })
    if (restoreResult._tag !== "Success") {
      throw restoreResult.error
    }
    assert.equal(restoreResult._tag, "Success")
    assert.equal(restoreResult.value.reauthorizationRequired, false)
    const recoveryDirectory = join(
      storage.dataDirectory,
      `.restore-recovery-${restoreResult.value.recoveryID}`
    )
    assert.equal(statSync(recoveryDirectory).mode & 0o077, 0)
    assert.deepEqual(readdirSync(recoveryDirectory).sort(), [
      "idempotency.sqlite",
      "recovery-plan.json"
    ])
    assert.equal(
      readdirSync(storage.dataDirectory).includes(StorageRestoreMarkerName),
      false
    )

    const replay = await withStore(
      storage.databasePath,
      Effect.gen(function* () {
        const store = yield* TranscriptionIdempotency
        const requestID = yield* parseRequestId(RequestIDText)
        const audioDigest = yield* parseAudioDigest(AudioDigestText)
        return yield* store.begin({
          devicePrincipalID: TestDevicePrincipalID,
          requestID,
          audioDigest,
          nowEpochMilliseconds: Date.now(),
          staleAfterMilliseconds: 120_000
        })
      })
    )
    assert.equal(replay._tag, "Replay")
    if (replay._tag !== "Replay") {
      throw new Error("restored response was not replayed")
    }
    assert.deepEqual(replay.response, response)

    const wrongRecovery = await finalizeRestoreRecovery({
      registryPath: storage.registryPath,
      dataDirectory: storage.dataDirectory,
      recoveryID: "0-00000000-0000-4000-8000-000000000000"
    })
    assert.equal(wrongRecovery._tag, "Failure")
    assert.equal(statSync(recoveryDirectory).isDirectory(), true)

    const finalized = await finalizeRestoreRecovery({
      registryPath: storage.registryPath,
      dataDirectory: storage.dataDirectory,
      recoveryID: restoreResult.value.recoveryID
    })
    assert.equal(finalized._tag, "Success")
    assert.equal(
      readdirSync(storage.dataDirectory).includes(
        `.restore-recovery-${restoreResult.value.recoveryID}`
      ),
      false
    )
  } finally {
    rmSync(storage.root, { recursive: true, force: true })
  }
})

test("restore rejects a changed artifact before replacing live storage", async () => {
  const storage = makeTemporaryStorage()
  try {
    await withStore(
      storage.databasePath,
      Effect.gen(function* () {
        yield* TranscriptionIdempotency
      })
    )
    const created = requireBackupSuccess(
      await createStorageBackup({
        registryPath: storage.registryPath,
        dataDirectory: storage.dataDirectory,
        backupDirectory: storage.backupDirectory,
        sourceBuildRevision: TestBuildRevision
      })
    )
    const before = readFileSync(storage.databasePath)
    const artifactPath = join(
      storage.backupDirectory,
      created.artifactName,
      "databases",
      "transcription-idempotency.sqlite"
    )
    const artifact = readFileSync(artifactPath)
    artifact[artifact.length - 1] = (artifact[artifact.length - 1] ?? 0) ^ 1
    writeFileSync(artifactPath, artifact, { mode: 0o600 })

    const result = await restoreStorageBackup({
      registryPath: storage.registryPath,
      dataDirectory: storage.dataDirectory,
      backupDirectory: storage.backupDirectory,
      artifactName: created.artifactName,
      sourceBuildRevision: TestBuildRevision
    })
    assert.equal(result._tag, "Failure")
    if (result._tag !== "Failure") {
      throw new Error("changed artifact unexpectedly restored")
    }
    assert.equal(result.error.reason, "artifact_invalid")
    assert.deepEqual(readFileSync(storage.databasePath), before)
    assert.equal(
      readdirSync(storage.dataDirectory).includes(StorageRestoreMarkerName),
      false
    )
  } finally {
    rmSync(storage.root, { recursive: true, force: true })
  }
})

test("backup rejects changed SQL with the expected names and user version", async () => {
  const storage = makeTemporaryStorage()
  try {
    const database = new Database(storage.databasePath)
    try {
      database.exec(`
        CREATE TABLE saved_value (
          slot INTEGER PRIMARY KEY NOT NULL CHECK (slot = 1),
          value INTEGER NOT NULL
        ) STRICT;
        PRAGMA user_version = 1;
      `)
    } finally {
      database.close()
    }
    chmodSync(storage.databasePath, 0o600)
    writeFileSync(
      storage.registryPath,
      `${JSON.stringify(
        {
          format: "hex-personal-dictation-storage-registry",
          version: 1,
          databases: [
            {
              databaseID: "settings",
              fileName: "idempotency.sqlite",
              schemaUserVersion: 1,
              expectedSchemaFingerprintSHA256:
                "affc23bf050515425c897f53ff21907682e9dd6686f61b598b58baf67e97ef21",
              maximumBytes: 4_194_304,
              containsAudio: false,
              allowedSchemaObjects: [
                { type: "table", name: "saved_value" }
              ]
            }
          ]
        },
        null,
        2
      )}\n`,
      { mode: 0o600 }
    )

    const result = await createStorageBackup({
      registryPath: storage.registryPath,
      dataDirectory: storage.dataDirectory,
      backupDirectory: storage.backupDirectory,
      sourceBuildRevision: TestBuildRevision
    })
    assert.equal(result._tag, "Failure")
    if (result._tag !== "Failure") {
      throw new Error("changed schema unexpectedly produced a backup")
    }
    assert.equal(result.error.reason, "schema_invalid")
    assert.equal(result.error.databaseID, "settings")
    assert.deepEqual(readdirSync(storage.backupDirectory), [])
  } finally {
    rmSync(storage.root, { recursive: true, force: true })
  }
})

test("an incomplete restore marker blocks service storage startup", async () => {
  const storage = makeTemporaryStorage()
  try {
    mkdirSync(join(storage.dataDirectory, StorageRestoreMarkerName), {
      mode: 0o700
    })
    const result = await Effect.runPromise(
      Effect.either(
        Effect.gen(function* () {
          yield* TranscriptionIdempotency
        }).pipe(
          Effect.provide(
            sqliteTranscriptionIdempotencyLayer(
              storage.databasePath,
              TestUpstreamEpoch
            )
          ),
          Effect.scoped
        )
      )
    )
    assert.equal(result._tag, "Left")
  } finally {
    rmSync(storage.root, { recursive: true, force: true })
  }
})

test("a new restore attempt preserves an existing fail-closed marker", async () => {
  const storage = makeTemporaryStorage()
  try {
    await withStore(
      storage.databasePath,
      Effect.gen(function* () {
        yield* TranscriptionIdempotency
      })
    )
    const created = requireBackupSuccess(
      await createStorageBackup({
        registryPath: storage.registryPath,
        dataDirectory: storage.dataDirectory,
        backupDirectory: storage.backupDirectory,
        sourceBuildRevision: TestBuildRevision
      })
    )
    const restoreMarker = join(
      storage.dataDirectory,
      StorageRestoreMarkerName
    )
    mkdirSync(restoreMarker, { mode: 0o700 })
    const markerEvidence = join(restoreMarker, "operator-review-required")
    writeFileSync(markerEvidence, "", { mode: 0o600 })

    const result = await restoreStorageBackup({
      registryPath: storage.registryPath,
      dataDirectory: storage.dataDirectory,
      backupDirectory: storage.backupDirectory,
      artifactName: created.artifactName,
      sourceBuildRevision: TestBuildRevision
    })
    assert.equal(result._tag, "Failure")
    assert.deepEqual(readdirSync(restoreMarker), [
      "operator-review-required"
    ])
    assert.equal(statSync(markerEvidence).isFile(), true)
  } finally {
    rmSync(storage.root, { recursive: true, force: true })
  }
})

test("one manifest backs up and restores multiple registered databases", async () => {
  const storage = makeTemporaryStorage()
  try {
    const secondDatabasePath = join(storage.dataDirectory, "settings.sqlite")
    const initialize = (path: string, value: string) => {
      const database = new Database(path)
      try {
        database.exec(
          `CREATE TABLE saved_value (slot INTEGER PRIMARY KEY NOT NULL CHECK (slot = 1), value TEXT NOT NULL) STRICT;
           INSERT INTO saved_value (slot, value) VALUES (1, '${value}');
           PRAGMA user_version = 1;`
        )
      } finally {
        database.close()
      }
      chmodSync(path, 0o600)
    }

    initialize(storage.databasePath, "first-original")
    initialize(secondDatabasePath, "second-original")
    const registry = {
      format: "hex-personal-dictation-storage-registry",
      version: 1,
      databases: [
        {
          databaseID: "first",
          fileName: "idempotency.sqlite",
          schemaUserVersion: 1,
          expectedSchemaFingerprintSHA256:
            "affc23bf050515425c897f53ff21907682e9dd6686f61b598b58baf67e97ef21",
          maximumBytes: 4_194_304,
          containsAudio: false,
          allowedSchemaObjects: [{ type: "table", name: "saved_value" }]
        },
        {
          databaseID: "second",
          fileName: "settings.sqlite",
          schemaUserVersion: 1,
          expectedSchemaFingerprintSHA256:
            "affc23bf050515425c897f53ff21907682e9dd6686f61b598b58baf67e97ef21",
          maximumBytes: 4_194_304,
          containsAudio: false,
          allowedSchemaObjects: [{ type: "table", name: "saved_value" }]
        }
      ]
    }
    writeFileSync(
      storage.registryPath,
      `${JSON.stringify(registry, null, 2)}\n`,
      { mode: 0o600 }
    )
    const created = requireBackupSuccess(
      await createStorageBackup({
        registryPath: storage.registryPath,
        dataDirectory: storage.dataDirectory,
        backupDirectory: storage.backupDirectory,
        sourceBuildRevision: TestBuildRevision
      })
    )

    const update = (path: string, value: string) => {
      const database = new Database(path)
      try {
        database
          .prepare("UPDATE saved_value SET value = ? WHERE slot = 1")
          .run(value)
      } finally {
        database.close()
      }
    }
    update(storage.databasePath, "first-changed")
    update(secondDatabasePath, "second-changed")

    const restored = await restoreStorageBackup({
      registryPath: storage.registryPath,
      dataDirectory: storage.dataDirectory,
      backupDirectory: storage.backupDirectory,
      artifactName: created.artifactName,
      sourceBuildRevision: TestBuildRevision
    })
    assert.equal(restored._tag, "Success")

    const read = (path: string) => {
      const database = new Database(path, { readonly: true })
      try {
        return Schema.decodeUnknownSync(
          Schema.Struct({ value: Schema.String })
        )(
          database
            .prepare("SELECT value FROM saved_value WHERE slot = 1")
            .get()
        ).value
      } finally {
        database.close()
      }
    }
    assert.equal(read(storage.databasePath), "first-original")
    assert.equal(read(secondDatabasePath), "second-original")
  } finally {
    rmSync(storage.root, { recursive: true, force: true })
  }
})

test("production registry backs up both live storage adapters", async () => {
  const storage = makeTemporaryStorage()
  try {
    const deviceDatabasePath = join(storage.dataDirectory, "devices.sqlite")
    const registryPath = join(process.cwd(), "storage-databases.json")
    let created: CreatedStorageBackup | undefined
    await Effect.runPromise(
      Effect.gen(function* () {
        yield* TranscriptionIdempotency
        yield* DeviceRegistry
        const backupResult = yield* Effect.promise(() =>
          createStorageBackup({
            registryPath,
            dataDirectory: storage.dataDirectory,
            backupDirectory: storage.backupDirectory,
            sourceBuildRevision: TestBuildRevision
          })
        )
        created = requireBackupSuccess(backupResult)
      }).pipe(
        Effect.provide(
          sqliteTranscriptionIdempotencyLayer(
            storage.databasePath,
            TestUpstreamEpoch
          )
        ),
        Effect.provide(sqliteDeviceRegistryLayer(deviceDatabasePath)),
        Effect.scoped
      )
    )
    assert.notEqual(created, undefined)
    if (created === undefined) {
      throw new Error("production backup was not created")
    }
    assert.deepEqual(
      readdirSync(
        join(
          storage.backupDirectory,
          created.artifactName,
          "databases"
        )
      ).sort(),
      ["device-registry.sqlite", "transcription-idempotency.sqlite"]
    )

    // A failure after this attempt creates its reauthorization gate must roll
    // the untouched live databases back to an immediately startable state.
    chmodSync(deviceDatabasePath, 0o644)
    const failedWithNewGate = await restoreStorageBackup({
      registryPath,
      dataDirectory: storage.dataDirectory,
      backupDirectory: storage.backupDirectory,
      artifactName: created.artifactName,
      sourceBuildRevision: TestBuildRevision
    })
    assert.equal(failedWithNewGate._tag, "Failure")
    assert.equal(
      readdirSync(storage.dataDirectory).includes(
        DeviceReauthorizationMarkerName
      ),
      false
    )
    assert.equal(
      readdirSync(storage.dataDirectory).includes(StorageRestoreMarkerName),
      false
    )
    chmodSync(deviceDatabasePath, 0o600)

    // A gate from an earlier restore is not owned by this attempt and must
    // remain fail-closed when a later restore rolls back.
    const preexistingReauthorizationDirectory = join(
      storage.dataDirectory,
      DeviceReauthorizationMarkerName
    )
    mkdirSync(preexistingReauthorizationDirectory, { mode: 0o700 })
    chmodSync(storage.databasePath, 0o644)
    const failedWithExistingGate = await restoreStorageBackup({
      registryPath,
      dataDirectory: storage.dataDirectory,
      backupDirectory: storage.backupDirectory,
      artifactName: created.artifactName,
      sourceBuildRevision: TestBuildRevision
    })
    assert.equal(failedWithExistingGate._tag, "Failure")
    assert.equal(
      statSync(preexistingReauthorizationDirectory).isDirectory(),
      true
    )
    assert.equal(
      readdirSync(storage.dataDirectory).includes(StorageRestoreMarkerName),
      false
    )
    chmodSync(storage.databasePath, 0o600)
    rmdirSync(preexistingReauthorizationDirectory)

    const restoreResult = await restoreStorageBackup({
      registryPath,
      dataDirectory: storage.dataDirectory,
      backupDirectory: storage.backupDirectory,
      artifactName: created.artifactName,
      sourceBuildRevision: TestBuildRevision
    })
    if (restoreResult._tag !== "Success") {
      throw restoreResult.error
    }
    assert.equal(restoreResult._tag, "Success")
    assert.equal(restoreResult.value.reauthorizationRequired, true)
    const reauthorizationDirectory = join(
      storage.dataDirectory,
      DeviceReauthorizationMarkerName
    )
    assert.equal(statSync(reauthorizationDirectory).mode & 0o077, 0)

    const staleRevocationProof = join(
      reauthorizationDirectory,
      DeviceRevocationCompleteMarkerName
    )
    mkdirSync(staleRevocationProof, { mode: 0o700 })
    const replacementRestore = await restoreStorageBackup({
      registryPath,
      dataDirectory: storage.dataDirectory,
      backupDirectory: storage.backupDirectory,
      artifactName: created.artifactName,
      sourceBuildRevision: TestBuildRevision
    })
    assert.equal(replacementRestore._tag, "Success")
    assert.equal(readdirSync(reauthorizationDirectory).length, 0)
  } finally {
    rmSync(storage.root, { recursive: true, force: true })
  }
})
