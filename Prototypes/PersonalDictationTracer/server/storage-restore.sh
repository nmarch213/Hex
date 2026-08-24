#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backup_directory="$script_directory/backups"
repo_root="$(git -C "$script_directory" rev-parse --show-toplevel)"
server_path="${script_directory#"$repo_root"/}"

if [[ $# -ne 1 ]] || [[ ! "$1" =~ ^hex-storage-backup-[0-9a-f]{64}$ ]]; then
  printf 'Usage: storage-restore.sh hex-storage-backup-<64 lowercase hex>.\n' >&2
  exit 2
fi
artifact_name="$1"

# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
# shellcheck source=compose-command.sh disable=SC1091
source "$script_directory/compose-command.sh"
compose=()
hex_compose_initialize "$script_directory"
hex_operations_lock_acquire "$script_directory/runtime"
trap 'hex_operations_lock_release' EXIT

if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal -- "$server_path")" ]]; then
  printf 'Refusing a production restore from an uncommitted server tree.\n' >&2
  exit 1
fi

command -v docker >/dev/null
if [[ "$(uname -s)" == "Linux" && "$(id -u)" != "1000" ]]; then
  printf 'Ronin storage administration requires deploying UID 1000.\n' >&2
  exit 1
fi
[[ -d "$backup_directory" && -O "$backup_directory" ]] || {
  printf 'The owner-only backup directory is unavailable.\n' >&2
  exit 1
}
if permissions="$(stat -c '%a' "$backup_directory" 2>/dev/null)"; then
  :
else
  permissions="$(stat -f '%Lp' "$backup_directory")"
fi
[[ "$permissions" == "700" ]] || {
  printf 'The backup directory must have mode 0700.\n' >&2
  exit 1
}
[[ -d "$backup_directory/$artifact_name" ]] || {
  printf 'The requested backup artifact is unavailable.\n' >&2
  exit 1
}

export HEX_BUILD_REVISION
HEX_BUILD_REVISION="$(git -C "$repo_root" rev-parse --verify HEAD)"
"${compose[@]}" config --quiet

stop_services_and_prove() {
  local container_id
  local container_ids
  local container_state

  if ! "${compose[@]}" stop --timeout 90 hex-proxy parakeet >/dev/null 2>&1; then
    return 1
  fi
  if ! container_ids="$("${compose[@]}" ps --all --quiet hex-proxy parakeet)"; then
    return 1
  fi
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    if ! container_state="$(docker container inspect \
      --format '{{.State.Running}} {{.State.Paused}} {{.State.Restarting}}' \
      "$container_id")"; then
      return 1
    fi
    [[ "$container_state" == "false false false" ]] || return 1
  done <<<"$container_ids"
}

if ! stop_services_and_prove; then
  printf 'Could not prove the proxy and Parakeet processes stopped; restore was not attempted.\n' >&2
  exit 1
fi

storage_replaced=0
restore_complete=0
cleanup() {
  local exit_code=$?

  trap - EXIT
  if [[ "$restore_complete" != "1" ]]; then
    if stop_services_and_prove; then
      if [[ "$storage_replaced" == "1" ]]; then
        printf 'Storage was replaced, but restored credentials could not be revoked; both services remain stopped and startup is blocked.\n' >&2
      else
        printf 'Storage restore failed; both services remain stopped.\n' >&2
      fi
    else
      printf 'Storage restore failed and service stop could not be reproven; inspect Ronin immediately.\n' >&2
    fi
    exit_code=1
  fi
  if ! hex_operations_lock_release; then
    exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup EXIT

"${compose[@]}" run \
  --rm \
  --no-deps \
  --build \
  storage-restore \
  restore "$artifact_name"

storage_replaced=1
"${compose[@]}" run \
  --rm \
  --no-deps \
  --build \
  -T \
  device-admin \
  restore-reset

restore_complete=1
printf 'Storage restored, restored credentials revoked, and services remain stopped. Re-enroll the health probe and a dictation client before completing reauthorization.\n'
