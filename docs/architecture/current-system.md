# Current System Architecture

This document records the inherited Hex architecture at the fork point so future work can preserve its hard-won boundaries without treating every current limitation as a product requirement. Product language lives in [`CONTEXT.md`](../../CONTEXT.md).

## Baseline

The fork's `main` branch and `kitlangton/Hex` were identical at `881c46f236f529a8f6c7eed61ed1f4cbca9ac267` (`v0.8.4`) when this document was created. The repository contains a macOS application and tests; it has no server, iOS application, HTTP API, or Tailscale integration.

The current product performs capture, Transcription, transcript processing, history, and Paste on one Mac. That is the inherited baseline, not a constraint on the fork's future design.

## Runtime shape

```text
macOS input events
    ↓
KeyEventMonitorClient → HotKeyProcessor → TranscriptionFeature
                                             ↓
                                      RecordingClient
                                             ↓
                                       Captured Audio
                                             ↓
                                     TranscriptionClient
                                             ↓
                                       Raw Transcript
                                             ↓
                      removal → remapping → output formatting
                                             ↓
                                       Final Transcript
                                      ↙                ↘
                    TranscriptPersistenceClient      PasteboardClient
                         (when enabled)              (Text Destination)
```

`HexApp` owns one global TCA store. `AppFeature` composes the transcription, settings, and history reducers. `HexAppDelegate` owns macOS lifecycle and window composition, including the nonactivating transcription overlay.

`TranscriptionFeature` orchestrates the end-to-end Dictation workflow. Platform effects are injected clients rather than reducer-owned implementations: recording, transcription, input monitoring, pasteboard access, permissions, sound, sleep management, and transcript persistence.

`HexCore` holds the deterministic vocabulary and policy that can be tested without UI or audio hardware, including hotkey processing, recording acceptance, transcript transforms, settings compatibility, and history models.

## End-to-end behavior

1. `KeyEventMonitorClient` converts global keyboard and mouse events into project input types and gives them to registered handlers.
2. The pure `HotKeyProcessor` turns input sequences into semantic outcomes: start, stop, cancel, discard, or no action.
3. `TranscriptionFeature` verifies model readiness, captures Source App metadata, starts recording feedback, optionally prevents sleep, and asks `RecordingClient` to capture audio.
4. Release-time policy in `RecordingDecisionEngine` decides whether a Recording Session is accepted or silently discarded.
5. `RecordingClient` returns a typed captured, ignored, or failed outcome. A valid audio file is passed to `TranscriptionClient` with the Selected Model.
6. The Raw Transcript passes through a fixed deterministic pipeline: optional Word Removal, Word Remapping, then Output Formatting. The transforms scratchpad deliberately bypasses this pipeline.
7. When history is enabled, the Final Transcript and audio are persisted before being inserted newest-first into shared history. The Final Transcript is then pasted and success feedback plays. When history is disabled, the temporary audio is deleted.
8. Cancel and Discard both clean up audio and restore environmental state; Cancel is explicit and audible, while Discard is silent.

## Preservation rules

These rules are supported by current code, tests, and repository history. New architecture should preserve the property even when the implementation changes.

### Pure policy, injected effects

Keep deterministic decisions in `HexCore` and operating-system, network, storage, or model effects behind narrow dependency clients. Reducers coordinate state and effects; they do not become hardware, transport, or persistence implementations.

### Deep clients with typed outcomes

Clients expose small interfaces over complicated behavior. `RecordingClient`, for example, hides device selection, media handling, warm capture, route recovery, audio normalization, and fallback recording while returning explicit captured, ignored, or failed outcomes.

### Isolated long-lived mutable state

Recording hardware, loaded models, sound resources, and sleep assertions are actor-isolated. Preserve serialized ownership for resources that cannot safely serve competing mutations.

### Explicit stale-work and cancellation identities

TCA cancellation IDs prevent overlapping workflow effects. Recording session IDs reject stale stops, capture generations reject callbacks from replaced engines, and model/history operations use identities to reject stale completion. Remote requests need equally explicit cancellation and idempotency semantics.

### Durable intent survives transient scans

A temporary model-availability failure must not silently erase the user's Selected Model. More generally, volatile discovery state must not overwrite durable user intent.

### Compatibility-first persistence

Settings decode missing fields to current defaults, legacy fields migrate explicitly, and storage migrations avoid destroying the old source before the new destination is valid. Preserve fixture-based migration coverage for durable formats.

### Privacy-aware diagnostics

Use the centralized `HexLog` subsystem and categories. Treat transcript text, file paths, device identifiers, authentication material, and request content as private data.

### Deterministic lifecycle cleanup

Warm audio capture is suspended across lock and sleep, rearmed after wake, and drained during application termination. Cleanup is a workflow requirement, not best-effort decoration.

### User-environment preservation

Modifier-only hotkeys pass through to macOS, accidental activations are silent, media state is restored, and successful clipboard insertion restores the previous rich clipboard unless retention is requested.

## Existing seams for a private server and mobile client

`TranscriptionClient` is the closest existing speech-recognition seam, but it is not provider-neutral yet: its request exposes WhisperKit decoding options and it combines transcription with local model discovery, download, deletion, and loading.

The Final Transcript pipeline is currently private to `TranscriptionFeature`. A server endpoint cannot reuse transforms, history rules, and delivery semantics without driving a macOS reducer. A future shared use-case boundary will need explicit request and result types independent of AppKit, TCA actions, WhisperKit, and a local file URL.

The current workflow also collapses Dictation origin and delivery onto one Mac. `Source App` is captured when recording begins, while Paste targets whichever app is frontmost later. Mobile work must separately decide ownership of the Recording Session, Captured Audio, Transcription, Final Transcript, and Text Destination.

Keep Tailscale reachability, application authentication, and HTTP transport outside speech-recognition semantics. Transport should authenticate and materialize a request before crossing the provider-neutral transcription boundary.

## Fork and security boundaries to resolve

- The sandbox allows outbound network connections but has no inbound network-server entitlement.
- The menu-bar app already holds microphone, Accessibility, Input Monitoring, Apple Events, clipboard, model, and history privileges. Hosting a listener inside that privileged process would enlarge its attack surface.
- Bundle identifiers, storage paths, logging subsystem, signing team, Sparkle feed and key, download links, and support links still use upstream identity.
- The fork has source parity with upstream but no independent tags or releases.
- Tailnet reachability limits who can route to a service; it does not by itself settle application authorization, replay protection, or request identity.

These are Wayfinder decisions, not inherited invariants.

## Known tensions in the inherited implementation

- `ModelBootstrapState` starts optimistic and is verified asynchronously, leaving a cold-launch readiness race.
- Recording startup cannot report failure through the client interface; the reducer can appear to record until stop reports no captured audio.
- History persistence currently gates Paste, so a disk failure can suppress delivery of an otherwise valid Final Transcript.
- Transcription errors are stored but not presented by the current view.
- Paste Last Transcript depends on saved history, so disabling history also removes the repeat-delivery source.
- `Source App` metadata and the eventual Text Destination can diverge when focus changes.
- The current `Transcript` record retains only transformed text and Mac source-app metadata; it has no request identity, origin device, raw text, provider, or delivery outcome.

Treat these as questions or refactoring candidates. They are not automatically defects in scope for the mobile/server effort.

## Documentation authority and drift

When prose conflicts with tests and current code, follow tests and code and repair the prose in a scoped change. Known drift includes hotkey minimum-duration behavior for Keyed Hotkeys, the curated model count, first-run model download behavior, required Input Monitoring permission, removed release CI, and descriptions of `RecordingClient` as a simple recorder wrapper.

The most relevant executable specifications are:

- `HexCore/Tests/HexCoreTests/HotKeyProcessorTests.swift`
- `HexCore/Tests/HexCoreTests/HexSettingsMigrationTests.swift`
- `HexTests/RecordingRaceTests.swift`
- `HexTests/ModelDownloadFeatureTests.swift`
- `HexTests/HistoryPlaybackTests.swift`
- `HexTests/KeyEventMonitorClientTests.swift`

## Historical anchors

- `9b1169d259c60309ebe4fe86d4bded77752faf49`: immediate capture with release-time filtering and distinct Cancel/Discard semantics.
- `c5d5162bf78be3def79c809295e18e3fd755b714`: warm capture and pre-roll to avoid first-word clipping.
- `210c1baa7adc345fdd050d1b49e13f733749f6a1`: recording acceptance extracted into testable policy.
- `9b90c2cf56d96f11fd66ae8d645770a6e3472d89`: permission handling extracted behind an injected client.
- `5217d3f5db56877ab74b009a8083047410d7bef1`: experimental LLM transforms replaced with deterministic remappings.
- `eae358bbdb734ed7748be97b8603eb7c1f829093`: missing-model state made explicit instead of silently clearing selection.
- `8739929` and `ca96427`: route recovery, lock/sleep suspension, and deterministic audio teardown.
