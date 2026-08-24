import Database from "better-sqlite3"
import { createHash, randomUUID } from "node:crypto"
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  open,
  readdir,
  readFile,
  rename,
  rmdir,
  rm,
  stat,
  unlink,
  writeFile
} from "node:fs/promises"
import { basename, dirname, join, resolve } from "node:path"
import { Either, Schema } from "effect"

import {
  DeviceReauthorizationMarkerName,
  DeviceRevocationCompleteMarkerName,
  StorageRestoreMarkerName
} from "./storage-layout.js"

const RegistryFormat = "hex-personal-dictation-storage-registry"
const BackupFormat = "hex-personal-dictation-storage-backup"
const ServiceID = "hex-personal-dictation"
const FormatVersion = 1
const MaximumRegistryBytes = 64 * 1_024
const MaximumManifestBytes = 64 * 1_024
const BackupNamePattern = /^hex-storage-backup-([0-9a-f]{64})$/
const RecoveryIDPattern =
  /^[0-9]{1,16}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const BuildRevisionPattern = /^(development|[0-9a-f]{40})$/
const DatabaseIDPattern = /^[a-z][a-z0-9-]{0,63}$/
const DatabaseFilePattern = /^[a-z0-9][a-z0-9.-]{0,126}\.sqlite$/
const SchemaObjectNamePattern = /^[A-Za-z][A-Za-z0-9_]{0,127}$/
const DigestPattern = /^[0-9a-f]{64}$/
const MaximumConfiguredDatabaseBytes = 1024 * 1_024 * 1_024
const DatabaseBusyTimeoutMilliseconds = 5_000
const DatabaseCopyDeadlineMilliseconds = 60_000

const AllowedSchemaObjectSchema = Schema.Struct({
  type: Schema.Literal("index", "table", "trigger", "view"),
  name: Schema.String
})

const StorageDatabaseDescriptorSchema = Schema.Struct({
  databaseID: Schema.String,
  fileName: Schema.String,
  schemaUserVersion: Schema.Number,
  expectedSchemaFingerprintSHA256: Schema.String,
  maximumBytes: Schema.Number,
  containsAudio: Schema.Literal(false),
  allowedSchemaObjects: Schema.Array(AllowedSchemaObjectSchema)
})

const StorageRegistrySchema = Schema.Struct({
  format: Schema.Literal(RegistryFormat),
  version: Schema.Literal(FormatVersion),
  databases: Schema.Array(StorageDatabaseDescriptorSchema)
})

type StorageDatabaseDescriptor = Schema.Schema.Type<
  typeof StorageDatabaseDescriptorSchema
>
type StorageRegistry = Schema.Schema.Type<typeof StorageRegistrySchema>

const BackupDatabaseManifestSchema = Schema.Struct({
  databaseID: Schema.String,
  sourceFileName: Schema.String,
  artifactFileName: Schema.String,
  bytes: Schema.Number,
  sha256: Schema.String,
  schemaUserVersion: Schema.Number,
  schemaFingerprintSHA256: Schema.String
})

const BackupManifestSchema = Schema.Struct({
  format: Schema.Literal(BackupFormat),
  version: Schema.Literal(FormatVersion),
  serviceID: Schema.Literal(ServiceID),
  artifactID: Schema.String,
  createdAt: Schema.String,
  sourceBuildRevision: Schema.String,
  registrySHA256: Schema.String,
  databases: Schema.Array(BackupDatabaseManifestSchema)
})

type BackupDatabaseManifest = Schema.Schema.Type<
  typeof BackupDatabaseManifestSchema
>
type BackupManifest = Schema.Schema.Type<typeof BackupManifestSchema>

const SqliteSchemaObjectSchema = Schema.Struct({
  type: Schema.Literal("index", "table", "trigger", "view"),
  name: Schema.String,
  table_name: Schema.String,
  sql: Schema.NullOr(Schema.String)
})

const IntegrityCheckRowSchema = Schema.Struct({
  integrity_check: Schema.String
})

const RecoveryPlanSchema = Schema.Struct({
  format: Schema.Literal("hex-personal-dictation-restore-recovery"),
  version: Schema.Literal(1),
  recoveryID: Schema.String,
  restoredArtifactID: Schema.String,
  priorFiles: Schema.Array(
    Schema.Struct({
      databaseID: Schema.String,
      fileName: Schema.String
    })
  )
})

type RecoveryPlan = Schema.Schema.Type<typeof RecoveryPlanSchema>

type StorageAdminOperation = "backup" | "restore" | "finalize_recovery"
type StorageAdminFailureReason =
  | "argument_invalid"
  | "artifact_invalid"
  | "backup_failed"
  | "configuration_invalid"
  | "finalize_failed"
  | "permission_invalid"
  | "recovery_invalid"
  | "recovery_not_ready"
  | "restore_failed"
  | "rollback_failed"
  | "schema_invalid"
  | "source_unavailable"

/** A classified, safely loggable storage-administration failure. */
export class StorageAdminError extends Error {
  readonly _tag = "StorageAdminError" as const

  /** Storage operation that failed. */
  readonly operation: StorageAdminOperation

  /** Stable failure classification without a path or database content. */
  readonly reason: StorageAdminFailureReason

  /** Safe logical database identifier, when one was known. */
  readonly databaseID: string | undefined

  /** Safe recovery directory identifier after an incomplete rollback. */
  readonly recoveryID: string | undefined

  /** Underlying adapter failure, intentionally excluded from CLI output. */
  override readonly cause: unknown

  constructor(input: {
    readonly operation: StorageAdminOperation
    readonly reason: StorageAdminFailureReason
    readonly databaseID?: string
    readonly recoveryID?: string
    readonly cause?: unknown
  }) {
    super(`storage ${input.operation} failed: ${input.reason}`)
    this.operation = input.operation
    this.reason = input.reason
    this.databaseID = input.databaseID
    this.recoveryID = input.recoveryID
    this.cause = input.cause
  }
}

/** An explicit success or classified expected failure from storage administration. */
export type StorageAdminResult<Success> =
  | { readonly _tag: "Success"; readonly value: Success }
  | { readonly _tag: "Failure"; readonly error: StorageAdminError }

/** Input for an online, consistent backup of every registered database. */
export interface CreateStorageBackupInput {
  readonly registryPath: string
  readonly dataDirectory: string
  readonly backupDirectory: string
  readonly sourceBuildRevision: string
}

/** Identity of a completed, content-addressed storage backup. */
export interface CreatedStorageBackup {
  readonly artifactID: string
  readonly artifactName: string
}

/** Input for an offline restore of one validated storage backup. */
export interface RestoreStorageBackupInput {
  readonly registryPath: string
  readonly dataDirectory: string
  readonly backupDirectory: string
  readonly artifactName: string
  readonly sourceBuildRevision: string
}

/** Identity of a completed restore and its retained pre-restore recovery set. */
export interface RestoredStorageBackup {
  readonly artifactID: string
  readonly recoveryID: string
  readonly reauthorizationRequired: boolean
}

/** Input for retiring one exact pre-restore recovery set after verification. */
export interface FinalizeRestoreRecoveryInput {
  readonly registryPath: string
  readonly dataDirectory: string
  readonly recoveryID: string
}

/** Identity of the retired pre-restore recovery set. */
export interface FinalizedRestoreRecovery {
  readonly recoveryID: string
}

interface DatabaseInspection {
  readonly bytes: number
  readonly schemaUserVersion: number
  readonly schemaFingerprintSHA256: string
}

interface ValidatedArtifact {
  readonly manifest: BackupManifest
  readonly databasePaths: ReadonlyMap<string, string>
}

interface MovedFile {
  readonly livePath: string
  readonly recoveryPath: string
}

const success = <Value>(value: Value): StorageAdminResult<Value> => ({
  _tag: "Success",
  value
})

const failure = <Value>(
  error: StorageAdminError
): StorageAdminResult<Value> => ({ _tag: "Failure", error })

const makeStorageError = (
  operation: StorageAdminOperation,
  reason: StorageAdminFailureReason,
  cause?: unknown,
  databaseID?: string,
  recoveryID?: string
) =>
  new StorageAdminError({
    operation,
    reason,
    ...(databaseID === undefined ? {} : { databaseID }),
    ...(recoveryID === undefined ? {} : { recoveryID }),
    ...(cause === undefined ? {} : { cause })
  })

const throwStorageError = (
  operation: StorageAdminOperation,
  reason: StorageAdminFailureReason,
  cause?: unknown,
  databaseID?: string,
  recoveryID?: string
): never => {
  throw makeStorageError(
    operation,
    reason,
    cause,
    databaseID,
    recoveryID
  )
}

const parseJSON = (raw: string): unknown => JSON.parse(raw)

const readBoundedFile = async (path: string, maximumBytes: number) => {
  const handle = await open(path, "r")
  try {
    const metadata = await handle.stat()
    if (!metadata.isFile() || metadata.size > maximumBytes) {
      throw new Error("bounded file requirement failed")
    }
    return await readFile(handle, "utf8")
  } finally {
    await handle.close()
  }
}

const canonicalRegistryValue = (registry: StorageRegistry) => ({
  format: registry.format,
  version: registry.version,
  databases: [...registry.databases]
    .sort((left, right) => left.databaseID.localeCompare(right.databaseID))
    .map((database) => ({
      databaseID: database.databaseID,
      fileName: database.fileName,
      schemaUserVersion: database.schemaUserVersion,
      expectedSchemaFingerprintSHA256:
        database.expectedSchemaFingerprintSHA256,
      maximumBytes: database.maximumBytes,
      containsAudio: database.containsAudio,
      allowedSchemaObjects: [...database.allowedSchemaObjects]
        .sort((left, right) =>
          `${left.type}:${left.name}`.localeCompare(
            `${right.type}:${right.name}`
          )
        )
        .map((object) => ({ type: object.type, name: object.name }))
    }))
})

const digestString = (value: string) =>
  createHash("sha256").update(value, "utf8").digest("hex")

const registryDigest = (registry: StorageRegistry) =>
  digestString(JSON.stringify(canonicalRegistryValue(registry)))

const parseRegistry = async (
  path: string,
  operation: StorageAdminOperation
): Promise<StorageRegistry> => {
  let decoded: Either.Either<StorageRegistry, unknown>
  try {
    const raw = await readBoundedFile(path, MaximumRegistryBytes)
    decoded = Schema.decodeUnknownEither(StorageRegistrySchema, {
      onExcessProperty: "error"
    })(parseJSON(raw))
  } catch (cause) {
    return throwStorageError(
      operation,
      "configuration_invalid",
      cause
    )
  }
  if (Either.isLeft(decoded)) {
    return throwStorageError(
      operation,
      "configuration_invalid",
      decoded.left
    )
  }

  const registry = decoded.right
  if (registry.databases.length === 0) {
    return throwStorageError(operation, "configuration_invalid")
  }

  const databaseIDs = new Set<string>()
  const fileNames = new Set<string>()
  for (const database of registry.databases) {
    if (
      !DatabaseIDPattern.test(database.databaseID) ||
      !DatabaseFilePattern.test(database.fileName) ||
      database.fileName.includes("..") ||
      !Number.isSafeInteger(database.schemaUserVersion) ||
      database.schemaUserVersion < 1 ||
      !DigestPattern.test(database.expectedSchemaFingerprintSHA256) ||
      !Number.isSafeInteger(database.maximumBytes) ||
      database.maximumBytes < 4_096 ||
      database.maximumBytes > MaximumConfiguredDatabaseBytes ||
      database.allowedSchemaObjects.length === 0 ||
      databaseIDs.has(database.databaseID) ||
      fileNames.has(database.fileName)
    ) {
      const safeDatabaseID = DatabaseIDPattern.test(database.databaseID)
        ? database.databaseID
        : undefined
      return throwStorageError(
        operation,
        "configuration_invalid",
        undefined,
        safeDatabaseID
      )
    }
    databaseIDs.add(database.databaseID)
    fileNames.add(database.fileName)

    const objectIDs = new Set<string>()
    for (const object of database.allowedSchemaObjects) {
      const objectID = `${object.type}:${object.name}`
      if (
        !SchemaObjectNamePattern.test(object.name) ||
        objectIDs.has(objectID)
      ) {
        return throwStorageError(
          operation,
          "configuration_invalid",
          undefined,
          database.databaseID
        )
      }
      objectIDs.add(objectID)
    }
  }
  return registry
}

const currentUserID = () => {
  const userID = process.getuid?.()
  if (userID === undefined) {
    throw new Error("POSIX ownership is required")
  }
  return userID
}

const assertOwnerOnlyDirectory = async (
  path: string,
  operation: StorageAdminOperation
) => {
  let metadata
  try {
    metadata = await lstat(path)
  } catch (cause) {
    return throwStorageError(operation, "permission_invalid", cause)
  }
  if (
    !metadata.isDirectory() ||
    metadata.isSymbolicLink() ||
    metadata.uid !== currentUserID() ||
    (metadata.mode & 0o077) !== 0
  ) {
    return throwStorageError(operation, "permission_invalid")
  }
}

const assertOwnerOnlyRegularFile = async (
  path: string,
  operation: StorageAdminOperation,
  databaseID?: string
) => {
  let metadata
  try {
    metadata = await lstat(path)
  } catch (cause) {
    return throwStorageError(
      operation,
      "source_unavailable",
      cause,
      databaseID
    )
  }
  if (
    !metadata.isFile() ||
    metadata.isSymbolicLink() ||
    metadata.uid !== currentUserID() ||
    (metadata.mode & 0o077) !== 0
  ) {
    return throwStorageError(
      operation,
      "permission_invalid",
      undefined,
      databaseID
    )
  }
}

const assertDirectChild = (parent: string, child: string) => {
  const resolvedParent = resolve(parent)
  const resolvedChild = resolve(parent, child)
  if (dirname(resolvedChild) !== resolvedParent) {
    throw new Error("path escaped its configured directory")
  }
  return resolvedChild
}

const schemaSQLForFingerprint = (sql: string | null) =>
  sql === null ? null : sql.trim()

const inspectDatabase = (
  databasePath: string,
  descriptor: StorageDatabaseDescriptor,
  operation: StorageAdminOperation
): DatabaseInspection => {
  let database: Database.Database | undefined
  try {
    database = new Database(databasePath, {
      readonly: true,
      fileMustExist: true,
      timeout: DatabaseBusyTimeoutMilliseconds
    })
    database.pragma("query_only = ON")

    const integrityRows = Schema.decodeUnknownSync(
      Schema.Array(IntegrityCheckRowSchema)
    )(database.pragma("integrity_check"))
    if (
      integrityRows.length !== 1 ||
      integrityRows[0]?.integrity_check !== "ok"
    ) {
      return throwStorageError(
        operation,
        "schema_invalid",
        undefined,
        descriptor.databaseID
      )
    }

    const foreignKeyFailures = Schema.decodeUnknownSync(
      Schema.Array(Schema.Unknown)
    )(database.pragma("foreign_key_check"))
    if (foreignKeyFailures.length !== 0) {
      return throwStorageError(
        operation,
        "schema_invalid",
        undefined,
        descriptor.databaseID
      )
    }

    const schemaUserVersion = Schema.decodeUnknownSync(Schema.Number)(
      database.pragma("user_version", { simple: true })
    )
    if (schemaUserVersion !== descriptor.schemaUserVersion) {
      return throwStorageError(
        operation,
        "schema_invalid",
        undefined,
        descriptor.databaseID
      )
    }

    const schemaObjects = Schema.decodeUnknownSync(
      Schema.Array(SqliteSchemaObjectSchema)
    )(
      database
        .prepare(
          `
            SELECT type, name, tbl_name AS table_name, sql
            FROM sqlite_schema
            WHERE name NOT LIKE 'sqlite_%'
              AND type IN ('index', 'table', 'trigger', 'view')
            ORDER BY type, name
          `
        )
        .all()
    )
    const expectedObjects = [...descriptor.allowedSchemaObjects]
      .sort((left, right) =>
        `${left.type}:${left.name}`.localeCompare(
          `${right.type}:${right.name}`
        )
      )
      .map((object) => `${object.type}:${object.name}`)
    const actualObjects = schemaObjects.map(
      (object) => `${object.type}:${object.name}`
    )
    if (JSON.stringify(actualObjects) !== JSON.stringify(expectedObjects)) {
      return throwStorageError(
        operation,
        "schema_invalid",
        undefined,
        descriptor.databaseID
      )
    }

    const schemaFingerprintSHA256 = digestString(
      JSON.stringify(
        schemaObjects.map((object) => ({
          type: object.type,
          name: object.name,
          tableName: object.table_name,
          sql: schemaSQLForFingerprint(object.sql)
        }))
      )
    )
    if (
      schemaFingerprintSHA256 !==
      descriptor.expectedSchemaFingerprintSHA256
    ) {
      return throwStorageError(
        operation,
        "schema_invalid",
        undefined,
        descriptor.databaseID
      )
    }
    const metadata = database.prepare("PRAGMA page_count").get()
    const pageCount = Schema.decodeUnknownSync(
      Schema.Struct({ page_count: Schema.Number })
    )(metadata).page_count
    const pageSize = Schema.decodeUnknownSync(Schema.Number)(
      database.pragma("page_size", { simple: true })
    )
    const bytes = pageCount * pageSize
    if (
      !Number.isSafeInteger(bytes) ||
      bytes <= 0 ||
      bytes > descriptor.maximumBytes
    ) {
      return throwStorageError(
        operation,
        "schema_invalid",
        undefined,
        descriptor.databaseID
      )
    }
    return {
      bytes,
      schemaUserVersion,
      schemaFingerprintSHA256
    }
  } catch (cause) {
    if (cause instanceof StorageAdminError) {
      throw cause
    }
    return throwStorageError(
      operation,
      "schema_invalid",
      cause,
      descriptor.databaseID
    )
  } finally {
    if (database?.open === true) {
      database.close()
    }
  }
}

const hashFile = async (path: string) => {
  const handle = await open(path, "r")
  try {
    const hash = createHash("sha256")
    const buffer = Buffer.allocUnsafe(64 * 1_024)
    let position = 0
    while (true) {
      const { bytesRead } = await handle.read(
        buffer,
        0,
        buffer.length,
        position
      )
      if (bytesRead === 0) {
        return hash.digest("hex")
      }
      hash.update(buffer.subarray(0, bytesRead))
      position += bytesRead
    }
  } finally {
    await handle.close()
  }
}

const fsyncFile = async (path: string) => {
  const handle = await open(path, "r")
  try {
    await handle.sync()
  } finally {
    await handle.close()
  }
}

const fsyncDirectory = async (path: string) => {
  const handle = await open(path, "r")
  try {
    await handle.sync()
  } finally {
    await handle.close()
  }
}

const copyDatabaseWithOnlineBackup = async (
  sourcePath: string,
  destinationPath: string,
  descriptor: StorageDatabaseDescriptor,
  operation: StorageAdminOperation
) => {
  let source: Database.Database | undefined
  let destination: Database.Database | undefined
  try {
    source = new Database(sourcePath, {
      readonly: true,
      fileMustExist: true,
      timeout: DatabaseBusyTimeoutMilliseconds
    })
    source.pragma("query_only = ON")
    // better-sqlite3 implements this method with SQLite's Online Backup API,
    // yielding a transactionally consistent destination while WAL writers run.
    const copyDeadline = performance.now() + DatabaseCopyDeadlineMilliseconds
    await source.backup(destinationPath, {
      progress: () => {
        if (performance.now() >= copyDeadline) {
          throw new Error("SQLite online backup exceeded its deadline")
        }
        return 100
      }
    })
    source.close()
    source = undefined

    // A backup inherits WAL journal mode. Normalize the closed artifact to a
    // standalone main database so validation never creates or depends on WAL
    // sidecars; the service restores WAL mode when it next opens live storage.
    destination = new Database(destinationPath, {
      fileMustExist: true,
      timeout: DatabaseBusyTimeoutMilliseconds
    })
    destination.pragma("wal_checkpoint(TRUNCATE)")
    const journalMode = Schema.decodeUnknownSync(Schema.String)(
      destination.pragma("journal_mode = DELETE", { simple: true })
    )
    if (journalMode.toLowerCase() !== "delete") {
      throw new Error("standalone backup journal mode was not applied")
    }
    destination.close()
    destination = undefined
    await chmod(destinationPath, 0o600)
    await fsyncFile(destinationPath)
  } catch (cause) {
    return throwStorageError(
      operation,
      operation === "backup" ? "backup_failed" : "restore_failed",
      cause,
      descriptor.databaseID
    )
  } finally {
    if (destination?.open === true) {
      destination.close()
    }
    if (source?.open === true) {
      source.close()
    }
  }
}

const canonicalManifestBase = (
  input: Omit<BackupManifest, "artifactID">
) => ({
  format: input.format,
  version: input.version,
  serviceID: input.serviceID,
  createdAt: input.createdAt,
  sourceBuildRevision: input.sourceBuildRevision,
  registrySHA256: input.registrySHA256,
  databases: input.databases.map((database) => ({
    databaseID: database.databaseID,
    sourceFileName: database.sourceFileName,
    artifactFileName: database.artifactFileName,
    bytes: database.bytes,
    sha256: database.sha256,
    schemaUserVersion: database.schemaUserVersion,
    schemaFingerprintSHA256: database.schemaFingerprintSHA256
  }))
})

const manifestArtifactID = (
  input: Omit<BackupManifest, "artifactID">
) => digestString(JSON.stringify(canonicalManifestBase(input)))

const parseManifest = async (
  path: string,
  operation: StorageAdminOperation
): Promise<BackupManifest> => {
  let decoded: Either.Either<BackupManifest, unknown>
  try {
    const raw = await readBoundedFile(path, MaximumManifestBytes)
    decoded = Schema.decodeUnknownEither(BackupManifestSchema, {
      onExcessProperty: "error"
    })(parseJSON(raw))
  } catch (cause) {
    return throwStorageError(operation, "artifact_invalid", cause)
  }
  if (Either.isLeft(decoded)) {
    return throwStorageError(
      operation,
      "artifact_invalid",
      decoded.left
    )
  }
  return decoded.right
}

const parseRecoveryPlan = async (
  planPath: string
): Promise<RecoveryPlan> => {
  try {
    const raw = await readBoundedFile(planPath, MaximumManifestBytes)
    const decoded = Schema.decodeUnknownEither(RecoveryPlanSchema, {
      onExcessProperty: "error"
    })(parseJSON(raw))
    if (Either.isLeft(decoded)) {
      return throwStorageError(
        "finalize_recovery",
        "recovery_invalid",
        decoded.left
      )
    }
    return decoded.right
  } catch (cause) {
    if (cause instanceof StorageAdminError) {
      throw cause
    }
    return throwStorageError(
      "finalize_recovery",
      "recovery_invalid",
      cause
    )
  }
}

const assertPathAbsent = async (path: string) => {
  try {
    await lstat(path)
  } catch (cause) {
    const code =
      typeof cause === "object" && cause !== null && "code" in cause
        ? cause.code
        : undefined
    if (code === "ENOENT") {
      return
    }
    return throwStorageError(
      "finalize_recovery",
      "permission_invalid",
      cause
    )
  }
  return throwStorageError(
    "finalize_recovery",
    "recovery_not_ready"
  )
}

const validateArtifact = async (
  registry: StorageRegistry,
  backupDirectory: string,
  artifactName: string,
  operation: StorageAdminOperation
): Promise<ValidatedArtifact> => {
  const nameMatch = BackupNamePattern.exec(artifactName)
  if (nameMatch === null) {
    return throwStorageError(operation, "argument_invalid")
  }
  const expectedNameArtifactID = nameMatch[1]
  if (expectedNameArtifactID === undefined) {
    return throwStorageError(operation, "argument_invalid")
  }

  const artifactDirectory = assertDirectChild(
    backupDirectory,
    artifactName
  )
  await assertOwnerOnlyDirectory(artifactDirectory, operation)
  const manifestPath = assertDirectChild(
    artifactDirectory,
    "manifest.json"
  )
  await assertOwnerOnlyRegularFile(manifestPath, operation)
  const manifest = await parseManifest(manifestPath, operation)

  if (
    !DigestPattern.test(manifest.artifactID) ||
    manifest.artifactID !== expectedNameArtifactID ||
    !BuildRevisionPattern.test(manifest.sourceBuildRevision) ||
    !DigestPattern.test(manifest.registrySHA256) ||
    manifest.registrySHA256 !== registryDigest(registry) ||
    manifest.createdAt !== new Date(manifest.createdAt).toISOString()
  ) {
    return throwStorageError(operation, "artifact_invalid")
  }

  const manifestBase: Omit<BackupManifest, "artifactID"> = {
    format: manifest.format,
    version: manifest.version,
    serviceID: manifest.serviceID,
    createdAt: manifest.createdAt,
    sourceBuildRevision: manifest.sourceBuildRevision,
    registrySHA256: manifest.registrySHA256,
    databases: manifest.databases
  }
  if (manifestArtifactID(manifestBase) !== manifest.artifactID) {
    return throwStorageError(operation, "artifact_invalid")
  }

  const expectedRootEntries = ["databases", "manifest.json"]
  const rootEntries = (await readdir(artifactDirectory)).sort()
  if (JSON.stringify(rootEntries) !== JSON.stringify(expectedRootEntries)) {
    return throwStorageError(operation, "artifact_invalid")
  }

  const databasesDirectory = assertDirectChild(
    artifactDirectory,
    "databases"
  )
  await assertOwnerOnlyDirectory(databasesDirectory, operation)

  const descriptors = [...registry.databases].sort((left, right) =>
    left.databaseID.localeCompare(right.databaseID)
  )
  if (manifest.databases.length !== descriptors.length) {
    return throwStorageError(operation, "artifact_invalid")
  }
  const expectedArtifactFiles = descriptors.map(
    (descriptor) => `${descriptor.databaseID}.sqlite`
  )
  const artifactFiles = (await readdir(databasesDirectory)).sort()
  if (
    JSON.stringify(artifactFiles) !==
    JSON.stringify(expectedArtifactFiles)
  ) {
    return throwStorageError(operation, "artifact_invalid")
  }

  const databasePaths = new Map<string, string>()
  for (const [index, descriptor] of descriptors.entries()) {
    const databaseManifest = manifest.databases[index]
    const artifactFileName = `${descriptor.databaseID}.sqlite`
    if (
      databaseManifest === undefined ||
      databaseManifest.databaseID !== descriptor.databaseID ||
      databaseManifest.sourceFileName !== descriptor.fileName ||
      databaseManifest.artifactFileName !== artifactFileName ||
      !Number.isSafeInteger(databaseManifest.bytes) ||
      databaseManifest.bytes <= 0 ||
      databaseManifest.bytes > descriptor.maximumBytes ||
      !DigestPattern.test(databaseManifest.sha256) ||
      !DigestPattern.test(databaseManifest.schemaFingerprintSHA256) ||
      databaseManifest.schemaFingerprintSHA256 !==
        descriptor.expectedSchemaFingerprintSHA256 ||
      databaseManifest.schemaUserVersion !== descriptor.schemaUserVersion
    ) {
      return throwStorageError(
        operation,
        "artifact_invalid",
        undefined,
        descriptor.databaseID
      )
    }

    const databasePath = assertDirectChild(
      databasesDirectory,
      artifactFileName
    )
    await assertOwnerOnlyRegularFile(
      databasePath,
      operation,
      descriptor.databaseID
    )
    const fileMetadata = await stat(databasePath)
    if (
      fileMetadata.size !== databaseManifest.bytes ||
      (await hashFile(databasePath)) !== databaseManifest.sha256
    ) {
      return throwStorageError(
        operation,
        "artifact_invalid",
        undefined,
        descriptor.databaseID
      )
    }
    const inspection = inspectDatabase(
      databasePath,
      descriptor,
      operation
    )
    if (
      inspection.bytes !== databaseManifest.bytes ||
      inspection.schemaUserVersion !== databaseManifest.schemaUserVersion ||
      inspection.schemaFingerprintSHA256 !==
        databaseManifest.schemaFingerprintSHA256
    ) {
      return throwStorageError(
        operation,
        "artifact_invalid",
        undefined,
        descriptor.databaseID
      )
    }
    databasePaths.set(descriptor.databaseID, databasePath)
  }
  return { manifest, databasePaths }
}

const normalizeError = (
  operation: StorageAdminOperation,
  cause: unknown,
  fallbackReason: StorageAdminFailureReason
) =>
  cause instanceof StorageAdminError
    ? cause
    : makeStorageError(operation, fallbackReason, cause)

/**
 * Creates a content-addressed backup with SQLite's Online Backup API.
 *
 * The registry is an explicit allowlist: only registered SQLite databases are
 * copied, so raw capture audio and unrelated files can never enter an artifact.
 */
export const createStorageBackup = async (
  input: CreateStorageBackupInput
): Promise<StorageAdminResult<CreatedStorageBackup>> => {
  let temporaryDirectory: string | undefined
  try {
    if (!BuildRevisionPattern.test(input.sourceBuildRevision)) {
      return failure(
        makeStorageError("backup", "argument_invalid")
      )
    }
    const registry = await parseRegistry(input.registryPath, "backup")
    await assertOwnerOnlyDirectory(input.dataDirectory, "backup")
    await mkdir(input.backupDirectory, { recursive: true, mode: 0o700 })
    await assertOwnerOnlyDirectory(input.backupDirectory, "backup")

    temporaryDirectory = await mkdtemp(
      join(input.backupDirectory, ".backup-incomplete-")
    )
    await chmod(temporaryDirectory, 0o700)
    const databasesDirectory = join(temporaryDirectory, "databases")
    await mkdir(databasesDirectory, { mode: 0o700 })

    const databaseManifests: Array<BackupDatabaseManifest> = []
    const descriptors = [...registry.databases].sort((left, right) =>
      left.databaseID.localeCompare(right.databaseID)
    )
    for (const descriptor of descriptors) {
      const sourcePath = assertDirectChild(
        input.dataDirectory,
        descriptor.fileName
      )
      await assertOwnerOnlyRegularFile(
        sourcePath,
        "backup",
        descriptor.databaseID
      )
      inspectDatabase(sourcePath, descriptor, "backup")

      const artifactFileName = `${descriptor.databaseID}.sqlite`
      const destinationPath = assertDirectChild(
        databasesDirectory,
        artifactFileName
      )
      await copyDatabaseWithOnlineBackup(
        sourcePath,
        destinationPath,
        descriptor,
        "backup"
      )
      const inspection = inspectDatabase(
        destinationPath,
        descriptor,
        "backup"
      )
      const fileMetadata = await stat(destinationPath)
      if (fileMetadata.size !== inspection.bytes) {
        return throwStorageError(
          "backup",
          "backup_failed",
          undefined,
          descriptor.databaseID
        )
      }
      databaseManifests.push({
        databaseID: descriptor.databaseID,
        sourceFileName: descriptor.fileName,
        artifactFileName,
        bytes: inspection.bytes,
        sha256: await hashFile(destinationPath),
        schemaUserVersion: inspection.schemaUserVersion,
        schemaFingerprintSHA256: inspection.schemaFingerprintSHA256
      })
    }

    const manifestBase: Omit<BackupManifest, "artifactID"> = {
      format: BackupFormat,
      version: FormatVersion,
      serviceID: ServiceID,
      createdAt: new Date().toISOString(),
      sourceBuildRevision: input.sourceBuildRevision,
      registrySHA256: registryDigest(registry),
      databases: databaseManifests
    }
    const artifactID = manifestArtifactID(manifestBase)
    const manifest: BackupManifest = { ...manifestBase, artifactID }
    const manifestPath = join(temporaryDirectory, "manifest.json")
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600
    })
    await fsyncFile(manifestPath)
    await fsyncDirectory(databasesDirectory)
    await fsyncDirectory(temporaryDirectory)

    const artifactName = `hex-storage-backup-${artifactID}`
    const artifactDirectory = assertDirectChild(
      input.backupDirectory,
      artifactName
    )
    await rename(temporaryDirectory, artifactDirectory)
    temporaryDirectory = undefined
    await fsyncDirectory(input.backupDirectory)
    await validateArtifact(
      registry,
      input.backupDirectory,
      artifactName,
      "backup"
    )
    return success({ artifactID, artifactName })
  } catch (cause) {
    return failure(normalizeError("backup", cause, "backup_failed"))
  } finally {
    if (temporaryDirectory !== undefined) {
      await rm(temporaryDirectory, { recursive: true, force: true }).catch(
        () => undefined
      )
    }
  }
}

const existingOwnerOnlyFiles = async (
  paths: ReadonlyArray<string>,
  operation: StorageAdminOperation,
  databaseID: string
) => {
  const existing: Array<string> = []
  for (const path of paths) {
    try {
      await lstat(path)
    } catch (cause) {
      const code =
        typeof cause === "object" && cause !== null && "code" in cause
          ? cause.code
          : undefined
      if (code === "ENOENT") {
        continue
      }
      return throwStorageError(
        operation,
        "source_unavailable",
        cause,
        databaseID
      )
    }
    await assertOwnerOnlyRegularFile(path, operation, databaseID)
    existing.push(path)
  }
  return existing
}

const rollbackRestore = async (
  installedDatabasePaths: ReadonlyArray<string>,
  movedFiles: ReadonlyArray<MovedFile>,
  dataDirectory: string
) => {
  const unlinkIfPresent = async (path: string) => {
    try {
      await unlink(path)
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
  for (const installedPath of [...installedDatabasePaths].reverse()) {
    await unlinkIfPresent(installedPath)
    await unlinkIfPresent(`${installedPath}-wal`)
    await unlinkIfPresent(`${installedPath}-shm`)
  }
  for (const moved of [...movedFiles].reverse()) {
    await rename(moved.recoveryPath, moved.livePath)
  }
  await fsyncDirectory(dataDirectory)
}

/**
 * Restores a validated backup into an owner-only data directory.
 *
 * The caller must prove the proxy and recognition services are stopped. A
 * durable marker blocks proxy startup during replacement or a failed rollback.
 */
export const restoreStorageBackup = async (
  input: RestoreStorageBackupInput
): Promise<StorageAdminResult<RestoredStorageBackup>> => {
  let stagingDirectory: string | undefined
  let recoveryDirectory: string | undefined
  let recoveryID: string | undefined
  let markerDirectory: string | undefined
  let reauthorizationMarkerDirectory: string | undefined
  let createdReauthorizationMarker = false
  const movedFiles: Array<MovedFile> = []
  const installedDatabasePaths: Array<string> = []
  try {
    if (!BuildRevisionPattern.test(input.sourceBuildRevision)) {
      return failure(
        makeStorageError("restore", "argument_invalid")
      )
    }
    const registry = await parseRegistry(input.registryPath, "restore")
    await assertOwnerOnlyDirectory(input.dataDirectory, "restore")
    await assertOwnerOnlyDirectory(input.backupDirectory, "restore")
    const artifact = await validateArtifact(
      registry,
      input.backupDirectory,
      input.artifactName,
      "restore"
    )

    stagingDirectory = await mkdtemp(
      join(input.dataDirectory, ".restore-staging-")
    )
    await chmod(stagingDirectory, 0o700)
    const descriptors = [...registry.databases].sort((left, right) =>
      left.databaseID.localeCompare(right.databaseID)
    )
    for (const descriptor of descriptors) {
      const sourcePath = artifact.databasePaths.get(
        descriptor.databaseID
      )
      if (sourcePath === undefined) {
        return throwStorageError(
          "restore",
          "artifact_invalid",
          undefined,
          descriptor.databaseID
        )
      }
      const stagedPath = assertDirectChild(
        stagingDirectory,
        descriptor.fileName
      )
      await copyDatabaseWithOnlineBackup(
        sourcePath,
        stagedPath,
        descriptor,
        "restore"
      )
      inspectDatabase(stagedPath, descriptor, "restore")
    }
    await fsyncDirectory(stagingDirectory)

    recoveryID = `${Date.now()}-${randomUUID()}`
    recoveryDirectory = assertDirectChild(
      input.dataDirectory,
      `.restore-recovery-${recoveryID}`
    )
    await mkdir(recoveryDirectory, { mode: 0o700 })
    const restoreMarkerDirectory = assertDirectChild(
      input.dataDirectory,
      StorageRestoreMarkerName
    )
    await mkdir(restoreMarkerDirectory, { mode: 0o700 })
    markerDirectory = restoreMarkerDirectory

    const reauthorizationRequired = descriptors.some(
      (descriptor) => descriptor.databaseID === "device-registry"
    )
    if (reauthorizationRequired) {
      reauthorizationMarkerDirectory = assertDirectChild(
        input.dataDirectory,
        DeviceReauthorizationMarkerName
      )
      try {
        await mkdir(reauthorizationMarkerDirectory, { mode: 0o700 })
        createdReauthorizationMarker = true
      } catch (cause) {
        const code =
          typeof cause === "object" && cause !== null && "code" in cause
            ? cause.code
            : undefined
        if (code !== "EEXIST") {
          throw cause
        }
        await assertOwnerOnlyDirectory(
          reauthorizationMarkerDirectory,
          "restore"
        )
      }
      const priorRevocationProof = assertDirectChild(
        reauthorizationMarkerDirectory,
        DeviceRevocationCompleteMarkerName
      )
      try {
        await lstat(priorRevocationProof)
        await assertOwnerOnlyDirectory(priorRevocationProof, "restore")
        if ((await readdir(priorRevocationProof)).length !== 0) {
          return throwStorageError("restore", "permission_invalid")
        }
        await rmdir(priorRevocationProof)
      } catch (cause) {
        const code =
          typeof cause === "object" && cause !== null && "code" in cause
            ? cause.code
            : undefined
        if (code !== "ENOENT") {
          throw cause
        }
      }
      await fsyncDirectory(reauthorizationMarkerDirectory)
    }

    const plannedFiles: Array<{
      readonly databaseID: string
      readonly fileName: string
    }> = []
    for (const descriptor of descriptors) {
      const livePath = assertDirectChild(
        input.dataDirectory,
        descriptor.fileName
      )
      const existing = await existingOwnerOnlyFiles(
        [livePath, `${livePath}-wal`, `${livePath}-shm`],
        "restore",
        descriptor.databaseID
      )
      for (const path of existing) {
        plannedFiles.push({
          databaseID: descriptor.databaseID,
          fileName: basename(path)
        })
      }
    }
    const recoveryPlanPath = join(
      recoveryDirectory,
      "recovery-plan.json"
    )
    await writeFile(
      recoveryPlanPath,
      `${JSON.stringify(
        {
          format: "hex-personal-dictation-restore-recovery",
          version: 1,
          recoveryID,
          restoredArtifactID: artifact.manifest.artifactID,
          priorFiles: plannedFiles
        },
        null,
        2
      )}\n`,
      { encoding: "utf8", flag: "wx", mode: 0o600 }
    )
    await fsyncFile(recoveryPlanPath)
    await fsyncDirectory(recoveryDirectory)
    await fsyncDirectory(markerDirectory)
    await fsyncDirectory(input.dataDirectory)

    for (const descriptor of descriptors) {
      const livePath = assertDirectChild(
        input.dataDirectory,
        descriptor.fileName
      )
      const existing = await existingOwnerOnlyFiles(
        [livePath, `${livePath}-wal`, `${livePath}-shm`],
        "restore",
        descriptor.databaseID
      )
      for (const path of existing) {
        const recoveryPath = assertDirectChild(
          recoveryDirectory,
          basename(path)
        )
        await rename(path, recoveryPath)
        movedFiles.push({ livePath: path, recoveryPath })
      }
      const stagedPath = assertDirectChild(
        stagingDirectory,
        descriptor.fileName
      )
      await rename(stagedPath, livePath)
      installedDatabasePaths.push(livePath)
      await chmod(livePath, 0o600)
    }
    await fsyncDirectory(input.dataDirectory)

    for (const descriptor of descriptors) {
      inspectDatabase(
        assertDirectChild(input.dataDirectory, descriptor.fileName),
        descriptor,
        "restore"
      )
    }
    await rm(stagingDirectory, { recursive: true })
    stagingDirectory = undefined
    await fsyncDirectory(input.dataDirectory)
    await rmdir(markerDirectory)
    markerDirectory = undefined
    await fsyncDirectory(input.dataDirectory)
    return success({
      artifactID: artifact.manifest.artifactID,
      recoveryID,
      reauthorizationRequired
    })
  } catch (cause) {
    if (markerDirectory !== undefined) {
      try {
        await rollbackRestore(
          installedDatabasePaths,
          movedFiles,
          input.dataDirectory
        )
        if (
          createdReauthorizationMarker &&
          reauthorizationMarkerDirectory !== undefined
        ) {
          await rmdir(reauthorizationMarkerDirectory)
          reauthorizationMarkerDirectory = undefined
          createdReauthorizationMarker = false
          await fsyncDirectory(input.dataDirectory)
        }
        if (recoveryDirectory !== undefined) {
          await rm(recoveryDirectory, { recursive: true })
          recoveryDirectory = undefined
        }
        await rmdir(markerDirectory)
        markerDirectory = undefined
        await fsyncDirectory(input.dataDirectory)
      } catch (rollbackCause) {
        return failure(
          makeStorageError(
            "restore",
            "rollback_failed",
            rollbackCause,
            undefined,
            recoveryID
          )
        )
      }
    }
    return failure(
      normalizeError("restore", cause, "restore_failed")
    )
  } finally {
    if (stagingDirectory !== undefined) {
      await rm(stagingDirectory, { recursive: true, force: true }).catch(
        () => undefined
      )
    }
  }
}

/**
 * Permanently retires one exact pre-restore recovery set.
 *
 * Recovery is retained until the restore and device-reauthorization gates are
 * both absent. The durable recovery plan is deleted last so an interrupted
 * finalization can be safely retried with the same recovery identifier.
 */
export const finalizeRestoreRecovery = async (
  input: FinalizeRestoreRecoveryInput
): Promise<StorageAdminResult<FinalizedRestoreRecovery>> => {
  try {
    if (!RecoveryIDPattern.test(input.recoveryID)) {
      return failure(
        makeStorageError("finalize_recovery", "argument_invalid")
      )
    }

    const registry = await parseRegistry(
      input.registryPath,
      "finalize_recovery"
    )
    await assertOwnerOnlyDirectory(
      input.dataDirectory,
      "finalize_recovery"
    )
    await assertPathAbsent(
      assertDirectChild(input.dataDirectory, StorageRestoreMarkerName)
    )
    await assertPathAbsent(
      assertDirectChild(
        input.dataDirectory,
        DeviceReauthorizationMarkerName
      )
    )

    const recoveryDirectory = assertDirectChild(
      input.dataDirectory,
      `.restore-recovery-${input.recoveryID}`
    )
    try {
      await assertOwnerOnlyDirectory(
        recoveryDirectory,
        "finalize_recovery"
      )
    } catch (cause) {
      if (
        cause instanceof StorageAdminError &&
        cause.reason === "permission_invalid"
      ) {
        return throwStorageError(
          "finalize_recovery",
          "recovery_invalid",
          cause,
          undefined,
          input.recoveryID
        )
      }
      throw cause
    }

    const recoveryPlanPath = assertDirectChild(
      recoveryDirectory,
      "recovery-plan.json"
    )
    await assertOwnerOnlyRegularFile(
      recoveryPlanPath,
      "finalize_recovery"
    )
    const plan = await parseRecoveryPlan(recoveryPlanPath)
    if (
      plan.recoveryID !== input.recoveryID ||
      !RecoveryIDPattern.test(plan.recoveryID) ||
      !DigestPattern.test(plan.restoredArtifactID) ||
      plan.priorFiles.length > registry.databases.length * 3
    ) {
      return throwStorageError(
        "finalize_recovery",
        "recovery_invalid",
        undefined,
        undefined,
        input.recoveryID
      )
    }

    const descriptorsByID = new Map(
      registry.databases.map((descriptor) => [
        descriptor.databaseID,
        descriptor
      ])
    )
    const plannedFileNames = new Set<string>()
    for (const priorFile of plan.priorFiles) {
      const descriptor = descriptorsByID.get(priorFile.databaseID)
      const allowedFileNames =
        descriptor === undefined
          ? []
          : [
              descriptor.fileName,
              `${descriptor.fileName}-wal`,
              `${descriptor.fileName}-shm`
            ]
      if (
        !allowedFileNames.includes(priorFile.fileName) ||
        plannedFileNames.has(priorFile.fileName)
      ) {
        return throwStorageError(
          "finalize_recovery",
          "recovery_invalid",
          undefined,
          priorFile.databaseID,
          input.recoveryID
        )
      }
      plannedFileNames.add(priorFile.fileName)
    }

    const recoveryEntries = await readdir(recoveryDirectory)
    for (const entry of recoveryEntries) {
      if (entry !== "recovery-plan.json" && !plannedFileNames.has(entry)) {
        return throwStorageError(
          "finalize_recovery",
          "recovery_invalid",
          undefined,
          undefined,
          input.recoveryID
        )
      }
    }

    for (const priorFile of plan.priorFiles) {
      const priorPath = assertDirectChild(
        recoveryDirectory,
        priorFile.fileName
      )
      try {
        await lstat(priorPath)
      } catch (cause) {
        const code =
          typeof cause === "object" && cause !== null && "code" in cause
            ? cause.code
            : undefined
        if (code === "ENOENT") {
          continue
        }
        throw cause
      }
      await assertOwnerOnlyRegularFile(
        priorPath,
        "finalize_recovery",
        priorFile.databaseID
      )
      await unlink(priorPath)
    }
    await fsyncDirectory(recoveryDirectory)
    await unlink(recoveryPlanPath)
    await fsyncDirectory(recoveryDirectory)
    await rmdir(recoveryDirectory)
    await fsyncDirectory(input.dataDirectory)
    return success({ recoveryID: input.recoveryID })
  } catch (cause) {
    return failure(
      normalizeError(
        "finalize_recovery",
        cause,
        "finalize_failed"
      )
    )
  }
}
