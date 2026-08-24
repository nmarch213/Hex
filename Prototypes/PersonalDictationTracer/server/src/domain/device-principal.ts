import { Schema } from "effect"

/** The singleton Owner identifier initialized on Ronin. */
export const OwnerIdSchema = Schema.UUID.pipe(Schema.brand("OwnerId"))

/** Identifies the one Owner without introducing an account or login. */
export type OwnerId = Schema.Schema.Type<typeof OwnerIdSchema>

/** A durable identifier for one independently revocable installation. */
export const DevicePrincipalIdSchema = Schema.UUID.pipe(
  Schema.brand("DevicePrincipalId")
)

/** Identifies one independently revocable Hex installation. */
export type DevicePrincipalId = Schema.Schema.Type<
  typeof DevicePrincipalIdSchema
>

/** Platforms accepted by Ronin-local device enrollment. */
export const DevicePlatformSchema = Schema.Literal(
  "ios",
  "macos",
  "windows",
  "linux",
  "service"
)

/** The bounded platform classification recorded for a device. */
export type DevicePlatform = Schema.Schema.Type<
  typeof DevicePlatformSchema
>

/** Capabilities that can be granted to a device principal. */
export const DeviceCapabilitySchema = Schema.Literal(
  "dictation:write",
  "service:health"
)

/** One operation an authenticated device may perform. */
export type DeviceCapability = Schema.Schema.Type<
  typeof DeviceCapabilitySchema
>

/** A human-readable device name bounded for storage and administration. */
export const DeviceDisplayNameSchema = Schema.String.pipe(
  Schema.trimmed(),
  Schema.minLength(1),
  Schema.maxLength(80),
  Schema.pattern(/^[^\u0000-\u001f\u007f]+$/)
)

/** A parsed display name for one device installation. */
export type DeviceDisplayName = Schema.Schema.Type<
  typeof DeviceDisplayNameSchema
>

/** An exact 256-bit bearer credential encoded as lowercase hexadecimal. */
export const DeviceCredentialSchema = Schema.String.pipe(
  Schema.pattern(/^[0-9a-f]{64}$/),
  Schema.brand("DeviceCredential")
)

/** A parsed device bearer credential that must remain redacted at boundaries. */
export type DeviceCredential = Schema.Schema.Type<
  typeof DeviceCredentialSchema
>

interface DevicePrincipalBase {
  readonly id: DevicePrincipalId
  readonly ownerID: OwnerId
  readonly displayName: DeviceDisplayName
  readonly platform: DevicePlatform
  readonly capabilities: ReadonlyArray<DeviceCapability>
  readonly createdAtEpochMilliseconds: number
  readonly rotatedAtEpochMilliseconds: number
}

/** An active installation that may authenticate for its granted capabilities. */
export interface ActiveDevicePrincipal extends DevicePrincipalBase {
  readonly state: { readonly _tag: "Active" }
}

/** A retained lost or retired installation whose credential can no longer authenticate. */
export interface RevokedDevicePrincipal extends DevicePrincipalBase {
  readonly state: {
    readonly _tag: "Revoked"
    readonly revokedAtEpochMilliseconds: number
  }
}

/** One independently managed installation belonging to the singleton Owner. */
export type DevicePrincipal =
  | ActiveDevicePrincipal
  | RevokedDevicePrincipal

/** Proof that one active device possesses the capability required by a request. */
export interface AuthenticatedDevice {
  readonly principal: ActiveDevicePrincipal
  readonly capability: DeviceCapability
}
