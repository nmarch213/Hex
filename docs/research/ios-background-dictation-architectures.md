# iOS Background Dictation Architectures

Research for the personal iOS keyboard prototype in [GitHub issue #1](https://github.com/nmarch213/Hex/issues/1) and the keyboard handoff probe in [issue #10](https://github.com/nmarch213/Hex/issues/10), captured 2026-08-21. The target is one owner-operated iPhone on iOS 27 beta, a custom Hex keyboard, an iOS containing app, and Ronin reachable through Tailscale. The desired interaction is: tap a button in the keyboard, speak in the current host app, send audio to Ronin, and insert the returned Parakeet transcript at the current cursor.

This note is limited to documented Apple APIs, Apple-published guidance, and the Hex device/simulator observations called out explicitly below. It does not treat private selectors, responder-chain tricks, process inspection, or undocumented entitlements as architecture.

## Executive conclusion

There are two separate problems:

1. A custom keyboard cannot own the microphone. Full Access enables network access and App Group writes, but Apple still excludes microphone and speaker access from the keyboard extension sandbox.
2. A custom keyboard cannot rely on opening its containing app. Apple’s extension guide grants containing-app URL opening to Today widgets, not custom keyboards, and Apple DTS describes direct app-extension URL opening as deliberately disallowed. In Hex’s current iOS 27 device/simulator probe, `NSExtensionContext.open(_:completionHandler:)` returned `false` from the keyboard in repeated trials.

The best candidate for the requested one-tap keyboard experience is therefore a **warm containing-app recorder**:

```text
Hex app foregrounded
  └─ user explicitly taps “Arm keyboard dictation”
       └─ app owns microphone + active audio background session
            └─ user returns to Messages/Mail/etc.
                 └─ Hex keyboard writes a request to the App Group mailbox
                      └─ already-running recorder starts/stops request-scoped capture
                           └─ app sends audio to Ronin over Tailscale
                                └─ keyboard reads result and calls textDocumentProxy.insertText(...)
```

This can make the keyboard button fast and avoid an app switch for each Dictation, but it is not a cold-start solution. The user must arm the recorder first; the microphone indicator remains visible while the audio input is active; the session consumes battery; calls, route changes, permission changes, memory pressure, termination, and force-quit can still revoke it. Apple’s own audio guidance says to deactivate a recording session when it is not actively being used, so an always-armed mode is an explicit personal-prototype tradeoff, not a generic keep-alive technique. [AVAudioSession recording category](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record), [Audio Session Programming Guide: audio guidelines](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioGuidelinesByAppType/AudioGuidelinesByAppType.html)

There is one important iOS 27-era alternative: an `AudioRecordingIntent` can describe recording to the system, and WidgetKit Controls can expose an App Intent from Control Center, the Lock Screen, or the Action button. Apple requires a Live Activity to remain active while an `AudioRecordingIntent` records on iOS, iPadOS, or watchOS. This is a promising **system-surface trigger** for a cold background recording experiment, especially on an iPhone with an Action button, but it is not a documented bridge from a custom-keyboard button. It needs a separate user interaction outside the keyboard and should be tested on the target iOS 27 build. [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent), [Creating controls to perform actions across the system](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system), [Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)

PushKit VoIP, silent APNs, Darwin notifications, App Group sockets, Live Activities, and ordinary local/network sockets do not provide a reliable way for a keyboard tap to wake a suspended or terminated containing app and seize the microphone. PushKit and Push to Talk are specialized communication products with different user-visible semantics and server requirements; they should not be repurposed as a private dictation wake mechanism. [Apple DTS: iOS background execution limits](https://developer.apple.com/forums/thread/685525), [PushKit VoIP rules](https://developer.apple.com/documentation/pushkit/pkpushtype/voip), [Push to Talk](https://developer.apple.com/documentation/pushtotalk)

If persistent microphone capture is unacceptable, the supported fallback remains: leave a durable capture request in the keyboard, tell the user to open Hex manually, start recording when Hex becomes foreground, and return to the host app manually. That is the only option in this set that does not trade away either a visible warm microphone session or an additional user action.

## 1. The keyboard-level input surface

### What a custom keyboard can do

Apple defines a custom keyboard as a separate, memory-limited extension process. Its supported text boundary is `UITextDocumentProxy`: insert or delete text, move the insertion point, inspect limited surrounding context, read selected text, and use marked text for composition. The keyboard does not receive a direct reference to the host app’s text view. [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [Handling text interactions in custom keyboards](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards), [`UITextDocumentProxy`](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)

The final delivery operation should remain request-scoped and direct:

```swift
guard result.recordID == pending.recordID,
      result.documentIdentifier == textDocumentProxy.documentIdentifier,
      result.state == .completed
else { return }

textDocumentProxy.insertText(result.transcript)
```

The `documentIdentifier` is useful as a stale-result guard, but it is not a durable insertion handle. After an app switch, keyboard recreation, field change, or cursor movement, the keyboard must validate the current destination again before inserting. A result mailbox should have an explicit consumed state so a keyboard process restart cannot insert the same transcript twice.

The keyboard can implement a full QWERTY layout and its own glide recognizer. Apple does not expose the implementation of the system keyboard or QuickPath to third-party keyboards; ordinary keyboard expectations such as autocorrection, capitalization, and a keyboard-switch affordance remain the extension’s responsibility. The system globe API only advances to the next enabled keyboard or presents the system picker. [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [Configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface), [`UIInputViewController.advanceToNextInputMode()`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/advancetonextinputmode%28%29)

### The system dictation key is not a Hex audio hook

`UIInputViewController.hasDictationKey` is only a declaration to the system. Apple says that setting it to `true` disables the system dictation key because the custom keyboard has its own dictation key. It does not grant the extension microphone access, return Apple’s audio stream, or route Apple Dictation through Ronin. Leaving the system key available could offer Apple’s own dictation as a fallback, but its transcript is not a controlled input to Hex’s Parakeet pipeline. [`hasDictationKey`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/hasdictationkey), [Configuring a custom keyboard interface: indicate dictation support](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)

### Full Access is necessary but insufficient

With `RequestsOpenAccess` enabled and **Allow Full Access** granted, the keyboard can use the network and write to its shared App Group container. Without Full Access, the extension should fail closed and provide only local keyboard behavior. Apple’s current open-access guide explicitly retains “no access to microphone and speaker” in the custom-keyboard restrictions. [Configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard), [`RequestsOpenAccess`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionattributes/requestsopenaccess)

Apple’s archived App Extension Programming Guide states the same boundary in broader terms: app extensions cannot access a device camera or microphone (with historically documented exceptions for iMessage extensions), cannot access `UIApplication.sharedApplication`, and cannot perform long-running background tasks. [App Extension Programming Guide: understand how an app extension works](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)

## 2. What can signal the containing app

An App Group gives the containing app and keyboard a common storage and IPC boundary. Apple documents shared user defaults, the group container URL, and additional same-team IPC mechanisms including Mach IPC, XPC, POSIX semaphores/shared memory, and UNIX domain sockets. This describes how processes can communicate when they are executing; it is not a promise that a write or signal resumes a suspended process. [Configuring App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups), [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups), [`UserDefaults.init(suiteName:)`](https://developer.apple.com/documentation/foundation/userdefaults/init%28suitename%3A%29)

| Mechanism | Durable data | Reaches an already-running app | Wakes a suspended app | Relaunches a terminated/force-quit app | Hex decision |
| --- | --- | --- | --- | --- | --- |
| App Group file or shared `UserDefaults` | Yes, if written atomically and coordinated | App can poll/read immediately | No | No | Primary mailbox |
| Darwin notification | No payload; use as a nudge beside durable state | Yes, if the observer process and run loop are alive | No | No | Optional low-latency hint, never the source of truth |
| App Group UNIX socket / semaphore / shared memory | No durable state unless paired with a file/database | Yes, while both endpoints execute | No | No | Not needed for MVP |
| Mach/XPC between same-team members | Process communication is possible under App Group rules | Only while the endpoint is alive and permitted | No general wake guarantee | No | Do not make it the keyboard-to-app wake path |
| `NSExtensionContext.open` URL | No | Not a supported custom-keyboard launch contract | No | No | Keep only as best-effort attempt with manual fallback |
| Local or Tailscale network socket | Depends on protocol | Yes, while the app has runtime | No general wake guarantee | No | Ronin transport only after capture starts |
| Background `URLSession` transfer | Transfer state is durable | Completion can relaunch the containing app for that transfer | Only for transfer completion | Not a command channel | Not a microphone trigger |
| Silent APNs (`content-available`) | Payload can carry a small command | Yes, when delivered | Sometimes, under system policy | Not reliable after force-quit | Not suitable for a per-keystroke trigger |
| PushKit VoIP | Push payload | Yes, for a real VoIP call | Yes, for the specialized call contract | Yes, under that contract | Do not repurpose |
| Push to Talk | Channel state and PTT push payload | Yes, while a channel is active | Yes, for PTT events | System-managed restoration rules | Only if Hex becomes a real PTT service |

### App Group files and defaults

Use a small, durable mailbox in the App Group. The keyboard writes a command and the app writes state/result records. File replacement or a small SQLite/Core Data store is preferable to treating a multi-key `UserDefaults` update as a transaction. Apple’s extension guidance requires coordinated shared-container access to avoid data corruption and specifically recommends synchronization/locking for shared data. [Sharing data with your containing app](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html), [Technical Note TN2408: accessing shared data from an app extension](https://developer.apple.com/library/archive/technotes/tn2408/_index.html)

The mailbox should contain only request-scoped state:

```text
CaptureRequest {
  id: UUID
  state: requested | capturing | stopping | processing | completed | failed | consumed
  documentIdentifier: UUID?
  createdAt: Date
  updatedAt: Date
  errorCode: String?
}

CaptureResult {
  id: UUID
  state: completed | failed
  transcript: String?
  documentIdentifier: UUID?
  consumedAt: Date?
}
```

Do not use the mailbox as a hidden transcript archive. Retain only the latest bounded result needed to survive a keyboard process restart, and clear it after successful insertion or an explicit user discard.

### Darwin notifications

Apple’s Core Foundation documentation describes the Darwin notification center as system-wide, without per-user sessions. Notifications carry no useful payload through this API, and delivery requires a running run loop. Several parameters are ignored by the Darwin center. [`CFNotificationCenterGetDarwinNotifyCenter`](https://developer.apple.com/documentation/corefoundation/cfnotificationcentergetdarwinnotifycenter%28%29), [`CFNotificationCenterAddObserver`](https://developer.apple.com/documentation/corefoundation/cfnotificationcenteraddobserver%28_%3A_%3A_%3A_%3A_%3A_%3A%29)

Apple DTS is explicit about the lifecycle boundary: Darwin notifications do not resume or relaunch a process that is suspended or terminated. The same DTS guidance says there is no general way to resume an iOS app in the background in response to IPC. [Apple DTS: detecting iPhone lock/unlock](https://developer.apple.com/forums/thread/69333), [Apple DTS: iOS background execution limits](https://developer.apple.com/forums/thread/685525)

The correct pattern is therefore:

```text
write durable command file
  -> post Darwin “command changed” hint
       -> active recorder reads file immediately
            -> if no callback arrives, active recorder’s short poll notices the file
```

The poll is not intended to wake a sleeping app. It covers notification loss, observer setup races, and keyboard/app process churn while the app is already held alive by an active recording session.

### Direct XPC and sockets

App Groups list XPC, Mach IPC, semaphores, shared memory, and UNIX domain sockets as possible same-team communication mechanisms. None changes the app’s execution state. A socket listener cannot accept a message when iOS has suspended the listener’s process; a semaphore cannot run code in a suspended process; and a direct XPC connection does not turn a custom keyboard into a host for a containing-app service. Apple’s background-execution guidance specifically lists “resuming in the background in response to a network or IPC request” among the things iOS does not provide generally. [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups), [Apple DTS: iOS background execution limits](https://developer.apple.com/forums/thread/685525)

The new iOS 26 `ExtensionFoundation` Enhanced Security helper extensions do not solve this direction. Apple’s model has the containing app define an extension point and launch the helper; the helper cannot present UI and communicates with its host through XPC. Apple DTS notes that these helpers can be invoked by the containing app, so they provide no background-execution benefit for a keyboard trying to wake the containing app. [Creating enhanced security helper extensions](https://developer.apple.com/documentation/xcode/creating-enhanced-security-helper-extensions), [Adding support for app extensions](https://developer.apple.com/documentation/extensionfoundation/adding-support-for-app-extensions-to-your-app), [Apple DTS: iOS background execution limits](https://developer.apple.com/forums/thread/685525)

## 3. The containing app’s lifecycle and audio session

### Background audio is a real execution mode, not a keep-alive flag

UIKit normally suspends a background app shortly after it leaves the foreground. Apps with an appropriate Background Modes capability can be launched or resumed in the background for the event associated with that capability, but Apple tells developers to use these modes sparingly and only for their documented purpose. [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes), [Preparing your UI to run in the background](https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background), [About the background execution sequence](https://developer.apple.com/documentation/uikit/about-the-background-execution-sequence)

For an app that records, Apple documents the `record` or `playAndRecord` audio-session categories and says recording can continue after the app enters the background when the `audio` value is present in `UIBackgroundModes`. The user must grant microphone permission. This is the supported basis for a containing-app recorder. [`AVAudioSession.Category.record`](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record), [`AVAudioSession.Category.playAndRecord`](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playandrecord), [Requesting record permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission%28completionhandler%3A%29)

It does not follow that configuring an audio session without actively recording keeps the app executing indefinitely. Apple’s audio guidelines recommend activating the session when the user presses Record and deactivating it when recording stops or when the app is not actively using audio. A “warm” mode should therefore mean an actual active input stream, not an inactive session held open as a hidden process lease. [Audio Guidelines by App Type](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioGuidelinesByAppType/AudioGuidelinesByAppType.html), [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)

### Session loss is normal and must be observable

The audio session can be interrupted by a phone call, another higher-priority audio session, a route change, or system suspension. Apple documents `AVAudioSessionInterruptionNotification` and says that iOS deactivates most apps’ audio sessions when it suspends their processes; the app receives the notification only once it runs again. [`AVAudioSessionInterruptionNotification`](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification), [Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)

The recorder must transition to an explicit `interrupted` or `unavailable` state when:

- permission is denied or later revoked;
- audio-session activation fails because another call/session owns the microphone;
- the input route disappears;
- an interruption begins;
- the process is terminated or force-quit;
- the background audio mode is not present in the signed build; or
- Ronin/Tailscale is unavailable after capture.

The keyboard must not infer “recording succeeded” merely because it wrote a command. It should display a retry/open-Hex state until the app writes an authoritative state transition.

### Privacy indicator and battery behavior

Apple Support states that an orange status indicator means an app is using the iPhone microphone; Control Center also identifies recent microphone use. [About the orange and green indicators in the iPhone status bar](https://support.apple.com/en-us/108331), [Control access to hardware features on iPhone](https://support.apple.com/en-ph/guide/iphone/-iph168c4bbd5/ios)

Apple’s privacy guidance says not to configure an audio session for recording at launch when the app does not plan to record immediately, and the recording permission API returns silence until permission is granted. [Protecting the user’s privacy](https://developer.apple.com/documentation/uikit/protecting-the-user-s-privacy), [Requesting record permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission%28completionhandler%3A%29)

Consequences of a warm recorder:

- **Orange indicator:** visible for the whole time the app has the microphone input active, including while the user is typing normally after arming. There is no supported way to hide it.
- **Battery:** the audio input graph, process, and any network connection consume power even if Hex discards pre-arm samples. Apple warns that unnecessary background modes negatively affect battery and system performance. [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- **Privacy:** pre-arm should discard samples immediately or keep only a very small in-memory ring buffer. Do not upload or persist ambient audio before the keyboard creates a request. The user-facing app must clearly say “Hex is listening for a Dictation” and expose a stop/disarm action.
- **Session timeout:** default to an explicit idle timeout and let the user choose a longer personal value. A timeout is safer than leaving the microphone active until the next reboot, while repeated Dictations during the active window avoid the app switch.
- **Interruption:** stop request-scoped capture and report `interrupted`; do not silently resume after a phone call or route change without a new user action.

`UIApplication` background tasks are not a substitute. Apple says most apps receive roughly five seconds when entering the background, and `beginBackgroundTask` only extends time to finish a critical operation. It does not make a recorder or IPC service indefinite. [Extending your app’s background execution time](https://developer.apple.com/documentation/uikit/extending-your-apps-background-execution-time)

Force-quit is a hard boundary. Apple DTS says that swiping an app away terminates it and sets a flag preventing background launch until the user next launches it manually. The warm-session UI must therefore recover after the user opens Hex again and cannot promise to survive a force-quit. [Apple DTS: iOS background execution limits](https://developer.apple.com/forums/thread/685525)

## 4. Concrete warm-session call flow

This is the smallest architecture that can plausibly meet “tap the keyboard button and stay in the host app.” It intentionally chooses transparent microphone use over an undocumented launch shim.

### Arm

1. The user opens Hex in the foreground and taps **Arm keyboard dictation**.
2. Hex asks for microphone permission if needed and checks `AVAudioApplication.requestRecordPermission()`.
3. Hex configures the existing recording stack with an input-capable `AVAudioSession` category and the `audio` Background Modes capability. It activates the session only in response to this explicit user action.
4. Hex starts an input graph/tap and drops samples immediately, or retains only a bounded in-memory pre-roll if that is a deliberate product choice. It does not send pre-arm audio to Ronin.
5. Hex writes an App Group state record such as `armed`, with a session UUID, app version, model/server configuration reference, and expiration time.
6. Hex presents an unmistakable armed state and a disarm action. A Live Activity is optional for this custom warm mode, but it is a useful status/stop surface; if the implementation is exposed through `AudioRecordingIntent`, the Live Activity becomes mandatory while recording.
7. The user returns to the host app using the app switcher. The recorder continues because it is actively using the audio background mode.

### Start a request from the keyboard

1. The keyboard checks `hasFullAccess`, reads the current `documentIdentifier`, and creates a new request UUID.
2. It atomically replaces the App Group command file with `{id, documentIdentifier, state: requested}`.
3. It posts a Darwin notification such as `com.nmarch213.hex.capture-command-changed`. The notification carries no authoritative data; the file is the source of truth.
4. The keyboard renders `starting` until the mailbox says `capturing`. It must not claim that a microphone handoff happened.
5. The already-running app observes the Darwin notification and reads the file. It also polls the mailbox at a short interval while `armed` because notification delivery can race observer setup or be dropped. This poll is safe only because the app is already held alive by active audio capture; it is not a background wake mechanism.
6. The app validates the request UUID, session UUID, expiration, and any state transition preconditions. It transitions the mailbox to `capturing`, begins retaining request-scoped audio, and updates the UI/Live Activity state if available.

### Stop, transcribe, and insert

1. The keyboard’s stop button writes `{id, state: stopping}` to the App Group mailbox and posts the same Darwin hint.
2. The app stops the request-scoped capture, restores the pre-arm discard behavior if the warm session remains active, and writes `processing`.
3. The app sends the captured audio to Ronin through the authenticated Tailscale HTTPS origin. The Ronin service returns the same request UUID and a Final Transcript; there is no cloud or offline fallback.
4. The app atomically writes `{id, state: completed, transcript, documentIdentifier}` or `{id, state: failed, errorCode}`.
5. The app posts `com.nmarch213.hex.capture-result-changed`. The keyboard observes it while visible and also polls the mailbox while a request is pending.
6. The keyboard verifies the request UUID, current `documentIdentifier`, completion state, and non-consumed status. It atomically consumes and erases the payload before calling `textDocumentProxy.insertText(transcript)`, providing at-most-once delivery: an extension crash in that narrow window may lose text but cannot duplicate it.
7. If the keyboard extension is recreated before consumption, it reloads the bounded durable result and can attempt insertion on the next active view only after the same Apple text-document identity check passes. Apple does not expose a documented field identity, so switching fields within one document remains a physical-device acceptance case rather than an API guarantee. A mismatched or missing document identity requires explicit discard.

### Session-loss paths

```text
keyboard writes requested
  ├─ app is armed + running → capturing → processing → completed
  ├─ app receives interruption → interrupted; no transcript claim
  ├─ microphone permission revoked → unavailable; open Settings/Hex
  ├─ Ronin/Tailscale fails → failed; leave host text unchanged
  ├─ app is suspended/terminated → request remains durable; opening Hex retries/reconciles
  └─ app was force-quit → no background wake; user must relaunch Hex manually
```

The keyboard must retain the existing manual fallback even in warm mode. If the app writes `unavailable` or stops updating its heartbeat, the Dictate button should say **Open Hex to arm dictation** rather than retrying private URL-opening tricks.

## 5. Other supported system-level triggers

### `AudioRecordingIntent` + Control Center/Action button

Apple’s App Intents framework includes `AudioRecordingIntent`, an intent that starts, stops, or modifies audio recording state. Apple says adopting it tells the system the app records audio and causes the system to display an audio recording indicator. On iOS, iPadOS, and watchOS, the app must start and keep a Live Activity active for the duration of recording or the system stops the recording. [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)

WidgetKit Controls can place a button or toggle in Control Center, the Lock Screen, or the Action button. Apple says a control’s App Intent can perform the action without opening the app; App Intents that conform to audio-recording/audio-playback system protocols are run in the app process rather than the widget process. [Creating controls to perform actions across the system](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system), [Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities), [App Intent](https://developer.apple.com/documentation/appintents/appintent)

This creates a potentially useful iOS 27 experiment:

```text
Action Button or Control Center: “Start Hex Dictation”
  -> system invokes Hex AudioRecordingIntent in Hex’s app process
       -> Hex starts request-scoped capture and Live Activity
            -> keyboard reads the App Group state and inserts the result
```

It does not solve the literal keyboard-button path: Apple provides no documented API for a custom keyboard to invoke an arbitrary App Intent in its containing app. It may nevertheless be the fastest supported cold-start control on a compatible iPhone with an Action button, and it is worth testing before committing to permanent warm capture. The test must verify microphone permission, background audio activation, Live Activity lifetime, Tailscale availability, and whether the keyboard remains the current text destination while the intent runs.

### Live Activities

Live Activities are a good status and stop/retry surface, not a hidden process lease. People can tap a Live Activity to launch the app, and interactive Live Activity buttons can perform an App Intent without launching the app. `LiveActivityIntent` runs in the app process, which makes it useful for a visible **Stop** action or a system-surface **Start** action. [ActivityKit](https://developer.apple.com/documentation/activitykit), [Launching your app from a Live Activity](https://developer.apple.com/documentation/activitykit/launching-your-app-from-a-live-activity), [LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent)

For Hex, use the Live Activity to show `armed`, `capturing`, `processing`, `failed`, and `completed` states and to provide a reliable disarm/stop control. Do not assume that displaying a Live Activity keeps the app executing or owning the microphone; the audio session/background mode or a system audio-recording intent supplies that behavior.

### Push to Talk

Push to Talk is Apple’s supported framework for walkie-talkie-style audio. It provides system UI controls, an ephemeral APNs token, channel management, and an audio-session callback that permits recording while the app is in the background. A channel must be joined while the app is foregrounded with explicit user interaction; only one PTT channel can be active on the system. [Push to Talk](https://developer.apple.com/documentation/pushtotalk), [Creating a Push to Talk app](https://developer.apple.com/documentation/pushtotalk/creating-a-push-to-talk-app), [`PTChannelManager`](https://developer.apple.com/documentation/pushtotalk/ptchannelmanager), [`PTChannelManagerDelegate.didActivate`](https://developer.apple.com/documentation/pushtotalk/ptchannelmanagerdelegate/channelmanager%28_%3Adidactivate%3A%29)

PTT is not a good Hex shortcut:

- it models a channel and audio transmission, not a private single-user dictation transaction;
- its network wake path is APNs/Push to Talk, not a Tailscale-local keyboard command;
- it brings system PTT UI and status semantics;
- it still requires an explicit foreground join/arming step; and
- it would make the user’s voice-to-text tool look like a communication service.

Do not use legacy unrestricted VoIP entitlements. Apple says VoIP pushes must initiate real calls and be reported to CallKit; repeated noncompliance can stop the system from launching the app for VoIP pushes. [Responding to VoIP notifications from PushKit](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit), [`PKPushTypeVoIP`](https://developer.apple.com/documentation/pushkit/pkpushtype/voip)

## 6. Why APNs and background tasks are not the keyboard bridge

### Silent APNs

Apple’s background notification API can wake an app in the background for a content refresh, but Apple explicitly says delivery is not guaranteed, notifications can be throttled, the system may hold only the newest one, and a force-quit/killed app discards a held notification. The app receives a limited execution window and must call the fetch completion handler. [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

This is unsuitable for the keyboard’s per-Dictation start/stop commands because:

- the keyboard would need a provider path to APNs rather than an immediate local signal;
- the command could be delayed, coalesced, or dropped;
- a background notification is not permission to capture the microphone indefinitely; and
- Ronin/Tailscale being reachable does not imply Apple push infrastructure is available or desirable.

APNs could be useful for a noninteractive “transcription job finished” notification in a different product, but not for this local keyboard control loop.

### Background URLSession

Apple supports background URLSession transfers started by an extension; when a transfer completes, iOS can relaunch the containing app to deliver the completion event. This is a transfer-completion contract, not a low-latency command or microphone-start contract. [App Extension Programming Guide: performing uploads and downloads](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html), [Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)

It may be useful later for uploading a completed audio file if the keyboard were the producer, but the keyboard is not allowed to produce microphone audio. It does not help Hex wake the recorder when a keyboard button is tapped.

### `BGAppRefreshTask`, `BGProcessingTask`, and `BGContinuedProcessingTask`

Background Tasks are scheduler mechanisms for refresh or bounded processing. Apple DTS cautions that there is no guaranteed periodic execution and no general IPC wake. iOS 26’s `BGContinuedProcessingTask` starts in the foreground and can continue a user-initiated workload after the user backgrounds the app, but Apple describes it for jobs such as Core ML, image processing, and network work; it can be terminated under resource pressure and does not replace the audio background mode. [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados), [`BGContinuedProcessingTask`](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask), [Apple DTS: iOS background execution limits](https://developer.apple.com/forums/thread/685525)

Use a continued-processing task to finish a bounded transcription transform if measurement shows it helps; do not use it as a hidden microphone daemon or a keyboard wake mechanism.

## 7. iOS 27 status and personal signing

Apple’s release page lists iOS 27 beta 6 (24A5418b) on August 17, 2026. The current iOS 27 documentation expands App Intents and system controls, including audio-recording intents, but the custom-keyboard documentation still describes the keyboard as an isolated extension with no microphone access. No iOS 27 release note or public API found in this research grants custom keyboards microphone ownership or a general containing-app launch path. Treat the iOS 27 behavior as beta and re-run the physical-device handoff and warm-session matrix on each beta update. [Apple Developer releases](https://developer.apple.com/news/releases/), [iOS & iPadOS release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/), [What’s new in iOS 27](https://developer.apple.com/ios/whats-new/), [Configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)

The fact that Hex is for one personal phone changes distribution and review logistics, not the iOS process/security model:

- A Personal Team can install development builds, but profiles expire after seven days and have tight device/app limits. [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- A paid developer account can install to registered devices or use internal TestFlight without a public App Store listing. [Distributing your app to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices), [Create a development provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile)
- App Review is not the immediate gate for a direct development install, but documented APIs and entitlements are still the only stable contract. Apple’s developer agreement requires documented APIs and prohibits private APIs; a personal build does not make private responder-chain or runtime selectors supported. [Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/), [Apple DTS: app extensions cannot open URLs directly](https://developer.apple.com/forums/thread/764570)

So a personal build may reasonably experiment with an explicit warm microphone mode and accept a higher battery cost, but it should not encode private API assumptions as the core architecture.

## 8. Ranked recommendation for Hex + Ronin

### 1. Warm containing-app recorder + App Group mailbox — prototype first

This is the only candidate that can preserve the keyboard as the current host surface while allowing a custom Hex button to delimit recording. It reuses the existing Ronin/Tailscale/Parakeet path and makes every state transition durable.

Prototype requirements:

- explicit **Arm keyboard dictation** action in Hex;
- an active input graph while armed, with pre-arm samples discarded;
- a clear orange-mic/armed indicator and a one-tap disarm action;
- App Group atomic command/result files;
- Darwin notifications as hints plus polling as the recovery path;
- request UUID + `documentIdentifier` validation;
- short idle timeout;
- interruption, route, permission, termination, and Ronin failure states;
- manual-open fallback whenever the app heartbeat or session state disappears.

This is a product decision with a privacy and battery cost. Measure it before polishing the keyboard.

### 2. `AudioRecordingIntent` exposed as Control Center/Action Button — supported cold-start spike

Implement a tiny iOS 27 experiment with a Control Center/Action Button control and a Live Activity. Verify whether the system runs Hex in the background, permits the app to activate audio, and updates the App Group state while Messages remains foreground. If this works, it provides a supported one-gesture start surface and may eliminate the need for an always-warm session when the user is willing to use the Action button. It cannot be invoked directly by the custom keyboard button, so it is complementary rather than a complete replacement.

### 3. Manual app activation + durable request — baseline and recovery path

Keep the current supported fallback. A failed keyboard handoff leaves `captureRequested`; opening Hex foreground starts recording automatically. This is the testable baseline for every device and every session-loss scenario.

### 4. PTT — investigate only if the product changes into a communication service

PTT is technically capable of background audio activation, but it adds a channel, APNs, system UI, explicit join, and communication semantics that do not fit single-user dictation. It should not be added merely to obtain a wake primitive.

### 5. Silent APNs, PushKit VoIP, private URL shims, or process tricks — reject

These either lack the necessary reliability, violate the specialized API contract, or already failed in Hex’s iOS 27 probe. They should not be the next implementation direction.

## 9. Device test matrix for the warm-session spike

Run this on the physical iPhone, not only Simulator:

| Test | Expected evidence |
| --- | --- |
| Arm Hex, return to Messages, wait 60 seconds | Orange mic indicator remains; Hex heartbeat remains fresh; battery/current draw is recorded |
| Tap Dictate once | Keyboard command appears; app transitions to `capturing` without app switch |
| Speak and tap Stop | App stops request capture, sends exactly one Ronin request, writes one result |
| Return result while keyboard stays visible | Keyboard inserts once at matching cursor/document ID |
| Dismiss/reopen keyboard before result | Durable result survives; no duplicate insertion |
| Move cursor or switch field before result | Keyboard refuses stale destination or asks for explicit insertion |
| Disarm while idle | Audio session deactivates; orange indicator disappears; app can be suspended |
| Receive a phone call during capture | State becomes `interrupted`; no false transcript; user can re-arm |
| Disable microphone permission | State becomes `unavailable`; no silent audio or retry loop |
| Disable Tailscale/Ronin | State becomes `failed`; host text remains unchanged |
| Lock phone while armed and while capturing | Measure whether capture remains active; record route/session transitions |
| Force-quit Hex from app switcher | Keyboard cannot wake it; mailbox remains recoverable only after manual Hex launch |
| Kill Hex under memory pressure | Keyboard shows stale-heartbeat/manual-open state and recovers after relaunch |
| Tap Action Button/Control Center AudioRecordingIntent | Compare cold-start latency and Live Activity/audio-session behavior with warm mode |
| Install over an existing build | Verify keyboard enablement, Full Access, App Group, and token persistence |

Record separate timings for arm, keyboard command delivery, audio start, Stop, Ronin upload, Parakeet processing, result publication, and `insertText`. Do not hide app-switch or mic-activation time inside transcription latency.

## Sources checked

Primary Apple sources used above:

- [Configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)
- [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)
- [Configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)
- [Handling text interactions in custom keyboards](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards)
- [App Extension Programming Guide: understand how an app extension works](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)
- [App Extension Programming Guide: sharing data and background transfers](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)
- [Configuring App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)
- [Darwin notification center](https://developer.apple.com/documentation/corefoundation/cfnotificationcentergetdarwinnotifycenter%28%29)
- [Preparing your UI to run in the background](https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background)
- [About the background execution sequence](https://developer.apple.com/documentation/uikit/about-the-background-execution-sequence)
- [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- [Extending your app’s background execution time](https://developer.apple.com/documentation/uikit/extending-your-apps-background-execution-time)
- [AVAudioSession recording category](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)
- [AVAudioSession interruption notification](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification)
- [Requesting record permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission%28completionhandler%3A%29)
- [Protecting the user’s privacy](https://developer.apple.com/documentation/uikit/protecting-the-user-s-privacy)
- [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Responding to VoIP notifications from PushKit](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit)
- [Push to Talk](https://developer.apple.com/documentation/pushtotalk)
- [Creating a Push to Talk app](https://developer.apple.com/documentation/pushtotalk/creating-a-push-to-talk-app)
- [ActivityKit](https://developer.apple.com/documentation/activitykit)
- [LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent)
- [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)
- [Creating controls to perform actions across the system](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)
- [Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- [Apple Developer releases](https://developer.apple.com/news/releases/)
- [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)

Apple DTS guidance used for lifecycle interpretation:

- [iOS background execution limits](https://developer.apple.com/forums/thread/685525)
- [Darwin notifications do not relaunch suspended processes](https://developer.apple.com/forums/thread/69333)
- [App extensions are not allowed to open URLs directly](https://developer.apple.com/forums/thread/764570)

Privacy indicator reference:

- [About the orange and green indicators in the iPhone status bar](https://support.apple.com/en-us/108331)
