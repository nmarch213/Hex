#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
secret_path="$script_directory/secrets/health-probe-token"
model_path="$script_directory/models/tdt-0.6b-v2-f16.gguf"

[[ -f "$secret_path" ]] || {
  printf 'The health-probe credential is missing; run ./server/configure-secret.sh.\n' >&2
  exit 1
}
[[ -O "$secret_path" ]] || {
  printf 'The health-probe credential must be owned by the deploying user.\n' >&2
  exit 1
}

if permissions="$(stat -c '%a' "$secret_path" 2>/dev/null)"; then
  :
else
  permissions="$(stat -f '%Lp' "$secret_path")"
fi
[[ "$permissions" == "600" ]] || {
  printf 'The health-probe credential must have mode 0600.\n' >&2
  exit 1
}

byte_count="$(wc -c <"$secret_path" | tr -d ' ')"
final_byte="$(tail -c 1 "$secret_path" | od -An -t u1 | tr -d ' ')"
LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$secret_path" || {
  printf 'The health-probe credential must be exactly 32 random bytes encoded as lowercase hex.\n' >&2
  exit 1
}
[[ "$byte_count" == "65" && "$final_byte" == "10" ]] || {
  printf 'The health-probe credential file must contain only the token and one newline.\n' >&2
  exit 1
}

if [[ "$(uname -s)" == "Linux" && "$(id -u)" != "1000" ]]; then
  printf 'Ronin deployment currently requires deploying UID 1000 so the non-root health check can read the mode-0600 file secret.\n' >&2
  exit 1
fi

[[ -r "$model_path" ]] || {
  printf 'The pinned model is missing; run ./server/prepare-model.sh.\n' >&2
  exit 1
}

command -v docker >/dev/null
command -v node >/dev/null
command -v openssl >/dev/null
node -e 'if (Number(process.versions.node.split(".")[0]) < 20) process.exit(1)'
docker compose version >/dev/null
