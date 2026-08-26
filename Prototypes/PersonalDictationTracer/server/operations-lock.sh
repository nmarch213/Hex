#!/usr/bin/env bash

# This file is sourced by Ronin operational commands. It deliberately leaves a
# directory behind after an ungraceful process death so a human must prove no
# mutation is still running before recovering the lock.

hex_operations_lock_owner=0

hex_operations_lock_permissions() {
  local target_path="$1"
  if stat -c '%a' "$target_path" 2>/dev/null; then
    return
  fi
  stat -f '%Lp' "$target_path"
}

hex_operations_lock_acquire() {
  local runtime_directory="$1"
  local lock_directory="$runtime_directory/.operations-lock"
  local holder_path="$lock_directory/holder"
  local inherited_directory="${HEX_OPERATIONS_LOCK_DIRECTORY:-}"
  local inherited_nonce="${HEX_OPERATIONS_LOCK_NONCE:-}"
  local recorded_nonce

  umask 077
  mkdir -p "$runtime_directory"
  chmod 700 "$runtime_directory"
  if [[ ! -O "$runtime_directory" ]] \
    || [[ "$(hex_operations_lock_permissions "$runtime_directory")" != "700" ]]; then
    printf 'The operations-lock runtime directory must be owner-only.\n' >&2
    return 1
  fi

  if [[ -n "$inherited_directory" || -n "$inherited_nonce" ]]; then
    if [[ "$inherited_directory" != "$lock_directory" ]] \
      || [[ ! -f "$holder_path" ]] \
      || [[ ! -O "$holder_path" ]] \
      || [[ "$(hex_operations_lock_permissions "$holder_path")" != "600" ]]; then
      printf 'The inherited Ronin operations lock is invalid.\n' >&2
      return 1
    fi
    recorded_nonce="$(<"$holder_path")"
    if [[ ! "$recorded_nonce" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] \
      || [[ "$recorded_nonce" != "$inherited_nonce" ]]; then
      printf 'The inherited Ronin operations lock does not match its holder.\n' >&2
      return 1
    fi
    hex_operations_lock_owner=0
    trap 'hex_operations_lock_release' EXIT
    return
  fi

  if ! mkdir -m 700 "$lock_directory" 2>/dev/null; then
    printf 'Another Ronin storage or deployment operation holds the owner lock.\n' >&2
    return 1
  fi

  HEX_OPERATIONS_LOCK_DIRECTORY="$lock_directory"
  HEX_OPERATIONS_LOCK_NONCE="${BASHPID}-${RANDOM}-${RANDOM}"
  export HEX_OPERATIONS_LOCK_DIRECTORY HEX_OPERATIONS_LOCK_NONCE
  printf '%s\n' "$HEX_OPERATIONS_LOCK_NONCE" >"$holder_path"
  chmod 600 "$holder_path"
  hex_operations_lock_owner=1
  trap 'hex_operations_lock_release' EXIT
}

hex_operations_lock_release() {
  local lock_directory="${HEX_OPERATIONS_LOCK_DIRECTORY:-}"
  local lock_nonce="${HEX_OPERATIONS_LOCK_NONCE:-}"
  local holder_path
  local recorded_nonce

  if [[ "$hex_operations_lock_owner" != "1" ]]; then
    return
  fi
  if [[ -z "$lock_directory" || -z "$lock_nonce" ]]; then
    printf 'The Ronin operations lock lost its owner identity.\n' >&2
    return 1
  fi
  holder_path="$lock_directory/holder"
  if [[ ! -f "$holder_path" ]]; then
    printf 'The Ronin operations lock holder file disappeared.\n' >&2
    return 1
  fi
  recorded_nonce="$(<"$holder_path")"
  if [[ "$recorded_nonce" != "$lock_nonce" ]]; then
    printf 'The Ronin operations lock changed owners unexpectedly.\n' >&2
    return 1
  fi

  rm -f "$holder_path"
  rmdir "$lock_directory"
  hex_operations_lock_owner=0
  unset HEX_OPERATIONS_LOCK_DIRECTORY HEX_OPERATIONS_LOCK_NONCE
}
