#!/usr/bin/env bash
set -euo pipefail

model_revision="bf0af9f425fa01809cadec671b3cb672709d13e9"
model_filename="tdt-0.6b-v2-f16.gguf"
model_sha256="f8df7f5dc7b9ceb5cd0637a81194aab5d93022ace555ce81c8969c7a694b8f3d"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
model_directory="$script_directory/models"
model_path="$model_directory/$model_filename"
model_url="https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/$model_revision/$model_filename"

# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
hex_operations_lock_acquire "$script_directory/runtime"
temporary_path=""
cleanup() {
  local exit_code=$?
  if [[ -n "$temporary_path" ]]; then
    rm -f "$temporary_path"
  fi
  if ! hex_operations_lock_release; then
    exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup EXIT

command -v curl >/dev/null || {
  printf 'curl is required to prepare the pinned Parakeet model.\n' >&2
  exit 1
}
if ! command -v sha256sum >/dev/null 2>&1 \
  && ! command -v shasum >/dev/null 2>&1; then
  printf 'sha256sum or shasum is required to verify the Parakeet model.\n' >&2
  exit 1
fi

verify_model() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$model_sha256" "$model_path" | sha256sum --check --status
  else
    [[ "$(shasum -a 256 "$model_path" | awk '{print $1}')" == "$model_sha256" ]]
  fi
}

mkdir -p "$model_directory"
chmod 700 "$model_directory"

if [[ -d "$model_path" ]]; then
  printf 'The model path is a directory, not the pinned GGUF file; remove that directory manually and retry.\n' >&2
  exit 1
fi

if [[ -f "$model_path" ]] && verify_model; then
  chmod 444 "$model_path"
  printf 'Pinned Parakeet model is already verified.\n'
  exit 0
fi

temporary_path="$(mktemp "$model_directory/.parakeet-download.XXXXXX")"

curl --fail --location --show-error --output "$temporary_path" "$model_url"
chmod 600 "$temporary_path"
mv -f "$temporary_path" "$model_path"
temporary_path=""

if ! verify_model; then
  rm -f "$model_path"
  printf 'Downloaded Parakeet model failed SHA-256 verification.\n' >&2
  exit 1
fi

chmod 444 "$model_path"
printf 'Pinned Parakeet model downloaded and verified.\n'
