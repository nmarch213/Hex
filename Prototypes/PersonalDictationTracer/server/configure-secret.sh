#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
secret_directory="$script_directory/secrets"
health_credential_path="$secret_directory/health-probe-token"
health_device_id_path="$health_credential_path.device-id"
enrollment_path="$secret_directory/.health-probe-token.enrollment"

# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
hex_operations_lock_acquire "$script_directory/runtime"

cleanup() {
  local exit_code=$?
  if [[ ! -s "$health_credential_path" ]]; then
    rm -f "$health_credential_path"
  fi
  rm -f "$enrollment_path" "$enrollment_path.device-id"
  if ! hex_operations_lock_release; then
    exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup EXIT

if [[ -e "$health_credential_path" || -e "$health_device_id_path" ]]; then
  printf 'Refusing to overwrite the existing health-probe principal.\n' >&2
  exit 1
fi

umask 077
mkdir -p "$secret_directory"
chmod 700 "$secret_directory"

# Compose parses every declared file secret even when only the offline
# device-admin profile is run. This empty placeholder is never started or
# mounted and is atomically replaced by the enrolled health-only credential.
: >"$health_credential_path"
chmod 600 "$health_credential_path"

"$script_directory/device-admin.sh" enroll \
  'Ronin health probe' \
  service \
  "$enrollment_path" \
  service:health

mv "$enrollment_path" "$health_credential_path"
mv "$enrollment_path.device-id" "$health_device_id_path"
hex_operations_lock_release
trap - EXIT

if [[ -e "$secret_directory/proxy-token" ]]; then
  printf 'The legacy proxy-token file is no longer consumed; do not reuse it for a device enrollment.\n' >&2
fi
printf 'Enrolled a distinct health-only principal without printing its credential.\n'
printf 'Enroll the iPhone separately with device-admin.sh before deployment.\n'
