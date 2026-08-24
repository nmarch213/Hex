#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
secret_directory="$script_directory/secrets"
health_credential_path="$secret_directory/health-probe-token"
health_device_id_path="$health_credential_path.device-id"
health_enrollment_path="$secret_directory/.restored-health-enrollment"

usage() {
  printf '%s\n' \
    'Usage: reauthorize-after-restore.sh DISPLAY_NAME PLATFORM CLIENT_CREDENTIAL_OUTPUT' \
    'Run this only after storage-restore.sh has stopped services and reset restored principals.' >&2
}

if [[ "$#" -ne 3 ]]; then
  usage
  exit 2
fi

display_name="$1"
platform="$2"
client_credential_output="$3"

if [[ "$platform" == "service" ]]; then
  printf 'The restored client must be a non-service installation.\n' >&2
  exit 2
fi
if [[ ! -d "$secret_directory" || ! -O "$secret_directory" ]]; then
  printf 'The owner-only secret directory is unavailable.\n' >&2
  exit 1
fi
if [[ -e "$client_credential_output" || -e "$client_credential_output.device-id" ]]; then
  printf 'Choose a new client credential output path; the requested path already exists.\n' >&2
  exit 1
fi

# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
hex_operations_lock_acquire "$script_directory/runtime"
trap 'hex_operations_lock_release' EXIT

umask 077
"$script_directory/device-admin.sh" restore-reset
rm -f "$health_enrollment_path" "$health_enrollment_path.device-id"
cleanup() {
  local exit_code=$?
  rm -f "$health_enrollment_path" "$health_enrollment_path.device-id"
  if ! hex_operations_lock_release; then
    exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup EXIT

"$script_directory/device-admin.sh" enroll \
  'Ronin health probe' \
  service \
  "$health_enrollment_path" \
  service:health

# Install the public ID first. If power is lost between these renames, the
# still-stale credential cannot clear the restore marker. Installing the
# credential last makes the pair usable only once both writes completed.
mv -f "$health_enrollment_path.device-id" "$health_device_id_path"
mv -f "$health_enrollment_path" "$health_credential_path"
chmod 600 "$health_credential_path" "$health_device_id_path"

"$script_directory/device-admin.sh" enroll \
  "$display_name" \
  "$platform" \
  "$client_credential_output" \
  dictation:write,service:health

"$script_directory/device-admin.sh" restore-complete
hex_operations_lock_release
trap - EXIT

printf 'Post-restore principals are fresh and the health credential was verified.\n'
printf 'Store the new client credential on that installation before starting the server.\n'
