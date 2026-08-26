import assert from "node:assert/strict"
import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import Database from "better-sqlite3"
import {
  Effect,
  Either,
  Layer,
  Redacted,
  Schema
} from "effect"

import { DeviceAuthentication } from "../application/device-authentication.js"
import {
  DeviceRegistry,
  MaximumDevicePrincipals,
  type DeviceRegistryService
} from "../application/device-registry.js"
import {
  DeviceDisplayNameSchema,
  DeviceCredentialSchema,
  DevicePlatformSchema,
  type DeviceCapability,
  type DevicePrincipalId
} from "../domain/device-principal.js"
import { sqliteDeviceRegistryLayer } from "./sqlite-device-registry.js"

const decodeDisplayName = Schema.decodeUnknownSync(DeviceDisplayNameSchema)
const decodePlatform = Schema.decodeUnknownSync(DevicePlatformSchema)

const withTemporaryDatabase = async (
  operation: (databasePath: string) => Promise<void>
) => {
  const directory = mkdtempSync(join(tmpdir(), "hex-devices-"))
  try {
    await operation(join(directory, "devices.sqlite"))
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

const runWithRegistry = <Output, Error>(
  databasePath: string,
  effect: Effect.Effect<Output, Error, DeviceRegistry>
) =>
  Effect.runPromise(
    effect.pipe(
      Effect.provide(sqliteDeviceRegistryLayer(databasePath)),
      Effect.scoped
    )
  )

const authenticationAndRegistryLayer = (databasePath: string) =>
  DeviceAuthentication.Default.pipe(
    Layer.provideMerge(sqliteDeviceRegistryLayer(databasePath))
  )

const enroll = (
  registry: DeviceRegistryService,
  displayName: string,
  platform: "ios" | "macos" | "windows" | "linux" | "service",
  capabilities: ReadonlyArray<DeviceCapability>
) =>
  registry.enroll({
    displayName: decodeDisplayName(displayName),
    platform: decodePlatform(platform),
    capabilities
  })

test("enrolls bounded devices under exactly one Owner and stores only digests", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    const enrollment = await runWithRegistry(
      databasePath,
      Effect.gen(function* () {
        const registry = yield* DeviceRegistry
        return yield* enroll(
          registry,
          "Personal iPhone",
          "ios",
          ["dictation:write", "service:health"]
        )
      })
    )
    const credential = Redacted.value(enrollment.credential)
    assert.match(credential, /^[0-9a-f]{64}$/)

    const listed = await runWithRegistry(
      databasePath,
      Effect.gen(function* () {
        const registry = yield* DeviceRegistry
        return yield* registry.list
      })
    )
    assert.equal(listed.length, 1)
    assert.equal(listed[0]?.id, enrollment.principal.id)
    assert.deepEqual(listed[0]?.capabilities, [
      "dictation:write",
      "service:health"
    ])

    const database = new Database(databasePath, { readonly: true })
    try {
      const ownerCount = Schema.decodeUnknownSync(
        Schema.Struct({ count: Schema.Number })
      )(
        database.prepare("SELECT count(*) AS count FROM owner").get()
      ).count
      assert.equal(ownerCount, 1)

      const stored = Schema.decodeUnknownSync(
        Schema.Struct({
          credential_digest: Schema.Uint8ArrayFromSelf
        })
      )(
        database
          .prepare(
            "SELECT credential_digest FROM device_principals LIMIT 1"
          )
          .get()
      )
      assert.equal(stored.credential_digest.byteLength, 32)
      assert.notEqual(
        Buffer.from(stored.credential_digest).toString("hex"),
        credential
      )
    } finally {
      database.close()
    }

    assert.equal(
      readFileSync(databasePath).includes(Buffer.from(credential, "utf8")),
      false
    )
  })
})

test("authenticates capabilities and immediately applies rotate and lost-device revocation", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    await Effect.runPromise(
      Effect.gen(function* () {
        const registry = yield* DeviceRegistry
        const authentication = yield* DeviceAuthentication
        const phone = yield* enroll(
          registry,
          "Personal iPhone",
          "ios",
          ["dictation:write", "service:health"]
        )
        const desktop = yield* enroll(
          registry,
          "Windows desktop",
          "windows",
          ["dictation:write"]
        )
        const healthProbe = yield* enroll(
          registry,
          "Ronin health probe",
          "service",
          ["service:health"]
        )

        const phoneCredential = Redacted.value(phone.credential)
        const authorized = yield* authentication.authenticate(
          `bEaReR ${phoneCredential}`,
          "dictation:write"
        )
        assert.equal(authorized.principal.id, phone.principal.id)
        assert.equal(authorized.capability, "dictation:write")

        const healthOnly = Redacted.value(healthProbe.credential)
        const healthGrant = yield* authentication.authenticate(
          `Bearer ${healthOnly}`,
          "service:health"
        )
        assert.equal(healthGrant.capability, "service:health")
        const insufficient = yield* Effect.either(
          authentication.authenticate(
            `Bearer ${healthOnly}`,
            "dictation:write"
          )
        )
        assert.equal(Either.isLeft(insufficient), true)

        const rotated = yield* registry.rotate(phone.principal.id)
        const oldAfterRotation = yield* Effect.either(
          authentication.authenticate(
            `Bearer ${phoneCredential}`,
            "dictation:write"
          )
        )
        assert.equal(Either.isLeft(oldAfterRotation), true)
        const replacementCredential = Redacted.value(rotated.credential)
        const replacement = yield* authentication.authenticate(
          `Bearer ${replacementCredential}`,
          "dictation:write"
        )
        assert.equal(replacement.principal.id, phone.principal.id)

        const revoked = yield* registry.revoke(phone.principal.id)
        assert.equal(revoked.state._tag, "Revoked")
        const revokedAgain = yield* registry.revoke(phone.principal.id)
        assert.deepEqual(revokedAgain, revoked)
        const lostPhone = yield* Effect.either(
          authentication.authenticate(
            `Bearer ${replacementCredential}`,
            "dictation:write"
          )
        )
        assert.equal(Either.isLeft(lostPhone), true)

        const unaffectedDesktop = yield* authentication.authenticate(
          `Bearer ${Redacted.value(desktop.credential)}`,
          "dictation:write"
        )
        assert.equal(unaffectedDesktop.principal.id, desktop.principal.id)
      }).pipe(
        Effect.provide(authenticationAndRegistryLayer(databasePath)),
        Effect.scoped
      )
    )
  })
})

test("enforces the retained device registry bound", async () => {
  await runWithRegistry(
    ":memory:",
    Effect.gen(function* () {
      const registry = yield* DeviceRegistry
      let firstDeviceID: DevicePrincipalId | undefined
      for (let index = 0; index < MaximumDevicePrincipals; index += 1) {
        const enrollment = yield* enroll(
          registry,
          `Device ${index + 1}`,
          "linux",
          ["dictation:write"]
        )
        firstDeviceID ??= enrollment.principal.id
      }
      const overflow = yield* Effect.either(
        enroll(registry, "One too many", "linux", ["dictation:write"])
      )
      assert.equal(Either.isLeft(overflow), true)
      if (Either.isLeft(overflow)) {
        assert.equal(overflow.left._tag, "DeviceRegistryCapacityError")
      }
      if (firstDeviceID === undefined) {
        return yield* Effect.die("expected a first device")
      }
      yield* registry.revoke(firstDeviceID)
      const replacement = yield* enroll(
        registry,
        "Replacement device",
        "linux",
        ["dictation:write"]
      )
      const retained = yield* registry.list
      assert.equal(retained.length, MaximumDevicePrincipals)
      assert.equal(
        retained.some((principal) => principal.id === firstDeviceID),
        false
      )
      assert.equal(
        retained.some(
          (principal) => principal.id === replacement.principal.id
        ),
        true
      )
    })
  )
})

test("uses the same bounded capability lookup for unknown and insufficient credentials", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    await Effect.runPromise(
      Effect.gen(function* () {
        const registry = yield* DeviceRegistry
        const health = yield* enroll(
          registry,
          "Health-only service",
          "service",
          ["service:health"]
        )
        yield* Effect.sync(() => {
          const sabotage = new Database(databasePath)
          try {
            sabotage.exec("DROP TABLE device_capabilities")
          } finally {
            sabotage.close()
          }
        })
        const unknown = Redacted.make(
          Schema.decodeUnknownSync(DeviceCredentialSchema)("ab".repeat(32))
        )
        const unknownResult = yield* Effect.either(
          registry.resolve({
            credential: unknown,
            requiredCapability: "dictation:write"
          })
        )
        const insufficientResult = yield* Effect.either(
          registry.resolve({
            credential: health.credential,
            requiredCapability: "dictation:write"
          })
        )
        assert.equal(Either.isLeft(unknownResult), true)
        assert.equal(Either.isLeft(insufficientResult), true)
        if (
          Either.isLeft(unknownResult) &&
          Either.isLeft(insufficientResult)
        ) {
          assert.equal(unknownResult.left._tag, "DeviceRegistryUnavailableError")
          assert.equal(
            insufficientResult.left._tag,
            "DeviceRegistryUnavailableError"
          )
          assert.equal(unknownResult.left.operation, "resolve")
          assert.equal(insufficientResult.left.operation, "resolve")
        }
      }).pipe(
        Effect.provide(sqliteDeviceRegistryLayer(databasePath)),
        Effect.scoped
      )
    )
  })
})

test("migrates a version-zero SQLite file once and rejects future schemas", async () => {
  await withTemporaryDatabase(async (databasePath) => {
    const legacy = new Database(databasePath)
    try {
      legacy.exec(`
        CREATE TABLE migration_sentinel (value TEXT NOT NULL) STRICT;
        INSERT INTO migration_sentinel (value) VALUES ('preserve-me');
        PRAGMA user_version = 0;
      `)
    } finally {
      legacy.close()
    }

    const firstOwnerID = await runWithRegistry(
      databasePath,
      Effect.gen(function* () {
        const registry = yield* DeviceRegistry
        const enrollment = yield* enroll(
          registry,
          "Migrated device",
          "macos",
          ["dictation:write"]
        )
        return enrollment.principal.ownerID
      })
    )
    const reopenedOwnerID = await runWithRegistry(
      databasePath,
      Effect.gen(function* () {
        const registry = yield* DeviceRegistry
        const devices = yield* registry.list
        assert.equal(devices.length, 1)
        return devices[0]?.ownerID
      })
    )
    assert.equal(reopenedOwnerID, firstOwnerID)

    const migrated = new Database(databasePath)
    try {
      assert.equal(
        migrated.pragma("user_version", { simple: true }),
        1
      )
      const sentinel = Schema.decodeUnknownSync(
        Schema.Struct({ value: Schema.String })
      )(
        migrated.prepare("SELECT value FROM migration_sentinel").get()
      )
      assert.equal(sentinel.value, "preserve-me")
      migrated.pragma("user_version = 2")
    } finally {
      migrated.close()
    }

    const unsupported = await Effect.runPromise(
      Effect.either(
        Effect.scoped(
          Layer.build(sqliteDeviceRegistryLayer(databasePath))
        )
      )
    )
    assert.equal(Either.isLeft(unsupported), true)
  })
})

test("does not expose credential digests through listed device metadata", async () => {
  await runWithRegistry(
    ":memory:",
    Effect.gen(function* () {
      const registry = yield* DeviceRegistry
      const enrollment = yield* enroll(
        registry,
        "Private phone",
        "ios",
        ["dictation:write"]
      )
      const devices = yield* registry.list
      const serialized = JSON.stringify(devices)
      assert.equal(
        serialized.includes(Redacted.value(enrollment.credential)),
        false
      )
      assert.equal(serialized.includes("credential"), false)
      assert.equal(serialized.includes("digest"), false)
    })
  )
})
