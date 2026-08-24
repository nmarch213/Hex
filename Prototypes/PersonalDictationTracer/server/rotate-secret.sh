#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
secret_directory="$script_directory/secrets"
health_credential_path="$secret_directory/health-probe-token"
health_device_id_path="$health_credential_path.device-id"
replacement_path="$secret_directory/.health-probe-token.rotation"

# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
# shellcheck source=compose-command.sh disable=SC1091
source "$script_directory/compose-command.sh"
compose=()
hex_compose_initialize "$script_directory"
hex_operations_lock_acquire "$script_directory/runtime"
trap 'hex_operations_lock_release' EXIT

"$script_directory/preflight.sh"
[[ -f "$health_device_id_path" ]] || {
  printf 'The public health-probe device ID is missing.\n' >&2
  exit 1
}
health_device_id="$(<"$health_device_id_path")"
[[ "$health_device_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
  printf 'The public health-probe device ID is invalid.\n' >&2
  exit 1
}

repo_root="$(git -C "$script_directory" rev-parse --show-toplevel)"
server_path="${script_directory#"$repo_root"/}"
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal -- "$server_path")" ]]; then
  printf 'Refusing to rotate a production credential from an uncommitted server tree.\n' >&2
  exit 1
fi

rm -f "$replacement_path" "$replacement_path.device-id"
prior_token="$(<"$health_credential_path")"
rotation_complete=0
services_stopped=0

stop_services_and_prove() {
  local container_id
  local container_ids
  local container_state

  if ! "${compose[@]}" stop --timeout 90 \
    hex-proxy parakeet >/dev/null 2>&1; then
    return 1
  fi
  if ! container_ids="$("${compose[@]}" ps \
    --all --quiet hex-proxy parakeet)"; then
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

cleanup() {
  local exit_code=$?
  trap - EXIT
  rm -f "$replacement_path" "$replacement_path.device-id"
  prior_token=""
  if [[ "$services_stopped" == "1" && "$rotation_complete" != "1" ]]; then
    if ! stop_services_and_prove; then
      printf 'Health credential rotation did not complete and service stop could not be proven; inspect Ronin immediately.\n' >&2
      exit_code=1
    fi
  fi
  if ! hex_operations_lock_release; then
    exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup EXIT

if ! stop_services_and_prove; then
  printf 'Could not prove the proxy and Parakeet stopped; health credential rotation was not attempted.\n' >&2
  exit 1
fi
services_stopped=1

"$script_directory/device-admin.sh" rotate \
  "$health_device_id" \
  "$replacement_path"
cmp -s "$health_device_id_path" "$replacement_path.device-id" || {
  printf 'The rotated credential was returned for a different device ID.\n' >&2
  exit 1
}
mv "$replacement_path" "$health_credential_path"
rm -f "$replacement_path.device-id"

if ! "$script_directory/deploy.sh"; then
  printf 'Health credential rotation deployment failed; the replacement remains installed.\n' >&2
  exit 1
fi

if ! node "$script_directory/authenticated-health-check.mjs" \
  "$health_credential_path" \
  200; then
  printf 'The replacement health credential did not pass authenticated health.\n' >&2
  exit 1
fi

if ! printf '%s\n' "$prior_token" | \
  node "$script_directory/authenticated-health-check.mjs" \
    /dev/stdin \
    401; then
  printf 'The prior health credential was not proven rejected.\n' >&2
  exit 1
fi

rotation_complete=1
printf 'Rotated the health-only credential and proved the prior value receives HTTP 401.\n'
