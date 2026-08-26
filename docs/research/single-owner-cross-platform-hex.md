# Single-owner, cross-platform Hex architecture

Research captured 2026-08-23. Claims about platform behavior are sourced from official specifications, vendor documentation, or the relevant first-party source repository. Product terms follow [`CONTEXT.md`](../../CONTEXT.md), and the proposal preserves the inherited boundaries recorded in [`current-system.md`](../architecture/current-system.md).

> **Status:** The accepted direction is distilled in [`personal-cross-platform-target.md`](../architecture/personal-cross-platform-target.md) and ADRs [0001](../adr/0001-model-one-owner-through-device-principals.md) and [0002](../adr/0002-ronin-owns-transcript-policy.md). This report remains the evidence and alternatives record; unresolved measurements here are not implied decisions.

## Decision summary

Hex should model exactly one **Owner**, but authenticate every installation as a separate **Device Principal**. Ronin should be the canonical owner of the versioned Transcript Profile, device enrollment and revocation, durable idempotency, and privacy-safe aggregate usage statistics. It should not grow accounts, login sessions, organizations, or multi-user authorization.

The near-term production shape is:

```text
macOS app ───────┐
iOS companion ──┼─ Tailscale grant + HTTPS Serve + device credential ─┐
Windows client ─┘                                                       │
                                                                        ▼
                                                            Ronin Effect service
                                               ┌────────────────┬─────────────────┐
                                               │ Parakeet v2    │ SQLite          │
                                               │ recognition   │ owner/profile/  │
                                               │ adapter       │ devices/stats   │
                                               └────────────────┴─────────────────┘
                                                                        │
                                                     Final Transcript + applied revision
                                                                        ▼
                                                         originating device delivers text
```

The iOS keyboard extension should remain a local control and insertion surface; it should not receive the Ronin credential or become a second HTTP client. The containing app already owns microphone capture and the request pipeline because Apple does not allow a custom keyboard to own the microphone ([Apple custom-keyboard limitations](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html), [existing iOS background research](ios-action-button-background-arm.md)).

| Horizon | Build now | Deliberately later |
| --- | --- | --- |
| Production hardening | Per-device enrollment/revocation; exact tailnet grant; durable SQLite state and idempotency; canonical Transcript Profile API; repeated iOS Dictations in one arm; backup/restore; redacted diagnostics | Remote enrollment UI, multiple owners, organizations, OAuth/OIDC |
| Cross-platform | Ronin-backed Windows capture/delivery client; shared wire contracts and conformance fixtures | Local Windows model adapter; TSF input method; automatic provider failover |
| Product capability | Aggregate counters and latency histograms; `normal` style with the current deterministic pipeline | Model-assisted `casual` and `professional` styles after a latency and semantic-preservation gate |

## 1. One Owner, independently revocable devices

### Domain model

`Owner` is a singleton aggregate created when Ronin initializes its database. It is not a person record used for login. Every enrolled client maps to that same Owner:

```text
Owner (one row)
  ├── Device Principal: iPhone
  ├── Device Principal: MacBook
  ├── Device Principal: Windows PC
  ├── Transcript Profile: owner-default
  └── Usage Aggregates
```

Recommended durable records:

```text
owners(owner_id, created_at)
devices(device_id, owner_id, display_name, platform, credential_digest,
        scopes, created_at, last_seen_at, revoked_at)
transcript_profiles(owner_id, schema_version, revision, document, updated_at,
                    updated_by_device_id)
transcript_profile_revisions(owner_id, revision, document, created_at,
                             created_by_device_id)
```

There should be no `users`, passwords, refresh tokens, email verification, or remote sign-up endpoint. A Ronin-local command such as `hexctl device enroll --name "iPhone" --platform ios` should mint a high-entropy credential once; the owner transfers it to the device by QR code or copy/paste while physically controlling both endpoints. A second Ronin-local command revokes or rotates one device without disturbing the others.

Phase 0 now implements this boundary in the Effect service. The iOS containing app and every future installation receive a different 256-bit lowercase-hex credential plus a public Device Principal ID. Ronin stores only the credential's SHA-256 digest in an owner-only, bounded SQLite `DeviceRegistry`; resolution compares the presented digest against the complete active set with constant-time comparisons. Ronin-local administration enrolls, lists, rotates, and revokes each principal independently. A separate Docker health principal has only `service:health`, while the iPhone principal has `dictation:write` and `service:health`; the health credential is rejected by transcription. Standard `Authorization: Bearer` transport remains in place over TLS rather than adding an application signing protocol. Bearer credentials are usable by whoever possesses them, and RFC 6750 requires protecting them in storage and transit ([implemented registry](../../Prototypes/PersonalDictationTracer/server/src/adapters/sqlite-device-registry.ts), [authentication service](../../Prototypes/PersonalDictationTracer/server/src/application/device-authentication.ts), [RFC 6750](https://www.rfc-editor.org/rfc/rfc6750.html)).

The implemented Phase-0 capabilities are `dictation:write` and `service:health`; future profile and statistics capabilities should be added only with those APIs. They are blast-radius controls for devices, not multi-user roles. The iOS containing app, macOS app, and Windows client can hold credentials; the iOS keyboard extension does not receive one.

On Apple platforms, store the secret in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Apple describes Keychain as encrypted storage for small secrets; the selected accessibility class keeps the credential bound to this device and unavailable while it is locked ([Keychain Services](https://developer.apple.com/documentation/security/keychain-services/), [`WhenUnlockedThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly)). This matches the interactive keyboard workflow and its fail-closed device-lock behavior. A future locked-screen workflow would require a separate security decision rather than silently weakening accessibility. On Windows, protect it for the current Windows logon with DPAPI; `CryptProtectData` normally makes data decryptable only by the same user on the same computer and adds an integrity check ([Microsoft `CryptProtectData`](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)). Credentials must not be synchronized as part of the Transcript Profile.

### Tailscale is the outer boundary, not the only credential

Every request should pass three independent gates:

1. A Tailscale **grant** permits only explicitly named Hex devices to reach Ronin's Hex port. Grants are deny-by-default, can select a particular device through a host alias/IP, and can attach application capabilities ([Tailscale grants syntax](https://tailscale.com/docs/reference/syntax/grants)).
2. Tailscale Serve terminates tailnet HTTPS and proxies only to a service bound on Ronin loopback. Serve strips caller-supplied Tailscale identity/capability headers before adding trusted values, and Tailscale specifically recommends a localhost-only backend when those headers affect authorization ([Tailscale Serve identity headers](https://tailscale.com/docs/features/tailscale-serve)). Funnel remains disabled.
3. Ronin authenticates the per-device application credential and rejects revoked devices.

`Tailscale-User-Login` is not a device identity: it represents the associated tailnet user, and Serve does not populate it for tagged callers. Tailscale's LocalAPI can identify the particular source node, while Serve can forward app capabilities for both users and tagged nodes ([Tailscale identity](https://tailscale.com/docs/concepts/tailscale-identity), [application capabilities](https://tailscale.com/docs/features/access-control/grants/grants-app-capabilities)). Therefore the first production release should use the exact-node network grant plus the application credential. An app-capability header can later add defense in depth, but should not be the only revocation mechanism until the deployed Tailscale version and policy are covered by integration tests.

Revocation is intentionally two-layered:

- Revoke the Hex Device Principal to stop application requests immediately while leaving other tailnet access alone.
- Remove/deauthorize the Tailscale node or its exact-node grant when the whole device is lost. Revoking a Tailscale provisioning auth key does not deauthorize nodes already enrolled, so it is not a substitute for removing the device itself ([Tailscale auth keys](https://tailscale.com/docs/features/access-control/auth-keys)).

### Effect service boundaries

Keep authentication and transport outside speech-recognition semantics, as the inherited architecture requires. A production composition root should wire narrow services resembling:

```text
DeviceAuthentication   bearer/header -> DevicePrincipal
DeviceRegistry         enroll/revoke/list (local administration first)
TranscriptProfiles     get/snapshot/update with revision checks
Dictation              recognition -> policy -> optional rewrite -> result
UsageStatistics        idempotent numeric outcome -> aggregates
SpeechRecognition      Parakeet adapter
TranscriptRewriter     absent for normal; local-model adapter later
```

SQLite is sufficient for one owner and a serialized inference service. Use transactions for credential/profile/idempotency/stat updates, enable and monitor WAL checkpointing, and take tested online snapshots; SQLite documents atomic transactions, WAL's same-host concurrency properties, and a snapshot-producing online backup API ([SQLite atomic commit](https://www.sqlite.org/atomiccommit.html), [WAL](https://www.sqlite.org/wal.html), [online backup](https://www.sqlite.org/backup.html)). The database, WAL, and backup destination must live on Ronin-local storage rather than a network filesystem.

## 2. Canonical, versioned Transcript Profile sync

The existing architecture already makes Ronin canonical for one Transcript Profile and distinguishes it from per-device interaction settings ([selected settings ownership](../architecture/current-system.md#selected-settings-ownership)). Preserve that decision:

- **Transcript Profile, shared:** canonical model checkpoint, Word Removals, Word Remappings, spoken-punctuation policy, Output Formatting, and eventually the default Transcript Style.
- **Device Interaction Settings, local:** microphone, Recording Hotkey/Action Button, feedback, warm capture, keyboard handoff, paste behavior, and platform permissions.

Use the provider-neutral checkpoint identity `nvidia/parakeet-tdt-0.6b-v2` in the shared profile. Apple clients can map that identity to the Core ML package `parakeet-tdt-0.6b-v2-coreml`, while Ronin maps it to its pinned GGUF/runtime. Sharing a checkpoint identity does not prove byte-identical output across runtimes or quantizations; a recorded cross-runtime corpus is required if exact transcript parity matters. Centralizing online processing on Ronin is the only simple way to guarantee the same runtime for every online client.

### Small HTTP contract

Use a single whole-document resource before considering patches or realtime synchronization:

```http
GET /v1/transcript-profile
Authorization: Bearer <device credential>

200 OK
ETag: "profile-42"
{
  "schemaVersion": 1,
  "revision": 42,
  "profileId": "owner-default",
  "selectedModel": "nvidia/parakeet-tdt-0.6b-v2",
  "transforms": { ... },
  "outputFormatting": { ... },
  "transcriptStyle": { "id": "normal", "policyVersion": 1 }
}
```

```http
PUT /v1/transcript-profile
If-Match: "profile-42"
Content-Type: application/json

<complete next document>
```

The server returns a strong ETag for the persisted revision. Every mutation requires `If-Match`; a missing precondition returns `428 Precondition Required`, and a stale one returns `412 Precondition Failed` plus the current representation/ETag. HTTP defines `If-Match` using strong comparison specifically for state-changing requests, and `428` exists to prevent lost updates ([RFC 9110 §13.1.1](https://www.rfc-editor.org/rfc/rfc9110.html#name-if-match), [RFC 6585 §3](https://www.rfc-editor.org/rfc/rfc6585.html#section-3)). This is preferable to timestamps or silent last-write-wins even for one person, because two devices can edit the profile concurrently.

The body needs both a `schemaVersion` and a monotonic server `revision`. `schemaVersion` chooses validation/migration code; `revision` provides concurrency and explainability. Unknown future schema versions fail explicitly. Accepted writes preserve the previous document as a revision for rollback and diagnostics.

A Dictation snapshots one accepted profile revision before selecting its model or applying policy, uses that same snapshot through completion, and returns at least:

```json
{
  "dictationId": "uuid",
  "finalTranscript": "...",
  "profileRevision": 42,
  "profileSchemaVersion": 1,
  "model": "nvidia/parakeet-tdt-0.6b-v2",
  "runtime": "parakeet.cpp@<pinned-version>",
  "style": { "id": "normal", "policyVersion": 1 },
  "timings": { "queueMS": 0, "recognitionMS": 0, "processingMS": 0, "totalMS": 0 }
}
```

Ronin, not mobile, applies the canonical transforms and returns the Final Transcript. That removes the tracer's temporary fixed phone-side transforms and makes the applied revision observable.

### Offline and conflict semantics

| Client state | Dictation | Profile reads | Profile edits |
| --- | --- | --- | --- |
| macOS, Ronin reachable | May use Ronin or an explicitly selected local adapter; result records runtime/revision | Refresh on launch/foreground/settings open with ETag | Online optimistic write only |
| macOS, Ronin unreachable | Continue local Dictation with the last accepted cached profile revision | Show cached revision as offline | Disabled; do not queue a hidden write |
| iOS, Ronin unreachable | Fail closed; do not fabricate or defer a Final Transcript | Cached display is allowed | Disabled |
| Windows, initial remote-only client | Fail closed like iOS | Cached display is allowed | Disabled |
| Windows, future explicit local adapter | May use last accepted cached revision | Show cached revision/runtime | Disabled |

This preserves the already-recorded macOS/iOS semantics and avoids a conflict-prone offline write queue. Polling with ETags at lifecycle boundaries is enough for a single owner; WebSockets, CRDTs, and background push synchronization would add machinery without solving a present requirement.

## 3. A viable Windows client

### Recommended first implementation

Build a native Windows 11 desktop process whose platform adapters mirror the existing macOS dependency clients. C# with thin Win32/Core Audio interop is a reasonable implementation choice, but the durable decision is the boundaries, not the UI framework:

```text
ActivationClient        global toggle first; press/hold later
RecordingClient         WASAPI capture + route recovery
AudioNormalizer         mono 16 kHz Float32 WAV
RoninDictationClient    authenticated, cancellable, idempotent HTTP
PasteboardClient        snapshot -> paste -> conditional restore
FeedbackClient          tray/overlay/sound
CredentialStore         current-user DPAPI
ProfileCache            last accepted profile + revision
```

Tailscale has a supported Windows client for Windows 10 or later, so the Windows process can use the same MagicDNS/Serve endpoint without introducing a public ingress ([Tailscale Windows installation](https://tailscale.com/docs/install/windows)). Target Windows 11 because Windows 10 support has ended.

For a toggle hotkey, `RegisterHotKey` is the smallest supported surface and posts `WM_HOTKEY` to the application's message loop ([Microsoft `RegisterHotKey`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)). Matching Hex's Press-and-Hold and Double-Tap Lock semantics requires key-down and key-up visibility, so it will eventually need a narrowly scoped `WH_KEYBOARD_LL` hook. Windows documents that low-level hook as observing events before they enter a thread input queue and cautions that hooks add system work; the callback should only classify/copy the event and post it to the pure activation policy, never capture audio or perform network work ([hooks overview](https://learn.microsoft.com/en-us/windows/win32/winmsg/about-hooks), [`LowLevelKeyboardProc`](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc)). Ignore events marked `LLKHF_INJECTED` so Hex does not react to its own insertion keystrokes ([`KBDLLHOOKSTRUCT`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-kbdllhookstruct)).

Use WASAPI shared-mode capture and read packets through `IAudioCaptureClient`, then normalize behind the recording adapter to the server's existing mono 16 kHz Float32 WAV contract. Microsoft documents WASAPI as the endpoint audio-flow API and the `GetBuffer`/`ReleaseBuffer` packet loop for capture ([WASAPI](https://learn.microsoft.com/en-us/windows/win32/coreaudio/wasapi), [capturing a stream](https://learn.microsoft.com/en-us/windows/win32/coreaudio/capturing-a-stream)). The app must surface microphone privacy denial; Windows 11 can disable microphone access for desktop apps globally ([Microsoft microphone privacy](https://support.microsoft.com/en-us/windows/privacy/turn-on-app-permissions-for-your-microphone-in-windows)).

For the first release, insert the Final Transcript by temporarily placing Unicode text on the clipboard and synthesizing `Ctrl+V`, then restore the exact prior clipboard only if no other actor changed it. This matches Hex's existing user-environment-preservation rule. Windows requires exclusive `OpenClipboard` access and exposes a sequence number to detect intervening changes ([clipboard operations](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-operations), [clipboard sequence number](https://learn.microsoft.com/en-us/windows/win32/dataxchg/using-the-clipboard#query-the-clipboard-sequence-number)). `SendInput` is subject to User Interface Privilege Isolation and can inject only into equal- or lower-integrity applications, so insertion into an elevated destination must fail explicitly rather than silently report success ([Microsoft `SendInput`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)). Do not run Hex elevated just to bypass this boundary.

Text Services Framework is a future alternative if clipboard insertion proves inadequate. TSF is Windows' framework for keyboard processors and speech text services, but it is a COM-based text service loaded into target applications and carries materially more compatibility and signing surface ([Microsoft TSF overview](https://learn.microsoft.com/en-us/windows/win32/tsf/text-services-framework), [IME requirements](https://learn.microsoft.com/en-us/windows/apps/develop/input/input-method-editor-requirements)). It is not required for a first production desktop client.

### Central versus local processing

| Option | Benefits | Costs/risks | Decision |
| --- | --- | --- | --- |
| Ronin only | One pinned runtime/model; canonical profile always applied; one statistics path; no model lifecycle on Windows | Requires Ronin and Tailscale; audio upload latency | **Default first release** |
| Explicit local Parakeet adapter | Offline use; avoids upload; can exploit Windows CPU/Vulkan/CUDA | Model download/update, memory, hardware variance, duplicate transforms/profile cache, stats reconciliation | Viable later behind the same provider-neutral port |
| Silent automatic fallback | Appears resilient | Output/runtime can change invisibly; makes incidents and latency hard to explain; conflicts with fail-closed mobile behavior | **Do not build** |

Local Windows inference is technically viable: the first-party `parakeet.cpp` project publishes Windows x64 CPU, Vulkan, and CUDA bundles and a flat C API, including support for `parakeet-tdt-0.6b-v2` ([`parakeet.cpp` README](https://github.com/mudler/parakeet.cpp/blob/master/README.md), [release artifacts](https://github.com/mudler/parakeet.cpp/releases)). It is not automatically production-ready for this Windows machine. Gate it on a pinned binary and model digest, the same recorded speech corpus used on Ronin/macOS, cold/warm latency, memory, cancellation, device-loss recovery, and the target hardware. If it is added, expose `RemoteRoninSpeechRecognition` and `LocalParakeetSpeechRecognition` as explicit adapters; never switch providers within a Dictation without recording that fact.

Do not attempt to share Swift/TCA UI code with Windows. Share versioned JSON schemas, normalized audio contracts, error taxonomy, and executable conformance fixtures. This preserves the inherited rule of pure policy plus injected platform effects without forcing a risky cross-language core rewrite.

## 4. Privacy-safe usage statistics

The server can answer useful personal questions without keeping Raw Transcripts, Final Transcripts, audio, Source App names, window titles, clipboard contents, or full request logs.

Record one idempotent **Dictation Outcome** with only bounded numeric/enumerated fields:

```text
dictation_id                 random UUID used only for deduplication
device_id / platform         known enrolled device; optional display grouping
day                          owner's local calendar day, not a full activity trail
outcome                      completed | cancelled | discarded | failed
failure_stage / reason       closed low-cardinality enums, never exception text
captured_ms                  Recording Session duration
final_word_count             count only; no text
queue_ms
recognition_ms
processing_ms
stop_to_insert_ms            client-reported end-to-end delivery latency
profile_revision
style_id / style_policy_version
runtime / model              bounded version identifiers
```

Apply an event exactly once in the same SQLite transaction that inserts its deduplication receipt and increments the daily aggregates. Durable request idempotency must replace the prototype's process-local 32-entry cache before statistics ship, or a retry can double-count and repeat inference. For macOS local Dictations, upload the numeric outcome later with the same Dictation ID; never upload transcript text just to count it.

Definitions should be stable and testable:

- **Words dictated:** sum of `final_word_count` for completed Dictations. Count words with one documented Unicode word-boundary implementation; Unicode Standard Annex #29 defines the default word-boundary rules and explains why whitespace splitting is not a complete definition ([UAX #29](https://unicode.org/reports/tr29/)).
- **Dictation WPM:** `60 × sum(final_word_count) / sum(captured_ms / 1000)` for completed Dictations. Use the ratio of totals, not an average of per-Dictation WPM, which overweights short samples.
- **Success/failure rate:** completed or failed count divided by terminal outcomes; keep Cancel and Discard distinct as the Hex domain requires.
- **Latency:** p50/p95 from histograms for queue, recognition, processing, and stop-to-insert. Histograms retain count/sum/buckets without retaining every raw observation and are the OpenTelemetry metric type intended for request duration and percentile-style analysis ([OpenTelemetry metrics API](https://opentelemetry.io/docs/specs/otel/metrics/api/), [histogram data model](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#histogram)).

Keep metric dimensions low-cardinality: platform, outcome, failure stage, model/runtime version, and one of three style IDs. Do not use transcript fragments, Source App, request URL, file path, IP, or arbitrary error messages as dimensions. Provide all-time and daily/weekly summaries from Ronin; a third-party analytics SDK is unnecessary for one owner.

## 5. Transcript styles without weakening the deterministic pipeline

The domain currently defines a Transcript Transform as deterministic. Keep `normal` exactly equal to the existing pipeline and do not disguise an LLM call as a transform ([Transcript processing vocabulary](../../CONTEXT.md#transcript-processing)). A useful split is:

```text
Raw Transcript
    -> deterministic Word Removal / Word Remapping
    -> optional Transcript Rewriter (casual or professional)
    -> deterministic Output Formatting
    -> validation/fallback
    -> Final Transcript
```

The exact ordering should be fixed in an ADR and executable fixtures before implementation. The key property is that `normal` skips the rewriter and remains byte-for-byte compatible with current behavior.

Deterministic policy can reliably handle casing, punctuation rules, filler removal, and explicit word remapping. It cannot generally make arbitrary speech “more casual” or “more professional” while preserving meaning; those presets require a generative rewrite and therefore add latency and semantic uncertainty.

For model-assisted styles:

- Store a preset ID and immutable `policyVersion` in the Transcript Profile. Do not accept an arbitrary prompt on each Dictation request.
- Prefer a local model on Ronin so transcript content does not leave the owner's machines/tailnet. Any remote model provider requires a separate explicit privacy and retention decision.
- Give the rewriter only the chosen preset policy and one transcript. Give it no credentials, history, tools, network access, Source App data, or other transcripts.
- Delimit the transcript as untrusted data, require plain-text/schema-constrained output, cap input/output size, and validate non-empty output and a conservative length ratio. Prompt injection remains an evolving risk even when models are trained to distinguish trusted instructions, so isolation and least authority are more important than a claim that escaping text “solves” it ([OpenAI prompt-injection overview](https://openai.com/safety/prompt-injections/), [OpenAI Model Spec treatment of untrusted quoted data](https://model-spec.openai.com/2025-09-12.html#follow-the-chain-of-command)).
- On timeout, model error, invalid output, or cancellation, return the deterministic candidate and record a bounded fallback reason. The rewriter never blocks `normal` and never causes loss of an otherwise valid Final Transcript.
- Record `style_id`, `policy_version`, local model/runtime version, and rewrite latency, but not the prompt or transcript.

Prompt injection is contained here because the rewriter has no actions or secrets; its maximum authority is proposing text that the owner already asked Hex to paste. It can still alter meaning. Promotion therefore requires a recorded, privacy-safe evaluation corpus containing conversational speech, professional prose, names/technical terms, quoted instructions such as “ignore the previous instructions,” profanity, numbers, URLs, and already-well-formed text. Review meaning preservation and terminology as well as style.

Style latency needs a separate budget. First preserve the measured `normal` p95 as a non-regression baseline. Enable `casual`/`professional` only after the selected local model meets an explicitly approved additional p95 budget on Ronin; otherwise styled Dictations should fall back to normal rather than make every Dictation slower.

## Production sequence and gates

### Phase 0 — harden the working path

1. Resolve repeated iOS Dictations during one warm arm on the physical phone; Simulator success is not a substitute for background audio lifecycle coverage.
2. Move the service out of prototype assumptions: durable idempotency, bounded request/body/time/queue limits, structured private logging, graceful shutdown, readiness, pinned runtime/model artifacts, SQLite migrations, and tested backup/restore.
3. Replace the shared secret with independently revocable Device Principals and install exact-node Tailscale grants. Keep Serve loopback-only and Funnel off.

Gate: repeated capture/transcribe/insert cycles, process restart during retries, wrong-body request-ID reuse, credential rotation/revocation, lost phone, Ronin restart, backup restore, Tailscale outage, microphone denial, and confidential-log inspection all pass.

### Phase 1 — shared settings

1. Add the singleton Transcript Profile repository and revision history.
2. Add GET/PUT with strong ETags, `If-Match`, `428`, and `412` conflict behavior.
3. Make Ronin apply the profile and return the Final Transcript plus applied revision.
4. Make macOS cache the last accepted revision and remove mobile-side duplicate transforms.

Gate: concurrent-edit, schema migration, crash consistency, rollback, Mac offline use, and iOS fail-closed tests pass.

### Phase 2 — Windows remote client

Implement toggle activation, WASAPI capture/normalization, Ronin request, clipboard-preserving insertion, explicit UIPI failure, feedback, DPAPI credential storage, profile display/edit, and a signed installer. Test at minimum Notepad, a Chromium browser, an Electron app, Office, password/secure fields, and an elevated target.

Gate: Windows repeats the cross-platform audio/API fixtures and meets the established stop-to-insert latency budget over the real tailnet.

### Phase 3 — aggregate statistics

Add idempotent outcomes, daily/all-time counters, weighted WPM, and latency histograms. Verify retries do not double-count and inspect the database/log exports to prove that no audio or transcript content is retained.

### Phase 4 — optional local Windows processing and styles

Treat local Parakeet and each model-assisted style as separate experiments with corpus parity, resource, privacy, failure, and latency gates. Neither is a prerequisite for the production remote Windows client or shared settings.

## Remaining decisions and measurements

1. **Exact-output requirement:** must Mac, Windows, iOS, and Ronin produce byte-identical Raw Transcripts, or is the same checkpoint plus recorded runtime metadata sufficient? Exact output implies routing online Mac Dictations through Ronin too.
2. **Windows hardware and target apps:** CPU/GPU/RAM, x64 versus ARM64, common elevated applications, and desired toggle versus Press-and-Hold semantics determine whether a local adapter or low-level hook is worth its surface.
3. **Ronin and tailnet state:** deployed Tailscale version, exact-node aliases, tailnet plan, backup destination, filesystem, and hardware must be recorded before app-capability headers, posture rules, or latency budgets become acceptance criteria.
4. **Statistics presentation:** all-time only versus day/week/device breakdown, timezone boundary, and whether numeric per-Dictation receipts may be retained beyond the deduplication window.
5. **Style budget and model:** acceptable additional p95 latency, the local rewrite model/runtime, and the human-approved meaning-preservation corpus remain empirical choices.

None of these unknowns blocks Phase 0 or the single-Owner/Profile architecture.
