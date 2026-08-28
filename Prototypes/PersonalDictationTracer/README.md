# Personal Dictation Tracer

> **Personal vertical slice.** The supported iOS flow works, but production promotion remains gated by [the hardening issue](https://github.com/nmarch213/Hex/issues/13) and its linked physical-device and Ronin checks.

This vertical-slice tracer proves the shortest supported iOS path:

1. The containing app keeps an explicitly armed audio session alive and records an English WAV when the keyboard requests it.
2. It uploads the WAV to a private Hex proxy on Ronin.
3. The proxy invokes `parakeet.cpp` with a revision- and checksum-pinned F16 `tdt-0.6b-v2` GGUF.
4. As temporary tracer instrumentation, the app runs the real Hex word-removal, remapping, and formatting code.
5. An App Group mailbox carries start/stop commands and exposes the Final Transcript to the custom keyboard.
6. The keyboard verifies Apple's identifier for the originating text document, durably marks the transcript consumed, and makes one at-most-once insertion attempt.

iOS does not give custom keyboard extensions microphone access. The containing app therefore owns capture while the keyboard controls it through the App Group. The user first runs the **Arm Hex** App Shortcut—ideally from the iPhone Action Button—and swipes back once. iOS shows the orange microphone indicator while the 15-minute session is armed.

Keyboard delivery deliberately favors no duplicate insertion over retrying after an extension crash. The mailbox erases the transcript when the keyboard claims it, before `insertText`; if iOS terminates the extension in that narrow window, Hex cannot safely know whether insertion happened, so the transcript is lost and must be dictated again. [ADR 0003](../../docs/adr/0003-ios-keyboard-delivery-is-at-most-once.md) records this accepted personal-product tradeoff.

While armed, Hex keeps the audio resource warm but discards idle microphone buffers. It does not open or write an audio file until **Start Voice** is accepted. Buffers arriving during that file boundary are bounded and ordered; disarming, expiry, lock, cancellation, or capture failure deletes partial and abandoned files.

The prototype requires iOS 18 or later. Its Core Audio tap publishes into a preallocated single-producer/single-consumer ring using Swift's supported `Synchronization.Atomic` API; conversion and file I/O stay off the real-time audio thread.

The accepted production boundary is different from step 4: Ronin owns a versioned Transcript Profile, applies it, and returns the Final Transcript. The client-side configuration is removed once that profile API exists.

## Local fake round trip

The fake server validates the iOS/network contract without downloading the model:

```bash
cd Prototypes/PersonalDictationTracer
npm --prefix server ci
make server-fake
```

The fake process is loopback-only and validates the server contract with `make server-health`. The phone build is deliberately pinned to Ronin's HTTPS MagicDNS origin and does not accept a development-origin override. Do not add an App Transport Security exception.

## Build

```bash
cd Prototypes/PersonalDictationTracer
make build
```

Open the generated project with:

```bash
make open
```

## Experimental swipe typing

The containing app now has a **Keyboard → Swipe to Type (Experimental)**
toggle. It is off by default. After enabling it, return to a text field and
reselect Hex if the keyboard was already visible.

With the setting on:

- draw across the letter keys to decode one English word entirely on-device;
- Hex inserts the first-ranked word plus a space and shows three candidates;
- tap another candidate to replace only the last committed glide word;
- short touches remain normal key taps, and number/symbol typing is unchanged;
- the existing Start Voice, Stop Voice, Cancel, and transcript-insertion flow
  remains in the top action row.

The prototype bundles a deterministic 20,000-entry SymSpell-derived frequency
resource. Run `make glide-lexicon` to regenerate it from the pinned source and
verify its checksum. Provenance, licenses, and the public-App-Store caveat are
documented in
[`docs/research/ios-glide-typing-word-frequency-source.md`](../../docs/research/ios-glide-typing-word-frequency-source.md)
and bundled beside the resource.

For a shareable, non-production walkthrough of the decoder interaction, open
`ios/Keyboard/Prototypes/GlideDecoderPrototype.html` directly in a browser.
The Swift decoder's checked-in tests use idealized paths only. A Debug device
build logs each selected word and normalized path with private unified-log
fields so a small real-iPhone fixture corpus can be collected without adding
cloud telemetry.

Do not call this QuickPath-equivalent yet. Before promoting it beyond the
personal prototype, issue #12 still requires real-iPhone top-three accuracy,
decode-latency and extension-memory baselines, explicit regression limits based
on those measurements, and a public-distribution license decision.

`make validate` regenerates the project, type-checks both Swift 6 targets, runs the bounded-capture unit suite, transactional App Group smoke suite, and authenticated server smoke suite, and verifies the background-audio, keyboard Full Access, and matching App Group declarations.

## Ronin service

On Ronin, enroll a health-only container principal and a separate iPhone principal, then deploy the detached service:

```bash
make server-configure
make server-device-enroll \
  DEVICE_NAME='Personal iPhone' \
  DEVICE_PLATFORM=ios \
  CREDENTIAL_OUTPUT=/owner-controlled/path/iphone-device-credential
make server
```

The health credential cannot transcribe and never leaves Ronin. The enrollment command writes the iPhone's one-time 256-bit credential and public device ID into separate owner-only files without revealing any existing secret; copy only that client credential into Hex. Ronin stores its SHA-256 digest, and the iPhone can be rotated or revoked independently. The deploy target verifies the model, configuration, hardened containers, readiness, and authenticated health. The Compose service binds only to Ronin loopback on port 8787. Expose that loopback service through Tailscale Serve at `https://ronin.tail451960.ts.net:8443`; Ronin's existing HTTPS service retains port 443. Do not enable Funnel.

## Physical-iPhone check

1. In Xcode, select your personal development team for both targets. Keep both targets under the same team.
2. If the default identifiers are unavailable, change both bundle identifiers and change `PrototypeMailbox.appGroupID` plus both entitlements to one matching App Group.
3. Run **Hex** on the phone once.
4. Add **Hex** under **Settings → General → Keyboard → Keyboards → Add New Keyboard**.
5. Enable **Allow Full Access** so the keyboard can use the shared command and transcript container.
6. Enter the iPhone Device Credential generated by `server-device-enroll`—never the Ronin health-probe credential. In **Settings → Action Button**, choose **Shortcut**, then select the **Arm Hex** App Shortcut.
7. Return to a text field and hold the Action Button. Hex opens and arms automatically; swipe back when Hex says it is armed. The token is stored in the device Keychain; the server origin is pinned in the prototype.
8. Select **Hex** with the globe key. Its status should read **Voice ready**.
9. Tap **Start Voice**, speak, then tap the red **Stop Voice** button in the keyboard. Keep the keyboard visible while it transcribes.
10. The Final Transcript should insert automatically at the active cursor in the originating text document. The keyboard remains usable for ordinary typing throughout the flow.
11. Before stopping a separate recording, move focus to another field in the same host document and verify the transcript is not inserted into an unintended field. Apple documents `UITextDocumentProxy.documentIdentifier` as a document identity, not a field identity, so this physical-device case remains a production acceptance gate.
12. Tap **Start Voice** again to prove the armed session can capture more than once without reopening Hex.
13. Switch away and back to **Hex** after insertion. The text must not insert a second time.

Record the phone model, iOS version, request ID, first insertion result, and second-activation result on [Prove one-time transcript insertion from the iOS keyboard](https://github.com/nmarch213/Hex/issues/9). Copy the displayed **Parakeet**, **Service before commit**, **Round trip**, **Return to insertion**, and **Stop to insertion** timings to [Establish the latency baseline and regression gate](https://github.com/nmarch213/Hex/issues/8); the first successful physical run becomes the prototype baseline. The server's OTEL request duration is the authoritative end-to-end service measurement because the client compatibility timing is captured before the durable completion commit.

## What this answers

- Whether the app and keyboard share the configured App Group on the real signing team.
- Whether mailbox state survives extension recreation.
- Whether `textDocumentProxy.insertText` delivers the Final Transcript at the active cursor.
- Whether the durable consumed marker prevents a second insertion attempt on keyboard reactivation.

If the armed session expires, Hex is killed, or its heartbeat disappears, the keyboard fails closed with **Arm with Action Button**. iOS does not expose a supported containing-app launch API to custom keyboards, so the App Shortcut is the supported foreground handoff.
