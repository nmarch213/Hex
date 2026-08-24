import Database, { type Statement } from "better-sqlite3"
import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual
} from "node:crypto"
import { chmodSync, lstatSync, mkdirSync, statSync } from "node:fs"
import { dirname, join } from "node:path"
import {
  Clock,
  Effect,
  Layer,
  Option,
  Redacted,
  Schema
} from "effect"

import {
  DevicePrincipalNotFoundError,
  DevicePrincipalRevokedError,
  DeviceRegistry,
  DeviceRegistryCapacityError,
  DeviceRegistryUnavailableError,
  MaximumDevicePrincipals,
  type DeviceRegistryService
} from "../application/device-registry.js"
import {
  DeviceCapabilitySchema,
  DeviceCredentialSchema,
  DeviceDisplayNameSchema,
  DevicePlatformSchema,
  DevicePrincipalIdSchema,
  OwnerIdSchema,
  type ActiveDevicePrincipal,
  type DeviceCapability,
  type DeviceCredential,
  type DevicePrincipal,
  type DevicePrincipalId
} from "../domain/device-principal.js"
import { DeviceReauthorizationMarkerName } from "../storage-layout.js"

const SchemaVersion = 1
const DatabaseBusyTimeoutMilliseconds = 1_000
const CredentialDigestBytes = 32
const CredentialGenerationAttempts = 4

const CredentialDigestSchema = Schema.Uint8ArrayFromSelf.pipe(
  Schema.filter(
    (bytes) => bytes.byteLength === CredentialDigestBytes,
    { message: () => "credential digest must contain exactly 32 bytes" }
  )
)

const StoredDeviceSchema = Schema.Struct({
  device_id: DevicePrincipalIdSchema,
  owner_id: OwnerIdSchema,
  display_name: DeviceDisplayNameSchema,
  platform: DevicePlatformSchema,
  credential_digest: CredentialDigestSchema,
  created_at_ms: Schema.NonNegativeInt,
  rotated_at_ms: Schema.NonNegativeInt,
  revoked_at_ms: Schema.NullOr(Schema.NonNegativeInt)
})

const StoredCapabilitySchema = Schema.Struct({
  device_id: DevicePrincipalIdSchema,
  capability: DeviceCapabilitySchema
})

interface PreparedStatements {
  readonly countDevices: Statement
  readonly deleteOldestRevokedDevices: Statement
  readonly credentialDigestExists: Statement
  readonly insertDevice: Statement
  readonly insertCapability: Statement
  readonly selectAllDevices: Statement
  readonly selectActiveDevices: Statement
  readonly selectAllCapabilities: Statement
  readonly selectDevice: Statement
  readonly updateCredential: Statement
  readonly revokeDevice: Statement
  readonly revokeAllDevices: Statement
}

interface DatabaseResource {
  readonly database: Database.Database
  readonly service: DeviceRegistryService
}

const decodeStoredDevice = Schema.decodeUnknownSync(StoredDeviceSchema)
const decodeStoredCapability = Schema.decodeUnknownSync(StoredCapabilitySchema)
const decodeDeviceCredential = Schema.decodeUnknownSync(DeviceCredentialSchema)
const decodeDeviceID = Schema.decodeUnknownSync(DevicePrincipalIdSchema)
const decodeOwnerID = Schema.decodeUnknownSync(OwnerIdSchema)

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
        // Preserve the original operation failure. Reopening the scoped
        // adapter is the only safe recovery after a rollback defect.
      }
    }
    throw cause
  }
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
      const ownerID = decodeOwnerID(randomUUID())
      const createdAtEpochMilliseconds = Date.now()
      database.exec(`
        CREATE TABLE owner (
          singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
          owner_id TEXT NOT NULL,
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0)
        ) STRICT;
        CREATE TABLE device_principals (
          device_id TEXT PRIMARY KEY NOT NULL,
          owner_singleton INTEGER NOT NULL DEFAULT 1
            CHECK (owner_singleton = 1)
            REFERENCES owner(singleton),
          display_name TEXT NOT NULL CHECK (
            length(display_name) BETWEEN 1 AND 80
          ),
          platform TEXT NOT NULL CHECK (
            platform IN ('ios', 'macos', 'windows', 'linux', 'service')
          ),
          credential_digest BLOB NOT NULL CHECK (
            length(credential_digest) = ${CredentialDigestBytes}
          ),
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          rotated_at_ms INTEGER NOT NULL CHECK (
            rotated_at_ms >= created_at_ms
          ),
          revoked_at_ms INTEGER CHECK (
            revoked_at_ms IS NULL OR revoked_at_ms >= created_at_ms
          )
        ) STRICT;
        CREATE UNIQUE INDEX device_principals_credential_digest
          ON device_principals (credential_digest);
        CREATE TABLE device_capabilities (
          device_id TEXT NOT NULL REFERENCES device_principals(device_id)
            ON DELETE CASCADE,
          capability TEXT NOT NULL CHECK (
            capability IN ('dictation:write', 'service:health')
          ),
          PRIMARY KEY (device_id, capability)
        ) STRICT;
        PRAGMA user_version = ${SchemaVersion};
      `)
      database
        .prepare(
          `INSERT INTO owner (singleton, owner_id, created_at_ms)
           VALUES (1, ?, ?)`
        )
        .run(ownerID, createdAtEpochMilliseconds)
    })
    return
  }

  if (version !== SchemaVersion) {
    throw new Error("unsupported device registry schema")
  }

  const ownerCount = Schema.decodeUnknownSync(
    Schema.Struct({ count: Schema.Number })
  )(
    database
      .prepare("SELECT count(*) AS count FROM owner WHERE singleton = 1")
      .get()
  ).count
  if (ownerCount !== 1) {
    throw new Error("device registry must contain exactly one owner")
  }
}

const prepareStatements = (
  database: Database.Database
): PreparedStatements => ({
  countDevices: database.prepare(
    "SELECT count(*) AS count FROM device_principals"
  ),
  deleteOldestRevokedDevices: database.prepare(`
    DELETE FROM device_principals
    WHERE device_id IN (
      SELECT device_id
      FROM device_principals
      WHERE revoked_at_ms IS NOT NULL
      ORDER BY revoked_at_ms, created_at_ms, device_id
      LIMIT ?
    )
  `),
  credentialDigestExists: database.prepare(`
    SELECT 1 AS present
    FROM device_principals
    WHERE credential_digest = ?
  `),
  insertDevice: database.prepare(`
    INSERT INTO device_principals (
      device_id,
      owner_singleton,
      display_name,
      platform,
      credential_digest,
      created_at_ms,
      rotated_at_ms,
      revoked_at_ms
    ) VALUES (?, 1, ?, ?, ?, ?, ?, NULL)
  `),
  insertCapability: database.prepare(`
    INSERT INTO device_capabilities (device_id, capability)
    VALUES (?, ?)
  `),
  selectAllDevices: database.prepare(`
    SELECT
      device.device_id,
      owner.owner_id,
      device.display_name,
      device.platform,
      device.credential_digest,
      device.created_at_ms,
      device.rotated_at_ms,
      device.revoked_at_ms
    FROM device_principals AS device
    JOIN owner ON owner.singleton = device.owner_singleton
    ORDER BY device.created_at_ms, device.device_id
    LIMIT ${MaximumDevicePrincipals + 1}
  `),
  selectActiveDevices: database.prepare(`
    SELECT
      device.device_id,
      owner.owner_id,
      device.display_name,
      device.platform,
      device.credential_digest,
      device.created_at_ms,
      device.rotated_at_ms,
      device.revoked_at_ms
    FROM device_principals AS device
    JOIN owner ON owner.singleton = device.owner_singleton
    WHERE device.revoked_at_ms IS NULL
    ORDER BY device.device_id
    LIMIT ${MaximumDevicePrincipals + 1}
  `),
  selectAllCapabilities: database.prepare(`
    SELECT device_id, capability
    FROM device_capabilities
    ORDER BY device_id, capability
    LIMIT ${(MaximumDevicePrincipals + 1) * 2}
  `),
  selectDevice: database.prepare(`
    SELECT
      device.device_id,
      owner.owner_id,
      device.display_name,
      device.platform,
      device.credential_digest,
      device.created_at_ms,
      device.rotated_at_ms,
      device.revoked_at_ms
    FROM device_principals AS device
    JOIN owner ON owner.singleton = device.owner_singleton
    WHERE device.device_id = ?
  `),
  updateCredential: database.prepare(`
    UPDATE device_principals
    SET credential_digest = ?, rotated_at_ms = ?
    WHERE device_id = ? AND revoked_at_ms IS NULL
  `),
  revokeDevice: database.prepare(`
    UPDATE device_principals
    SET revoked_at_ms = ?
    WHERE device_id = ? AND revoked_at_ms IS NULL
  `),
  revokeAllDevices: database.prepare(`
    UPDATE device_principals
    SET revoked_at_ms = ?
    WHERE revoked_at_ms IS NULL
  `)
})

const credentialDigest = (credential: DeviceCredential): Uint8Array =>
  createHash("sha256").update(credential, "utf8").digest()

const makeFreshCredential = (
  statements: PreparedStatements
): {
  readonly credential: DeviceCredential
  readonly digest: Uint8Array
} => {
  for (let attempt = 0; attempt < CredentialGenerationAttempts; attempt += 1) {
    const credential = decodeDeviceCredential(randomBytes(32).toString("hex"))
    const digest = credentialDigest(credential)
    if (statements.credentialDigestExists.get(digest) === undefined) {
      return { credential, digest }
    }
  }
  throw new Error("could not generate a unique device credential")
}

const readCapabilities = (
  statements: PreparedStatements
): ReadonlyMap<DevicePrincipalId, ReadonlyArray<DeviceCapability>> => {
  const rows = statements.selectAllCapabilities.all()
  if (rows.length > MaximumDevicePrincipals * 2) {
    throw new Error("device capability registry exceeds its bound")
  }
  const capabilities = new Map<
    DevicePrincipalId,
    Array<DeviceCapability>
  >()
  for (const unknownRow of rows) {
    const row = decodeStoredCapability(unknownRow)
    const existing = capabilities.get(row.device_id)
    if (existing === undefined) {
      capabilities.set(row.device_id, [row.capability])
    } else {
      existing.push(row.capability)
    }
  }
  return capabilities
}

const toPrincipal = (
  row: ReturnType<typeof decodeStoredDevice>,
  capabilities: ReadonlyArray<DeviceCapability>
): DevicePrincipal => {
  if (capabilities.length === 0) {
    throw new Error("device principal has no capability")
  }
  const base = {
    id: row.device_id,
    ownerID: row.owner_id,
    displayName: row.display_name,
    platform: row.platform,
    capabilities,
    createdAtEpochMilliseconds: row.created_at_ms,
    rotatedAtEpochMilliseconds: row.rotated_at_ms
  }
  return row.revoked_at_ms === null
    ? { ...base, state: { _tag: "Active" } }
    : {
        ...base,
        state: {
          _tag: "Revoked",
          revokedAtEpochMilliseconds: row.revoked_at_ms
        }
      }
}

const readPrincipal = (
  statements: PreparedStatements,
  deviceID: DevicePrincipalId
): DevicePrincipal | undefined => {
  const unknownRow = statements.selectDevice.get(deviceID)
  if (unknownRow === undefined) {
    return undefined
  }
  const capabilities = readCapabilities(statements).get(deviceID) ?? []
  return toPrincipal(decodeStoredDevice(unknownRow), capabilities)
}

const readAllPrincipals = (
  statements: PreparedStatements
): ReadonlyArray<DevicePrincipal> => {
  const unknownRows = statements.selectAllDevices.all()
  if (unknownRows.length > MaximumDevicePrincipals) {
    throw new Error("device principal registry exceeds its bound")
  }
  const capabilities = readCapabilities(statements)
  return unknownRows.map((unknownRow) => {
    const row = decodeStoredDevice(unknownRow)
    return toPrincipal(row, capabilities.get(row.device_id) ?? [])
  })
}

type RegistryDomainError =
  | DeviceRegistryCapacityError
  | DevicePrincipalNotFoundError
  | DevicePrincipalRevokedError

const noExpectedDomainError = (_cause: unknown): _cause is never => false

const isCapacityError = (
  cause: unknown
): cause is DeviceRegistryCapacityError =>
  cause instanceof DeviceRegistryCapacityError

const isNotFoundError = (
  cause: unknown
): cause is DevicePrincipalNotFoundError =>
  cause instanceof DevicePrincipalNotFoundError

const isRotationDomainError = (
  cause: unknown
): cause is DevicePrincipalNotFoundError | DevicePrincipalRevokedError =>
  cause instanceof DevicePrincipalNotFoundError ||
  cause instanceof DevicePrincipalRevokedError

const mapOperationFailure = <Output, ExpectedError extends RegistryDomainError>(
  operation: DeviceRegistryUnavailableError["operation"],
  run: () => Output,
  isExpectedError: (cause: unknown) => cause is ExpectedError
) =>
  Effect.try({
    try: run,
    catch: (cause) =>
      isExpectedError(cause)
        ? cause
        : new DeviceRegistryUnavailableError({ operation })
  })

const isActivePrincipal = (
  principal: DevicePrincipal
): principal is ActiveDevicePrincipal => principal.state._tag === "Active"

const requireActivePrincipal = (
  principal: DevicePrincipal | undefined,
  defect: string
): ActiveDevicePrincipal => {
  if (principal === undefined) {
    throw new Error(defect)
  }
  if (!isActivePrincipal(principal)) {
    throw new Error(defect)
  }
  return principal
}

const makeService = (
  database: Database.Database,
  statements: PreparedStatements
): DeviceRegistryService => ({
  enroll: (input) =>
    Clock.currentTimeMillis.pipe(
      Effect.flatMap((nowEpochMilliseconds) =>
        mapOperationFailure(
          "enroll",
          () => transaction(database, () => {
            const count = Schema.decodeUnknownSync(
              Schema.Struct({ count: Schema.Number })
            )(statements.countDevices.get()).count
            if (count >= MaximumDevicePrincipals) {
              statements.deleteOldestRevokedDevices.run(
                count - MaximumDevicePrincipals + 1
              )
              const retainedCount = Schema.decodeUnknownSync(
                Schema.Struct({ count: Schema.Number })
              )(statements.countDevices.get()).count
              if (retainedCount >= MaximumDevicePrincipals) {
                throw new DeviceRegistryCapacityError({
                  maximumDevices: MaximumDevicePrincipals
                })
              }
            }

            const capabilities = [
              ...new Set<DeviceCapability>(input.capabilities)
            ].sort()
            if (capabilities.length === 0) {
              throw new Error("device principal has no capability")
            }
            const deviceID = decodeDeviceID(randomUUID())
            const generated = makeFreshCredential(statements)
            statements.insertDevice.run(
              deviceID,
              input.displayName,
              input.platform,
              generated.digest,
              nowEpochMilliseconds,
              nowEpochMilliseconds
            )
            for (const capability of capabilities) {
              statements.insertCapability.run(deviceID, capability)
            }
            const principal = requireActivePrincipal(
              readPrincipal(statements, deviceID),
              "new device principal could not be read"
            )
            return {
              principal,
              credential: Redacted.make(generated.credential)
            }
          }),
          isCapacityError
        )
      )
    ),
  list: mapOperationFailure(
    "list",
    () => readAllPrincipals(statements),
    noExpectedDomainError
  ),
  resolve: (input) =>
    mapOperationFailure(
      "resolve",
      () => {
        const unknownRows = statements.selectActiveDevices.all()
        if (unknownRows.length > MaximumDevicePrincipals) {
          throw new Error("active device principal registry exceeds its bound")
        }
        // Load the same bounded metadata before deciding whether the digest
        // matches. Unknown and capability-insufficient credentials therefore
        // follow the same database access shape.
        const capabilities = readCapabilities(statements)
        const presentedDigest = credentialDigest(
          Redacted.value(input.credential)
        )
        let matchingRow: ReturnType<typeof decodeStoredDevice> | undefined
        for (const unknownRow of unknownRows) {
          const row = decodeStoredDevice(unknownRow)
          const matches = timingSafeEqual(
            presentedDigest,
            row.credential_digest
          )
          if (matches) {
            matchingRow = row
          }
        }

        if (matchingRow === undefined) {
          return Option.none()
        }
        const deviceCapabilities =
          capabilities.get(matchingRow.device_id) ?? []
        if (!deviceCapabilities.includes(input.requiredCapability)) {
          return Option.none()
        }
        const principal = requireActivePrincipal(
          toPrincipal(matchingRow, deviceCapabilities),
          "active-device query returned a revoked principal"
        )
        return Option.some({
          principal,
          capability: input.requiredCapability
        })
      },
      noExpectedDomainError
    ),
  rotate: (deviceID) =>
    Clock.currentTimeMillis.pipe(
      Effect.flatMap((nowEpochMilliseconds) =>
        mapOperationFailure(
          "rotate",
          () => transaction(database, () => {
            const existing = readPrincipal(statements, deviceID)
            if (existing === undefined) {
              throw new DevicePrincipalNotFoundError({ deviceID })
            }
            if (existing.state._tag === "Revoked") {
              throw new DevicePrincipalRevokedError({ deviceID })
            }
            const generated = makeFreshCredential(statements)
            const updated = statements.updateCredential.run(
              generated.digest,
              nowEpochMilliseconds,
              deviceID
            )
            if (updated.changes !== 1) {
              throw new Error("active device changed during rotation")
            }
            const principal = requireActivePrincipal(
              readPrincipal(statements, deviceID),
              "rotated device principal could not be read"
            )
            return {
              principal,
              credential: Redacted.make(generated.credential)
            }
          }),
          isRotationDomainError
        )
      )
    ),
  revoke: (deviceID) =>
    Clock.currentTimeMillis.pipe(
      Effect.flatMap((nowEpochMilliseconds) =>
        mapOperationFailure(
          "revoke",
          () => transaction(database, () => {
            const existing = readPrincipal(statements, deviceID)
            if (existing === undefined) {
              throw new DevicePrincipalNotFoundError({ deviceID })
            }
            if (existing.state._tag === "Active") {
              const revoked = statements.revokeDevice.run(
                nowEpochMilliseconds,
                deviceID
              )
              if (revoked.changes !== 1) {
                throw new Error("active device changed during revocation")
              }
            }
            const principal = readPrincipal(statements, deviceID)
            if (
              principal === undefined ||
              principal.state._tag !== "Revoked"
            ) {
              throw new Error("revoked device principal could not be read")
            }
            return principal
          }),
          isNotFoundError
        )
      )
    ),
  revokeAll: Clock.currentTimeMillis.pipe(
    Effect.flatMap((nowEpochMilliseconds) =>
      mapOperationFailure(
        "revoke_all",
        () =>
          transaction(database, () => {
            statements.revokeAllDevices.run(nowEpochMilliseconds)
            const principals = readAllPrincipals(statements)
            if (
              principals.some(
                (principal) => principal.state._tag === "Active"
              )
            ) {
              throw new Error("device revocation reset left an active principal")
            }
            return principals
          }),
        noExpectedDomainError
      )
    )
  )
})

/** Controls whether a registry open enforces the post-restore startup gate. */
export type DeviceRegistryRestoreAccess =
  | "enforce_reauthorization"
  | "administration"

const assertReauthorizationComplete = (
  databasePath: string,
  restoreAccess: DeviceRegistryRestoreAccess
) => {
  if (
    databasePath === ":memory:" ||
    restoreAccess === "administration"
  ) {
    return
  }
  try {
    lstatSync(join(dirname(databasePath), DeviceReauthorizationMarkerName))
    throw new Error("device reauthorization is required")
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

const openDatabaseResource = (
  databasePath: string,
  restoreAccess: DeviceRegistryRestoreAccess
): DatabaseResource => {
  if (databasePath !== ":memory:") {
    const parentDirectory = dirname(databasePath)
    mkdirSync(parentDirectory, { recursive: true, mode: 0o700 })
    const parent = statSync(parentDirectory)
    if (!parent.isDirectory() || (parent.mode & 0o077) !== 0) {
      throw new Error("device database directory is not owner-only")
    }
    assertReauthorizationComplete(databasePath, restoreAccess)
  }

  let database: Database.Database | undefined
  try {
    database = new Database(databasePath, {
      timeout: DatabaseBusyTimeoutMilliseconds
    })
    initializeDatabase(database)
    if (databasePath !== ":memory:") {
      chmodSync(databasePath, 0o600)
    }
    const statements = prepareStatements(database)
    return {
      database,
      service: makeService(database, statements)
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

/**
 * Builds the scoped SQLite adapter for one Owner and bounded device principals.
 *
 * Raw credentials are returned only at enrollment or rotation. The database
 * stores fixed-size SHA-256 digests, and every valid presented credential is
 * compared against every active digest with `timingSafeEqual` before a match
 * is selected.
 */
export const sqliteDeviceRegistryLayer = (
  databasePath: string,
  restoreAccess: DeviceRegistryRestoreAccess = "enforce_reauthorization"
): Layer.Layer<DeviceRegistry, DeviceRegistryUnavailableError> =>
  Layer.scoped(
    DeviceRegistry,
    Effect.acquireRelease(
      Effect.try({
        try: () => openDatabaseResource(databasePath, restoreAccess),
        catch: () =>
          new DeviceRegistryUnavailableError({ operation: "initialize" })
      }),
      (resource) => Effect.sync(() => resource.database.close())
    ).pipe(Effect.map((resource) => resource.service))
  )
