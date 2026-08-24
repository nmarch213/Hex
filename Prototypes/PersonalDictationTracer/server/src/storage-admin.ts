import { isAbsolute } from "node:path"

import {
  createStorageBackup,
  finalizeRestoreRecovery,
  restoreStorageBackup,
  type StorageAdminError
} from "./storage-administration.js"

const registryPath = process.env["HEX_STORAGE_REGISTRY_PATH"]
const dataDirectory = process.env["HEX_STORAGE_DATA_DIRECTORY"]
const backupDirectory = process.env["HEX_STORAGE_BACKUP_DIRECTORY"]
const sourceBuildRevision = process.env["HEX_BUILD_REVISION"]

const failConfiguration = () => {
  process.stderr.write("storage administration configuration is invalid\n")
  process.exitCode = 1
}

const reportFailure = (error: StorageAdminError) => {
  const fields = [
    `operation=${error.operation}`,
    `reason=${error.reason}`,
    ...(error.databaseID === undefined
      ? []
      : [`database_id=${error.databaseID}`]),
    ...(error.recoveryID === undefined
      ? []
      : [`recovery_id=${error.recoveryID}`])
  ]
  process.stderr.write(`storage administration failed ${fields.join(" ")}\n`)
  process.exitCode = 1
}

const configured =
  registryPath !== undefined &&
  dataDirectory !== undefined &&
  backupDirectory !== undefined &&
  sourceBuildRevision !== undefined &&
  isAbsolute(registryPath) &&
  isAbsolute(dataDirectory) &&
  isAbsolute(backupDirectory)

if (!configured) {
  failConfiguration()
} else {
  const [command, argument, ...unexpected] = process.argv.slice(2)
  if (command === "backup" && argument === undefined && unexpected.length === 0) {
    const result = await createStorageBackup({
      registryPath,
      dataDirectory,
      backupDirectory,
      sourceBuildRevision
    })
    if (result._tag === "Failure") {
      reportFailure(result.error)
    } else {
      process.stdout.write(`backup=${result.value.artifactName}\n`)
    }
  } else if (
    command === "restore" &&
    argument !== undefined &&
    unexpected.length === 0
  ) {
    const result = await restoreStorageBackup({
      registryPath,
      dataDirectory,
      backupDirectory,
      artifactName: argument,
      sourceBuildRevision
    })
    if (result._tag === "Failure") {
      reportFailure(result.error)
    } else {
      process.stdout.write(
        `restored=${result.value.artifactID} recovery=${result.value.recoveryID} reauthorization_required=${String(result.value.reauthorizationRequired)}\n`
      )
    }
  } else if (
    command === "finalize-recovery" &&
    argument !== undefined &&
    unexpected.length === 0
  ) {
    const result = await finalizeRestoreRecovery({
      registryPath,
      dataDirectory,
      recoveryID: argument
    })
    if (result._tag === "Failure") {
      reportFailure(result.error)
    } else {
      process.stdout.write(`finalized_recovery=${result.value.recoveryID}\n`)
    }
  } else {
    process.stderr.write(
      "usage: storage-admin <backup|restore BACKUP_NAME|finalize-recovery RECOVERY_ID>\n"
    )
    process.exitCode = 2
  }
}
