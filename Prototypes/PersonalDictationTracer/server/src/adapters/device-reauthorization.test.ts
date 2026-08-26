import assert from "node:assert/strict"
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { Effect, Either, Layer, Redacted, Schema } from "effect"

import { DeviceAuthentication } from "../application/device-authentication.js"
import { DeviceRegistry } from "../application/device-registry.js"
import {
  DeviceDisplayNameSchema,
  DevicePlatformSchema,
  type DeviceCapability
} from "../domain/device-principal.js"
import {
  DeviceReauthorizationMarkerName,
  DeviceRevocationCompleteMarkerName
} from "../storage-layout.js"
import {
  completeRestoredDeviceReauthorization,
  resetRestoredDevicePrincipals
} from "./device-reauthorization.js"
import { sqliteDeviceRegistryLayer } from "./sqlite-device-registry.js"

const decodeDisplayName = Schema.decodeUnknownSync(DeviceDisplayNameSchema)
const decodePlatform = Schema.decodeUnknownSync(DevicePlatformSchema)

const withTemporaryRegistry = async (
  operation: (input: {
    readonly databasePath: string
    readonly markerDirectory: string
  }) => Promise<void>
) => {
  const directory = mkdtempSync(join(tmpdir(), "hex-device-restore-"))
  const databasePath = join(directory, "devices.sqlite")
  try {
    await operation({
      databasePath,
      markerDirectory: join(
        directory,
        DeviceReauthorizationMarkerName
      )
    })
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

const enroll = (
  displayName: string,
  platform: "ios" | "service",
  capabilities: ReadonlyArray<DeviceCapability>
) =>
  Effect.gen(function* () {
    const registry = yield* DeviceRegistry
    return yield* registry.enroll({
      displayName: decodeDisplayName(displayName),
      platform: decodePlatform(platform),
      capabilities
    })
  })

const runAdministration = <Output, Error>(
  databasePath: string,
  effect: Effect.Effect<Output, Error, DeviceRegistry>
) =>
  Effect.runPromise(
    effect.pipe(
      Effect.provide(
        sqliteDeviceRegistryLayer(databasePath, "administration")
      ),
      Effect.scoped
    )
  )

test("blocks normal startup until restored credentials are reset and replaced", async () => {
  await withTemporaryRegistry(async ({
    databasePath,
    markerDirectory
  }) => {
    const restored = await runAdministration(
      databasePath,
      Effect.all({
        health: enroll(
          "Restored health probe",
          "service",
          ["service:health"]
        ),
        phone: enroll(
          "Restored iPhone",
          "ios",
          ["dictation:write", "service:health"]
        )
      })
    )
    mkdirSync(markerDirectory, { mode: 0o700 })

    const blocked = await Effect.runPromise(
      Effect.either(
        Effect.scoped(
          Layer.build(sqliteDeviceRegistryLayer(databasePath))
        )
      )
    )
    assert.equal(Either.isLeft(blocked), true)

    await runAdministration(
      databasePath,
      resetRestoredDevicePrincipals(databasePath)
    )
    assert.equal(
      existsSync(
        join(markerDirectory, DeviceRevocationCompleteMarkerName)
      ),
      true
    )

    const staleCompletion = await runAdministration(
      databasePath,
      Effect.either(
        completeRestoredDeviceReauthorization(
          databasePath,
          restored.health.credential
        )
      )
    )
    assert.equal(Either.isLeft(staleCompletion), true)
    assert.equal(existsSync(markerDirectory), true)

    const fresh = await runAdministration(
      databasePath,
      Effect.all({
        health: enroll(
          "Fresh Ronin health probe",
          "service",
          ["service:health"]
        ),
        phone: enroll(
          "Fresh personal iPhone",
          "ios",
          ["dictation:write", "service:health"]
        )
      })
    )
    await runAdministration(
      databasePath,
      completeRestoredDeviceReauthorization(
        databasePath,
        fresh.health.credential
      )
    )
    assert.equal(existsSync(markerDirectory), false)

    await Effect.runPromise(
      Effect.gen(function* () {
        const authentication = yield* DeviceAuthentication
        const restoredPhone = yield* Effect.either(
          authentication.authenticate(
            `Bearer ${Redacted.value(restored.phone.credential)}`,
            "dictation:write"
          )
        )
        assert.equal(Either.isLeft(restoredPhone), true)
        const freshPhone = yield* authentication.authenticate(
          `Bearer ${Redacted.value(fresh.phone.credential)}`,
          "dictation:write"
        )
        assert.equal(freshPhone.principal.id, fresh.phone.principal.id)
      }).pipe(
        Effect.provide(
          DeviceAuthentication.Default.pipe(
            Layer.provideMerge(sqliteDeviceRegistryLayer(databasePath))
          )
        ),
        Effect.scoped
      )
    )
  })
})

test("does not clear the restore marker without a distinct dictation client", async () => {
  await withTemporaryRegistry(async ({
    databasePath,
    markerDirectory
  }) => {
    await runAdministration(
      databasePath,
      Effect.gen(function* () {
        yield* enroll("Restored phone", "ios", ["dictation:write"])
      })
    )
    mkdirSync(markerDirectory, { mode: 0o700 })
    await runAdministration(
      databasePath,
      resetRestoredDevicePrincipals(databasePath)
    )
    const health = await runAdministration(
      databasePath,
      enroll("Only a health probe", "service", ["service:health"])
    )
    // A recovery retry invalidates partially enrolled principals before it
    // creates a fresh proof, so repeated operator runs cannot accumulate
    // multiple active health principals.
    await runAdministration(
      databasePath,
      resetRestoredDevicePrincipals(databasePath)
    )
    const result = await runAdministration(
      databasePath,
      Effect.either(
        completeRestoredDeviceReauthorization(
          databasePath,
          health.credential
        )
      )
    )
    assert.equal(Either.isLeft(result), true)
    assert.equal(existsSync(markerDirectory), true)
  })
})
