# iOS input surfaces for Hex remote dictation

Research date: 2026-08-21. This report covers the public iOS APIs documented for iOS 17 through the current iOS 27 beta documentation. It is deliberately scoped to Apple primary sources: UIKit and Foundation documentation, SDK headers, Apple platform and security documentation, Apple Support, and WWDC sessions.

The target is a personal, single-device iPhone client that can send English audio to a Parakeet service over Tailscale and put the resulting text into whatever field currently has the insertion point. The server is required: there is no offline fallback. The prototype should be as fast as possible, but should not depend on a private API that can disappear on the next OS update.

## Executive conclusion

There is no public Apple-supported one-tap path that satisfies all of these requirements at once. iOS intentionally separates the two capabilities we need:

1. An active [custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard) is given a narrowly scoped `UITextDocumentProxy`, which can insert text at the current cursor.
2. An app (or a suitably privileged app-owned extension) can request microphone access, run networking, and send audio to a server.

The custom keyboard cannot use the microphone, even when the user grants it Full Access. The containing app cannot normally be opened by a custom keyboard: Apple documents `NSExtensionContext.open` as extension-point-specific and lists Today and iMessage as the iOS extension points that support it, not custom keyboards. There is also no public API that transfers a host app's current text-field proxy to the containing app or lets an App Intent return text into an arbitrary host cursor.

The best supported Hex design therefore remains a two-part system:

- the containing app owns recording, the Tailscale connection, and Parakeet;
- the keyboard owns insertion through `textDocumentProxy` after the user is back in the target app.

The closest supported route to one-tap keyboard Dictation is a foreground-armed warm recorder. The user opens Hex once and explicitly arms an app-owned microphone/background-audio session, then returns to the host app. While that session is alive, the keyboard can publish start/stop commands through an App Group mailbox, the containing app can record and call Ronin, and the still-visible keyboard can insert the result. This removes the per-Dictation app switch at the cost of a visible microphone indicator, battery use, an expiration policy, and a cold recovery path.

An App Intent/App Shortcut exposed through the Action Button or Control Center is the strongest cold-start experiment. It can pre-arm or start Hex without relying on the keyboard to launch its containing app, but it still cannot silently restore focus or insert text into another app. Native Dictation and Voice Control are the only Apple-supported ways to dictate directly into the current field from a cold state without a custom handoff; neither can use Hex's Parakeet/Tailscale recognizer.

## Evidence and status vocabulary

- **Documented** — directly stated or exposed by Apple's public documentation or SDK headers.
- **Inference** — a conclusion from the public API boundary; useful for design, but not an Apple promise about every private implementation detail.
- **Unavailable/private** — not exposed as a supported public mechanism. A private selector, responder-chain trick, or undocumented keyboard framework may work on one build, but is not a viable foundation for a personal app that needs to survive OS updates.

The iOS 27 beta notes are included only to identify the current platform direction. Apple says beta APIs and behavior are preliminary; absence from release notes is not proof that no internal mechanism exists.

## The insertion boundary

### Custom keyboard extension: the supported arbitrary-cursor API

Apple's [custom keyboard guide](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard) describes a keyboard as an extension that replaces the system keyboard in text-entry contexts where third-party keyboards are allowed. The keyboard receives a [text document proxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy), which conforms to `UIKeyInput` and provides operations such as `insertText(_:)`, `deleteBackward()`, `adjustTextPosition(byCharacterOffset:)`, `selectedText`, and limited text before and after the insertion point. The guide's example inserts a string with `textDocumentProxy.insertText(...)`.

This is the only public iOS API in the reviewed surface that directly targets the current insertion point in an arbitrary host app. It is also intentionally limited: [handling text interactions in a custom keyboard](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards) says the keyboard does not directly access the host's edited text, and text-input delegate notifications do not provide the host's full contents. The proxy is an editing capability, not a general host-app automation capability.

Important documented constraints:

- A host app can reject third-party keyboards, and [some fields do not allow them](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface), including secure text fields and phone/name-phone-pad fields.
- A keyboard extension runs in a separate process and can be terminated by the system. The [extension overview](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html) also warns that extensions cannot use APIs marked unavailable to extensions, such as `UIApplication.sharedApplication`, and cannot assume the containing app is running.
- `UIInputViewController.hasDictationKey` only tells the system whether the keyboard supplies a dictation key. [Setting it to `true` disables the system Dictation key](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/hasdictationkey); it does not provide microphone access or a custom recognizer hook.

### Full Access does not turn a keyboard into a recorder

With the keyboard extension's `RequestsOpenAccess` entitlement, the user may grant “Allow Full Access.” Apple's [open-access documentation](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard) says Full Access enables network access, writes to a shared container, and server-side processing of keystrokes/input events. Without it, the keyboard has no network and only read-only shared-container access. The same documentation explicitly says that the keyboard still cannot access the device microphone or speaker.

This makes an App Group mailbox and a Tailscale HTTP/WebSocket client technically reasonable inside a Full Access keyboard, but it does not solve audio capture. The containing app must still obtain microphone permission and record. The keyboard can then read a pending transcript and call `insertText`, but only while it is active.

### The keyboard-to-app launch boundary

`NSExtensionContext.open(_:completionHandler:)` is public, but Apple's [API documentation](https://developer.apple.com/documentation/foundation/nsextensioncontext/open%28_%3Acompletionhandler%3A%29.md) says that support is determined by each extension point and identifies iOS Today and iMessage as supported cases. It is not documented as supported for custom keyboard extensions. The archived [extension overview](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html) also describes the containing app and extension as separate processes that communicate indirectly through shared data, not through an always-available app object.

**Inference:** a custom keyboard cannot rely on `extensionContext.open` to launch Hex, wait for its result, and regain the host cursor. A URL scheme, responder-chain lookup, `UIApplication` access, Objective-C message send, or private `UIKeyboard`/SpringBoard class is outside the public contract. Even if a personal-device experiment happens to work, it is an unsupported handoff and should be isolated behind a disposable prototype rather than the core architecture.

### Other text-input APIs do not widen the boundary

The [UITextInput](https://developer.apple.com/documentation/uikit/uitextinput) protocol belongs to the app that owns a text view. It includes dictation lifecycle methods such as `dictationRecordingDidEnd()`, `dictationRecognitionFailed()`, and `insertDictationResult(_:)`; those methods let a host text control receive Apple's dictation result. They are not an API for a different app or keyboard to claim the host's audio session. A [UITextInputContext](https://developer.apple.com/documentation/uikit/uitextinputcontext) similarly describes input context for the owning app.

**Inference:** iOS has no public, macOS-`NSServices`-style text service that can receive remote text and target the insertion point of any foreground app. `UITextDocumentProxy` is the systemwide keyboard boundary; `UITextInput` is the app-owned text-control boundary. An app-owned `UIInputView` can be useful inside Hex itself, but is not a systemwide keyboard.

## Native Dictation and speech APIs

### Apple Dictation is the direct current-field path

Apple's [iPhone Dictation guide](https://support.apple.com/guide/iphone/dictate-text-iph2c0651d2/26/ios/26) says Dictation works anywhere text can be entered, keeps the keyboard visible, and inserts recognized text into the current field. Apple's [dictation command guide](https://support.apple.com/en-ie/guide/iphone/iph3bf19d7b9/ios) documents punctuation, formatting, editing, and deletion commands. This is exactly the desired insertion behavior, but the recognizer and audio path belong to the operating system.

The public UIKit dictation methods confirm the receiving side, but there is no public API for a custom keyboard to replace Apple's recognizer with a remote audio stream. `hasDictationKey` only hides or leaves visible the system dictation affordance. A Hex keyboard can leave `hasDictationKey` false and keep Apple's Dictation available, which is a useful native fallback, but that fallback violates the requirement that the server be mandatory and uses neither Tailscale nor Parakeet.

Apple's [iOS/iPadOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) mention an advanced on-device Dictation model preview and related beta behavior. This improves the native path, not the third-party recognizer boundary. No public iOS 27 API in the reviewed documentation exposes remote recognizer injection into system Dictation.

### Speech framework is app-owned, not field-owned

[`SFSpeechRecognizer`](https://developer.apple.com/documentation/speech/sfspeechrecognizer) and Apple's [speech-recognition permission guidance](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition) allow an app to request speech recognition and process audio. This can be used by a containing app, but the framework does not grant an arbitrary current-field handle. It also represents Apple's speech service/on-device behavior rather than the required Parakeet-over-Tailscale path. It is not a way for a keyboard extension to capture audio.

## App Intents, Shortcuts, Action Button, and controls

### These are excellent triggers, not insertion channels

[App Intents](https://developer.apple.com/documentation/appintents/appintent) expose typed app actions to Siri, Shortcuts, Spotlight, widgets, the Action Button, and other system experiences. An intent's `perform()` can start a Hex recording session, connect to Tailscale, or return a transcript result to the invoking system surface. [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts) make selected intents discoverable without a separate user-created Shortcut, and [hardware interactions](https://developer.apple.com/documentation/appintents/hardware-interactions) documents Action Button use for supported iPhone configurations.

The newer iOS 26+ execution controls are useful for pre-arming:

- [`supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes.md) describes background and foreground execution modes.
- [`continueInForeground`](https://developer.apple.com/documentation/appintents/appintent/continueinforeground%28_%3Aalwaysconfirm%3A%29.md) can request a foreground transition when the system allows it.

Neither API carries the foreground host app's `UITextDocumentProxy` into the intent. A foreground transition changes which app is visible; it does not grant a later App Intent permission to insert into the app that was previously visible. A String parameter can collect dictated or typed input for the intent, but the returned value is an intent result, not a current-field edit.

[Widget and Control Center controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system) and [interactive widgets/Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities) provide additional one-tap surfaces for an App Intent. They can start or stop recording, display status, or open Hex. They do not expose arbitrary text-field insertion.

The WWDC sessions [Bring your app's core features to users with App Intents](https://developer.apple.com/videos/play/wwdc2024/10210/), [Design App Intents for system experiences](https://developer.apple.com/videos/play/wwdc2024/10176/), and [Get to know App Intents](https://developer.apple.com/videos/play/wwdc2025/244/) show the same model: expose an app action and its result to system surfaces. The examples include opening content and changing app-owned state, not editing another app's active text control.

**Recommended use for Hex:** expose “Start remote dictation,” “Stop and prepare transcript,” and possibly “Copy latest transcript” as App Intents. Make them available as an App Shortcut, Action Button action, and Control Center control. Treat these as session controls and a way to avoid the unsupported keyboard-to-app launch, not as a current-cursor insertion API.

## Accessibility and Voice Control

[Voice Control](https://developer.apple.com/documentation/accessibility/voice-control) is an Apple assistive technology that can perform gestures and dictate/edit text. Apple's [Voice Control guide](https://support.apple.com/en-mo/guide/iphone/iph2c21a3c88/ios) describes Dictation, Spelling, and Command modes. Apple's [custom Voice Control command guide](https://support.apple.com/en-us/118275) allows a user to create commands that insert predefined text, run a Shortcut, or perform a custom gesture. Apple's [Voice Control evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voice-control-evaluation-criteria) says standard text fields support dictation/editing automatically and calls out additional work for custom text entry.

This yields three separate results:

- **Native Voice Control Dictation:** direct arbitrary text insertion into the current field, English-capable, and user-configurable. It uses Apple's speech path, not Parakeet or Tailscale. It also conflicts with ordinary Dictation while Voice Control is active, according to Apple's user guide.
- **Custom “Insert text” command:** direct insertion, but only fixed text chosen when the command is configured. It cannot insert a transcript that Hex computes later.
- **Custom “Run Shortcut” command:** can trigger a Hex App Intent and server request, but has no public API to return the dynamic result to the prior host field. The user still needs a paste or keyboard insertion step.

Voice Control is therefore a good direct-field comparison and accessibility test, but not a solution for a remote Parakeet backend.

## Share and Action extensions

Apple's archived [Action extension documentation](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Action.html) describes an extension that operates on content explicitly supplied by a host app and returns an `NSExtensionItem`. The [Share extension documentation](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html) similarly covers sharing/posting content from the host. The current [`NSExtensionContext`](https://developer.apple.com/documentation/foundation/nsextensioncontext) contract provides input items and [`completeRequest(returningItems:)`](https://developer.apple.com/documentation/foundation/nsextensioncontext/completerequest%28returningitems%3Acompletionhandler%3A%29); it does not provide a current text cursor.

An Action extension may transform selected text when the host chooses it. That can be useful for a “rewrite selected text” product, but it is not a dictation keyboard: the user must invoke the share/action UI, the host decides what content is supplied, and the extension returns data to the host rather than calling `insertText` in an arbitrary field.

The [extension overview](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html) and [extension creation/scenarios documentation](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html) also establish the relevant security boundary: extensions cannot use general app APIs unavailable to extensions, and long-running background work is limited. In particular, a Share or Action extension is not a supported place to capture microphone audio for a remote dictation session. The iMessage extension exception is specific to iMessage and does not generalize to arbitrary host apps.

**Feasibility:** low for this product. It could be a future selected-text transformation feature, not the first keyboard-level input path.

## Pasteboard

The [UIPasteboard](https://developer.apple.com/documentation/uikit/uipasteboard) general pasteboard is the supported app-to-app data channel. Hex can write a transcript and the user can paste it into the target app. iOS limits silent cross-app reads: Apple documents user notifications when an app reads general pasteboard data without an explicit user action, and named App Group pasteboards are limited to apps in the same team.

[`UIPasteControl`](https://developer.apple.com/documentation/uikit/uipastecontrol), available from iOS 16, gives the recipient app a user-visible paste control that avoids the normal prompt for that user action. It still requires a button in the recipient app; it does not let a background Hex process paste into another app's field.

Pasteboard is a reasonable failure-mode UX—“copy the pending transcript”—but it is not less friction than an active custom keyboard. The keyboard's `textDocumentProxy.insertText` remains the correct insertion mechanism when the keyboard is visible.

## Notifications, Live Activities, and system controls

[Actionable notifications](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types) can show buttons and a text-input action. The app can process the action in the background using [notification action handling](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions). The text entered into a notification action is an input to Hex; it is not the current field of the app underneath the notification. A notification can therefore stop recording, report failure, or offer “Copy latest transcript,” but cannot insert into an arbitrary cursor.

[Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) and interactive widgets can show recording state, elapsed time, server availability, and a stop action. Their buttons invoke App Intents, as described in [WidgetKit's interactivity documentation](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities). They are good session-control surfaces and poor text-insertion surfaces.

**Feasibility:** useful as an adjunct to reduce “is the server recording?” friction; no direct insertion.

## Microphone injection: a nearby API with the wrong boundary

Recent AVFAudio SDKs expose [microphone injection availability](https://developer.apple.com/documentation/avfaudio/avaudiosession/ismicrophoneinjectionavailable) and [`AVAudioSession.MicrophoneInjectionMode`](https://developer.apple.com/documentation/avfaudio/avaudiosession/microphoneinjectionmode). The SDK header describes these APIs as a way for one audio session to inject audio into another app's input stream, primarily for accessibility apps implementing augmentative and alternative communication. The `spokenAudio` mode is for synthesized speech mixed with microphone audio. The APIs are available from iOS 18.2.

This is an audio-routing capability, not a text-input capability. It does not provide a `UITextDocumentProxy`, does not establish that Apple's Dictation engine will consume the injected audio, and is intended for communication/call input scenarios rather than arbitrary text fields. Synthesizing Parakeet's transcript back into speech and trying to feed it into Dictation would be an unsupported inference with extra latency and error modes.

**Feasibility:** do not use for Hex's first prototype. It is worth remembering only to avoid confusing “inject microphone audio” with “insert text at the current cursor.”

## Ranked feasibility matrix

Legend: `✓` meets the criterion; `△` meets it only with an additional user step or an experimental composition; `✗` does not meet it through a public supported API. “Server-only” means the route can fail closed when Tailscale/Parakeet is unavailable and does not silently substitute Apple's offline recognizer.

| Rank / surface | Personal device | Direct current-field insertion | English | Tailscale | Parakeet | Fast prototype | Server-only / no offline fallback | Assessment |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1. Foreground-armed warm Hex recorder + custom keyboard + App Group mailbox | ✓ | ✓, while keyboard is active | ✓ | ✓ | ✓ | △ | ✓ | Only public composition that preserves Hex's recognizer, direct insertion, and repeated one-tap keyboard capture. It requires a visible active microphone session and a cold recovery path. |
| 2. Hex app pre-armed by App Intent/App Shortcut, Action Button, or Control Center, then custom keyboard inserts | ✓ | △, after the user returns to the target app and keyboard | ✓ | ✓ | ✓ | △ | ✓ | Best supported friction-reduction experiment. The system trigger starts the session; it cannot restore the prior cursor automatically. |
| 3. Apple Dictation left available in the Hex keyboard | ✓ | ✓ | ✓ | ✗ | ✗ | ✓ | ✗ | Best direct-field UX, but it delegates recognition to Apple and may use on-device processing. Keep `hasDictationKey` false as an optional fallback only. |
| 4. Native Voice Control Dictation | ✓ | ✓ | ✓ | ✗ | ✗ | ✓ (user setup) | ✗ | Direct current-field input, but it is an accessibility/system recognizer, not a Hex backend. |
| 5. Voice Control custom command → Hex Shortcut/App Intent | ✓ | ✗ | ✓ | ✓ | ✓ | △ | ✓ | Can trigger the server, but no public dynamic-result-to-prior-field path. Requires return/paste/keyboard step. |
| 6. Hex app → pasteboard → user paste or `UIPasteControl` | ✓ | △, manual recipient action | ✓ | ✓ | ✓ | ✓ | ✓ | Simple fallback and useful recovery UX, not lower-friction keyboard input. |
| 7. Notification action / Live Activity / Control Center status | ✓ | ✗ | ✓ | ✓ | ✓ | △ | ✓ | Good for start/stop/status/copy actions; no arbitrary host cursor. |
| 8. Share or Action extension | ✓ | ✗ / host-dependent | ✓ | △ | △ (extension cannot own the required mic session) | ✗ | ✓ | Selected-content workflow, not universal dictation. |
| 9. AVFAudio microphone injection | ✓ | ✗ | ✓ | △ | △ | ✗ | ✓ | Audio is injected into an input stream, not text into a field; Apple documents an accessibility/call-oriented use case. |
| 10. Private keyboard launch/responder/host APIs | ✓ | △ / device-dependent | ✓ | ✓ | ✓ | △ | ✓ | Not Apple-supported. Treat as a disposable investigation only, never as the architecture. |

The matrix shows why improving the keyboard UI alone cannot remove the central handoff: the missing capability is not a better text-editing primitive; it is a supported way for a keyboard extension to obtain microphone input or launch/coordinate its containing app while retaining the host cursor.

## Recommended prototype order

### 1. Keep the supported keyboard contract small and reliable

Keep Hex's keyboard as a functional keyboard with a prominent remote-dictation button. Use Full Access only for the network and shared App Group mailbox. When a transcript is ready, insert it with `textDocumentProxy.insertText`. Do not set `hasDictationKey` to `true` unless the product intentionally removes Apple Dictation.

The keyboard should treat the server as authoritative: if it cannot reach the Tailscale endpoint or Parakeet fails, it should report unavailable and leave the field untouched. A clipboard copy of the last successful transcript can be a recovery affordance, not an offline recognizer.

### 2. Prototype the warm recorder

Add an explicit **Arm keyboard dictation** action to Hex. In response to that foreground action, start an app-owned input graph under the `audio` background mode, discard samples until a keyboard request arrives, and publish an armed heartbeat in the App Group. While armed, let the keyboard write request-scoped start/stop commands and poll for the matching result so it can insert exactly once without leaving the host app.

Make the privacy and lifecycle costs visible: keep the orange microphone indicator, start with a short timeout, expose a one-tap disarm action, and fall back to **Open Hex to arm dictation** after interruption, force-quit, or a stale heartbeat. The detailed call flow and device matrix live in [iOS background dictation architectures](ios-background-dictation-architectures.md).

### 3. Add a system-triggered cold path

Implement an App Intent for “Start remote dictation” and expose it as an App Shortcut. Test it as an Action Button action and as a Control Center control. The intent should start or pre-arm the containing app's recorder, use the existing Tailscale/Parakeet service, and persist a pending result in the App Group.

The expected flow is:

```text
Action Button / Control Center / Shortcut
        ↓
Hex containing app records and calls Tailscale → Parakeet
        ↓
pending transcript in App Group
        ↓
user returns to target app and activates Hex keyboard
        ↓
keyboard inserts with UITextDocumentProxy
```

This is the highest-value supported experiment because it attacks the app-launch friction without pretending that an App Intent has the host cursor. Use a Live Activity or notification to expose stop/error state, not to claim insertion.

### 4. Measure native alternatives separately

Keep a test build with Apple's Dictation available and compare time-to-text and correction behavior. Test Voice Control only as an accessibility/direct-field baseline. These tests answer whether the custom backend is worth the extra handoff, but they must not silently become the production path if server-only behavior is a hard requirement.

### 5. Stop before private automation becomes a dependency

Do not build around private keyboard classes, `UIApplication` access from an extension, responder-chain launches, synthetic key events, or an inferred URL-scheme return protocol. Apple's documented extension restrictions and extension-point-specific URL behavior make these inherently fragile. If a personal-device experiment is run, keep it behind a debug flag and assume it will be rejected or terminated on a future iOS release.

## Answer to the “can we do better than switching apps?” question

For a cold containing app, **not through a public keyboard API while preserving an arbitrary host cursor**. After the user explicitly arms a background recorder, however, repeated one-tap capture from the keyboard is viable while that warm session remains alive. The closest supported improvements are:

1. arm Hex once, return to the target field, and let the keyboard delimit capture and insert each result while the session is warm;
2. start Hex from a hardware/system surface before or while preparing the target field when the warm session is unavailable;
3. return to the target field and let the keyboard insert a pending transcript;
4. use native Dictation or Voice Control when direct insertion is more important than Parakeet/server ownership;
5. offer pasteboard recovery when keyboard handoff fails.

Any design that claims to both start a custom microphone capture from the keyboard and automatically return to the prior app's cursor is relying on an unsupported/private boundary unless Apple documents a new extension point in a future SDK.

## Primary sources

The links in each section are the sources used for the corresponding claim. The most important boundary documents are:

- [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)
- [Handling text interactions in custom keyboards](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards)
- [UITextDocumentProxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)
- [Configuring Open Access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)
- [Configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)
- [NSExtensionContext.open](https://developer.apple.com/documentation/foundation/nsextensioncontext/open%28_%3Acompletionhandler%3A%29.md)
- [Extension Programming Guide: Overview](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)
- [UITextInput](https://developer.apple.com/documentation/uikit/uitextinput)
- [iPhone User Guide: Dictate text](https://support.apple.com/guide/iphone/dictate-text-iph2c0651d2/26/ios/26)
- [AppIntent](https://developer.apple.com/documentation/appintents/appintent) and [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)
- [Voice Control](https://developer.apple.com/documentation/accessibility/voice-control)
- [Declaring actionable notification types](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types)
- [UIPasteboard](https://developer.apple.com/documentation/uikit/uipasteboard) and [UIPasteControl](https://developer.apple.com/documentation/uikit/uipastecontrol)
- [Creating controls for system actions](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)
- [AVAudioSession microphone injection availability](https://developer.apple.com/documentation/avfaudio/avaudiosession/ismicrophoneinjectionavailable)
- [iOS/iPadOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
