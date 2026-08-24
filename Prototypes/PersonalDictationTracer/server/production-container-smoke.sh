#!/usr/bin/env bash
set -euo pipefail

image_name="${1:-hex-personal-dictation:test}"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expected_service_revision="$(docker image inspect \
  --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
  "$image_name")"
[[ "$expected_service_revision" =~ ^[0-9a-f]{40}$ ]]
suffix="$RANDOM-$RANDOM"
proxy_container="hex-production-smoke-proxy-$suffix"
upstream_container="hex-production-smoke-upstream-$suffix"
volume_name="hex-production-smoke-data-$suffix"
network_name="hex-production-smoke-network-$suffix"
smoke_directory="$(mktemp -d)"

cleanup() {
  docker rm --force "$proxy_container" "$upstream_container" >/dev/null 2>&1 || true
  docker volume rm --force "$volume_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  if [[ -n "$smoke_directory" && "$smoke_directory" != "/" ]]; then
    rm -r "$smoke_directory"
  fi
}
trap cleanup EXIT

device_token_path="$smoke_directory/device-token"
health_token_path="$smoke_directory/health-probe-token"
epoch_path="$smoke_directory/upstream-epoch"
audio_path="$smoke_directory/audio.wav"
openssl rand -hex 32 >"$epoch_path"
chmod 644 "$epoch_path"

node --input-type=module - "$audio_path" <<'NODE'
import { writeFileSync } from "node:fs"

const outputPath = process.argv[2]
const frameCount = 1_600
const dataByteLength = frameCount * 4
const bytes = new Uint8Array(44 + dataByteLength)
const view = new DataView(bytes.buffer)
const encoder = new TextEncoder()
bytes.set(encoder.encode("RIFF"), 0)
view.setUint32(4, bytes.byteLength - 8, true)
bytes.set(encoder.encode("WAVE"), 8)
bytes.set(encoder.encode("fmt "), 12)
view.setUint32(16, 16, true)
view.setUint16(20, 3, true)
view.setUint16(22, 1, true)
view.setUint32(24, 16_000, true)
view.setUint32(28, 64_000, true)
view.setUint16(32, 4, true)
view.setUint16(34, 32, true)
bytes.set(encoder.encode("data"), 36)
view.setUint32(40, dataByteLength, true)
writeFileSync(outputPath, bytes)
NODE

docker network create --internal "$network_name" >/dev/null
docker volume create "$volume_name" >/dev/null
docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --volume "$volume_name:/var/lib/hex-personal-dictation" \
  --env HEX_DEVICE_REGISTRY_DB_PATH=/var/lib/hex-personal-dictation/devices.sqlite \
  "$image_name" node dist/device-admin.js \
    enroll 'Production smoke device' linux dictation:write,service:health \
    >"$device_token_path" 2>"$smoke_directory/device-admin.log"
docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --volume "$volume_name:/var/lib/hex-personal-dictation" \
  --env HEX_DEVICE_REGISTRY_DB_PATH=/var/lib/hex-personal-dictation/devices.sqlite \
  "$image_name" node dist/device-admin.js \
    enroll 'Production health probe' service service:health \
    >"$health_token_path" 2>"$smoke_directory/health-admin.log"
chmod 600 "$device_token_path" "$health_token_path"
docker run --detach --name "$upstream_container" \
  --network "$network_name" \
  --network-alias parakeet \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --user node \
  --mount "type=bind,source=$script_directory/container-upstream-stub.mjs,target=/stub.mjs,readonly" \
  node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 \
  node /stub.mjs >/dev/null

docker run --detach --name "$proxy_container" \
  --network "$network_name" \
  --network-alias hex-proxy \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --volume "$volume_name:/var/lib/hex-personal-dictation" \
  --mount "type=bind,source=$epoch_path,target=/run/hex/upstream-epoch,readonly" \
  --env HEX_LISTEN_HOST=0.0.0.0 \
  --env HEX_UPSTREAM_EPOCH_FILE=/run/hex/upstream-epoch \
  --env HEX_UPSTREAM_URL=http://parakeet:8080/v1/audio/transcriptions \
  --env HEX_IDEMPOTENCY_DB_PATH=/var/lib/hex-personal-dictation/idempotency.sqlite \
  --env HEX_DEVICE_REGISTRY_DB_PATH=/var/lib/hex-personal-dictation/devices.sqlite \
  "$image_name" >/dev/null

docker run --rm \
  --network "$network_name" \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --mount "type=bind,source=$script_directory/production-container-client.mjs,target=/client.mjs,readonly" \
  --mount "type=bind,source=$smoke_directory,target=/smoke,readonly" \
  node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 \
  node /client.mjs \
    http://hex-proxy:8787 \
    /smoke \
    /smoke/audio.wav \
    "$expected_service_revision"

log_path="$smoke_directory/service.log"
docker logs "$proxy_container" >"$log_path" 2>&1
for credential_path in "$device_token_path" "$health_token_path"; do
  if grep -Fq -f "$credential_path" "$log_path"; then
    exit 1
  fi
done
if grep -Fq "Production container transcript." "$log_path"; then
  exit 1
fi
node "$script_directory/verify-json-logs.mjs" \
  "$log_path" \
  8d758ae5-705c-4e1b-a62f-0defe5b830a6

printf 'Production entrypoint container smoke test passed.\n'
