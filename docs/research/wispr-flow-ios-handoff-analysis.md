# Wispr Flow-like iOS keyboard handoff analysis

Research captured 2026-08-21 for the Hex personal iOS dictation prototype. This answers a narrow question: whether a third-party **custom keyboard** can, with public iOS APIs, tap once to foreground its containing app for microphone arming and then return to the text field in the prior app.

## Bottom line

**No public API provides that end-to-end transition from a custom keyboard.** A keyboard can edit the active field through `UITextDocumentProxy`, switch to the next enabled keyboard, and dismiss itself. It does not receive the host app identity or a generic “return to the prior app” capability. Apple's extension guidance says that a Today widget—and no other extension type—may ask the system to open its containing app using `NSExtensionContext.open`. It also says extensions cannot access `UIApplication.shared` or the microphone. [Apple: App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html), [Apple: `UIInputViewController`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller), [Apple: Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)

That makes the physical-device result meaningful: the keyboard's URL-launch attempt may animate or dismiss UI, but it cannot be treated as a supported app-open operation. The SDK continues to expose the generic `NSExtensionContext.openURL` selector, but Apple's extension-point contract—not selector existence—decides whether an extension may use it. [Apple: `NSExtensionContext.open`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:))

Wispr's own current help identifies a supported-looking fallback rather than a universal one-tap guarantee: on iOS 26.4 and later, using its keyboard microphone **may** take the user to Flow, and the user swipes right on the bottom bar to return. Its separate iOS 26.4 note says automatic return was unavailable on some builds and documents a dedicated swipe-back screen. [Wispr: iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone), [Wispr: adapting to iOS 26.4](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4)

## Public API boundary

### What the keyboard can do

`UIInputViewController`'s public surface supplies a `UITextDocumentProxy`, `dismissKeyboard()`, `advanceToNextInputMode()`, the system keyboard-picker handler, and state such as Full Access. The text proxy provides direct field operations such as `insertText`, deletion, selection/context access, and cursor adjustment. It does **not** expose a host application bundle identifier, an application URL, a scene handle, or a previous-app token. [Apple: `UIInputViewController`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller), [Apple: `UITextDocumentProxy`](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)

That is the correct, supported delivery path once Hex's keyboard is already visible: the extension inserts the completed transcript into the active field. It does not solve cold microphone arming because Apple says ordinary app extensions cannot access the microphone. [Apple: App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)

### Custom URL schemes

An ordinary foreground app can call `UIApplication.open(_:options:completionHandler:)` for a URL, which can open a known app URL scheme or universal link. That capability is app-owned; it does not mean a custom keyboard is allowed to invoke it. The public extension guide explicitly says extensions cannot use `UIApplication.shared`, and says only the Today extension type can ask the system to open its containing app through `NSExtensionContext`. [Apple: `UIApplication.open`](https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:)), [Apple: App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)

**Verdict:** a Hex URL such as `hextracer://arm` is useful when opened by the user, an App Intent/Shortcut system surface, or another foreground app. It is not a documented custom-keyboard-to-containing-app handoff. Calling private/responder-chain `UIApplication` selectors from the extension does not change that boundary and is not a production option.

### Shortcuts and App Intents

App Intents are a good way to expose an app-owned action to system surfaces such as Shortcuts, Siri, Spotlight, the Action Button, widgets, and controls. Current SDK interfaces expose foreground/background execution modes and `continueInForeground`; those are capabilities of an intent execution requested by the system, not a keyboard API. [Apple: App Intents](https://developer.apple.com/documentation/appintents/appintent), [Apple: App Shortcuts](https://developer.apple.com/documentation/appintents/appshortcuts), [Apple: `supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)

There are two decisive limits:

1. The foreground-continuation interfaces are marked unavailable to iOS application extensions in the public SDK, so a keyboard cannot use them as a back door to foreground its container.
2. No App Intent API carries the keyboard's `UITextDocumentProxy`, host identity, or a prior-app cursor into the containing app. Foregrounding Hex consequently cannot itself insert a later transcript into the previous app.

**Verdict:** worthwhile as a deliberate arming trigger—e.g. an Action Button, Control Center control, Siri/Shortcut, or Home Screen widget starts the Hex session. It cannot make the keyboard's own **Open Hex** button reliably perform the transition or return the user to an arbitrary app.

### Live Activity and Control Center

Live Activities can present current Hex state on the Lock Screen/Dynamic Island. WidgetKit's interactive widget and Live Activity controls execute App Intents; Control Center controls do likewise. This makes them well suited to an **armed / recording / stop / unavailable** indicator and a global arm/disarm control. [Apple: Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), [Apple: Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities), [Apple: Creating controls to perform actions across the system](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)

They do not gain access to the prior application's active field and are not a custom-keyboard app-launch privilege.

**Verdict:** a strong post-prototype improvement for visible armed state and stop/disarm, but not an automatic switchback mechanism.

### Notifications

An actionable notification can offer an arm, stop, or open action after the user interacts with a system notification. The action is delivered to Hex; it is not delivered with the text proxy of whatever app had focus. [Apple: Declaring actionable notification types](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types)

**Verdict:** an acceptable recovery/status route, but neither a one-tap keyboard launch nor a text-insertion path.

## What Wispr's published UX establishes—and what it does not

### Observable first-party claims

Wispr documents all of the following:

- Its keyboard is selected through the normal iOS globe keyboard picker, and Full Access is required for its transcription. [Wispr: iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- On iOS 26.4 and later, a microphone activation from its keyboard may foreground Flow; its documented fallback is to swipe right on the bottom bar to go back. [Wispr: iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- It says a prior automatic-return behavior changed on some iOS 26.4 builds, and its replacement screen says Flow is on and tells the user to swipe across the bottom edge. [Wispr: adapting to iOS 26.4](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4)
- Its June 2026 release note claims auto-switchback for more named apps and calls out supported apps including Claude, ChatGPT, Gemini, Grok, Perplexity, Kin, and LinkedIn. [Wispr: What's new](https://wisprflow.ai/whats-new)

Wispr does **not** publish the API or mechanism behind “auto-switchback.” A named-app list is evidence that its behavior is conditional rather than a public generic return primitive, but it is not evidence of how it is implemented.

### Bounded inferences

The smallest explanation consistent with those claims and Apple's APIs is:

1. The keyboard uses App Group/shared state to request or observe an already-armed session; shared containers are a documented extension/container communication route. [Apple: App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)
2. The containing app owns the microphone session and a keyboard inserts the resulting text through its proxy. This is an inference from the microphone restriction and Wispr's behavior, not a claim that Wispr has disclosed its architecture.
3. Where an automatic return works, Flow may be using an app-specific route for a known destination or an undocumented system behavior. This is also an inference. Apple exposes no public keyboard-host identity and no generic “go back to the application containing this keyboard” call.
4. The documented, platform-resilient path is the manual bottom-edge swipe-back. That path uses iOS navigation rather than a custom keyboard's private ownership of the host app.

## Decision table for Hex

| Candidate | Can it arm Hex? | Can a keyboard invoke it as documented? | Can it restore an arbitrary host field? | Recommendation |
| --- | --- | --- | --- | --- |
| Keyboard → `hextracer://arm` | Possibly on a particular OS build | No | No | Remove it as a promised UX; retain only as a diagnostic experiment if desired. |
| App Intent / Shortcut / Action Button / Control Center | Yes | Not from the keyboard; yes from the system surface | No | Implement as the supported cold-start path. |
| Live Activity | Yes, through its App Intent controls | N/A | No | Add after core stability for armed/recording/disarm visibility. |
| Notification action | Yes | N/A | No | Recovery/status only. |
| Manual open Hex → arm → bottom-edge swipe back | Yes | Yes, because the user foregrounds Hex | Yes, via system navigation | The dependable initial UX. |
| Pre-armed background Hex + keyboard controls | Yes, once armed | Yes | Yes, because the keyboard stays in the host | The core experience to optimize. |

## Recommended product contract

1. Do not label the keyboard action **Open Hex** unless it has an actual supported launch surface. It currently promises a transition iOS does not grant this extension type.
2. Make **Arm Hex** a foreground-app/System-surface operation. When arming succeeds, immediately show an honest “Hex is armed — swipe back to continue” screen with the bottom-edge gesture. This is not a regression: Wispr itself documents that recovery flow.
3. Once returned, keep all start/stop/transcription/insertion controls in the Hex keyboard; that is where iOS grants the necessary `UITextDocumentProxy`.
4. Add an App Intent and expose it through the Action Button/Control Center as the fastest public cold-path experiment. A Live Activity then makes that state clear and supplies a stop/disarm action.
5. Treat any apparent automatic Flow-like switchback as an optional, device-and-host-specific enhancement only after a documented Apple API or a repeatable, publicly supported system behavior is identified. It must never be required for correctness.

## Primary-source basis

- Apple extension architecture and restrictions: [App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)
- Apple keyboard interface and text proxy: [`UIInputViewController`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller), [`UITextDocumentProxy`](https://developer.apple.com/documentation/uikit/uitextdocumentproxy), [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)
- Apple URL and intent surfaces: [`NSExtensionContext.open`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)), [`UIApplication.open`](https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:)), [App Intents](https://developer.apple.com/documentation/appintents/appintent)
- Apple system controls: [Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), [interactive widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities), [Control Center controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system), [actionable notifications](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types)
- Wispr's observable UX claims: [keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone), [iOS 26.4 adaptation](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4), [release notes](https://wisprflow.ai/whats-new)

### Local SDK corroboration

The inspected local Xcode iPhoneOS 26.4 SDK agrees with the documentation: `UIInputViewController.h` contains the text proxy and keyboard-dismiss/switch operations but no host-app or URL-launch method; `NSExtensionContext.h` contains the generic `openURL` selector; and `ForegroundContinuableIntent` is marked unavailable for iOS application extensions in the AppIntents module interface. This source inspection is corroborating evidence, not a substitute for the extension-point restriction in Apple's documentation above.
