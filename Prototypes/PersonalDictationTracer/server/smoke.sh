#!/usr/bin/env bash
set -euo pipefail

smoke_dir="$(mktemp -d)"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ -n "$smoke_dir" && "$smoke_dir" != "/" ]]; then
    rm -r "$smoke_dir"
  fi
}
trap cleanup EXIT

npm --prefix server run build >/dev/null

token_path="$smoke_dir/device-token"
HEX_DEVICE_REGISTRY_DB_PATH="$smoke_dir/devices.sqlite" \
  node server/dist/device-admin.js \
    enroll 'Smoke iPhone' ios dictation:write,service:health \
    >"$token_path" 2>"$smoke_dir/device-admin.log"
test_token="$(<"$token_path")"
[[ "$test_token" =~ ^[0-9a-f]{64}$ ]]

start_server() {
  local fake_transcript="$1"
  local ready=0
  rm -f "$smoke_dir/health.json"
  HEX_LISTEN_HOST=127.0.0.1 \
  HEX_LISTEN_PORT=18787 \
  HEX_IDEMPOTENCY_DB_PATH="$smoke_dir/idempotency.sqlite" \
  HEX_DEVICE_REGISTRY_DB_PATH="$smoke_dir/devices.sqlite" \
  HEX_FAKE_TRANSCRIPT="$fake_transcript" \
    node server/dist/main-fake.js >>"$smoke_dir/server.log" 2>&1 &
  server_pid="$!"

  for _ in {1..50}; do
    if curl --silent --fail \
      -H "Authorization: Bearer $test_token" \
      http://127.0.0.1:18787/health >"$smoke_dir/health.json"; then
      ready=1
      break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  [[ "$ready" == "1" ]]
}

stop_server() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}

start_server 'Hello from the Ronin tracer.'

node --input-type=module - "$smoke_dir/health.json" <<'NODE'
import { readFileSync } from "node:fs"

const path = process.argv[2]
const health = JSON.parse(readFileSync(path, "utf8"))
if (
  health.status !== "ready" ||
  health.model !== "nvidia/parakeet-tdt-0.6b-v2"
) {
  process.exit(1)
}
NODE

[[ -f "$smoke_dir/idempotency.sqlite" ]]
[[ -f "$smoke_dir/devices.sqlite" ]]

write_wav_fixture() {
  local output_path="$1"
  local phase="$2"
  node --input-type=module - "$output_path" "$phase" <<'NODE'
import { writeFileSync } from "node:fs"

const outputPath = process.argv[2]
const phase = Number(process.argv[3])
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

for (let frame = 0; frame < frameCount; frame += 1) {
  const sample = Math.sin((frame / 16_000) * Math.PI * 2 * 440 + phase) * 0.1
  view.setFloat32(44 + frame * 4, sample, true)
}

writeFileSync(outputPath, bytes)
NODE
}

write_wav_fixture "$smoke_dir/audio.wav" 0
write_wav_fixture "$smoke_dir/other.wav" 0.75

request_id='8D758AE5-705C-4E1B-A62F-0DEFE5B830A5'
lowercase_request_id='8d758ae5-705c-4e1b-a62f-0defe5b830a5'
common_headers=(
  -H "Authorization: Bearer $test_token"
  -H 'Content-Type: audio/wav'
  -H "X-Hex-Request-ID: $request_id"
)

unauthorized_status="$(curl --silent --output "$smoke_dir/unauthorized.json" --write-out '%{http_code}' \
  -H 'Authorization: Bearer 00000000000000000000000000000000' http://127.0.0.1:18787/health)"
[[ "$unauthorized_status" == "401" ]]
printf '%064d\n' 0 | node server/authenticated-health-check.mjs \
  /dev/stdin 401 http://127.0.0.1:18787

first_status="$(curl --silent --output "$smoke_dir/first.json" --write-out '%{http_code}' \
  "${common_headers[@]}" --data-binary "@$smoke_dir/audio.wav" \
  http://127.0.0.1:18787/v1/transcribe)"
[[ "$first_status" == "200" ]]
node --input-type=module - "$smoke_dir/first.json" "$lowercase_request_id" <<'NODE'
import { readFileSync } from "node:fs"

const response = JSON.parse(readFileSync(process.argv[2], "utf8"))
if (
  response.requestID !== process.argv[3] ||
  response.transcript !== "Hello from the Ronin tracer." ||
  response.timings.queueMS !== 0 ||
  response.timings.totalMS !== response.timings.serviceMS
) {
  process.exit(1)
}
NODE

stop_server
start_server 'This replacement runtime output must not be used.'

replay_status="$(curl --silent --dump-header "$smoke_dir/replay.headers" \
  --output "$smoke_dir/replay.json" --write-out '%{http_code}' \
  "${common_headers[@]}" --data-binary "@$smoke_dir/audio.wav" \
  http://127.0.0.1:18787/v1/transcribe)"
[[ "$replay_status" == "200" ]]
grep -Eiq '^X-Hex-Idempotent-Replay: true' "$smoke_dir/replay.headers"
cmp "$smoke_dir/first.json" "$smoke_dir/replay.json"

conflict_status="$(curl --silent --output "$smoke_dir/conflict.json" --write-out '%{http_code}' \
  "${common_headers[@]}" --data-binary "@$smoke_dir/other.wav" \
  http://127.0.0.1:18787/v1/transcribe)"
[[ "$conflict_status" == "409" ]]

grep -Fq 'http_request_completed' "$smoke_dir/server.log"
for forbidden_log_value in \
  "$test_token" \
  'Hello from the Ronin tracer.' \
  'This replacement runtime output must not be used.'; do
  if grep -Fq "$forbidden_log_value" "$smoke_dir/server.log"; then
    exit 1
  fi
done

echo 'Prototype server smoke test passed'
