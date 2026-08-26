#!/usr/bin/env bash

# Builds the one Compose command used by every production mutation. A local
# collector override is optional, but when present it must be an owner-controlled
# regular file so a writable or swapped override cannot alter deployment.
hex_compose_initialize() {
  local server_directory="$1"
  local compose_file="$server_directory/compose.yaml"
  local override_file="$server_directory/compose.override.yaml"
  local override_mode
  local override_owner

  compose=(docker compose --project-name server -f "$compose_file")
  # Consumed by deploy.sh after this helper is sourced.
  # shellcheck disable=SC2034
  HEX_COMPOSE_OVERRIDE_ACTIVE=0

  if [[ -L "$override_file" ]]; then
    printf 'Refusing a symlinked Compose override: %s\n' "$override_file" >&2
    return 1
  fi
  if [[ ! -e "$override_file" ]]; then
    return 0
  fi
  if [[ ! -f "$override_file" ]]; then
    printf 'Compose override must be a regular file: %s\n' "$override_file" >&2
    return 1
  fi

  override_owner="$(stat -c '%u' "$override_file")"
  override_mode="$(stat -c '%a' "$override_file")"
  if [[ "$override_owner" != "$EUID" ]] ||
    (( (8#$override_mode & 8#022) != 0 )); then
    printf 'Compose override must be owned by the deploy user and not group/world writable.\n' >&2
    return 1
  fi

  compose+=(-f "$override_file")
  # shellcheck disable=SC2034
  HEX_COMPOSE_OVERRIDE_ACTIVE=1
}
