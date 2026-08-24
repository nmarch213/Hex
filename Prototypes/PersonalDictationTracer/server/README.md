# Ronin prototype service

This is a deliberately small Effect service around the upstream `parakeet.cpp` example server. It adds the pieces the personal iOS tracer needs: per-installation Device Principal authentication, WAV validation, request IDs, fail-fast single-inference admission, durable idempotency, stable JSON timing fields, and optional Effect-native OTLP telemetry.

The application service owns inference admission and retry semantics through an application-owned persistence port. A scoped `better-sqlite3` adapter owns the local database and crash-safe transactions; no ORM or database type enters the application service. The inbound HTTP adapter separately owns one fail-fast audio-body slot so concurrent uploads cannot accumulate in memory before inference admission. Inbound HTTP/authentication and outbound `parakeet.cpp` calls are adapters selected by the composition root in `src/main.ts`.

Audio is never persisted. Successful response bodies are persisted because exact replay after a process restart necessarily includes the transcript. The local database retains at most 256 completed responses and removes responses older than 24 hours. Its parent directory is mode `0700` and the database is mode `0600`, but the database is not encrypted; protect the Ronin host and Docker volume accordingly.

The pinned Node 24.19 runtime still marks built-in [`node:sqlite`](https://nodejs.org/download/release/v24.19.0/docs/api/sqlite.html) as a release candidate rather than stable. The adapter therefore pins `better-sqlite3` instead. Reconsider the built-in module after Node marks it stable; the application-owned port keeps that swap local to one adapter.

## Develop and verify

```bash
npm ci --ignore-scripts
npm run validate
```

`npm run validate` runs strict TypeScript checking, service tests through public Effect layers and a real temporary SQLite database, and the production build. From the prototype root, `make smoke-server` additionally exercises the real HTTP wire contract against the deterministic fake recognition adapter. The smoke fixture is generated with Node, restarts the server against the same database, and runs on macOS or Linux. Linux CI also starts the built image twice: once through the fake adapter and once through the real production composition root against a bounded local upstream stub. The latter verifies production configuration, artifact metadata, authenticated health, the WAV contract, and redacted logs without downloading the model.

The upstream process is not exposed from Docker. The proxy binds inside its container and is published only on Ronin loopback so Tailscale Serve is the sole network ingress. Native launches default to `127.0.0.1` as well.

Parakeet deliberately has no Docker automatic-restart policy. A new native process must have a new verified process epoch, and `deploy.sh` is the authority that proves both prior containers stopped before rotating that epoch. If Parakeet exits or Ronin reboots, the proxy fails readiness until the Owner reruns the deploy target; never restart only the Parakeet container.

Plaintext upstream recognition is accepted only on `localhost`, `127.0.0.1`, `[::1]`, or the Compose service hostname `parakeet`. Remote upstreams must use HTTPS. Upstream URLs containing credentials are rejected at startup.

## Observe latency over time

Set `HEX_OTLP_BASE_URL` to the origin of an OTLP/HTTP collector to export protobuf logs, metrics, and traces. Empty or absent disables export. The production Compose network has no general internet egress, so the normal deployment is an `otel-collector` service attached to `hex-internal` and configured through a Ronin-local `server/compose.override.yaml`:

```bash
export HEX_OTLP_BASE_URL=http://otel-collector:4318
```

The override is intentionally local and ignored by Git because its exporter destination can be owner-specific. Pin the collector image by digest, name the service exactly `otel-collector`, attach it to `hex-internal`, and give only that collector whatever separate egress network its exporter needs. Every deploy, stop, rotation, device-administration, backup, and restore command uses the same override when it exists. Those commands reject a symlink, a non-regular file, a file owned by another user, or group/world write permission; use mode `600`. Deployment validates the merged model and pulls the collector image before stopping the healthy service. Without the override, leave `HEX_OTLP_BASE_URL` empty so export is explicitly disabled rather than pointed at a nonexistent service.

The collector and its persistent backend remain separate operational components; do not place backend credentials in the proxy environment. Use a private collector to add authenticated export and retention. Collector failure never delays or fails dictation: the Effect exporter batches off the request path, applies a circuit breaker after export failures, and resumes later.

The principal latency series are `hex_http_server_duration_ms` and `hex_dictation_stage_duration_ms`. Group the latter by its bounded `stage` label to compare authentication, body read, WAV parse, digest, idempotency, inference admission, recognition preparation, upstream recognition, response decode, completion, cleanup, and lease release. Request counts are bounded by route, method, outcome, status class, and replay state. Audio byte and duration histograms measure workload shape without recording audio or transcript content.

Spans use the same bounded stage vocabulary. Automatic Effect Platform HTTP tracing is intentionally disabled because its default attributes include full URLs, headers, user agents, and client addresses. Exported telemetry never includes credentials, authorization headers, request/device IDs, transcript text, audio, audio digests, raw URLs, query strings, file paths, client addresses, user agents, or error bodies. The OTLP contract is covered by a local receiver test for `/v1/logs`, `/v1/metrics`, and `/v1/traces`.

Record the first physical-phone stop-to-insert p50/p95/p99 baseline before declaring a performance regression threshold. The iOS client already measures capture stop, upload, server timing, mailbox delivery, and insertion; the server stage histograms identify which portion can actually be made faster. Do not substitute a generous CI wall-clock assertion for that real-device baseline.

## Start

From the prototype root, enroll the container health probe, enroll the iPhone separately, and deploy:

```bash
make server-configure
make server-device-enroll \
  DEVICE_NAME='Personal iPhone' \
  DEVICE_PLATFORM=ios \
  CREDENTIAL_OUTPUT=/owner-controlled/path/iphone-device-credential
make server
```

Ronin needs Docker with Compose, Node.js 20 or newer, OpenSSL, `curl`, Git, and a SHA-256 verifier on the host. The current Compose secret mapping also requires the deploying Linux account to have UID 1000. Deployment verifies the pinned model, repository, configuration, replacement proxy build, and pinned Parakeet pull before it interrupts the running services.

`server-configure` creates a distinct, health-only Device Principal and writes its one-time credential to `server/secrets/health-probe-token` with mode `0600`. It cannot call `/v1/transcribe` and must never be copied to a client. `server-device-enroll` creates a different principal for the iPhone with `dictation:write` and `service:health`; stdout is redirected into the requested owner-only file, and the safe public device ID is written beside it as `.device-id`. Store that 64-character lowercase hexadecimal credential in the iPhone Keychain through Hex, then remove any unnecessary transfer copy. Neither command reveals an existing credential.

Ronin stores only a SHA-256 digest of each independently generated 256-bit credential in the owner-only `devices.sqlite` registry. The registry contains exactly one Owner, retains at most 64 installation records, and compares a presented credential against the complete bounded active set with constant-time digest comparisons. Rotation invalidates the old credential in the same transaction; revocation, including a lost-device revocation, takes effect on the next request without a process restart or credential cache.

The Compose project name remains explicitly `server`, and operational commands pass that name at the highest-precedence CLI boundary, so upgrades address and stop the same stack created by the original unnamed Compose file. `make server` requires a committed server tree, verifies the pinned model and health-only secret, builds and pulls the complete replacement while the prior service remains available, then stops both the proxy and Parakeet and proves they are no longer running. It rotates a non-secret native-process epoch, stamps the Hex commit into the already-built proxy image, starts Compose without builds or pulls, waits for readiness, and checks authenticated loopback health. This deliberate restart is the recovery boundary for an inference whose completion was unknown. A failed start or final health check stops both services and proves that fail-closed state when possible; it never leaves a known-unhealthy deployment serving traffic. Use `make server-status`, `make server-logs`, and `make server-stop` for explicit operations.

The Compose file pins the tested multi-architecture `parakeet.cpp-server` image digest and mounts one local F16 GGUF instead of resolving a mutable alias. `prepare-model.sh` downloads `tdt-0.6b-v2-f16.gguf` from model-repository revision `bf0af9f425fa01809cadec671b3cb672709d13e9` and requires SHA-256 `f8df7f5dc7b9ceb5cd0637a81194aab5d93022ace555ce81c8969c7a694b8f3d`. Parakeet's own startup command verifies that checksum before every verified deploy. The native upstream and non-root proxy run read-only with all Linux capabilities dropped on an internal-only network; only the proxy loopback port is published. Only the health-probe credential is mounted as a Compose secret; client credentials are never placed in the proxy environment, container configuration, or health check. Compose mounts the Ronin-local `hex-proxy-data` volume at `/var/lib/hex-personal-dictation`; recreating the proxy container therefore preserves device digests and idempotent responses. Check the detached service from Ronin with:

```bash
make server-health
```

Use `docker compose config --quiet` or the bounded JSON inspection in CI when validating this stack. Never run `docker compose config --environment` in a credential-bearing shell because that command prints unrelated ambient environment values.

Expose `http://127.0.0.1:8787` with Tailscale Serve on HTTPS port 8443 at Ronin's MagicDNS name. Never enable Funnel. Port 443 already belongs to another Ronin service. Restrict Ronin TCP 8443 to the personal iPhone in the tailnet policy before considering the service ready.

## Back up and restore storage

Create a backup while the service is running:

```bash
make server-backup
```

The command prints only a safe `hex-storage-backup-<sha256>` name and writes the artifact under the ignored, owner-only `server/backups/` directory. It uses SQLite's [Online Backup API](https://www.sqlite.org/backup.html), not a copy of the main file or guesses about WAL sidecars. Every destination is normalized to a standalone SQLite file, checked with `integrity_check` and `foreign_key_check`, bounded by its registry limit, and fsynced before the content-addressed directory is published.

`storage-databases.json` is the allowlist and multi-database contract. A backup includes exactly the idempotency database and device registry declared there; adding another durable service database requires one registry descriptor with its filename, schema version, size ceiling, exact SQLite object allowlist, and code-known schema-SQL fingerprint. The fingerprint prevents a database with the expected object names and `user_version` but altered table or index definitions from entering an artifact. The manifest binds that complete registry, the service identity, build revision, per-database schema fingerprint, size, and SHA-256 into the artifact ID. Directories are mode `0700`, files are owner-only, symlinks and unexpected files are rejected, and neither the CLI nor Compose storage tools receive a network, bearer secret, model, or audio directory. The databases can contain retained transcript responses and device credential digests, so treat the artifact as sensitive and copy it only to an owner-controlled encrypted backup destination. Raw capture audio is never persisted and cannot enter the explicit registry-backed artifact.

The registry match is deliberately exact. If a later schema revision rejects an older artifact, use the committed Hex revision recorded in that artifact's manifest to perform the restore, complete device reauthorization, and then deploy the newer revision so its normal database migrations run. Do not weaken or hand-edit the manifest to force a cross-schema restore.

Exercise the same online backup, multi-database restore, integrity checks, and retained-response replay locally or in CI with:

```bash
make server-storage-drill
```

To restore, select the exact printed backup name:

```bash
make server-restore BACKUP=hex-storage-backup-<64-lowercase-hex>
```

Restore is deliberately offline. The wrapper first stops both the proxy and Parakeet and inspects every existing container to prove it is neither running, paused, nor restarting. The restore tool rejects a mismatched service/registry/artifact identity, digest, schema, integrity check, permission, or unexpected file before changing live storage. It restores all registered databases through the Online Backup API into a staged owner-only directory, moves the prior database and any SQLite sidecars into a named recovery directory, atomically installs each staged main database, and validates the complete live set. A durable `.restore-in-progress` marker prevents the proxy's idempotency adapter from opening storage if the process is interrupted; failed replacement rolls the original files back, and a failed rollback leaves that marker plus the safe recovery identifier for manual intervention.

A successful restore retains the previous database set under `.restore-recovery-<id>` in the Docker data volume and leaves both services stopped. Restoring `devices.sqlite` could otherwise resurrect a revoked or lost-device credential, so restore durably creates `.device-reauthorization-required`, invalidates any proof from an earlier restore, and immediately runs an offline `restore-reset` transaction that revokes every restored principal. Normal proxy startup derives this gate from the device-registry path and refuses to open while the marker exists. The proof is durable, owner-only, and still leaves every old credential unusable.

Create a fresh health principal and a fresh client principal, verify that the actual host health secret authenticates as the sole health-only service principal, and remove the marker only after both exist:

```bash
make server-restore-reauthorize \
  DEVICE_NAME='Personal iPhone' \
  DEVICE_PLATFORM=ios \
  CREDENTIAL_OUTPUT=/owner-controlled/path/restored-iphone-credential
```

Update the iPhone Keychain with that new client credential before running `make server`. If the reauthorization command is interrupted, the marker remains and `make server` cannot serve rollback credentials. Rerunning the command starts with another revoke-all reset so partially enrolled principals cannot accumulate; if a prior attempt already created the requested output file, choose a new output path and treat the earlier credential as revoked. `make server-restore-auth-reset` deliberately revokes the entire active set and recreates the proof for recovery; `make server-restore-auth-complete` is a low-level completion retry and still verifies the mounted host health credential plus a distinct non-service dictation client. A second restore removes only the stale revocation proof while retaining the blocking parent marker. CI proves both fail-closed startup and retained-response replay.

After the restored service is healthy, the new iPhone credential works, and the old credentials have been proven rejected, permanently retire the exact retained pre-restore database set using the recovery ID printed by restore:

```bash
make server-restore-finalize RECOVERY_ID=<timestamp-UUID>
```

This deletion is irreversible. The locked command refuses to run while either restore gate exists, verifies the recovery plan and exact allowlisted files, and deletes the plan last so interruption is safely retryable.

### Recover an operations lock after a host crash

An ungraceful mutating command intentionally leaves `server/runtime/.operations-lock` behind. Do not remove it merely because the original shell is gone. First prove there is no running deploy, rotate, backup, restore, reauthorization, device-admin, stop, or recovery-finalization process; then inspect `docker compose --project-name server -f server/compose.yaml ps --all` and every listed container state. If any relevant process is running, paused, or restarting, leave the lock in place. Once all host mutators are absent and the service state is understood, remove only the owner-controlled holder and empty lock directory:

```bash
rm server/runtime/.operations-lock/holder
rmdir server/runtime/.operations-lock
```

If either exact command fails, stop and inspect rather than using recursive deletion. The next mutating command will create a new nonce-bound lock.

## Administer and rotate Device Principals

List public metadata, revoke a lost installation, or rotate one client independently:

```bash
make server-device-list
make server-device-revoke DEVICE_ID=<public-device-uuid>
make server-device-rotate \
  DEVICE_ID=<public-device-uuid> \
  CREDENTIAL_OUTPUT=/owner-controlled/path/replacement-credential
```

`list` never returns a credential or digest. Rotation returns only the new credential into a previously nonexistent owner-only output file; the prior credential fails immediately. Revocation is idempotent and does not affect other installations.

Treat a credential as compromised if it appears in a terminal transcript, build log, Docker inspection output, or issue. For the dedicated Docker health principal, run:

```bash
make server-rotate
```

The health rotation helper first stops both services and inspects every service container to prove it is neither running, paused, nor restarting. Only then does it atomically replace the owner-only health secret, redeploy, check the new credential, and prove the previous credential receives `401`. The previous value remains only in process memory for that proof and is never copied to a durable temporary file or printed. The helper never restores it: a failed deployment or proof keeps the replacement installed and stops both services, so a credential being rotated as compromised cannot become live again. Never paste any credential into an issue, commit, command transcript, service log, or command argument.

## API

`GET /health` requires `service:health`. The Docker health credential has only that capability and receives `401` from `/v1/transcribe`; an iPhone principal may carry both capabilities so the containing app can check readiness before arming.

`POST /v1/transcribe` requires:

- `Authorization: Bearer <64-character Device Credential>` with `dictation:write`
- `Content-Type: audio/wav`
- an exact decimal `Content-Length` (chunked request bodies are rejected)
- `X-Hex-Request-ID: <UUID>`
- a complete mono 16 kHz Float32 WAV body no longer than five minutes

The same authenticated Device Principal, request ID, and audio body returns the exact saved response without running inference twice, including after the proxy process or container restarts. Request IDs are namespaced by the authenticated principal, so two installations may independently generate the same UUID without colliding. A replay returns `X-Hex-Idempotent-Replay: true`. Reusing a retained ID for different audio on the same principal returns `409`.

The service checks recognition readiness before it creates a durable request claim or engine lease; a cold upstream therefore returns `503` without consuming either fence. After that gate, it commits the in-progress request claim and sole global engine lease in short `BEGIN IMMEDIATE` transactions. Acquisition and worker publication are interruption-safe, and the scoped `Transcription` service supervises every accepted worker. The HTTP request is only a cancellable waiter: a client disconnect or handler deadline does not cancel accepted body processing or inference. The inbound-body slot remains held until that supervised worker releases its audio, so a disconnect cannot admit a second full recording into memory. A matching retry returns `503` with `Retry-After` while that worker runs, then replays the exact durable response after it completes.

Completion is a separate transaction, so no database transaction spans inference or a network call. A received upstream response proves native inference settled; success is durably completed before the engine lease is released, while status/body failures abandon the claim and release the lease. The recognition-result/settlement handoff is uninterruptible so service shutdown cannot misclassify a completed native call. An upstream transport timeout, proxy crash, or service shutdown while native completion is still unknown retains the engine fence without a wall-clock expiry because native Parakeet inference may outlive its proxy worker. Only a verified Parakeet stop plus a new process epoch can replace that fence. The request-ID claim itself becomes recoverable after two minutes, but any retry remains blocked by the engine fence until native completion is known or the process epoch changes. The engine fence survives a proxy-only restart, and token fencing prevents an old attempt from releasing or completing a replacement. Until a request claim is stale, a matching retry returns `503` with `Retry-After`; a different digest still returns `409`.

SQLite runs in WAL mode with FULL synchronous commits and secure deletion enabled. Completed responses become eligible for deletion after 23 hours 45 minutes; startup and 15-minute maintenance sweeps therefore enforce a 24-hour ceiling while the service is running, and startup immediately reconciles a service that was stopped. Maintenance also truncates the WAL after cleanup. A storage failure makes authenticated readiness acquire the same immediate-write domain and probe both durable tables; it returns `503` until that complete probe succeeds, including while an unexpected external writer holds the database. SQLite write contention is bounded to one second so readiness and requests fail closed without stalling the HTTP process. A maintenance failure remains not-ready until a later maintenance sweep succeeds. A current-process inference fence is also not-ready, including after a completion-unknown proxy restart. The newest-256 count bound is enforced on every request, and abandoned in-progress rows are removed after one day. A transcript is capped at 100,000 characters before persistence, so count retention also bounds storage. Once a completed row ages out, its request ID is no longer reserved.

The body limit is the canonical five-minute Float32 payload plus 64 KiB of WAV container overhead. A body read has a 30-second deadline, and the HTTP waiter has an 85-second whole-handler deadline so its `504` arrives before the iOS client's 90-second ceiling. That `504` does not terminate an already accepted worker: the worker continues under the service scope, durably records a late success, and makes it available to an idempotent retry. The upstream adapter independently allows 80 seconds to receive response headers and four seconds to validate a known-settled response body. Node also bounds header receipt, complete request receipt, and idle keep-alive connections.

Only one authenticated audio body and one cache-miss inference are admitted at a time. An overlapping request fails immediately with `503` and `Retry-After: 1`; the service does not retain an unbounded queue of uploaded audio.

Successful responses expose monotonic `queueMS`, `recognitionMS`, and `serviceMS` values. `queueMS` is always zero under the fail-fast admission policy. `serviceMS` ends when recognition has produced the response, before the durable completion commit; the legacy `totalMS` key is its compatibility alias, not transport-level total latency. Use the `idempotency_complete` span to isolate the FULL-synchronous SQLite commit and `hex_http_server_duration_ms` for the actual end-to-end service duration. The older `upstreamMS` key remains for client compatibility.

Production emits one bounded JSON completion event per HTTP request. It includes request routing, status, duration, runtime, model, and safe request metadata, but never credentials, request/device IDs, audio, transcripts, digests, raw paths, query strings, or error bodies. A request interrupted before a response exists is recorded with diagnostic status `499` and outcome `interrupted`. Compose bounds each container's local JSON logs and checks proxy health with the dedicated health-only Device Principal.

## Fake recognition adapter

The fake runtime is available only through its explicit development entrypoint; the production entrypoint cannot select it. Point both administration and the fake server at one disposable SQLite path, redirect the one-time enrollment credential to an owner-only file, then run it from the prototype root:

```bash
export HEX_DEVICE_REGISTRY_DB_PATH=/absolute/disposable/path/devices.sqlite
npm --prefix server run build
HEX_DEVICE_REGISTRY_DB_PATH="$HEX_DEVICE_REGISTRY_DB_PATH" \
  node server/dist/device-admin.js \
    enroll 'Local fake client' macos dictation:write,service:health \
    > /owner-controlled/path/fake-device-credential
make server-fake
```

It exercises authentication, WAV validation, response decoding, and per-device idempotency without Docker or a model. The transcript is deterministic. `make smoke-server` is the self-contained automated version and removes its disposable credentials and databases on exit.
