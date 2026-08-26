import {
  closeSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  rmdirSync
} from "node:fs"
import { dirname, join } from "node:path"
import { Effect, Option, Redacted, Schema } from "effect"

import { DeviceRegistry } from "../application/device-registry.js"
import type {
  DeviceCredential,
  DevicePrincipal,
  DevicePrincipalId
} from "../domain/device-principal.js"
import {
  DeviceReauthorizationMarkerName,
  DeviceRevocationCompleteMarkerName
} from "../storage-layout.js"

/** Safe failure classifications for post-restore device reauthorization. */
export class DeviceReauthorizationError extends Schema.TaggedError<DeviceReauthorizationError>()(
  "DeviceReauthorizationError",
  {
    operation: Schema.Literal("reset", "complete"),
    reason: Schema.Literal(
      "marker_missing",
      "marker_invalid",
      "principal_set_invalid",
      "filesystem_unavailable"
    )
  }
) {}

interface ReauthorizationPaths {
  readonly dataDirectory: string
  readonly markerDirectory: string
  readonly revocationProofDirectory: string
}

const pathsForDatabase = (databasePath: string): ReauthorizationPaths => {
  if (databasePath === ":memory:") {
    throw new DeviceReauthorizationError({
      operation: "reset",
      reason: "marker_invalid"
    })
  }
  const dataDirectory = dirname(databasePath)
  const markerDirectory = join(
    dataDirectory,
    DeviceReauthorizationMarkerName
  )
  return {
    dataDirectory,
    markerDirectory,
    revocationProofDirectory: join(
      markerDirectory,
      DeviceRevocationCompleteMarkerName
    )
  }
}

const fileSystemCode = (cause: unknown) =>
  typeof cause === "object" && cause !== null && "code" in cause
    ? cause.code
    : undefined

const currentUserID = () => {
  if (process.getuid === undefined) {
    throw new Error("effective user ID is unavailable")
  }
  return process.getuid()
}

const assertOwnerOnlyDirectory = (
  path: string,
  operation: DeviceReauthorizationError["operation"],
  missingReason: DeviceReauthorizationError["reason"]
) => {
  try {
    const metadata = lstatSync(path)
    if (
      !metadata.isDirectory() ||
      metadata.uid !== currentUserID() ||
      (metadata.mode & 0o077) !== 0
    ) {
      throw new DeviceReauthorizationError({
        operation,
        reason: "marker_invalid"
      })
    }
  } catch (cause) {
    if (cause instanceof DeviceReauthorizationError) {
      throw cause
    }
    throw new DeviceReauthorizationError({
      operation,
      reason:
        fileSystemCode(cause) === "ENOENT"
          ? missingReason
          : "filesystem_unavailable"
    })
  }
}

const fsyncDirectory = (
  path: string,
  operation: DeviceReauthorizationError["operation"]
) => {
  let descriptor: number | undefined
  try {
    descriptor = openSync(path, "r")
    fsyncSync(descriptor)
  } catch {
    throw new DeviceReauthorizationError({
      operation,
      reason: "filesystem_unavailable"
    })
  } finally {
    if (descriptor !== undefined) {
      closeSync(descriptor)
    }
  }
}

const assertEmptyDirectory = (
  path: string,
  operation: DeviceReauthorizationError["operation"]
) => {
  try {
    if (readdirSync(path).length !== 0) {
      throw new DeviceReauthorizationError({
        operation,
        reason: "marker_invalid"
      })
    }
  } catch (cause) {
    if (cause instanceof DeviceReauthorizationError) {
      throw cause
    }
    throw new DeviceReauthorizationError({
      operation,
      reason: "filesystem_unavailable"
    })
  }
}

const invalidatePriorProof = (paths: ReauthorizationPaths) => {
  try {
    const metadata = lstatSync(paths.revocationProofDirectory)
    if (
      !metadata.isDirectory() ||
      metadata.uid !== currentUserID() ||
      (metadata.mode & 0o077) !== 0
    ) {
      throw new DeviceReauthorizationError({
        operation: "reset",
        reason: "marker_invalid"
      })
    }
    assertEmptyDirectory(paths.revocationProofDirectory, "reset")
    rmdirSync(paths.revocationProofDirectory)
    fsyncDirectory(paths.markerDirectory, "reset")
  } catch (cause) {
    if (fileSystemCode(cause) === "ENOENT") {
      return
    }
    if (cause instanceof DeviceReauthorizationError) {
      throw cause
    }
    throw new DeviceReauthorizationError({
      operation: "reset",
      reason: "filesystem_unavailable"
    })
  }
}

const createRevocationProof = (paths: ReauthorizationPaths) => {
  try {
    mkdirSync(paths.revocationProofDirectory, { mode: 0o700 })
    fsyncDirectory(paths.markerDirectory, "reset")
  } catch (cause) {
    if (cause instanceof DeviceReauthorizationError) {
      throw cause
    }
    throw new DeviceReauthorizationError({
      operation: "reset",
      reason: "filesystem_unavailable"
    })
  }
}

const isActive = (principal: DevicePrincipal) =>
  principal.state._tag === "Active"

const validFreshPrincipalSet = (
  principals: ReadonlyArray<DevicePrincipal>,
  authenticatedHealthDeviceID: DevicePrincipalId
) => {
  const active = principals.filter(isActive)
  const healthOnly = active.filter(
    (principal) =>
      principal.platform === "service" &&
      principal.capabilities.length === 1 &&
      principal.capabilities[0] === "service:health"
  )
  const dictationClients = active.filter(
    (principal) =>
      principal.platform !== "service" &&
      principal.capabilities.includes("dictation:write")
  )
  return (
    healthOnly.length === 1 &&
    healthOnly[0]?.id === authenticatedHealthDeviceID &&
    dictationClients.length >= 1 &&
    active.every(
      (principal) =>
        principal.platform !== "service" ||
        principal.id === healthOnly[0]?.id
    )
  )
}

/** Revokes every restored credential and durably records that reset. */
export const resetRestoredDevicePrincipals = (databasePath: string) =>
  Effect.gen(function* () {
    const paths = yield* Effect.try({
      try: () => pathsForDatabase(databasePath),
      catch: (cause) =>
        cause instanceof DeviceReauthorizationError
          ? cause
          : new DeviceReauthorizationError({
              operation: "reset",
              reason: "marker_invalid"
            })
    })
    yield* Effect.try({
      try: () => {
        assertOwnerOnlyDirectory(
          paths.markerDirectory,
          "reset",
          "marker_missing"
        )
        invalidatePriorProof(paths)
      },
      catch: (cause) =>
        cause instanceof DeviceReauthorizationError
          ? cause
          : new DeviceReauthorizationError({
              operation: "reset",
              reason: "filesystem_unavailable"
            })
    })
    const registry = yield* DeviceRegistry
    const revoked = yield* registry.revokeAll
    yield* Effect.try({
      try: () => createRevocationProof(paths),
      catch: (cause) =>
        cause instanceof DeviceReauthorizationError
          ? cause
          : new DeviceReauthorizationError({
              operation: "reset",
              reason: "filesystem_unavailable"
            })
    })
    return revoked.length
  })

/** Removes the startup gate only after distinct fresh health and client principals exist. */
export const completeRestoredDeviceReauthorization = (
  databasePath: string,
  healthProbeCredential: Redacted.Redacted<DeviceCredential>
) =>
  Effect.gen(function* () {
    const paths = yield* Effect.try({
      try: () => pathsForDatabase(databasePath),
      catch: () =>
        new DeviceReauthorizationError({
          operation: "complete",
          reason: "marker_invalid"
        })
    })
    yield* Effect.try({
      try: () => {
        assertOwnerOnlyDirectory(
          paths.markerDirectory,
          "complete",
          "marker_missing"
        )
        assertOwnerOnlyDirectory(
          paths.revocationProofDirectory,
          "complete",
          "marker_invalid"
        )
        assertEmptyDirectory(paths.revocationProofDirectory, "complete")
        const markerEntries = readdirSync(paths.markerDirectory)
        if (
          markerEntries.length !== 1 ||
          markerEntries[0] !== DeviceRevocationCompleteMarkerName
        ) {
          throw new DeviceReauthorizationError({
            operation: "complete",
            reason: "marker_invalid"
          })
        }
      },
      catch: (cause) =>
        cause instanceof DeviceReauthorizationError
          ? cause
          : new DeviceReauthorizationError({
              operation: "complete",
              reason: "filesystem_unavailable"
            })
    })
    const registry = yield* DeviceRegistry
    const authenticatedHealthProbe = yield* registry.resolve({
      credential: healthProbeCredential,
      requiredCapability: "service:health"
    })
    if (
      Option.isNone(authenticatedHealthProbe) ||
      authenticatedHealthProbe.value.principal.platform !== "service" ||
      authenticatedHealthProbe.value.principal.capabilities.length !== 1 ||
      authenticatedHealthProbe.value.principal.capabilities[0] !==
        "service:health"
    ) {
      return yield* new DeviceReauthorizationError({
        operation: "complete",
        reason: "principal_set_invalid"
      })
    }
    const principals = yield* registry.list
    if (
      !validFreshPrincipalSet(
        principals,
        authenticatedHealthProbe.value.principal.id
      )
    ) {
      return yield* new DeviceReauthorizationError({
        operation: "complete",
        reason: "principal_set_invalid"
      })
    }
    yield* Effect.try({
      try: () => {
        rmdirSync(paths.revocationProofDirectory)
        fsyncDirectory(paths.markerDirectory, "complete")
        rmdirSync(paths.markerDirectory)
        fsyncDirectory(paths.dataDirectory, "complete")
      },
      catch: (cause) =>
        cause instanceof DeviceReauthorizationError
          ? cause
          : new DeviceReauthorizationError({
              operation: "complete",
              reason: "filesystem_unavailable"
            })
    })
  })
