/** Durable marker that blocks service startup during an interrupted restore. */
export const StorageRestoreMarkerName = ".restore-in-progress"

/** Durable marker that blocks startup until restored devices are reauthorized. */
export const DeviceReauthorizationMarkerName =
  ".device-reauthorization-required"

/** Auth-admin proof that restored principals were revoked for this restore. */
export const DeviceRevocationCompleteMarkerName = "revocation-complete"
