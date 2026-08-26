# iOS Action Button: return and background microphone arming

Research captured 2026-08-21 for the personal Hex iOS dictation prototype. Sources are limited to Apple documentation, Apple Support, Apple SDK interfaces, and Apple Developer Technical Support answers.

## Answers

### 1. Can Hex automatically return to the previously active arbitrary app?

**No public iOS API documents this capability.** An App Shortcut can bring Hex forward, but neither App Intents nor UIKit exposes a “previous foreground app” destination or a way to synthesize the app-switching gesture. App Intents execution modes only decide whether Hex runs in the foreground or background; `.foreground(.immediate)` explicitly brings Hex forward. [`supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)

The public cross-app mechanism is destination-based: `UIApplication.open` launches the app that handles a supplied URL, and `OpenURLIntent` opens one of the caller's universal links. Neither API discovers or returns to whichever app happened to be frontmost before Hex. [`UIApplication.open`](https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:)), [`OpenURLIntent`](https://developer.apple.com/documentation/appintents/openurlintent)

There is one supported approximation when the destination is known in advance: a personal Shortcut can run **Arm Hex**, wait for arming to finish, then use Shortcuts' **Open App** action for a fixed app. Apple documents that shortcuts run their actions sequentially and that `Open App` launches a chosen app. This does not generalize to “return to the original app,” and it needs one shortcut per destination. [Apple: shortcut execution order](https://support.apple.com/en-gb/guide/shortcuts/-apd5ba077760/ios), [Apple: Open App action](https://support.apple.com/en-mide/guide/shortcuts/apdaf74d75a5/ios)

**Conclusion:** retain the bottom-edge swipe for arbitrary host apps. If one or two apps dominate the workflow, add fixed-destination shortcuts as an optional convenience.

### 2. Can the Action Button arm Hex without opening it?

**A background App Intent can perform ordinary state work without opening Hex, but that is not a useful arm for the current architecture.** Apple supports `.background` intents, and the Action Button runs App Shortcuts as a system action. Such an intent could check Ronin and write an `armed` flag to the App Group. [`supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes), [Apple: Action button](https://developer.apple.com/design/human-interface-guidelines/action-button)

However, the current Hex “arm” also activates `AVAudioSession`, starts an `AVAudioRecorder`, and keeps the containing app alive so the keyboard can later mark capture boundaries. A custom keyboard cannot own the microphone, even with Full Access. [Apple: custom keyboard open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard), [Apple: custom keyboard limitations](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)

Apple documents the `audio` background mode as allowing an already-active recording to **continue when the app transitions to the background**. It does not grant a general right to activate a new microphone session from a cold or suspended background state. [`AVAudioSession.Category.record`](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record), [`UIBackgroundModes`](https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes)

Apple DTS is more explicit: general audio APIs have a privacy block that prevents activating a recording session in the background. CallKit, LiveCommunicationKit, and PushToTalk have exceptions as part of genuine call-management systems, and Apple says those frameworks cannot be used for unrelated recording. [Apple DTS: background microphone activation](https://developer.apple.com/forums/thread/816408)

**Conclusion:** Hex can perform a *logical* background arm, but it cannot dependably perform the *microphone arm* the keyboard workflow requires. The supported reliable path remains: Action Button foregrounds Hex, Hex activates recording, then the person swipes back.

## `AudioRecordingIntent` and Live Activities

`AudioRecordingIntent` is the one API worth a bounded device experiment. Apple describes it as an intent that starts, stops, or modifies audio recording and says the system displays a recording indicator. On iOS, recording begun through this intent must have a Live Activity for its entire duration or the system stops the recording. [`AudioRecordingIntent`](https://developer.apple.com/documentation/appintents/audiorecordingintent)

`LiveActivityIntent` can start a Live Activity from a user-invoked system surface while the app is in the background. A Live Activity is therefore the correct visible state surface for armed/recording Hex, but ActivityKit does not itself grant microphone activation or indefinite execution. [Apple: displaying Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), [Apple: ActivityKit](https://developer.apple.com/documentation/activitykit)

The public documentation and current device behavior leave a narrow uncertainty: Apple exposes `AudioRecordingIntent`, but its documentation does not state that it overrides the background microphone privacy block. Apple DTS's explicit “no” addressed a background trigger from a Bluetooth accessory, not a genuine Action Button system invocation; Apple does not document the Action Button as an exemption. Developers testing a cold Action Button/Shortcut start report `AVAudioSession.setActive` failure on iOS 26 and iOS 27 beta. Treat a cold background start as **unproven and expected to fail**, not as a supported architecture. [Apple Developer Forums: Action Button recording experiment](https://developer.apple.com/forums/topics/app-and-system-services/app-and-system-services-widgets-and-live-activities), [Apple DTS](https://developer.apple.com/forums/thread/816408)

### Required physical-device spike

If Hex tests this path, use a real Action Button invocation of an intent that conforms to `AudioRecordingIntent`, starts the required Live Activity, and attempts the audio-session activation inside `perform()`. Do not infer success from directly calling the intent or from Simulator. Test:

| Starting state | Expected result |
| --- | --- |
| Hex foreground | Recording should start; baseline only. |
| Hex recently backgrounded but session inactive | Privacy-sensitive; likely failure. |
| Hex suspended | Likely failure. |
| Hex terminated | Likely failure. |
| Device unlocked vs. locked | Test separately; lock state may add authorization constraints. |
| Existing active Hex audio session | Start/stop or pause/resume is the most plausible supported use. |

Do not replace the working foreground shortcut unless the full matrix passes repeatedly on the physical iOS 27 device.

## iOS 27 execution targets

`allowedExecutionTargets = .main` means the system performs the intent in the main app **process**. Apple documents execution targets as process selection among the main app, an App Intents extension, and a WidgetKit extension. Foreground/background behavior remains a separate choice controlled by `supportedModes`. [Apple: `IntentExecutionTargets`](https://developer.apple.com/documentation/appintents/intentexecutiontargets), [Apple: `.main`](https://developer.apple.com/documentation/appintents/intentexecutiontargets/main), [Apple: intent modes](https://developer.apple.com/documentation/appintents/intentmodes)

Therefore `.main` does not imply that Hex is visible, does not return to another app, and does not grant microphone access. It can ensure shared in-process state is available when an otherwise-valid intent executes.

## Recommended UX

1. **Default, dependable:** hold Action Button → Hex opens and arms → one bottom-edge swipe back → dictate from the keyboard.
2. **Optional fixed-app shortcut:** Arm Hex → wait until armed → Open App (for example, Messages or ChatGPT). This removes the swipe only for a preselected destination.
3. **Next spike:** genuine `AudioRecordingIntent` + Live Activity on the physical phone. Keep it isolated and expect the privacy boundary to reject cold microphone activation.
4. **After arming:** use the Live Activity/Dynamic Island for visible armed/recording status and stop/disarm controls. Apple specifically recommends lightweight surfaces such as Live Activities for Action Button actions that should preserve the current context. [Apple: Action button HIG](https://developer.apple.com/design/human-interface-guidelines/action-button)

The key architectural distinction is: **App Intents can arm shared software state in the background; only an already-authorized, active containing-app audio session makes keyboard dictation operational.**
