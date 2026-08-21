# Viable iOS Keyboard Dictation Flow

Research for [GitHub issue #2](https://github.com/nmarch213/Hex/issues/2), captured 2026-08-20. This note evaluates the public iOS platform surface against one requirement:

> On one personal iPhone, choose the Hex keyboard in any eligible text field, tap its microphone button, speak, and have the server-produced Final Transcript inserted at the cursor as quickly as possible.

The phone is English-only, the server is deliberately required, and offline fallback is out of scope. Tailscale transport and the Linux Transcription Model are separate decisions.

## Conclusion

The ideal interaction is **not implementable end to end with documented public iOS APIs**. Apple currently gives custom keyboards network access and a text-insertion proxy, but it denies them microphone access even when the user enables Full Access. Apple also does not document a custom-keyboard API for launching its containing app or returning automatically to the arbitrary app that owns the Text Destination.

The least-compromising architecture is therefore a **companion-app capture round trip**:

1. A lightweight custom keyboard displays the dictate action and ultimately performs Paste through `textDocumentProxy`.
2. The containing iOS app owns microphone permission and the Recording Session.
3. The containing app sends Captured Audio to Ronin, receives the Final Transcript, and writes a request-scoped result into an App Group container.
4. The user returns to the original app and reselects or reveals the Hex keyboard. The keyboard consumes the pending result and inserts it at the current cursor.

One transition remains a product choice:

- **Public-API-only:** the user must leave the host app and open the companion app manually. This is reliable but fails the one-tap requirement.
- **Private personal build:** isolate a best-effort keyboard-to-container launch shim, test it on the owner's exact iOS release, and accept that an OS update may break it. Do not depend on discovering the host app or returning to it programmatically; rely on the system's visible Back affordance or manual app switching. Apple documents URL opening from Today and iMessage extensions, not custom keyboards.

Because this project is deliberately private and installed on one phone, the second option is a reasonable **prototype**, but the unsupported transition must remain a replaceable edge adapter rather than a foundational domain capability. The supported core—capture in the app, request/result state in the App Group, server call, and insertion in the keyboard—should not depend on it.

There is one experimental path that could remain visually in the keyboard: pre-arm a continuously recording containing app, keep it alive with the audio background mode, and use App Group IPC to delimit a Dictation. Apple separately supports background recording in apps and App Group IPC, but does not document their combination as a keyboard-controlled recorder. It also implies an always-active microphone indicator, battery cost, restart/termination recovery, and an explicit arming step. Prototype it only to measure the UX; do not select it as the baseline architecture.

## Supported platform facts

### A custom keyboard cannot capture microphone audio

Apple's current open-access guide lists **no microphone or speaker access** among the custom-keyboard sandbox restrictions. Enabling `RequestsOpenAccess` preserves the basic keyboard restrictions while adding network access and shared-container writes; it does not grant microphone capture. Apple's earlier, still-published App Extension Programming Guide states the consequence directly: dictation input from a custom keyboard extension is unavailable. [Configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard), [App Extension Programming Guide: Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)

`UIInputViewController.hasDictationKey` does not change that boundary. It only indicates that a keyboard has a dictation key; when set, Apple says the system dictation key is disabled. It grants no audio capability and offers no audio stream to the extension. Leaving Apple's system dictation control available would use Apple's dictation path, not Hex's Captured Audio, server, or Final Transcript pipeline. [`hasDictationKey`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/hasdictationkey)

Therefore a keyboard-only design, an in-extension `AVAudioEngine`, and an in-extension speech recognizer are not viable supported architectures.

### The keyboard can insert returned text while it is active

A custom keyboard runs in a separate process and interacts with the host's text input only through `UITextDocumentProxy`. The proxy supports inserting a string at the insertion point, deleting backward, moving the insertion point, inspecting limited nearby context, and reading the selected text. It does not grant direct access to the host's text view. [Handling text interactions in custom keyboards](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards), [`textDocumentProxy`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/textdocumentproxy), [`UITextDocumentProxy`](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)

The delivery operation should consequently be one request-scoped call such as:

```swift
textDocumentProxy.insertText(finalTranscript)
```

The proxy represents the Text Destination that is current **when insertion occurs**. It is not a durable handle that the containing app can retain across an app switch. Pending results therefore need a request ID, completion state, and consumed flag in shared storage. On reactivation, the keyboard should reject stale or already-consumed results before inserting.

### “Whatever I am typing into” has unavoidable exceptions

iOS substitutes the system keyboard for secure text fields and phone/name-phone-pad fields. An app may also reject all third-party keyboards through `application(_:shouldAllowExtensionPointIdentifier:)`. The custom keyboard cannot override those choices. [Configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)

The product requirement should therefore read: **insert into the focused field wherever iOS permits third-party keyboards**, not literally every text field.

### Network and shared state require Full Access

By default, a custom keyboard has no network access and only read-only access to the containing app's shared group containers. To send data over the network and write shared state, the keyboard target must set `RequestsOpenAccess` to `true`, and the user must explicitly enable **Allow Full Access** for that keyboard in Settings. The runtime can inspect `UIInputViewController.hasFullAccess` and fail closed when it is false. [Configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard), [`hasFullAccess`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/hasfullaccess)

An App Group is the documented storage boundary for an app and its extension. Apple describes group containers as shared data storage and also permits additional IPC between same-team members of the group. Both the app and keyboard targets must carry the same App Group entitlement. [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)

Use the App Group as a small durable mailbox, not as a replacement for a long-lived service connection. A minimal record needs:

- request ID and creation time;
- state: requested, capturing, processing, completed, failed, or consumed;
- Final Transcript or a privacy-safe error code;
- enough destination identity to detect an obviously stale return, without storing surrounding user text.

For the companion-app round trip, the containing app should perform the audio upload and server request. Keyboard networking is then needed for availability checks or future direct requests, not for moving audio that the keyboard cannot capture.

### Extension lifecycle is hostile to long-lived workflow state

Apple launches the keyboard in a separate, memory-constrained process. The system terminates an extension that exceeds its memory limit, and dismissing the keyboard does not guarantee either immediate termination or continued survival. More generally, extensions must launch quickly; they do not receive background-audio execution, although a background `URLSession` transfer is available for suitable uploads/downloads. [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [Creating an App Extension](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)

Consequences for Hex:

- keep no authoritative Dictation state solely in the keyboard process;
- keep the Transcription Model and all audio capture out of the extension;
- make request creation, completion, and consumption idempotent;
- expect the keyboard controller to be recreated before the Final Transcript arrives;
- cancel UI observation when the keyboard disappears, while leaving the durable request state intact.

### The containing app is not a keyboard service process

Apple's extension architecture says there is no direct communication between an extension and its containing app and that the containing app typically is not running while the extension runs. Shared containers provide indirect communication. Apple's public `NSExtensionContext.open` documentation says URL opening on iOS is supported by Today and iMessage extension points; it does not list custom keyboards. The archived extension overview is more explicit that only a Today extension can ask iOS to open its containing app. [`NSExtensionContext.open`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)), [Understand How an App Extension Works](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)

Accordingly, there is no documented keyboard API to:

- launch the containing app on microphone-button tap;
- wake a suspended containing app as a general-purpose recorder;
- identify the arbitrary host app that owns the current text field; or
- programmatically return to that host after capture.

Responder-chain calls to application-opening selectors, host-process inspection, or private workspace APIs are outside the documented keyboard contract. Personal installation removes App Review as a concern, but it does not make those calls stable across iOS releases.

### A containing app may record in the background only after recording is active

An ordinary iOS app can use an `AVAudioSession` recording category after the user grants microphone permission. Apple says an app can continue recording after it enters the background when it declares the `audio` background mode. This capability belongs to the containing app, not the keyboard extension. [`AVAudioSession.Category.record`](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record), [`AVAudioSession`](https://developer.apple.com/documentation/avfaudio/avaudiosession)

This supports an experiment where the user explicitly opens and arms the containing app before returning to another app. It does **not** document a way for a suspended, nonrecording app to wake when the keyboard button is tapped. Keeping the app executable would require it to be actively recording already; treating the background mode as a generic keep-alive would not be a supported design.

### Network privacy and transport security still apply

App Transport Security applies to apps and app extensions and makes HTTPS the default for `URLSession`; a cleartext `http://` endpoint is blocked unless an exception is configured. The client/server contract should use authenticated HTTPS rather than broad ATS exceptions. [Preventing insecure network connections](https://developer.apple.com/documentation/security/preventing-insecure-network-connections)

Apple defines a local network as a network on a broadcast-capable interface such as Wi-Fi or Ethernet, explicitly excluding VPN interfaces. Because a Tailscale address is expected to route through a VPN interface, it likely does not itself trigger Local Network permission. That is an inference to verify on the physical phone. If the app also connects directly to a LAN address, it needs `NSLocalNetworkUsageDescription`; app extensions share the containing app's Local Network privilege, and the description belongs in the app's `Info.plist`. [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

## Architecture comparison

| Architecture | Public API status | Stays in host app while speaking | Meets Hex-server requirement | Main compromise |
| --- | --- | --- | --- | --- |
| Keyboard captures and uploads audio | Not supported | Yes in theory | Yes in theory | iOS denies microphone access to the keyboard |
| Apple system Dictation beside custom keyboard | Supported | Yes | No | Audio and transcription do not pass through Hex |
| User manually opens companion app, records, then returns | Supported | No | Yes | Multiple app-switch actions; misses one-tap UX |
| Keyboard opens companion through an undocumented shim, user returns manually | Unsupported transition; supported capture/storage/insertion | No | Yes | Can break on an iOS update; no supported automatic return |
| Pre-armed background containing app plus App Group IPC | Supported components, unproven composition | Yes after arming | Yes | Persistent mic/battery cost, lifecycle fragility, mandatory arming |

No architecture can be both public-API-only and fully satisfy “tap once in the keyboard and remain there while Hex captures microphone audio.”

## Recommended prototype sequence

1. **Prove the supported delivery seam first.** Build a containing app plus custom keyboard with App Group state. Seed a fake completed request in the app, activate the keyboard in Notes, and verify one-time insertion through `textDocumentProxy` after extension termination/relaunch.
2. **Prove Full Access and tailnet reachability on the physical phone.** Check `hasFullAccess`, call an authenticated HTTPS health endpoint, and record whether any Local Network prompt appears. Do not use the simulator as evidence for microphone or local-network privacy behavior.
3. **Build the supported manual round trip.** Record in the containing app, send Captured Audio, store the Final Transcript, manually return, and insert. This proves every durable boundary without a private API.
4. **Spike the private launch shim separately.** Its only contract is “request that iOS foreground the containing app.” Measure it on the owner's current iOS build and after each OS update. Failure must leave an instruction to open the app manually, not corrupt or lose a request.
5. **Only if the app switch remains unacceptable, spike pre-armed background capture.** Measure battery drain, microphone-indicator behavior, interruptions, phone lock, process termination, and command latency. Reject it if it requires silent audio, generic background keep-alive behavior, or undocumented entitlements.

The first latency baseline should begin at Stop and end after `insertText` returns, with separately recorded upload, server queue, Transcription, transform, response, app-switch, and keyboard-reactivation intervals. App-switch time must not be hidden inside server latency.

## Personal signing, installation, and updates

The app and its embedded keyboard extension must be code signed consistently. After installation, the user must enable the keyboard under **Settings > General > Keyboard > Keyboards** and separately enable **Allow Full Access**. [Creating an App Extension](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html), [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)

Three installation paths fit one private phone:

### Free Personal Team

Xcode can install directly using an ordinary Apple Account. Apple limits Personal Team provisioning profiles to seven days, after which the app must be rebuilt and reinstalled; it also limits active App IDs, devices, and installed development apps. App Groups and Background Modes are listed as supported iOS capabilities for the free Apple Developer tier, but the weekly reprovisioning makes this unsuitable as the daily keyboard. [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account), [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)

### Paid Developer Program with Xcode or Ad Hoc installation

A paid membership can register the personal phone and install development builds from Xcode, or export an Ad Hoc build for registered devices without App Store review. Updates are manual rebuild/reinstall operations. Direct Xcode installation requires Developer Mode; Apple also identifies installing an `.ipa` with Apple Configurator as a Developer Mode scenario. Ordinary TestFlight installation does not require Developer Mode. [Distributing your app to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices), [Create an Ad Hoc provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/), [Enabling Developer Mode on a device](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

### Paid Developer Program with internal TestFlight

Internal TestFlight can deliver the app privately to the account holder through the TestFlight app. Apple permits up to 100 internal App Store Connect testers; each build remains testable for 90 days. This avoids Developer Mode and provides the cleanest install/update experience, at the cost of uploading a fresh build before the 90-day window expires. [Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers), [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)

**Recommendation:** develop through direct Xcode installation, then use internal TestFlight for steady personal use if App Store Connect accepts the keyboard build and the owner is willing to refresh it at least every 90 days. Keep Ad Hoc as the private fallback. No public App Store listing is required.

## Remaining uncertainty requiring device evidence

These points are not settled by Apple's public documentation and should remain open until a physical-device prototype records them:

- Whether any best-effort container-launch shim works on the owner's exact iOS version, and whether it continues to produce a usable system Back affordance.
- Whether the keyboard extension remains alive during the entire server request, especially across host-app state changes; the architecture must work even when it does not.
- Whether Tailscale-routed traffic triggers Local Network privacy on the target iOS/Tailscale versions despite the VPN-interface definition in TN3179.
- Whether an actively recording background containing app can receive low-latency App Group IPC from the keyboard reliably enough to delimit Dictations, and its measured battery cost.
- Whether reinstallation or a particular update path preserves the enabled-keyboard and Allow Full Access settings on the personal phone.

None of these uncertainties weakens the central finding: the custom keyboard itself cannot own the Recording Session, so the ideal interaction necessarily depends on either an app transition or an already-running recorder outside the extension.
