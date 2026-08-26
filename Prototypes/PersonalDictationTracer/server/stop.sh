#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
# shellcheck source=compose-command.sh disable=SC1091
source "$script_directory/compose-command.sh"
compose=()
hex_compose_initialize "$script_directory"
hex_operations_lock_acquire "$script_directory/runtime"
trap 'hex_operations_lock_release' EXIT

"${compose[@]}" config --quiet
"${compose[@]}" down --timeout 90

if [[ -n "$("${compose[@]}" ps --all --quiet hex-proxy parakeet)" ]]; then
  printf 'Could not prove the proxy and Parakeet containers were removed.\n' >&2
  exit 1
fi

printf 'Ronin proxy and Parakeet services are stopped.\n'
