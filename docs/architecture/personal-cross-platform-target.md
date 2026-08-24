# Personal Cross-Platform Target Architecture

This document is the production handoff for the accepted personal Hex topology. Product language lives in [`CONTEXT.md`](../../CONTEXT.md), inherited preservation rules remain in [`current-system.md`](current-system.md), and the supporting research remains in [`single-owner-cross-platform-hex.md`](../research/single-owner-cross-platform-hex.md).

## Status and scope

This is the target architecture, not a description of the current prototypes. It accepts one Owner, independently revocable Device Principals, Ronin-owned transcript policy, a remote-only first Windows client, privacy-safe Dictation Statistics, and three Transcript Styles.

ADRs [0001](../adr/0001-model-one-owner-through-device-principals.md), [0002](../adr/0002-ronin-owns-transcript-policy.md), [0003](../adr/0003-ios-keyboard-delivery-is-at-most-once.md), [0004](../adr/0004-ios-keyboard-presence-bounds-capture.md), and [0005](../adr/0005-ios-warm-capture-discards-idle-audio.md) record the durable ownership and iOS lifecycle/delivery decisions.

## Runtime shape

```text
macOS app                 iOS containing app              Windows app
local interaction        local interaction               local interaction
and delivery             + keyboard delivery             and delivery
     │                           │                              │
     └──────── Tailscale grant + HTTPS + Device Credential ───┘
                                 │
                                 ▼
                         Ronin Effect service
              ┌──────────────────┼──────────────────┐
              │                  │                  │
      Device Principals   Transcript Profile    Dictation
              │                  │          profile snapshot
              │                  │                  ↓
              │                  │          Parakeet v2
              │                  │                  ↓
              │                  │       versioned transcript policy
              │                  │       (deterministic + optional
              │                  │        isolated rewrite)
              │                  │                  ↓
              │                  └────────── Final Transcript
              │                                     │
              └──────────── Dictation Outcomes ─────┘
                                 │
                                 ▼
                     SQLite + tested backups
```

The originating device owns activation, the Recording Session, Recording Feedback, and delivery to the Text Destination. Ronin authenticates the Device Principal, snapshots one Transcript Profile Revision, performs remote Transcription and transcript processing, and returns the Final Transcript. Tailscale limits reachability but is not application authentication.

## Invariants

- Exactly one Owner exists. Owner is domain ownership, not an account, login, organization, or tenant.
- Every installation is a separate Device Principal with a distinct Device Credential and independent revocation.
- Device Credentials never enter a Transcript Profile or the iOS keyboard App Group.
- Ronin is canonical for the Transcript Profile. A Dictation uses one immutable Transcript Profile Revision from start to finish.
- Profile writes require the revision the editor read; stale or missing preconditions never become last-write-wins updates.
- Device Interaction Settings remain local to each device.
- Remote iOS and Windows Dictations fail closed when Ronin is unavailable. There is no queued or silent local fallback.
- A Dictation ID is idempotent. Reusing it with different Captured Audio is a conflict; a valid retry replays the durable result and does not repeat statistics.
- Normal produces the existing deterministic pipeline. A Transcript Rewriter is not a Transcript Transform.
- Casual or professional rewriter failure returns the deterministic candidate with a bounded fallback reason; it never loses an otherwise valid Final Transcript.
- Dictation Statistics contain bounded numeric or enumerated fields only. They never contain Captured Audio, Raw Transcripts, Final Transcripts, Source App names, window titles, clipboard content, file paths, IP addresses, or arbitrary errors.
- iOS keyboard delivery is at-most-once. The pending Final Transcript is consumed before `insertText`; a rare extension termination in that unacknowledged side-effect window requires re-dictation instead of risking duplicate text.
- iOS audio capture requires a recent heartbeat from the keyboard that requested it. Extension eviction, switching keyboards, or changing Apple's originating text-document identity cancels and erases partial capture within the bounded presence lease. Apple does not document that identity as field-specific, so same-document field switching remains a physical acceptance gate.
- An armed iOS session keeps its audio resource warm but discards idle input. Captured Audio begins only after an accepted Begin command and all boundary/live writer admission is bounded.

## Ownership boundaries

### Owner and Device Principals

Ronin initializes one Owner and now provides Ronin-local CLI administration for Device Principal enrollment, rotation, listing, and revocation. Each enrollment mints a distinct 256-bit lowercase-hex credential exactly once; the bounded SQLite registry stores only its SHA-256 digest and resolves it with constant-time comparisons. The Docker health probe is a separate health-only principal and cannot transcribe. A friendlier future enrollment surface remains optional, but remote sign-up is not part of the topology.

A production request passes three gates:

1. An exact-device Tailscale grant permits access to Ronin's Hex port.
2. Tailscale Serve terminates tailnet HTTPS and proxies to a loopback-only listener; Funnel remains off.
3. Ronin resolves the bearer credential to an active Device Principal with the required capability.

Apple clients protect their Device Credential with a device-only Keychain class. Windows protects it for the current Windows user with DPAPI.

### Transcript Profile and Device Interaction Settings

The Transcript Profile contains the Selected Model identity, Word Removals, Word Remappings, spoken-punctuation policy, Output Formatting, and default Transcript Style. Ronin stores its schema version, monotonic revision, and immutable prior revisions.

Device Interaction Settings include Input Device, Recording Hotkey or Action Button behavior, Recording Feedback, warm capture, keyboard handoff, and clipboard delivery. They are not synchronized merely because several clients expose similarly named controls.

macOS may continue an explicitly local Dictation with its last accepted cached Transcript Profile Revision while offline. Profile edits are online-only. Whether online macOS Dictations must route through Ronin for byte-identical output remains unresolved.

## Effect service modules and contracts

Domain modules remain pure. Each Effect service module below is an authority seam with a narrow domain-shaped interface; SQLite, HTTP, Parakeet, time, secrets, and platform APIs stop at adapters.

| Effect service module | Authority |
| --- | --- |
| `DeviceAuthentication` | Resolve an untrusted credential to an active Device Principal and capability set. |
| `DeviceRegistry` | Enroll, rotate, list, and revoke Device Principals through local administration. |
| `TranscriptProfiles` | Read, snapshot, validate, update, and retain Transcript Profile Revisions. |
| `Dictation` | Own idempotency, inference serialization, profile application, optional rewrite, and result projection. |
| `DictationStatistics` | Apply one content-free Dictation Outcome exactly once and query aggregates. |
| `SpeechRecognition` | Application-owned port implemented by the pinned Parakeet v2 adapter. |
| `TranscriptRewriter` | Application-owned optional port; absent for normal and isolated for styled output. |

Illustrative domain contracts:

```ts
type OwnerId = string & Brand<"OwnerId">
type DevicePrincipalId = string & Brand<"DevicePrincipalId">
type DictationId = string & Brand<"DictationId">
type ProfileRevision = number & Brand<"ProfileRevision">

type TranscriptStyle =
  | { readonly id: "normal"; readonly policyVersion: number }
  | { readonly id: "casual"; readonly policyVersion: number }
  | { readonly id: "professional"; readonly policyVersion: number }

type TranscriptStyleOutcome =
  | { readonly _tag: "Normal"; readonly style: Extract<TranscriptStyle, { id: "normal" }> }
  | { readonly _tag: "Rewritten"; readonly style: Exclude<TranscriptStyle, { id: "normal" }> }
  | {
      readonly _tag: "DeterministicFallback"
      readonly requestedStyle: Exclude<TranscriptStyle, { id: "normal" }>
      readonly reason: StyleFallbackReason
    }

interface VersionedTranscriptProfile {
  readonly schemaVersion: number
  readonly revision: ProfileRevision
  readonly selectedModel: TranscriptionModelId
  readonly transforms: TranscriptTransforms
  readonly outputFormatting: OutputFormatting
  readonly transcriptStyle: TranscriptStyle
}

interface DictationRequest {
  readonly dictationId: DictationId
  readonly devicePrincipalId: DevicePrincipalId
  readonly audio: CapturedAudio
  readonly audioDigest: AudioDigest
}

interface DictationResult {
  readonly dictationId: DictationId
  readonly finalTranscript: FinalTranscript
  readonly profileRevision: ProfileRevision
  readonly profileSchemaVersion: number
  readonly model: TranscriptionModelId
  readonly runtime: RecognitionRuntimeId
  readonly styleOutcome: TranscriptStyleOutcome
  readonly timings: DictationTimings
}

interface ProfileUpdate {
  readonly expectedRevision: ProfileRevision
  readonly next: TranscriptProfileDocument
  readonly editedBy: DevicePrincipalId
}

interface DictationService {
  readonly transcribe: (
    input: DictationRequest
  ) => Effect.Effect<DictationResult, DictationError>
}

interface TranscriptProfilesService {
  readonly getCurrent: Effect.Effect<VersionedTranscriptProfile, ProfileReadError>
  readonly update: (
    input: ProfileUpdate
  ) => Effect.Effect<VersionedTranscriptProfile, ProfileUpdateError>
}
```

The production Layers provide SQLite repositories, the Parakeet adapter, configuration, cryptography, and HTTP only at the composition root. Tests cross the same interfaces using a real temporary SQLite adapter where transaction, migration, idempotency, or concurrency behavior matters.

## HTTP boundary

The HTTP adapter authenticates and parses untrusted values before calling an Effect service module. It does not own transcript policy.

```http
GET /v1/transcript-profile
Authorization: Bearer <Device Credential>

200 OK
ETag: "profile-42"
```

```http
PUT /v1/transcript-profile
Authorization: Bearer <Device Credential>
If-Match: "profile-42"
Content-Type: application/json

<complete next Transcript Profile>
```

Every profile update requires a strong `If-Match`. A missing precondition returns `428 Precondition Required`; a stale ETag returns `412 Precondition Failed` with the current representation and ETag. Unknown schema versions fail explicitly.

The existing authenticated `POST /v1/transcribe` remains the initial Dictation transport. Its successful response expands to `DictationResult`. The request keeps a caller-generated Dictation ID and validated audio digest so retries are durable and conflicting reuse returns `409 Conflict`.

Statistics presentation and any client-reported delivery-outcome endpoint remain unresolved; do not create an endpoint until those contracts are accepted.

## Remote Dictation flow

```text
HTTP bytes and headers
  → transport schemas
  → DeviceAuthentication
  → DevicePrincipal + DictationRequest
  → durable idempotency claim
  → TranscriptProfiles.getCurrent and immutable revision selection
  → SpeechRecognition
  → Raw Transcript
  → versioned pipeline policy selects ordered stages
  → deterministic stages and, for casual/professional only,
    optional TranscriptRewriter at a fixture-defined seam
  → rewrite validation or deterministic fallback
  → Final Transcript
  → durable result + Dictation Outcome transaction
  → DictationResult DTO
  → originating device delivery
```

The exact placement of the Transcript Rewriter among deterministic stages is unresolved and requires fixtures before implementation. Normal must remain byte-compatible with the inherited deterministic pipeline regardless of that decision.

Cancellation stops queued or active work where the Parakeet runtime permits it and never commits a completed outcome. A retry with the same Dictation ID and digest observes the same durable state; a retry with a different digest is rejected. Logs carry Dictation ID, Device Principal ID, bounded stage/outcome, revisions, model/runtime identifiers, and timings with privacy annotations, never content or credentials.

## Windows first release

The first Windows client is a native Windows 11 remote client:

```text
RegisterHotKey toggle
  → WASAPI shared-mode capture
  → mono 16 kHz Float32 WAV normalization
  → authenticated Ronin Dictation
  → Final Transcript
  → clipboard snapshot
  → Unicode clipboard value + Ctrl+V
  → restore prior clipboard only if unchanged
```

- Store the Device Credential for the current Windows user with DPAPI.
- Use Tailscale to reach the same private Ronin origin and fail closed when it is unavailable.
- Begin with toggle activation through `RegisterHotKey`. Press-and-Hold and Double-Tap Lock may later use a narrowly scoped low-level hook after the required semantics and target applications are measured.
- Surface microphone privacy denial, recording failure, network failure, and UIPI-blocked insertion explicitly.
- Do not run elevated to bypass UIPI.
- Local Parakeet, silent provider fallback, Text Services Framework, and a custom input method are not part of the first release.

## Dictation Statistics

One idempotent Dictation Outcome may contain only:

```text
Dictation ID, Device Principal ID, platform, Owner-local day,
terminal outcome, bounded failure stage/reason, captured milliseconds,
final word count, bounded latency values, Transcript Profile Revision,
Transcript Style and policy version, model and runtime identifiers
```

Ronin increments aggregates in the same SQLite transaction that accepts the outcome's deduplication receipt. Weighted Dictation WPM is `60 × total final words / total captured seconds`; it is not an average of per-Dictation rates. Latency uses bounded histograms suitable for p50/p95 summaries.

Timezone boundaries, day/week/device presentation, and retention of numeric per-Dictation receipts beyond the deduplication window remain unresolved.

## Transcript Styles

- `normal`: always the deterministic Hex pipeline; no Transcript Rewriter requirement and no additional rewrite latency.
- `casual`: Ronin may invoke the isolated Transcript Rewriter using an immutable preset policy version.
- `professional`: the same isolation and versioning rules with a different immutable preset.

The Transcript Rewriter receives one transcript and one preset. It receives no Device Credential, tools, history, network authority, Source App context, or arbitrary caller prompt. Output is bounded and validated for non-empty content, conservative length, and schema. Timeout, invalid output, cancellation, or model failure falls back to the deterministic candidate.

No external model provider is approved by this architecture. Model/runtime selection, exact stage ordering, acceptable added p95 latency, and the human-reviewed meaning-preservation corpus remain rollout decisions.

## Explicit non-goals

- Multiple Owners, users, accounts, organizations, teams, passwords, OAuth/OIDC, or public registration.
- Public ingress, Tailscale Funnel, or exposing the Ronin listener beyond loopback behind Serve.
- Synchronizing Device Interaction Settings or Device Credentials.
- Giving the iOS keyboard extension microphone ownership, a Device Credential, or direct Ronin access.
- Offline iOS or initial Windows Transcription, queued offline profile writes, CRDTs, WebSockets, or push synchronization.
- Local Windows inference, automatic provider failover, TSF, or an IME in the first Windows release.
- Raw Transcript, Final Transcript, or Captured Audio retention for statistics.
- Arbitrary per-Dictation rewrite prompts or reclassifying a model-assisted rewrite as a Transcript Transform.
- Cross-runtime byte identity until the exact-output requirement is resolved and proven by a corpus.

## Rollout gates

| Phase | Deliverable | Gate |
| --- | --- | --- |
| 0 — harden | Reusable iOS capture, production Ronin runtime, durable idempotency, Device Principals, exact-node Tailscale policy, backup/restore | Repeated physical-iPhone Dictations per arm; idle audio discarded; interruption/route/expiry cleanup; retry/restart/conflict/revocation/lost-device/Tailscale-outage tests; private-log inspection; restored backup serves requests. |
| 1 — profile | Versioned Transcript Profile repository and history, ETag/`If-Match`, Ronin processing, client cache/edit UI | Concurrent edits, `428`/`412`, schema migration, rollback, crash consistency, macOS cached offline Dictation, and iOS fail-closed behavior pass. |
| 2 — Windows | Remote-only Windows 11 client with WASAPI, hotkey, DPAPI, Tailscale, and clipboard-preserving insertion | Shared audio/API fixtures pass; Notepad, browser, Electron, Office, secure-field, and elevated-target behavior is explicit; real-tailnet latency meets the approved baseline. |
| 3 — statistics | Idempotent Dictation Outcomes and aggregate summaries | Retries cannot double-count; weighted WPM and histograms pass fixtures; database, backup, logs, and exports contain no audio or transcript content. |
| 4 — styles | Casual and professional isolated rewrite experiments | Normal p95 does not regress; approved corpus demonstrates meaning and terminology preservation; fallback, isolation, model/runtime pinning, and added-latency budget pass. |

## Unresolved decisions

1. Whether online macOS must route through Ronin for byte-identical Raw Transcripts or may use a recorded local runtime with the same Transcript Profile Revision.
2. The Owner's Windows hardware, required target applications, and eventual Press-and-Hold or Double-Tap Lock scope.
3. Exact Tailscale node aliases/policy, encrypted off-host backup destination, and operational latency budgets. The local multi-database backup/restore boundary and fail-closed post-restore Device Principal reset are implemented.
4. Whether the existing Ronin-local enrollment command needs a friendlier owner-controlled transfer surface, and the normal credential-rotation cadence. Per-install credentials, SHA-256 digest storage, immediate rotation/revocation, and lost-device behavior are settled.
5. Dictation Statistics timezone, presentation, and numeric receipt retention.
6. Transcript Rewriter implementation, deterministic-stage ordering, model/runtime, added p95 budget, and acceptance corpus.

None of these decisions permits code to invent multi-user behavior, content retention, silent fallback, or client-owned transcript policy.
