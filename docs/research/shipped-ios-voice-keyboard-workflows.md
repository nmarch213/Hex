# Shipped iOS Voice-Keyboard Workflows

Research for Hex's mobile Dictation work and the glide-typing follow-up, captured 2026-08-21. The target is one personal English-only iPhone: tap a control, send audio to the authenticated Hex service on Ronin over Tailscale, and insert the server's Final Transcript into the focused field. This report focuses on workflows that have actually shipped or are documented by their vendors, the public iOS boundaries underneath them, and reusable foundations for a full custom keyboard.

The source priority is:

1. Apple's platform and review documentation for normative constraints.
2. First-party product support pages, release notes, privacy pages, and App Store listings for shipped-product behavior.
3. First-party open-source repositories and licenses for reusable foundations.

Product documentation is self-reported. It is evidence of the promised or supported workflow, not proof of the private implementation. In particular, no vendor page examined here discloses the exact mechanism it uses to start or resume a containing app from a keyboard extension. Claims marked **inference** are architectural conclusions from the documented behavior and Apple's APIs, not claims about private selectors or source code.

## Executive answer

There are four useful patterns:

| Pattern | What the user experiences | Fit for Hex |
| --- | --- | --- |
| Warm containing-app session | Open Hex once, arm a visible microphone session, return to the source app, then tap the Hex keyboard's Dictate button repeatedly without another app switch | Best match for the desired one-tap flow. Willow documents this explicitly; Wispr documents a related idle-session model. It costs a visible mic indicator, battery, and a cold-start/timeout path. |
| Full custom keyboard plus direct insertion | Hex stays selected as the keyboard for normal typing and Dictation; the extension calls `textDocumentProxy.insertText` with the authenticated result | The right primary product shape. It is also how the shipped keyboard products describe their normal delivery. It requires building keyboard behavior ourselves. |
| Action Button/App Shortcut | Press the iPhone 16 Pro Action Button to start/stop Hex from outside the keyboard | The best independent cold-start escape hatch. It avoids the fragile keyboard-to-app handoff, but an App Intent cannot be assumed to retain a host text-field insertion handle. Clipboard is the reliable fallback when no keyboard proxy is active. |
| Apple keyboard as the glide escape hatch | Use the globe key to return to Apple's keyboard and QuickPath | The fastest way to offer excellent glide typing. Apple's QuickPath recognizer is not a public API for third-party keyboards. |

For the fastest Hex prototype, keep the existing full QWERTY keyboard and direct-insertion path, make the containing app own the microphone and Ronin request, and prototype a **warm armed session**. Retain an explicit cold-start screen and an Action Button shortcut. Do not block the core Dictation milestone on implementing QuickPath. Keep Apple's keyboard one globe tap away while a Hex glide engine is evaluated separately.

## Evidence levels and important caveats

- **Apple** means a documented public platform or review rule.
- **Vendor** means a first-party support page, release note, privacy page, or App Store listing. The vendor may omit implementation details.
- **Repository** means a first-party source repository and its declared license.
- **Inference** means a conclusion that is useful for Hex design but is not directly stated by the source.
- App Store descriptions and latency numbers are vendor-authored marketing material. They are useful for interaction mapping but not an independent benchmark.
- A private sideload can avoid App Store review, but it does not make private iOS APIs stable or turn an undocumented transition into a supported contract.
- The product pages below change over time. Re-check the exact iOS build and product version on the physical phone before making a release decision.

## 1. The public iOS substrate

### A custom keyboard cannot own the microphone

Apple's current open-access documentation describes a custom keyboard as an isolated extension process. Full Access enables network access and writes to an App Group container, but it does not grant the extension microphone or speaker access. Apple's archived Custom Keyboard guide states the consequence plainly: custom keyboards cannot provide dictation input themselves. [Apple: configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard), [Apple: Custom Keyboard App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)

The containing application must therefore own microphone permission, `AVAudioSession`, capture, and the upload to Ronin. Apple documents recording in the background after the app has started a recording session and declared the `audio` background mode. That is an app capability, not a keyboard-extension capability. [Apple: `AVAudioSession.Category.record`](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record), [Apple: `AVAudioSession`](https://developer.apple.com/documentation/avfaudio/avaudiosession)

**Inference for Hex:** the keyboard should publish a request into a small App Group mailbox. The app should consume the request, capture and upload audio, and publish a request-scoped result. A keyboard tap cannot, through the documented API, turn a dormant extension into a microphone recorder.

### The supported text-delivery seam is direct insertion

Custom keyboards run in a separate process and interact with the current host field through `UITextDocumentProxy`. The supported operation for the final result is:

```swift
textDocumentProxy.insertText(finalTranscript)
```

The proxy also supports deletion, selected text, limited surrounding context, and moving the insertion point. It is not a durable handle that the containing app can retain across an app switch. [Apple: handling text interactions in custom keyboards](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards), [Apple: `UIInputViewController.textDocumentProxy`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/textdocumentproxy), [Apple: `UITextDocumentProxy`](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)

**Inference for Hex:** the keyboard must perform the final insertion while it is active and while the destination field is still the current field. The app should never be the component that assumes it can insert into a field after returning from Ronin. The App Group record should include a request ID, state, creation time, result or privacy-safe error, and consumed marker. It should not retain a host-app proxy or surrounding text as a substitute for one.

### Third-party keyboards have field and host-app exceptions

Secure text fields and phone/name-phone-pad fields use the system keyboard. A host application may also reject third-party keyboards entirely. Apple expects a custom keyboard to adapt to the current `UIKeyboardType`, provide a way to switch keyboards, and supply common behavior such as capitalization and deletion. [Apple: configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface), [Apple: creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)

The literal product requirement should consequently be: **insert into the focused field wherever iOS permits a third-party keyboard**, not every possible text field.

### Full Access is a real privacy boundary

By default, a custom keyboard has no network access and cannot write to the shared App Group container. Setting `RequestsOpenAccess` and asking the user to enable **Allow Full Access** changes that. Apple warns that a full-access keyboard can send keystrokes or other input data to a server, so the user must understand the privacy consequence. [Apple: configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard), [Apple App Review Guidelines, keyboards](https://developer.apple.com/app-store/review/guidelines/)

For Hex, Full Access should be needed only for the App Group mailbox and any direct authenticated request required by the implementation. The microphone audio should remain in the containing app. The keyboard should fail closed and show a specific setup error when Full Access is absent; it should not silently upload arbitrary surrounding text.

### Launching the containing app from a keyboard is not a public contract

Apple's `NSExtensionContext.open` documentation describes the extension points for which URL opening is supported; it does not promise a custom-keyboard-to-containing-app transition. Apple's review guidance also says a keyboard must remain functional without Full Access and must not launch other apps except Settings. [Apple: `NSExtensionContext.open`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)), [Apple App Review Guidelines, keyboards](https://developer.apple.com/app-store/review/guidelines/)

**Inference:** a personal build may experiment with a URL scheme and measure it on one OS version, but that transition must remain a replaceable best-effort adapter. The durable architecture must also work when the user opens Hex manually. Do not use a responder-chain trick, host-process inspection, or private workspace selector as a domain capability.

### QuickPath is not exposed to third-party keyboards

Apple's public custom-keyboard surface asks the extension to provide its own interface, respond to its own taps/gestures, and emit text through the proxy. The public API exposes `advanceToNextInputMode()` for switching keyboards; it does not expose Apple's keyboard view or QuickPath decoder. Apple does not state this as a single “QuickPath unavailable” sentence, so the conclusion is an **inference from the public surface**, not a reverse-engineered claim. [Apple: creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [Apple: `UIInputViewController`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller)

Therefore we cannot embed Apple's QuickPath recognizer in Hex through a supported API. A Hex keyboard needs its own touch-path capture and decoder, or the user needs one globe tap to return to Apple's keyboard.

## 2. Tap-by-tap workflows in shipped products

The matrix intentionally says **not documented** where a vendor page does not establish a behavior. It is safer than filling the gap with an assumption about private implementation.

| Product | Cold workflow | Warm/background workflow | Return/switch behavior | Delivery and ordinary typing | Permissions / platform notes |
| --- | --- | --- | --- | --- | --- |
| **Apple Dictation** | Focus a text field, keep Apple's keyboard visible, tap the system microphone, speak, and stop. | The keyboard remains present while dictating; typing and voice input coexist. | No third-party keyboard or app handoff. | Text is inserted by Apple's system Dictation, not through Hex or Ronin. | Apple documents this as the baseline system experience. [Apple: dictate text on iPhone](https://support.apple.com/guide/iphone/dictate-text-iph2c0651d2/ios) |
| **Wispr Flow** | Install and enable Flow Keyboard, enable Full Access, grant mic permission, switch to Flow, and tap its mic. If the Flow session is dormant, the app may briefly become active; the current fallback can require a bottom-edge swipe back before speaking. | Wispr documents an idle Flow session with timeout choices of immediately, 5 minutes, 15 minutes, 1 hour, or never. The microphone is released after a Dictation; the session indicator can remain. | Globe picker/ABC returns to another keyboard. Wispr documents iOS 26.4 manual swipe-back behavior and a later release note claiming automatic switchback on supported iOS versions, including iOS 27. | Full QWERTY is a staged option; otherwise Flow is voice-first. Wispr says the final transcript goes to the cursor or replaces the selection, not through the iOS clipboard. | Full Access and main-app mic permission are required. Wispr's docs say not to leave the Flow keyboard while the result is being inserted. [Wispr: iPhone setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone), [Wispr: setup guide](https://docs.wisprflow.ai/articles/3152211871-setup-guide), [Wispr: text insertion troubleshooting](https://docs.wisprflow.ai/articles/7971211038-fix-text-not-pasting-after-dictation), [Wispr: iOS 26.4](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4), [Wispr: current release notes](https://wisprflow.ai/whats-new), [Wispr: mic indicator and session timeout](https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios) |
| **Willow** | Enable the Willow keyboard, Full Access, and microphone. Willow says iOS requires the user to open Willow first, activate its background microphone session, and then return to the source app. | While that session remains alive, tap Willow's mic in the source app and move between apps without another pullback. The session can stop through the Live Activity, the app, force quit, or timeout. | A cold activation requires the app round trip; the warm path does not. The yellow mic indicator/Live Activity is intentionally visible. | Willow's App Store listing says it works in any text field and the support docs describe its custom voice-first keyboard. Its docs explicitly warn that its autocorrect lacks Apple's keyboard's personalized model. Full-QWERTY parity and the exact insertion API are not publicly documented here. | Full Access and mic permission are required. The background session trades handoff friction for a persistent microphone indicator and lifecycle/battery cost. [Willow: cold activation requirement](https://help.willowvoice.com/en/articles/12855752-why-am-i-taken-back-to-the-willow-ios-app-before-i-can-dictate), [Willow: microphone indicator](https://help.willowvoice.com/en/articles/12855770-why-do-i-see-the-yellow-microphone-indicator-or-floating-island-that-says-on-when-i-use-willow-on-ios), [Willow: permissions](https://help.willowvoice.com/en/articles/12845807-setting-up-permissions-on-ios-keyboard-access-full-access-microphone), [Willow: autocorrect limitations](https://help.willowvoice.com/en/articles/12855792-why-does-willow-s-keyboard-autocorrect-feel-different-from-the-willow-ios-keyboard), [Willow App Store listing](https://apps.apple.com/us/app/willow-dictation-ai-keyboard/id6753057525) |
| **Superwhisper** | Install its iOS keyboard, tap the keyboard dictation control, and follow its app/keyboard flow. Superwhisper's current iOS 26.4 guidance says the automatic return can fail and the user must swipe back manually before speaking. | A warm-session workflow is not documented in the public iOS guidance examined here. | Superwhisper independently reports that iOS 26.4 stopped allowing its keyboard to return automatically to the previous app; it tracks an Apple feedback item. | The product page promises formatted text in any app, but the public docs do not disclose whether that is direct proxy insertion or an internal clipboard fallback. Swipe typing/full-QWERTY behavior is not documented; community requests for swipe typing are not product evidence. | Treat the 26.4 manual swipe as a real compatibility case, not a Wispr-only quirk. [Superwhisper: iOS 26 keyboard changes](https://superwhisper.com/docs/common-issues/ios-26-keyboard-changes), [Superwhisper iOS](https://superwhisper.com/ios), [Superwhisper community swipe request (secondary)](https://feedback.superwhisper.com/board/p/ios-keyboard-enhancements) |
| **Grammarly** | With Grammarly active, tap the mic in its toolbar. Grammarly briefly shows a branded recording screen; on iOS 26 the user may need to swipe back to the source app before speaking. Stop recording and the transcript appears in the field. | No persistent/background keyboard microphone session is documented in its speech-to-text guide. | Manual swipe-back is the documented iOS 26 fallback. | Grammarly documents a full native-style keyboard with swipe typing and says speech text appears in the current field after stopping; it does not document a clipboard path. Speech-to-text requires internet and does not retain a dictation history or recording. | Use its full-keyboard and post-dictation UX as a reference, not its cloud/privacy posture. [Grammarly: speech-to-text](https://support.grammarly.com/hc/en-us/articles/46245126716941-Introducing-speech-to-text), [Grammarly: keyboard features](https://support.grammarly.com/hc/en-us/articles/360009187612-How-does-the-Grammarly-Keyboard-work-on-iPhones), [Grammarly: keyboard settings and swipe typing](https://support.grammarly.com/hc/en-us/articles/360041391992-Managing-your-keyboard-settings-in-Grammarly-for-iPhone), [Grammarly speech-to-text](https://www.grammarly.com/speech-to-text) |
| **Gboard** | Add Gboard, focus a field, tap its microphone, say “Speak now,” and stop. Gboard's help page also documents selecting a word and dictating a replacement. | A separate warm/background session is not documented by the iOS help pages examined. | Globe picker is the ordinary system keyboard switch; no app handoff is described. | Gboard is a complete QWERTY keyboard with a documented **Glide typing** setting and voice input. The help page describes text appearing in the field, but not the private insertion implementation. | Good UX reference for normal typing plus voice; not evidence that a custom keyboard can capture Hex audio or reach Ronin. [Gboard: voice typing on iOS](https://support.google.com/gboard/answer/2781851?co=GENIE.Platform%3DiOS&hl=en), [Gboard: Glide typing and Voice input](https://support.google.com/gboard/answer/6102154?co=GENIE.Platform%3DiOS&hl=en), [Gboard: keyboard input](https://support.google.com/gboard/answer/2842292?co=GENIE.Platform%3DiOS&hl=en) |
| **Microsoft SwiftKey** | With SwiftKey active, tap the toolbar microphone or long-press the comma key, speak, and tap the mic again to stop. | The iOS support page describes simultaneous talking and typing, but does not establish a containing-app background session or a cold/warm handoff. | Globe picker is the ordinary switch; no app-return behavior is documented. | SwiftKey documents a normal keyboard, **Flow** glide typing, and voice input. Microsoft warns on its voice-typing page that voice clips may be sent to Microsoft speech services; verify the current iOS scope before using it as a privacy model. | Strong reference for the “normal keyboard + voice button” interaction; not a reusable implementation. [Microsoft: SwiftKey voice typing](https://support.microsoft.com/en-us/swiftkey-keyboard/how-do-i-use-voice-to-text-with-microsoft-swiftkey-keyboard), [Microsoft: SwiftKey setup and Flow](https://support.microsoft.com/en-US/swiftkey-keyboard/how-to-set-up-microsoft-swiftkey-keyboard) |
| **Aqua Voice** | Install Aqua Keyboard, open any app, tap its mic, speak, and receive text in the field. The iOS product also documents editing the last transcript or current selection with voice. | No public iOS warm/background microphone workflow is documented. | No app-return behavior is documented. | Aqua markets a full voice keyboard and voice-edit mode. Its own realtime page says the desktop “Realtime” and “send it” commands do not work on iPhone; do not carry the desktop architecture onto iOS. [Aqua's iOS article](https://aquavoice.com/blog/aqua-voice-for-ios), [Aqua App Store listing](https://apps.apple.com/us/app/aqua-voice-ai-dictation/id6759074969), [Aqua realtime limitations](https://aquavoice.com/realtime) | Cloud/privacy behavior differs by mode; its privacy page says default sessions may be collected to improve the product and offers a privacy mode. This is not compatible with Hex's Ronin-only boundary without a different implementation. [Aqua privacy](https://aquavoice.com/info/privacy) |
| **Whispr / other emerging keyboards** | App Store listings for Whispr claim: enable the custom keyboard, tap its mic, and receive on-device text in any app; one listing also mentions a Live Activity recording state. | Cold/warm session behavior is not documented well enough to rely on. | Not documented. | Useful market evidence that an on-device voice-first keyboard and a Live Activity can be shipped, but the listing is vendor-authored and does not expose its architecture. | Treat as a low-confidence interaction reference, not a platform capability. [Whispr App Store listing](https://apps.apple.com/us/app/whispr-voice-keyboard-text/id6757571618) |

### What iOS 26/27 changes mean for Hex

Wispr's iOS 26.4 guide, Superwhisper's iOS 26.4 compatibility note, and Grammarly's speech-to-text guide independently describe a break or regression in the automatic return to the source app. Wispr's current release notes say automatic switchback works on supported versions including iOS 27, but that is a product-version claim, not a promise made by Apple's custom-keyboard API. The right product behavior is therefore:

1. Attempt the best supported/current path.
2. Show a clear “return to the source app” state with a bottom-edge swipe instruction when the source app is not restored.
3. Keep the request pending and make a manual-open path safe.
4. Never interpret “automatic switchback worked on my build” as a durable API guarantee.

## 3. Direct insertion versus clipboard

The public keyboard contract favors direct insertion. Apple's proxy inserts into the current field; Wispr explicitly distinguishes iOS direct insertion from clipboard behavior, and Grammarly, Aqua, and Whispr describe text appearing in the active field. A containing app cannot retain the proxy across an app switch, so an app-owned transcript should be written to shared state and consumed by the keyboard after it is active again.

Clipboard remains valuable in two cases:

- An Action Button/App Intent starts a capture when no custom keyboard proxy is active.
- The user dictates from the app itself or the focused field has been lost.

Clipboard should be an explicit fallback with a visible “Copied to clipboard” result, not a silent replacement for direct insertion. It can overwrite the user's existing clipboard and cannot reliably preserve cursor/selection semantics. For the ordinary Hex keyboard path:

1. The keyboard creates a request ID in the App Group.
2. The containing app owns capture and sends audio to Ronin.
3. The app publishes a completed result for that request.
4. The still-active keyboard validates the request, inserts the Final Transcript through `textDocumentProxy.insertText`, and marks it consumed.

The state must be idempotent because the extension can be recreated or killed while the app is processing. This is architectural guidance derived from Apple's process model, not a vendor implementation claim.

## 4. A functional keyboard and glide typing

### What “a normal keyboard” means for Hex

Apple's custom-keyboard guidance says users expect a keyboard-switch affordance, appropriate layouts for input types, capitalization, deletion, return, autocorrection/suggestions, and support for varying widths. A minimally credible Hex keyboard therefore needs:

- letter, number, symbol, Shift, Caps Lock, Delete, Space, Return, and Globe/next-keyboard controls;
- dynamic handling for at least ASCII, email, URL, number, and punctuation input traits;
- visible press feedback and long-press alternatives for accents/symbols;
- cursor movement or space-bar cursor behavior if that is part of the chosen UX;
- a clear Dictate action with idle, requesting, recording, processing, unavailable, completed, and failed states;
- a direct insertion path that does not require users to copy and paste.

The custom keyboard owns this UI. It does not inherit Apple's autocorrection, personalization, or QuickPath just because it is enabled as a keyboard. Apple exposes `UILexicon` and limited surrounding text to help an extension build its own suggestions, but there is no dedicated API for the system keyboard's complete feature set. [Apple: creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [Apple: configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface), [Apple: archived custom-keyboard guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)

### QuickPath conclusion

We should not spend time looking for a public “turn on Apple's QuickPath for my extension” switch. None of the public APIs above expose Apple's keyboard view, recognizer, lexicon model, or swipe decoder. Third-party keyboards such as Gboard, SwiftKey, and Grammarly prove that a glide experience can be built, but they do not make Apple's implementation reusable.

The practical options are:

1. Keep the Apple globe key as the high-quality glide path while Hex voice typing is the priority.
2. Build a small English-only swipe decoder ourselves.
3. Port a separately licensed/open-source decoder such as FUTO Swipe and own the iOS touch capture and keyboard integration.

### Open-source and licensed foundations

| Foundation | What it actually provides | License/capability check | Hex assessment |
| --- | --- | --- | --- |
| [KeyboardKit](https://github.com/KeyboardKit/KeyboardKit) | Swift/SwiftUI custom-keyboard controller, native-looking keyboard rendering, layouts, actions, proxy helpers, App Group/deep-link setup, status and dictation orchestration. | The current repository says it is a binary framework and calls itself “closed-source.” The repository's [license](https://github.com/KeyboardKit/KeyboardKit/blob/main/LICENSE) allows starting for free but reserves Pro features for a valid license and prohibits distributing or using source obtained elsewhere. Its current release notes also say KeyboardKit 10 requires a license file or key. | Do not treat it as an MIT dependency or copy its source into Hex. It could accelerate rendering if its license fits the private project, but it does not remove Apple's microphone boundary or supply Apple's QuickPath. For the fastest prototype, the current Hex keyboard is simpler and avoids a new licensing dependency. |
| [SnipKey](https://github.com/jtvargas/SnipKey) | A real iOS app plus keyboard extension. Its README documents a full QWERTY implementation, UIKit touch areas, key feedback, direct character-by-character proxy insertion, keyboard process constraints, and App Group/notification patterns. | The repository declares the [MIT license](https://github.com/jtvargas/SnipKey/blob/main/LICENSE). It does not provide a voice recorder or a swipe decoder; its “next-generation touch engine” improves tap hit resolution rather than decoding a continuous swipe. | Useful MIT reference for a functional QWERTY keyboard and touch ergonomics. Borrow ideas or code only after auditing the current revision and preserving attribution. It is not a QuickPath solution. |
| [FUTO Swipe](https://swipe.futo.tech/) | A compact encoder/decoder/context-language-model family plus a C++ inference library that maps swipe paths to dictionary-constrained word predictions. The current public decoder is English QWERTY; the encoder is layout/language-agnostic. | FUTO says the dataset is MIT, but the model weights use the [FUTO Model License](https://huggingface.co/futo-org/futo-swipe) and the inference library is GPL. The site says the models are permissive with attribution and the library is GPL; those are different obligations. | Best technical starting point for an English glide experiment, but not a drop-in iOS package. Hex would need Swift/Objective-C++ bridging, touch-path capture, layout normalization, dictionary/context handling, model packaging, and a license decision around GPL/library linkage and model attribution. Keep it behind a later experiment. |
| [Dasher-Apple](https://github.com/dasher-project/Dasher-Apple) | MIT-licensed iOS/macOS/visionOS front end with a custom keyboard extension and a C++ DasherCore engine for continuous pointing input, accessibility, eye gaze, switches, joystick, and touch. | The repository says the iOS app and keyboard are in active development, beta, and not yet on the App Store. The repo and bundled DasherCore are MIT. | Interesting “other keyboard-level input” research, not a normal QWERTY or QuickPath replacement. Too different and immature for the fastest Hex prototype. |
| [azooKey](https://github.com/azooKey/azooKey) | A substantial Swift open-source Japanese iOS/iPadOS keyboard with its own Kana–Kanji conversion engine, live conversion, layouts, app target, and extension. | The repository declares MIT, but its language model and conversion engine are Japanese-specific. | Good architecture reference for a full keyboard and conversion pipeline; not a useful English glide or voice component without replacing most of the engine. |

The shipped Gboard, SwiftKey, and Grammarly apps remain useful UX references for a normal keyboard plus a mic control. Their implementations are proprietary and should not be copied. For a personal build, “open source” still requires checking each dependency's actual license, model-weight terms, attribution requirements, and whether GPL code is acceptable in the chosen distribution path.

## 5. Other keyboard-adjacent input controls

### Action Button and App Shortcuts

App Shortcuts can expose an intent to Siri, Spotlight, Shortcuts, and the Action Button on supported iPhones. Apple's hardware-interactions documentation explicitly describes associating an App Shortcut with the Action Button; Apple's iPhone guide identifies the Action Button on iPhone 15 Pro and later, which includes an iPhone 16 Pro. [Apple: App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts), [Apple: hardware interactions](https://developer.apple.com/documentation/appintents/hardware-interactions), [Apple: Action Button](https://support.apple.com/en-us/111772)

Wispr documents a “Quick Dictation to Clipboard” Action Button shortcut that starts dictation from a text field and falls back to the clipboard when there is no field. That is a strong interaction pattern for Hex, but the clipboard behavior should be stated honestly: an App Intent is not guaranteed to have the custom keyboard's current `textDocumentProxy`. [Wispr: Action Button setup](https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone)

Recommended Hex intent shape:

- **Start Hex Dictation**: foreground/arm the containing app if necessary, begin a visible recording session, and send the result to Ronin.
- **Stop Hex Dictation**: stop, wait for the authenticated result, and copy it to the clipboard if no active keyboard proxy can consume it.
- If the keyboard remains the current responder, let the keyboard consume the request and insert directly instead of copying.

This is not a replacement for the keyboard, but it creates a reliable escape hatch when iOS refuses a keyboard-to-app handoff.

### Back Tap and Shortcuts

iOS can run a shortcut from a double- or triple-tap on the back of the device. It is less discoverable than the Action Button but useful for experiments or for a phone case that makes the Action Button awkward. [Apple: Back Tap](https://support.apple.com/en-us/111772), [Apple: run shortcuts with Back Tap](https://support.apple.com/en-euro/guide/shortcuts/apd897693606/ios)

### System Dictation

Apple Dictation is the only path that keeps the stock keyboard and its typing behavior together with voice without a custom app switch. It cannot be pointed at Ronin or Parakeet, so it is a UX baseline and fallback, not a Hex implementation.

## 6. What is safe to reproduce for one personal device

This is engineering guidance, not legal advice.

The following are public primitives and interaction patterns we can use:

- `UIInputViewController`, `UITextDocumentProxy.insertText`, deletion, selected text, and `advanceToNextInputMode()`;
- an App Group mailbox between the containing app and keyboard extension;
- Full Access with an explicit explanation of why Hex needs it;
- microphone permission, an app-owned `AVAudioSession`, and a declared `audio` background mode;
- App Intents/App Shortcuts for the Action Button and Shortcuts;
- a visible warm-session microphone indicator and explicit timeout/stop control;
- the general interaction idea “tap a mic, speak, receive formatted text, and keep normal typing available.”

The following should not become dependencies or assumptions:

- Apple's private QuickPath model or keyboard view;
- private responder-chain/workspace selectors to launch or switch apps;
- Wispr, Willow, Grammarly, Gboard, SwiftKey, or Aqua code/assets/trademarks;
- a claim that Full Access grants microphone access to the extension;
- a claim that a custom keyboard can always identify or return to its host app;
- unreviewed FUTO model/library code without honoring its model license, GPL terms, and attribution requirements.

Apple's App Store keyboard rules are stricter than the personal-device requirement, but they are still useful as a design smell: the keyboard should remain useful without network/full access, provide keyboard switching, and avoid unexpected app launching. [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## 7. Recommendation for the fastest Hex prototype

### Primary path: a Willow-like warm session, with Hex's server boundary

1. The user opens Hex once and taps **Arm voice**. Hex requests microphone permission, establishes an app-owned recording session, and shows a visible Live Activity/microphone state.
2. The user returns to the source app and selects Hex as the keyboard. The keyboard renders full QWERTY plus a prominent Dictate button and Globe escape.
3. A Dictate tap writes a request ID into the App Group. It does not attempt to capture audio in the extension.
4. The containing app owns capture, sends Captured Audio to Ronin over the authenticated Tailscale path, and writes the Final Transcript into the request record.
5. While Hex is still the active keyboard, the extension consumes that exact request and calls `textDocumentProxy.insertText`. The request becomes consumed exactly once.
6. The warm session has a short explicit timeout (start with 5 or 15 minutes), a Stop button, and a clear cold-start instruction. If Hex is killed, Full Access is missing, or Ronin is unavailable, the keyboard shows unavailable/pending and does not invent offline text.

This gives the desired tap-to-speak experience without claiming that a keyboard extension can own the microphone. It deliberately accepts the yellow/orange microphone indicator and some battery cost. Test those costs rather than hiding them.

### Cold path: Action Button plus clipboard/direct insertion

Add an App Shortcut for **Start/Stop Hex Dictation**. On a cold session it can foreground Hex and acquire the microphone permission. If the keyboard proxy remains available, publish the result for direct consumption; otherwise copy the result to the clipboard and say so. This should be treated as a separate entry point, not as proof that `extensionContext.open` is reliable from the keyboard.

### Typing path: use the existing keyboard, then evaluate swipe separately

Keep the Hex full QWERTY implementation as the normal typing surface and keep Globe visible. Do not pull KeyboardKit into the critical path without a license decision. If issue #12 still requires native-feeling glide typing after warm Dictation is measured, run a small experiment with FUTO Swipe or an in-house English decoder. SnipKey is a better MIT reference for keyboard touch/layout behavior than a glide engine.

### Test matrix before calling the prototype fast

- cold Hex app → arm → return to Notes/Messages/Slack;
- warm one-tap Dictation repeatedly until timeout;
- app killed, keyboard extension recreated, phone locked/unlocked, and audio interrupted by a call;
- Ronin/Tailscale unavailable: verify the keyboard fails closed and does not insert stale text;
- direct insertion into a normal text field, selected text, empty field, long text, and multiline field;
- secure/password, phone, number, email, URL, and apps that reject third-party keyboards;
- iOS 26.4-style manual swipe-back and the target iOS 27 build;
- Action Button cold-start and no-focused-field clipboard fallback;
- microphone indicator, Live Activity, battery impact, and end-to-end latency split into capture, upload, server, and insertion intervals.

The first performance bar should be the fastest successful warm-session path from the Dictate tap to `insertText` completion. Cold app activation and swipe-back time should be reported separately rather than hidden inside the Parakeet/Ronin latency.

## 8. Local Hex observation (not vendor evidence)

During the current Hex prototype investigation, the keyboard's `extensionContext.open` attempt returned `false` repeatedly on the tested iOS 27 simulator/phone profile, while an external `simctl openurl` invocation could launch the main app. The keyboard mailbox remained in a pending/capture-requested state. Private responder-chain/Objective-C launch probes were not a stable alternative and could terminate the extension.

This observation is consistent with Apple's documented lack of a custom-keyboard launch guarantee and with Wispr/Superwhisper's documented need for manual fallback on some iOS 26.4 flows. It does **not** prove how any vendor implements its private or version-specific handoff. The engineering consequence is the same: keep cold activation as an explicit supported/manual path and put the product effort into a warm session plus reliable request/result insertion.

## Related Hex research

- [Wispr Flow iOS keyboard workflow](wispr-flow-ios-keyboard-workflow.md) — focused source-backed Wispr flow and Apple constraints.
- [Viable iOS keyboard dictation flow](ios-keyboard-dictation.md) — public API boundary, App Group mailbox, and manual-round-trip architecture.
- [Hex architecture current system](../architecture/current-system.md) — repository vocabulary and current mobile/server direction.
