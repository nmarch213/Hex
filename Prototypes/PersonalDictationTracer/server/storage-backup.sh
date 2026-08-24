#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backup_directory="$script_directory/backups"
repo_root="$(git -C "$script_directory" rev-parse --show-toplevel)"
server_path="${script_directory#"$repo_root"/}"

# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
# shellcheck source=compose-command.sh disable=SC1091
source "$script_directory/compose-command.sh"
compose=()
hex_compose_initialize "$script_directory"
hex_operations_lock_acquire "$script_directory/runtime"
trap 'hex_operations_lock_release' EXIT

if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal -- "$server_path")" ]]; then
  printf 'Refusing a production backup from an uncommitted server tree.\n' >&2
  exit 1
fi

command -v docker >/dev/null
if [[ "$(uname -s)" == "Linux" && "$(id -u)" != "1000" ]]; then
  printf 'Ronin storage administration requires deploying UID 1000.\n' >&2
  exit 1
fi

umask 077
mkdir -p "$backup_directory"
chmod 700 "$backup_directory"
[[ -O "$backup_directory" ]] || {
  printf 'The backup directory must be owned by the deploying user.\n' >&2
  exit 1
}

export HEX_BUILD_REVISION
HEX_BUILD_REVISION="$(git -C "$repo_root" rev-parse --verify HEAD)"
"${compose[@]}" run --rm --no-deps --build storage-backup backup
