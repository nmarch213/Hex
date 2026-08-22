# Personal Dictation Tracer

> **Throwaway prototype.** This exists to answer Wayfinder questions, not to become production code.

This vertical-slice tracer proves the shortest supported iOS path:

1. The containing app keeps an explicitly armed audio session alive and records an English WAV when the keyboard requests it.
2. It uploads the WAV to a private Hex proxy on Ronin.
3. The proxy invokes `parakeet.cpp` with the exact `tdt-0.6b-v2` model alias.
4. As temporary tracer instrumentation, the app runs the real Hex word-removal, remapping, and formatting code.
5. An App Group mailbox carries start/stop commands and exposes the Final Transcript to the custom keyboard.
6. The keyboard verifies the originating text field, durably marks the transcript consumed, and inserts it once.

iOS does not give custom keyboard extensions microphone access. The containing app therefore owns capture while the keyboard controls it through the App Group. The user first runs the **Arm Hex** App Shortcut—ideally from the iPhone Action Button—and swipes back once. iOS shows the orange microphone indicator while the 15-minute session is armed.

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

`make validate` regenerates the project, type-checks both Swift 6 targets, and asserts the URL scheme, keyboard Full Access declaration, and matching App Group entitlements without invoking the local simulator stack.

## Ronin service

Copy `server/.env.example` to `server/.env`, replace the prototype token with a long random value, and run:

```bash
make server
```

The Compose service binds only to Ronin loopback on port 8787. Expose that loopback service through Tailscale Serve at `https://ronin.tail451960.ts.net:8443`; Ronin's existing HTTPS service retains port 443. Do not enable Funnel.

## Physical-iPhone check

1. In Xcode, select your personal development team for both targets. Keep both targets under the same team.
2. If the default identifiers are unavailable, change both bundle identifiers and change `PrototypeMailbox.appGroupID` plus both entitlements to one matching App Group.
3. Run **Hex Keyboard Tracer** on the phone once.
4. Add **Hex Prototype** under **Settings → General → Keyboard → Keyboards → Add New Keyboard**.
5. Enable **Allow Full Access** so the keyboard can use the shared command and transcript container.
6. Enter the Ronin bearer token. In **Settings → Action Button**, choose **Shortcut**, then select the **Arm Hex** App Shortcut.
7. Return to a text field and hold the Action Button. Hex opens and arms automatically; swipe back when Hex says it is armed. The token is stored in the device Keychain; the server origin is pinned in the prototype.
8. Select **Hex Prototype** with the globe key. Its status should read **Voice ready**.
9. Tap **Start Voice**, speak, then tap the red **Stop Voice** button in the keyboard. Keep the keyboard visible while it transcribes.
10. The Final Transcript should insert automatically into the field where Start Voice was tapped. The keyboard remains usable for ordinary typing throughout the flow.
11. Tap **Start Voice** again to prove the armed session can capture more than once without reopening Hex.
12. Switch away and back to **Hex Prototype** after insertion. The text must not insert a second time.

Record the phone model, iOS version, request ID, first insertion result, and second-activation result on [Prove one-time transcript insertion from the iOS keyboard](https://github.com/nmarch213/Hex/issues/9). Copy the displayed **Parakeet**, **Service total**, **Round trip**, **Return to insertion**, and **Stop to insertion** timings to [Establish the latency baseline and regression gate](https://github.com/nmarch213/Hex/issues/8); the first successful physical run becomes the prototype baseline.

## What this answers

- Whether the app and keyboard share the configured App Group on the real signing team.
- Whether mailbox state survives extension recreation.
- Whether `textDocumentProxy.insertText` delivers the Final Transcript at the active cursor.
- Whether the durable consumed marker prevents a second insertion attempt on keyboard reactivation.

If the armed session expires, Hex is killed, or its heartbeat disappears, the keyboard fails closed with **Arm with Action Button**. iOS does not expose a supported containing-app launch API to custom keyboards, so the App Shortcut is the supported foreground handoff.
