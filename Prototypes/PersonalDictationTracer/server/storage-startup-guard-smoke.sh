#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/hex-storage-marker.XXXXXX")"
output_path="$temporary_directory/output"

cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

chmod 700 "$temporary_directory"
mkdir -m 700 \
  "$temporary_directory/data"
printf '%064d\n' 0 >"$temporary_directory/upstream-epoch"
chmod 600 "$temporary_directory/upstream-epoch"

assert_marker_blocks_startup() {
  local expected_error="$1"
  local marker_name="$2"

  mkdir -m 700 "$temporary_directory/data/$marker_name"
  if HEX_BUILD_REVISION=0000000000000000000000000000000000000000 \
    HEX_LISTEN_HOST=127.0.0.1 \
    HEX_LISTEN_PORT=18787 \
    HEX_IDEMPOTENCY_DB_PATH="$temporary_directory/data/idempotency.sqlite" \
    HEX_DEVICE_REGISTRY_DB_PATH="$temporary_directory/data/devices.sqlite" \
    HEX_UPSTREAM_EPOCH_FILE="$temporary_directory/upstream-epoch" \
    HEX_UPSTREAM_URL=http://127.0.0.1:18080/v1/audio/transcriptions \
    node "$script_directory/dist/main.js" >"$output_path" 2>&1; then
    printf 'Production entrypoint ignored storage startup marker %s.\n' \
      "$marker_name" >&2
    exit 1
  fi

  grep -Fq "$expected_error" "$output_path" || {
    printf 'Production entrypoint failed for an unexpected reason.\n' >&2
    exit 1
  }
  rmdir "$temporary_directory/data/$marker_name"
}

assert_marker_blocks_startup \
  TranscriptionIdempotencyUnavailableError \
  .restore-in-progress
assert_marker_blocks_startup \
  DeviceRegistryUnavailableError \
  .device-reauthorization-required

printf 'Production entrypoint failed closed on both storage startup markers.\n'
