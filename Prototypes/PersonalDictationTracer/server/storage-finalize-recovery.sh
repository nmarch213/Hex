#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_directory" rev-parse --show-toplevel)"
server_path="${script_directory#"$repo_root"/}"

if [[ $# -ne 1 ]] \
  || [[ ! "$1" =~ ^[0-9]{1,16}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  printf 'Usage: storage-finalize-recovery.sh <timestamp-UUID recovery ID>.\n' >&2
  exit 2
fi
recovery_id="$1"

# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
# shellcheck source=compose-command.sh disable=SC1091
source "$script_directory/compose-command.sh"
compose=()
hex_compose_initialize "$script_directory"
hex_operations_lock_acquire "$script_directory/runtime"
trap 'hex_operations_lock_release' EXIT

if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal -- "$server_path")" ]]; then
  printf 'Refusing recovery finalization from an uncommitted server tree.\n' >&2
  exit 1
fi

export HEX_BUILD_REVISION
HEX_BUILD_REVISION="$(git -C "$repo_root" rev-parse --verify HEAD)"
"${compose[@]}" config --quiet
"${compose[@]}" run \
  --rm \
  --no-deps \
  --build \
  storage-restore \
  finalize-recovery "$recovery_id"
