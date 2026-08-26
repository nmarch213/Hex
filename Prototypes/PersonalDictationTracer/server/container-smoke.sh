#!/usr/bin/env bash
set -euo pipefail

image_name="${1:-hex-personal-dictation:test}"
container_name="hex-container-smoke-$RANDOM-$RANDOM"
volume_name="$container_name-data"
smoke_directory="$(mktemp -d)"

cleanup() {
  docker rm --force "$container_name" >/dev/null 2>&1 || true
  docker volume rm --force "$volume_name" >/dev/null 2>&1 || true
  if [[ -n "$smoke_directory" && "$smoke_directory" != "/" ]]; then
    rm -r "$smoke_directory"
  fi
}
trap cleanup EXIT

token_path="$smoke_directory/device-token"
docker volume create "$volume_name" >/dev/null
docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --volume "$volume_name:/var/lib/hex-personal-dictation" \
  --env HEX_DEVICE_REGISTRY_DB_PATH=/var/lib/hex-personal-dictation/devices.sqlite \
  "$image_name" node dist/device-admin.js \
    enroll 'Container smoke device' ios dictation:write,service:health \
    >"$token_path" 2>"$smoke_directory/device-admin.log"
chmod 600 "$token_path"
docker run --detach --name "$container_name" \
  --publish 127.0.0.1:18788:8787 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --volume "$volume_name:/var/lib/hex-personal-dictation" \
  --env HEX_LISTEN_HOST=0.0.0.0 \
  --env HEX_IDEMPOTENCY_DB_PATH=/var/lib/hex-personal-dictation/idempotency.sqlite \
  --env HEX_DEVICE_REGISTRY_DB_PATH=/var/lib/hex-personal-dictation/devices.sqlite \
  --env HEX_FAKE_TRANSCRIPT='Container smoke transcript.' \
  "$image_name" node dist/main-fake.js >/dev/null

ready=0
for _ in {1..100}; do
  if node "$(dirname "${BASH_SOURCE[0]}")/authenticated-health-check.mjs" \
    "$token_path" 200 http://127.0.0.1:18788 >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! docker container inspect "$container_name" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
[[ "$ready" == "1" ]]

node --input-type=module - "$smoke_directory/audio.wav" <<'NODE'
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

node --input-type=module - \
  "$token_path" \
  "$smoke_directory/audio.wav" \
  "$smoke_directory/response.json" <<'NODE'
import { readFile, writeFile } from "node:fs/promises"

const [tokenPath, audioPath, responsePath] = process.argv.slice(2)
const token = (await readFile(tokenPath, "utf8")).trimEnd()
const audio = await readFile(audioPath)
const response = await fetch("http://127.0.0.1:18788/v1/transcribe", {
  method: "POST",
  headers: {
    authorization: `Bearer ${token}`,
    "content-type": "audio/wav",
    "content-length": String(audio.byteLength),
    "x-hex-request-id": "8d758ae5-705c-4e1b-a62f-0defe5b830a5"
  },
  body: audio
})
if (response.status !== 200) {
  process.exit(1)
}
await writeFile(responsePath, await response.text())
NODE
node --input-type=module - "$smoke_directory/response.json" <<'NODE'
import { readFileSync } from "node:fs"

const response = JSON.parse(readFileSync(process.argv[2], "utf8"))
if (response.transcript !== "Container smoke transcript.") {
  process.exit(1)
}
NODE

log_path="$smoke_directory/service.log"
docker logs "$container_name" >"$log_path" 2>&1
if grep -Fq -f "$token_path" "$log_path"; then
  exit 1
fi
node "$(dirname "${BASH_SOURCE[0]}")/verify-json-logs.mjs" \
  "$log_path" \
  8d758ae5-705c-4e1b-a62f-0defe5b830a5

printf 'Pinned Alpine container smoke test passed.\n'
