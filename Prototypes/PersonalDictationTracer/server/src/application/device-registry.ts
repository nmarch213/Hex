import { Context, Effect, Option, Redacted, Schema } from "effect"

import type {
  ActiveDevicePrincipal,
  AuthenticatedDevice,
  DeviceCapability,
  DeviceCredential,
  DeviceDisplayName,
  DevicePlatform,
  DevicePrincipal,
  DevicePrincipalId
} from "../domain/device-principal.js"

/** Maximum retained device records, including revoked installations. */
export const MaximumDevicePrincipals = 64

/** Input for enrolling one new installation under the singleton Owner. */
export interface EnrollDevice {
  readonly displayName: DeviceDisplayName
  readonly platform: DevicePlatform
  readonly capabilities: ReadonlyArray<DeviceCapability>
}

/** A newly enrolled principal and the only returned copy of its credential. */
export interface DeviceEnrollment {
  readonly principal: ActiveDevicePrincipal
  readonly credential: Redacted.Redacted<DeviceCredential>
}

/** Input used to resolve one parsed credential for a required capability. */
export interface ResolveDeviceCredential {
  readonly credential: Redacted.Redacted<DeviceCredential>
  readonly requiredCapability: DeviceCapability
}

/** Reports a durable registry operation that could not complete safely. */
export class DeviceRegistryUnavailableError extends Schema.TaggedError<DeviceRegistryUnavailableError>()(
  "DeviceRegistryUnavailableError",
  {
    operation: Schema.Literal(
      "initialize",
      "enroll",
      "list",
      "resolve",
      "rotate",
      "revoke",
      "revoke_all"
    )
  }
) {}

/** Reports that the bounded personal-device registry is full. */
export class DeviceRegistryCapacityError extends Schema.TaggedError<DeviceRegistryCapacityError>()(
  "DeviceRegistryCapacityError",
  { maximumDevices: Schema.Number }
) {}

/** Reports that Ronin has no device with the supplied public identifier. */
export class DevicePrincipalNotFoundError extends Schema.TaggedError<DevicePrincipalNotFoundError>()(
  "DevicePrincipalNotFoundError",
  { deviceID: Schema.String }
) {}

/** Reports an attempt to rotate a credential that was already revoked. */
export class DevicePrincipalRevokedError extends Schema.TaggedError<DevicePrincipalRevokedError>()(
  "DevicePrincipalRevokedError",
  { deviceID: Schema.String }
) {}

/** Durable device lifecycle and credential-resolution operations owned by Ronin. */
export interface DeviceRegistryService {
  /** Creates a device and returns its credential exactly once. */
  readonly enroll: (
    input: EnrollDevice
  ) => Effect.Effect<
    DeviceEnrollment,
    DeviceRegistryCapacityError | DeviceRegistryUnavailableError
  >

  /** Lists bounded public device metadata without credential material or digests. */
  readonly list: Effect.Effect<
    ReadonlyArray<DevicePrincipal>,
    DeviceRegistryUnavailableError
  >

  /** Resolves an active credential without disclosing whether an unknown token existed. */
  readonly resolve: (
    input: ResolveDeviceCredential
  ) => Effect.Effect<
    Option.Option<AuthenticatedDevice>,
    DeviceRegistryUnavailableError
  >

  /** Atomically invalidates the previous credential and returns one replacement. */
  readonly rotate: (
    deviceID: DevicePrincipalId
  ) => Effect.Effect<
    DeviceEnrollment,
    | DevicePrincipalNotFoundError
    | DevicePrincipalRevokedError
    | DeviceRegistryUnavailableError
  >

  /** Immediately and idempotently revokes one retained device principal. */
  readonly revoke: (
    deviceID: DevicePrincipalId
  ) => Effect.Effect<
    DevicePrincipal,
    DevicePrincipalNotFoundError | DeviceRegistryUnavailableError
  >

  /** Atomically revokes every active device during fail-closed restore recovery. */
  readonly revokeAll: Effect.Effect<
    ReadonlyArray<DevicePrincipal>,
    DeviceRegistryUnavailableError
  >
}

/** Application-owned port for the singleton Owner's device registry. */
export class DeviceRegistry extends Context.Tag(
  "@hex/personal-dictation/DeviceRegistry"
)<DeviceRegistry, DeviceRegistryService>() {}
