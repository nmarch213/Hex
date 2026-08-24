#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
secret_path="$script_directory/secrets/health-probe-token"
runtime_directory="$script_directory/runtime"
epoch_path="$runtime_directory/upstream-epoch"
wait_seconds="${HEX_DEPLOY_WAIT_SECONDS:-600}"

# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
# shellcheck source=compose-command.sh disable=SC1091
source "$script_directory/compose-command.sh"
compose=()
hex_compose_initialize "$script_directory"
hex_operations_lock_acquire "$runtime_directory"
trap 'hex_operations_lock_release' EXIT

if [[ ! "$wait_seconds" =~ ^[1-9][0-9]{0,3}$ ]] || (( wait_seconds > 3600 )); then
  printf 'HEX_DEPLOY_WAIT_SECONDS must be an integer from 1 through 3600.\n' >&2
  exit 1
fi

repo_root="$(git -C "$script_directory" rev-parse --show-toplevel)"
server_path="${script_directory#"$repo_root"/}"

"$script_directory/prepare-model.sh"
"$script_directory/preflight.sh"

if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal -- "$server_path")" ]]; then
  printf 'Refusing a production deploy from an uncommitted server tree.\n' >&2
  exit 1
fi

export HEX_BUILD_REVISION
HEX_BUILD_REVISION="$(git -C "$repo_root" rev-parse --verify HEAD)"

"${compose[@]}" config --quiet

# Complete every network- and build-dependent replacement step while the
# currently healthy service is still running. The post-stop start below is
# deliberately offline and cannot discover that an image is unavailable.
if ! "${compose[@]}" pull --quiet parakeet; then
  printf 'Could not pull the pinned Parakeet image; the running service was not interrupted.\n' >&2
  exit 1
fi
if [[ "$HEX_COMPOSE_OVERRIDE_ACTIVE" == "1" ]] &&
  ! "${compose[@]}" pull --quiet otel-collector; then
  printf 'Could not pull the pinned OTEL collector; the running service was not interrupted.\n' >&2
  exit 1
fi
if ! "${compose[@]}" build hex-proxy; then
  printf 'Could not build the replacement Hex proxy; the running service was not interrupted.\n' >&2
  exit 1
fi

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

fail_closed() {
  deployment_failure_reason="$1"
  exit 1
}

# Stopping both containers is the proof boundary for rotating the native
# process epoch. A proxy-only restart must never clear an uncertain inference.
if ! stop_services_and_prove; then
  printf 'Could not prove the prior proxy and Parakeet processes stopped.\n' >&2
  exit 1
fi

deployment_complete=0
deployment_failure_reason='Ronin deployment did not complete.'
epoch_temporary_path=""
cleanup() {
  local exit_code=$?

  trap - EXIT
  if [[ -n "$epoch_temporary_path" ]]; then
    rm -f "$epoch_temporary_path"
  fi
  if [[ "$deployment_complete" != "1" ]]; then
    if stop_services_and_prove; then
      printf '%s Both services are stopped; fix the deployment and rerun it.\n' \
        "$deployment_failure_reason" >&2
    else
      printf '%s Service stop could not be proven; inspect Ronin immediately.\n' \
        "$deployment_failure_reason" >&2
    fi
    exit_code=1
  fi
  if ! hex_operations_lock_release; then
    exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup EXIT

umask 077
mkdir -p "$runtime_directory"
chmod 700 "$runtime_directory"
epoch_temporary_path="$(mktemp "$runtime_directory/.upstream-epoch.next.XXXXXX")"
openssl rand -hex 32 >"$epoch_temporary_path"
chmod 644 "$epoch_temporary_path"
mv "$epoch_temporary_path" "$epoch_path"
epoch_temporary_path=""

if ! "${compose[@]}" up \
  --detach \
  --no-build \
  --pull never \
  --force-recreate \
  --wait \
  --wait-timeout "$wait_seconds"; then
  fail_closed 'Ronin deployment failed.'
fi

if ! node "$script_directory/authenticated-health-check.mjs" \
  "$secret_path" \
  200; then
  fail_closed 'Ronin authenticated health verification failed.'
fi

deployment_complete=1
printf 'Ronin service is detached and healthy on 127.0.0.1:8787.\n'
