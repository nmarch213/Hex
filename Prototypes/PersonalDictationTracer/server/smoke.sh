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

HEX_LISTEN_HOST=127.0.0.1 \
HEX_LISTEN_PORT=18787 \
HEX_PROXY_TOKEN=prototype \
HEX_FAKE_TRANSCRIPT='Hello from the Ronin tracer.' \
  node server/dist/main.js >"$smoke_dir/server.log" 2>&1 &
server_pid="$!"

for _ in {1..50}; do
  if curl --silent --fail \
    -H 'Authorization: Bearer prototype' \
    http://127.0.0.1:18787/health >"$smoke_dir/health.json"; then
    break
  fi
  sleep 0.1
done
jq -e '.status == "ready" and .model == "nvidia/parakeet-tdt-0.6b-v2"' \
  "$smoke_dir/health.json" >/dev/null

say -o "$smoke_dir/audio.aiff" 'hello from hex'
afconvert -f WAVE -d LEF32@16000 -c 1 "$smoke_dir/audio.aiff" "$smoke_dir/audio.wav"
say -o "$smoke_dir/other.aiff" 'different audio'
afconvert -f WAVE -d LEF32@16000 -c 1 "$smoke_dir/other.aiff" "$smoke_dir/other.wav"

request_id='8D758AE5-705C-4E1B-A62F-0DEFE5B830A5'
lowercase_request_id="$(printf '%s' "$request_id" | tr '[:upper:]' '[:lower:]')"
common_headers=(
  -H 'Authorization: Bearer prototype'
  -H 'Content-Type: audio/wav'
  -H "X-Hex-Request-ID: $request_id"
)

unauthorized_status="$(curl --silent --output "$smoke_dir/unauthorized.json" --write-out '%{http_code}' \
  -H 'Authorization: Bearer wrong' http://127.0.0.1:18787/health)"
[[ "$unauthorized_status" == "401" ]]

first_status="$(curl --silent --output "$smoke_dir/first.json" --write-out '%{http_code}' \
  "${common_headers[@]}" --data-binary "@$smoke_dir/audio.wav" \
  http://127.0.0.1:18787/v1/transcribe)"
[[ "$first_status" == "200" ]]
jq -e --arg id "$lowercase_request_id" \
  '.requestID == $id and .transcript == "Hello from the Ronin tracer."' \
  "$smoke_dir/first.json" >/dev/null

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

echo 'Prototype server smoke test passed'
