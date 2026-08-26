#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/hex-operations-lock.XXXXXX")"

cleanup() {
  hex_operations_lock_release
  if [[ -d "$test_directory" ]]; then
    rm -f "$test_directory/contender.out" "$test_directory/contender.err"
    rmdir "$test_directory/runtime" 2>/dev/null || true
    rmdir "$test_directory" 2>/dev/null || true
  fi
}

hex_operations_lock_acquire "$test_directory/runtime"
trap cleanup EXIT

# A nested helper must reuse the inherited holder instead of deadlocking.
bash -c '
  set -euo pipefail
  source "$1"
  hex_operations_lock_acquire "$2"
  hex_operations_lock_release
' bash "$script_directory/operations-lock.sh" "$test_directory/runtime"

# An independent mutator must fail before entering its critical section.
# The child shell expands its positional parameters.
# shellcheck disable=SC2016
if env \
  -u HEX_OPERATIONS_LOCK_DIRECTORY \
  -u HEX_OPERATIONS_LOCK_NONCE \
  bash -c '
    set -euo pipefail
    source "$1"
    hex_operations_lock_acquire "$2"
  ' bash "$script_directory/operations-lock.sh" "$test_directory/runtime" \
    >"$test_directory/contender.out" 2>"$test_directory/contender.err"; then
  printf 'An independent operation acquired an already-held owner lock.\n' >&2
  exit 1
fi
grep -Fq 'Another Ronin storage or deployment operation holds the owner lock.' \
  "$test_directory/contender.err"

printf 'Nested reuse and independent operation contention passed.\n'
