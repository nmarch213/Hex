# iOS keyboard system-handoff alternatives

Research captured 2026-08-21 for the Hex personal iOS dictation prototype. Sources are limited to Apple documentation, Apple Support, Apple SDK interfaces, WWDC sessions, and answers from Apple engineers.

## Bottom line

There is no documented one-tap path from a custom keyboard button to its containing app. `NSExtensionContext.open` is extension-point-specific; on iOS Apple documents support for Today and iMessage extensions, not custom keyboards. Apple Developer Technical Support states more broadly that app extensions cannot open URLs directly and that the supported way for an extension to get the user's attention is a local notification. [`NSExtensionContext.open`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)), [Apple DTS on extension URL opening](https://developer.apple.com/forums/thread/764570), [Apple engineer on supported extension types](https://developer.apple.com/forums/thread/773342)

The best supported UX for this device is therefore not another keyboard-launch hack. It is one of these:

1. **Action Button → foreground and arm Hex → swipe back.** One press-and-hold plus one bottom-edge swipe. App Shortcuts are explicitly supported on the Action Button, and an intent can require immediate foreground execution. [Apple: Action button](https://developer.apple.com/design/human-interface-guidelines/action-button), [Apple: App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts), [Apple: intent execution modes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)
2. **Action Button or Back Tap → background recording intent.** Potentially a single hold or a double-tap, with no app switch, using `AudioRecordingIntent` and a required Live Activity. This is the most attractive experiment, but it is not yet a dependable product contract: Apple also enforces a privacy block against activating an ordinary recording session from a completely backgrounded state. It needs a physical-device spike before relying on it. [`AudioRecordingIntent`](https://developer.apple.com/documentation/appintents/audiorecordingintent), [Apple DTS on background microphone activation](https://developer.apple.com/forums/thread/816408), [Apple: Back Tap shortcuts](https://support.apple.com/en-gb/guide/shortcuts/apd897693606/ios)
3. **Keyboard tap → immediate local notification → notification tap opens Hex.** This is the only Apple-recommended route that the keyboard itself can initiate. It takes two taps to foreground Hex and a third gesture to swipe back. Notification permission and presentation settings make it a fallback, not the primary path. [Apple DTS on extension attention](https://developer.apple.com/forums/thread/764570), [`UNUserNotificationCenter`](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter), [`UNNotificationRequest`](https://developer.apple.com/documentation/usernotifications/unnotificationrequest/init(identifier:content:trigger:))

Once Hex is armed, keep recording ownership in the containing app and start/stop/insert in the keyboard through the App Group. Apple permits an open-access keyboard to write shared-container state, but a keyboard extension cannot own the microphone or a long-running audio background task. [Apple: configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard), [Apple: extension restrictions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)

## Interaction-count assumptions

The counts below begin with the person in another app, a text field active, and the Hex keyboard visible. One press-and-hold, swipe, or double-tap sequence is described as one gesture, with physical tap count called out where useful. One-time configuration—granting notification permission, adding a control, assigning the Action Button, or enabling Back Tap—is not included.

“Arm microphone” means that Hex actually activates an audio-recording session that can continue after returning to the host app. Merely writing `armed = true` to shared storage does not count if iOS later refuses to activate the microphone.

## Decision table

| Route | Can the keyboard initiate it? | Gestures to foreground or arm | Gestures to return to the text field | Cold microphone start | Verdict |
| --- | --- | ---: | ---: | --- | --- |
| Keyboard `NSExtensionContext.open` / URL scheme | **No documented support** | 1 desired, but rejected | N/A | N/A | Stop pursuing. |
| Keyboard SwiftUI `Button(intent:)` + iOS 27 execution target | The button can invoke an intent, but Apple does not document this as a keyboard app-launch entitlement | 1 desired; current device experiment did not foreground | N/A | Not established | iOS 27 process targeting does not override extension-point launch policy. |
| App Shortcut on Action Button, foreground intent | No; the user invokes the hardware surface | 1 press-and-hold | 1 bottom-edge swipe | **Yes**, because Hex is foregrounded before activating audio | **Best dependable two-gesture path.** |
| `AudioRecordingIntent` on Action Button | No | Potentially 1 press-and-hold | 0 | Plausible by API design, but privacy-sensitive and device-test required | Best no-switch experiment, not yet a guarantee. |
| App Shortcut via Back Tap | No | Double- or triple-tap on phone back | 0 for background intent; 1 swipe for foreground intent | Same caveat as Action Button | Strong personal-device alternative. |
| Control Center control | No | Swipe down + tap control = 2 | Usually 1 more gesture to dismiss or swipe back | Yes if control opens Hex; uncertain if background-only | Good discoverable fallback; slower than Action Button. |
| Siri App Shortcut | No | One spoken request, no tap | 0 for background intent; 1 swipe for foreground intent | Same caveat as other background intent surfaces | Useful hands-free alternative. |
| Active Live Activity, tap activity | No; it must already exist | 1 tap opens Hex | 1 swipe back | Not a cold-start solution | Useful while already armed. |
| Active Live Activity, hold then tap button | No; it must already exist | Hold to expand + tap = 2 | 0 | Can control an already-running session | Excellent start/stop/disarm surface after arming. |
| Immediate local notification from keyboard | **Yes** | Tap keyboard + tap banner = 2 | 1 swipe back | Yes if notification foregrounds Hex | Only supported keyboard-originated fallback. |
| Universal or custom link | No direct keyboard opening privilege | Depends on a separate surface that presents the link | Usually 1 swipe back | Yes after foregrounding | Routing mechanism, not a handoff surface. |
| Japan-only conversational-app side button | No | Side-button gesture | System-defined | Region-specific | Not applicable outside Japan. |

## Why the keyboard cannot perform the launch itself

### Extension-point policy, not URL correctness

Apple's `NSExtensionContext.open` documentation says each extension point decides whether it supports URL opening, and names Today and iMessage as supported on iOS. An Apple engineer states that no other app extension can launch its app directly; widgets use their own App Intents-based opening route. [`NSExtensionContext.open`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)), [Apple engineer clarification](https://developer.apple.com/forums/thread/773342)

The general app-extension guide also says an extension cannot access `UIApplication.shared`, communicates directly only with its host rather than its containing app, and is normally terminated soon after its focused task completes. Responder-chain or Objective-C runtime calls that bypass compile-time unavailability remain outside the supported contract; Apple DTS specifically warns against them as compatibility hazards. [Apple: extension architecture](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html), [Apple DTS](https://developer.apple.com/forums/thread/764570)

A keyboard has one narrow URL-related exception: Apple's archived QA permits the specific `prefs:root=General&path=Keyboard` URL to open Keyboard Settings, and says other use of the undocumented `prefs:` scheme violates review rules. That exception does not generalize to opening the containing app. [Apple QA1924](https://developer.apple.com/library/archive/qa/qa1924/_index.html)

### Open Access does not add app-launch or microphone rights

Full Access grants network access and write access to the App Group so a keyboard and containing app can share requests, status, audio metadata, and transcript results. It does not add `UIApplication`, microphone capture, or long-running background audio. [Apple: configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)

Apple's extension guide says iOS app extensions cannot access the camera or microphone and cannot perform long-running background tasks. Its custom-keyboard guide states directly that custom keyboards have no microphone access, while the current keyboard documentation describes `hasDictationKey` only as a way to tell iOS that the keyboard provides some dictation workflow. [Apple: extension restrictions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html), [Apple: custom keyboard limitations](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html), [Apple: configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)

## App Intents and App Shortcuts

### What they solve

App Intents expose app actions to Siri, Shortcuts, Spotlight, widgets, controls, Live Activities, and the Action Button. App Shortcuts are immediately discoverable after installation and can have preconfigured parameters, so `Arm Hex` can be a zero-parameter system action. [Apple: App Intents](https://developer.apple.com/documentation/appintents), [Apple: App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts), [WWDC25: Get to know App Intents](https://developer.apple.com/videos/play/wwdc2025/244/)

On current SDKs, `supportedModes` can require:

- background execution;
- foregrounding before the action (`.foreground(.immediate)`);
- beginning in the background and transitioning later; or
- dynamic foreground continuation.

That makes a foreground `Arm Hex` App Shortcut a documented cold-start path. The system opens Hex, Hex activates its recorder while foregrounded, and the person swipes back. [Apple: `supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)

### What iOS 27 execution targets do—and do not do

iOS 27 adds `allowedExecutionTargets`, letting an intent specify the main app, an App Intents extension, a WidgetKit extension, or a combination. Apple's WWDC26 example describes this as choosing which process handles an intent request from Siri, Shortcuts, widgets, or another system surface. It does not document a new custom-keyboard privilege to foreground its containing app. [`allowedExecutionTargets`](https://developer.apple.com/documentation/appintents/appintent/allowedexecutiontargets), [WWDC26: Discover new App Intents capabilities](https://developer.apple.com/videos/play/wwdc2026/345/)

SwiftUI does provide `Button(intent:)`, which asks the App Intents system to perform an intent. Combining that button in the keyboard with `.main` and `.foreground(.immediate)` is therefore a reasonable beta-API experiment, and it is the exact narrow experiment already run on the iOS 27 device. Its failure to foreground Hex is consistent with the older extension-point restriction. Process selection is not the same thing as permission to switch applications. [Apple: SwiftUI `Button(intent:)`](https://developer.apple.com/documentation/swiftui/button/init(intent:label:)), [`allowedExecutionTargets`](https://developer.apple.com/documentation/appintents/appintent/allowedexecutiontargets)

iOS 27 also adds `RunSystemShortcutIntent`, which can open another app or run an App Shortcut, custom shortcut, or system action. Apple explicitly limits it to a button inside a **widget** and says it has no effect in other contexts. It therefore cannot turn a keyboard button into a shortcut or app launcher. A Home Screen widget remains possible, but reaching it from an active text field adds a Home gesture and loses the current keyboard context. [Apple: `RunSystemShortcutIntent`](https://developer.apple.com/documentation/appintents/runsystemshortcutintent)

Likewise, a `shortcuts://` URL would still require the keyboard extension to open a URL, so wrapping the same handoff in a personal Shortcut does not change the extension boundary. Shortcuts are useful when invoked by Siri, the Action Button, Back Tap, Control Center, a widget, or the Shortcuts app itself—not as a keyboard escape hatch.

**Decision:** do not spend further prototype cycles varying URL schemes, `completeRequest`, responder traversal, or App Intent execution-target combinations. The documented system surfaces—not the keyboard extension—should invoke the intent.

## Action Button and Back Tap

### Foreground-and-arm: dependable path

Apple lets a person associate an App Shortcut or a Control with the Action Button. Pressing and holding the button runs it, and Apple's HIG recommends keeping people in their current context when possible. [Apple Support: Action Button behavior](https://support.apple.com/en-gb/guide/iphone/iphe89d61d66/ios), [Apple: Action button HIG](https://developer.apple.com/design/human-interface-guidelines/action-button)

For the current architecture, the low-risk intent is:

- require `.foreground(.immediate)`;
- open the Hex armed-session screen;
- activate the audio session and start the warm recorder;
- show the bottom-edge swipe-back instruction;
- continue recording in the background after the person swipes back.

Interaction count from the text field is exactly two gestures: hold the Action Button, then swipe back along the bottom edge. Unlike a keyboard URL launch, both transitions are normal system operations.

Back Tap can run a Shortcut after a double- or triple-tap on the back of the phone. For a personal iPhone this is a second strong trigger, particularly if the Action Button is already committed to another function. [Apple Support: Back Tap shortcuts](https://support.apple.com/en-gb/guide/shortcuts/apd897693606/ios)

iOS 26.2 and later also let people in Japan assign the iPhone **side button** to a voice-based conversational app through a dedicated Assistant App Intent schema. Apple documents that schema as Japan-only. It is not a general replacement for the Action Button and is unavailable for this workflow outside Japan. [Apple: Assistant App Intent schema](https://developer.apple.com/documentation/appintents/app-schema-domain-assistant), [Apple: iOS changes in Japan](https://developer.apple.com/support/app-distribution-in-japan)

### Background-only arm: high-value device spike

`AudioRecordingIntent` is an App Intent specifically for starting, stopping, or modifying audio recording. Apple says the system displays a recording indicator, and on iOS an app adopting it must start a Live Activity when recording begins and keep it active for the duration; recording stops otherwise. [`AudioRecordingIntent`](https://developer.apple.com/documentation/appintents/audiorecordingintent)

This suggests an ideal one-gesture experience: Action Button → `Start Hex Dictation` → Live Activity appears → recording runs while the original app and keyboard remain visible. Apple's Action Button guidance explicitly recommends Live Activities for actions that should not pull a person from their context. [Apple: Action button HIG](https://developer.apple.com/design/human-interface-guidelines/action-button), [Apple: Live Activities HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)

There is an important boundary. Apple DTS says the general audio APIs have a privacy block that prevents activating a recording session from a fully backgrounded state; CallKit, LiveCommunicationKit, and PushToTalk are exceptions only as part of genuine call-management architectures. [`AudioRecordingIntent`](https://developer.apple.com/documentation/appintents/audiorecordingintent) establishes the system-intent contract, but Apple does not document it as a blanket bypass for every background activation circumstance. [Apple DTS on background recording](https://developer.apple.com/forums/thread/816408)

**Decision:** build one isolated physical-device spike using a genuine system invocation—Action Button or Siri—not a direct call to `perform()` and not a keyboard-originated `Button(intent:)`. Conform the start/stop action to `AudioRecordingIntent`, start the required Live Activity synchronously with recording, and test app terminated, suspended, already armed, device locked, and device unlocked. Keep foreground-and-arm as the fallback until that matrix passes.

## Controls and Control Center

WidgetKit controls can be placed in Control Center, on the Lock Screen, and on the Action Button. A control button can run an ordinary App Intent or use `OpenIntent` to launch the app to a specific view. Apple requires the intent's target membership in both the app and widget extension for app opening. [Apple: Controls](https://developer.apple.com/documentation/widgetkit/controls-collection), [Apple: creating controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)

From an active text field on a Face ID iPhone:

1. Swipe down from the top-right to open Control Center.
2. Tap the Hex control.
3. If it performs inline, dismiss Control Center to see the text field again; if it opens Hex, swipe back after arming.

Apple documents the open and close gestures, making this normally three interactions end to end. [Apple Support: Control Center](https://support.apple.com/en-ie/guide/iphone/iph59095ec58/ios)

A toggle that merely writes shared state can run inline, but it cannot cold-activate a normal microphone session. For a true cold start, use `OpenIntent` to foreground Hex or reuse the physical-device-tested `AudioRecordingIntent` if that succeeds. The same control can be assigned directly to the Action Button, reducing the interaction to one hardware gesture.

## Live Activities and the Dynamic Island

Live Activities are a strong armed/recording UI, not a bootstrap from the keyboard. Apple says an app can only start a normal Live Activity while foregrounded, unless it starts one through a `LiveActivityIntent` or ActivityKit push notification. [`Activity`](https://developer.apple.com/documentation/activitykit/activity), [Apple: displaying Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)

Once an armed Live Activity exists:

- Tapping its compact/minimal presentation launches Hex. That is one tap to foreground and one swipe to return. [Apple: launching from a Live Activity](https://developer.apple.com/documentation/activitykit/launching-your-app-from-a-live-activity)
- Touching and holding the compact activity expands it; tapping an App Intent button is a second interaction and can pause, resume, stop, or disarm without launching Hex. Apple explicitly lists microphone recording among appropriate Live Activity controls. [Apple Support: Dynamic Island gestures](https://support.apple.com/en-gb/guide/iphone/iph28f50d10d/26/ios/26), [Apple: Live Activities HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities), [Apple: Live Activity buttons](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)

For Hex, the Live Activity should represent the bounded 15-minute armed session and expose one essential action, probably disarm while idle and stop while capturing. This matches Apple's guidance that Live Activities have a defined beginning and end and keep interactive controls simple. It should not be kept alive indefinitely merely to create a permanent app launcher.

## Local notification handoff

This is the only supported path directly initiated by the custom keyboard.

`UNUserNotificationCenter` is documented as the notification manager for an app **or app extension**. After the containing app obtains alert authorization during onboarding, the keyboard can add a local `UNNotificationRequest` with a `nil` trigger; Apple documents `nil` as “deliver right away.” [`UNUserNotificationCenter`](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter), [`UNNotificationRequest`](https://developer.apple.com/documentation/usernotifications/unnotificationrequest/init(identifier:content:trigger:)), [Apple: notification permission](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)

Flow:

1. User taps **Open Hex to Arm** in the keyboard.
2. Keyboard posts an immediate `Open Hex to arm dictation` notification.
3. User taps the banner; the system foregrounds Hex, which reads notification context and arms.
4. User swipes back to the original app.

The default notification tap launches the app. A custom notification action marked `.foreground` also foregrounds it, but Apple says not to use that option merely as an app launcher; use it when the action requires further interaction. [Apple: handling notification actions](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions), [Apple: foreground action option](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/foreground)

Limitations:

- Notifications require prior permission, and the person can later disable banners or route them to a scheduled summary. [Apple: notification permission](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
- Apple says notification delivery is timely on a best-effort basis, not guaranteed. [Apple: User Notifications](https://developer.apple.com/documentation/usernotifications)
- A background notification action must not be expected to cold-start the microphone; foreground Hex first.
- This is two taps to open and three interactions end to end, so it is less smooth than the Action Button route.

**Decision:** implement only if an on-keyboard recovery affordance is still valuable after Action Button setup. Label it honestly—such as **Notify Me to Open Hex**—rather than promising the keyboard itself will open Hex.

## Universal links and custom URL schemes

Universal links securely route an HTTP(S) URL to an installed app and deliver an `NSUserActivity`; custom URL schemes can also foreground an app in a specified context. [Apple: universal links](https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content), [Apple: custom URL schemes](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app)

Neither technology supplies an invocation surface. The caller still needs permission to open the URL, and a custom keyboard does not have it. A universal link in a notification, Control Center intent, Siri result, webpage, or message can route into `arm`, but changing `hextracer://arm` to `https://…/arm` cannot make the keyboard button work.

For a private Tailscale-hosted app, universal links also add an HTTPS domain, Associated Domains entitlement, and an `apple-app-site-association` file. They are worthwhile for secure external routing but unnecessary for this handoff problem. [Apple: supporting associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)

## Audio and background constraints

The containing app—not the keyboard—must own the recorder.

Apple documents that:

- the default audio session disallows recording;
- the app must configure `.record` or `.playAndRecord` and receive microphone permission;
- to **continue** recording when the app transitions to the background, add `audio` to `UIBackgroundModes`; and
- phone calls, alarms, and other nonmixable sessions can interrupt recording. [`AVAudioSession`](https://developer.apple.com/documentation/avfaudio/avaudiosession), [`AVAudioSession.Category.record`](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record), [`AVAudioRecorder`](https://developer.apple.com/documentation/avfaudio/avaudiorecorder)

The wording is important: background audio mode lets an already-active recording **continue**. It is not a general right to activate a microphone from a cold background launch. Apple DTS confirms the latter is privacy-blocked for general audio apps. [Apple DTS](https://developer.apple.com/forums/thread/816408)

For Hex this validates the existing warm-session architecture:

1. A supported surface foregrounds Hex.
2. Hex activates the microphone and starts its bounded warm session.
3. The user returns to the host app.
4. The keyboard changes capture boundaries and exchanges audio/transcript state through the App Group.
5. Hex stops the audio session when disarmed or expired.

Do not use CallKit, LiveCommunicationKit, PushToTalk, silent pushes, or fake playback to evade the rule. Apple DTS says the communication frameworks' background microphone privileges are tied to their call-management architecture and are unavailable for unrelated recording use cases. [Apple DTS](https://developer.apple.com/forums/thread/816408)

## Recommended prototype order

1. **Ship the foreground Action Button App Shortcut first.** It is the most reliable supported two-gesture flow: hold Action Button, then swipe back.
2. **Run one bounded `AudioRecordingIntent` + Live Activity spike from the Action Button.** If it cold-starts the recorder across the device-state matrix, it becomes the preferred one-gesture route. If not, retain foreground arming.
3. **Add the armed Live Activity.** Use it for visible state and stop/disarm, not as an indefinite launcher.
4. **Add a Control Center control** using the same intents for discoverability and for devices where the Action Button is assigned elsewhere.
5. **Optionally add immediate local-notification handoff from the keyboard.** Treat it as a two-tap recovery route and detect notification authorization before presenting it.
6. **Remove the failing keyboard URL/App Intent launch experiments from the feature branch.** iOS 27 execution targeting changes which process handles a valid App Intent request; it does not document a custom-keyboard app-switch entitlement.

## Primary-source index

- Custom keyboard and extension boundaries: [extension overview](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html), [custom keyboard limitations](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html), [open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)
- URL opening: [`NSExtensionContext.open`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)), [Apple DTS](https://developer.apple.com/forums/thread/764570), [Apple engineer clarification](https://developer.apple.com/forums/thread/773342)
- App Intents and shortcuts: [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts), [`supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes), [`allowedExecutionTargets`](https://developer.apple.com/documentation/appintents/appintent/allowedexecutiontargets), [WWDC26 execution targets](https://developer.apple.com/videos/play/wwdc2026/345/)
- Recording: [`AudioRecordingIntent`](https://developer.apple.com/documentation/appintents/audiorecordingintent), [`AVAudioSession.Category.record`](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record), [Apple DTS background restriction](https://developer.apple.com/forums/thread/816408)
- System surfaces: [Action Button](https://developer.apple.com/design/human-interface-guidelines/action-button), [Controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system), [Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), [Back Tap](https://support.apple.com/en-gb/guide/shortcuts/apd897693606/ios)
- Notification fallback: [`UNUserNotificationCenter`](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter), [immediate notification request](https://developer.apple.com/documentation/usernotifications/unnotificationrequest/init(identifier:content:trigger:)), [notification handling](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions)

### Local SDK corroboration

The local Xcode 26.4 iPhoneOS SDK declares `AudioRecordingIntent` from iOS 18 and `LiveActivityIntent` from iOS 17. The iOS 27 beta documentation adds `allowedExecutionTargets` and marks it beta. These interfaces corroborate the Apple documentation above; they do not contain a keyboard-specific containing-app launch API.
