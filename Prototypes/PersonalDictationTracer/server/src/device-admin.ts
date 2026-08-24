import { NodeRuntime } from "@effect/platform-node"
import { lstatSync, readFileSync } from "node:fs"
import { isAbsolute } from "node:path"
import { Effect, Logger, Redacted, Schema } from "effect"

import { DeviceRegistry } from "./application/device-registry.js"
import {
  completeRestoredDeviceReauthorization,
  resetRestoredDevicePrincipals
} from "./adapters/device-reauthorization.js"
import { sqliteDeviceRegistryLayer } from "./adapters/sqlite-device-registry.js"
import {
  DeviceCapabilitySchema,
  DeviceCredentialSchema,
  DeviceDisplayNameSchema,
  DevicePlatformSchema,
  DevicePrincipalIdSchema,
  type DeviceCapability
} from "./domain/device-principal.js"
import { deviceAdministrationConfiguration } from "./runtime-config.js"

class DeviceAdministrationInputError extends Schema.TaggedError<DeviceAdministrationInputError>()(
  "DeviceAdministrationInputError",
  {
    reason: Schema.Literal(
      "usage",
      "invalid_device_id",
      "invalid_display_name",
      "invalid_platform",
      "invalid_capabilities",
      "invalid_health_probe_credential"
    )
  }
) {}

const decodeInput = <S extends Schema.Schema.AnyNoContext>(
  schema: S,
  input: string,
  reason: DeviceAdministrationInputError["reason"]
) =>
  Schema.decodeUnknown(schema)(input).pipe(
    Effect.mapError(() => new DeviceAdministrationInputError({ reason }))
  )

const parseCapabilities = (input: string) =>
  Effect.gen(function* () {
    const rawCapabilities = input.split(",")
    if (rawCapabilities.length === 0 || rawCapabilities.length > 2) {
      return yield* new DeviceAdministrationInputError({
        reason: "invalid_capabilities"
      })
    }
    const capabilities = new Set<DeviceCapability>()
    for (const rawCapability of rawCapabilities) {
      capabilities.add(
        yield* decodeInput(
          DeviceCapabilitySchema,
          rawCapability,
          "invalid_capabilities"
        )
      )
    }
    if (capabilities.size !== rawCapabilities.length) {
      return yield* new DeviceAdministrationInputError({
        reason: "invalid_capabilities"
      })
    }
    return [...capabilities].sort()
  })

const writeCredential = (credential: Parameters<typeof Redacted.value>[0]) =>
  Effect.sync(() => {
    process.stdout.write(`${Redacted.value(credential)}\n`)
  })

const writeStatus = (message: string) =>
  Effect.sync(() => {
    process.stderr.write(`${message}\n`)
  })

const loadHealthProbeCredential = (path: string | undefined) =>
  Effect.try({
    try: () => {
      if (path === undefined || !isAbsolute(path)) {
        throw new Error("health credential path is unavailable")
      }
      const metadata = lstatSync(path)
      if (!metadata.isFile() || metadata.size < 64 || metadata.size > 65) {
        throw new Error("health credential file is invalid")
      }
      const raw = readFileSync(path, "utf8")
      const credential =
        raw.length === 65 && raw.endsWith("\n") ? raw.slice(0, -1) : raw
      return Redacted.make(
        Schema.decodeUnknownSync(DeviceCredentialSchema)(credential)
      )
    },
    catch: () =>
      new DeviceAdministrationInputError({
        reason: "invalid_health_probe_credential"
      })
  })

const enroll = (args: ReadonlyArray<string>) =>
  Effect.gen(function* () {
    const [rawDisplayName, rawPlatform, rawCapabilities] = args
    if (
      rawDisplayName === undefined ||
      rawPlatform === undefined ||
      rawCapabilities === undefined ||
      args.length !== 3
    ) {
      return yield* new DeviceAdministrationInputError({ reason: "usage" })
    }
    const displayName = yield* decodeInput(
      DeviceDisplayNameSchema,
      rawDisplayName,
      "invalid_display_name"
    )
    const platform = yield* decodeInput(
      DevicePlatformSchema,
      rawPlatform,
      "invalid_platform"
    )
    const capabilities = yield* parseCapabilities(rawCapabilities)
    const registry = yield* DeviceRegistry
    const enrollment = yield* registry.enroll({
      displayName,
      platform,
      capabilities
    })
    yield* writeCredential(enrollment.credential)
    yield* writeStatus(`Enrolled device ${enrollment.principal.id}.`)
  })

const list = (args: ReadonlyArray<string>) =>
  Effect.gen(function* () {
    if (args.length !== 0) {
      return yield* new DeviceAdministrationInputError({ reason: "usage" })
    }
    const registry = yield* DeviceRegistry
    const devices = yield* registry.list
    yield* Effect.sync(() => {
      process.stdout.write(`${JSON.stringify(devices, null, 2)}\n`)
    })
  })

const rotate = (args: ReadonlyArray<string>) =>
  Effect.gen(function* () {
    const [rawDeviceID] = args
    if (rawDeviceID === undefined || args.length !== 1) {
      return yield* new DeviceAdministrationInputError({ reason: "usage" })
    }
    const deviceID = yield* decodeInput(
      DevicePrincipalIdSchema,
      rawDeviceID.toLowerCase(),
      "invalid_device_id"
    )
    const registry = yield* DeviceRegistry
    const enrollment = yield* registry.rotate(deviceID)
    yield* writeCredential(enrollment.credential)
    yield* writeStatus(`Rotated device ${enrollment.principal.id}.`)
  })

const revoke = (args: ReadonlyArray<string>) =>
  Effect.gen(function* () {
    const [rawDeviceID] = args
    if (rawDeviceID === undefined || args.length !== 1) {
      return yield* new DeviceAdministrationInputError({ reason: "usage" })
    }
    const deviceID = yield* decodeInput(
      DevicePrincipalIdSchema,
      rawDeviceID.toLowerCase(),
      "invalid_device_id"
    )
    const registry = yield* DeviceRegistry
    const principal = yield* registry.revoke(deviceID)
    yield* writeStatus(`Revoked device ${principal.id}.`)
  })

const restoreReset = (
  args: ReadonlyArray<string>,
  databasePath: string
) =>
  Effect.gen(function* () {
    if (args.length !== 0) {
      return yield* new DeviceAdministrationInputError({ reason: "usage" })
    }
    const revokedCount = yield* resetRestoredDevicePrincipals(databasePath)
    yield* writeStatus(
      `Reset ${revokedCount} restored device principal records.`
    )
  })

const restoreComplete = (
  args: ReadonlyArray<string>,
  databasePath: string,
  healthProbeCredentialPath: string | undefined
) =>
  Effect.gen(function* () {
    if (args.length !== 0) {
      return yield* new DeviceAdministrationInputError({ reason: "usage" })
    }
    const healthProbeCredential = yield* loadHealthProbeCredential(
      healthProbeCredentialPath
    )
    yield* completeRestoredDeviceReauthorization(
      databasePath,
      healthProbeCredential
    )
    yield* writeStatus("Completed post-restore device reauthorization.")
  })

const runCommand = (
  args: ReadonlyArray<string>,
  databasePath: string,
  healthProbeCredentialPath: string | undefined
) =>
  Effect.gen(function* () {
    const [command, ...commandArguments] = args
    switch (command) {
      case "enroll":
        return yield* enroll(commandArguments)
      case "list":
        return yield* list(commandArguments)
      case "rotate":
        return yield* rotate(commandArguments)
      case "revoke":
        return yield* revoke(commandArguments)
      case "restore-reset":
        return yield* restoreReset(commandArguments, databasePath)
      case "restore-complete":
        return yield* restoreComplete(
          commandArguments,
          databasePath,
          healthProbeCredentialPath
        )
      default:
        return yield* Effect.fail(
          new DeviceAdministrationInputError({ reason: "usage" })
        )
    }
  })

const program = Effect.gen(function* () {
  const configuration = yield* deviceAdministrationConfiguration
  return yield* runCommand(
    process.argv.slice(2),
    configuration.deviceRegistryDatabasePath,
    process.env["HEX_HEALTH_PROBE_CREDENTIAL_FILE"]
  ).pipe(
    Effect.provide(
      sqliteDeviceRegistryLayer(
        configuration.deviceRegistryDatabasePath,
        "administration"
      )
    ),
    Effect.scoped
  )
})

NodeRuntime.runMain(
  program.pipe(
    Effect.provide(Logger.replace(Logger.defaultLogger, Logger.jsonLogger))
  )
)
