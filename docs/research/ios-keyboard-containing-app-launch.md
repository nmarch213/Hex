# iOS 27 custom keyboard → containing-app launch contract

Research captured 2026-08-21 for Hex's personal iOS keyboard prototype. Sources are limited to current Apple Developer documentation, Apple's archived App Extension Programming Guide, Apple Developer Forums answers by Apple engineers, and the public interfaces bundled with Xcode 27 beta.

## Answer

There is **no documented iOS 27 API that lets a custom keyboard extension foreground its containing app from a button inside `UIInputViewController`**.

iOS 27's new `allowedExecutionTargets = .main` and iOS 26's `supportedModes = .foreground(.immediate)` do not change that extension-point boundary. They configure **where and in what mode the system performs an App Intent after a supported system surface has invoked it**. Apple documents surfaces such as Shortcuts, Siri, Spotlight, widgets, Live Activities, and controls. Apple does not document an ordinary control inside a custom keyboard as such a surface.

Calling an intent's `callAsFunction(donate:)` method directly inside the keyboard is valid source code, but Apple documents that method as resolving the intent's parameters and calling its `perform()` method. Apple does not document it as submitting a new cross-process system invocation, overriding the keyboard extension's restrictions, or foregrounding the containing app. Combining direct `callAsFunction`, `.foreground(.immediate)`, and `.main` is therefore **not a supported keyboard-to-app launch mechanism**.

| Attempt | Public API status in a custom keyboard | Finding |
| --- | --- | --- |
| `extensionContext.open(hexURL)` | API exists, but launch use is unsupported for this extension point | Current docs list Today and iMessage as the iOS extension points that support it; custom keyboards are absent. |
| `UIApplication.shared.open(...)` | Unavailable | `sharedApplication` is explicitly unavailable to iOS app extensions. |
| Responder-chain / Objective-C runtime `openURL:` | Private bypass | Apple DTS calls this a deliberate restriction and warns that runtime bypasses create compatibility failures. |
| `SomeIntent().callAsFunction()` | Supported for directly performing intent functionality; **not documented as an app-launch request** | It resolves parameters and calls `perform()`. No documentation promises a process handoff from an arbitrary app extension. |
| `supportedModes = .foreground(.immediate)` | Supported App Intents metadata | It asks the system to foreground the app before a system-executed intent; it does not make the keyboard a supported invocation surface. |
| `allowedExecutionTargets = .main` | New beta App Intents metadata in iOS 27 | It chooses the main app process as the performer of an accepted intent request. It neither identifies the containing app as launchable from a keyboard nor grants foreground authority. |
| `OpenURLIntent` called from the keyboard | Unsupported use | Apple documents it for universal links returned by another intent or placed on an interactive widget/Live Activity, not as a general extension launcher. |

## 1. `NSExtensionContext.open` does not cover custom keyboards

The current [`NSExtensionContext.open(_:completionHandler:)`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)) documentation says that each extension point decides whether URL opening is supported. For iOS, it names the Today and iMessage extension points. It does not name the custom-keyboard extension point (`com.apple.keyboard-service`). Consequently, the method's presence on the generic `NSExtensionContext` type is not a promise that a keyboard's extension context will honor it.

The archived architecture guide states the older rule even more narrowly: a Today widget, and no other extension type, could request that the system open its containing app. The guide also says an extension communicates directly with its host, not its containing app, and that the containing app typically is not running. The current documentation later added the constrained iMessage case, but neither version includes keyboards. [Apple App Extension Programming Guide: extension architecture](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)

An Apple Frameworks Engineer gave a current practical interpretation in January 2025: directly launching the main app is unsupported from app extensions except the explicitly supported widget cases, and developers should file an enhancement request for other extension types. [Apple Developer Forums: “Clarification on Opening Main App from Share Extension”](https://developer.apple.com/forums/thread/773342)

**Contract result:** A keyboard may compile a call to `extensionContext.open`, but success is outside the documented keyboard contract. A `false` completion, no foreground change, or future behavioral change must be treated as normal for an unsupported use.

## 2. `UIApplication` and responder-chain launch paths are explicitly outside the contract

The public iOS 27 UIKit header marks `UIApplication.sharedApplication` with:

```objc
NS_EXTENSION_UNAVAILABLE_IOS("Use view controller based solutions where appropriate instead.")
```

That declaration is in `UIKit.framework/Headers/UIApplication.h` in the iOS 27 SDK. A normal extension build therefore rejects `UIApplication.shared.open(...)`.

Walking the responder chain, looking up `UIApplication` with `NSClassFromString`, or invoking `openURL:` with Objective-C selectors only circumvents that compile-time protection. It does not turn the operation into a public extension API. Apple DTS addressed this exact pattern: the unavailability is deliberate, app extensions are not allowed to open URLs directly, and runtime bypasses are compatibility hazards. [Apple Developer Forums: “iOS 18 ShareExtension openURL”](https://developer.apple.com/forums/thread/764570)

The iOS 27 `UIInputViewController.h` public surface reinforces the boundary. It exposes the text document proxy, full-access state, keyboard dismissal, next-input-mode actions, input-mode list handling, and supplementary lexicon access. It adds no URL-opening, containing-app activation, host-app identity, scene activation, or App Intent dispatch API. [`UIInputViewController`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller)

**Contract result:** Responder-chain and dynamically looked-up `UIApplication` launch paths are unsupported private techniques. Personal signing avoids App Review, but it cannot make the selector behavior stable or require iOS to honor it.

## 3. What `callAsFunction(donate:)` actually promises

Apple documents [`AppIntent.callAsFunction(donate:)`](https://developer.apple.com/documentation/appintents/appintent/callasfunction%28donate%3A%29-7v1om) as a convenience for directly performing the current intent's action. Its documented steps are to resolve the parameters and call the intent's `perform()` method, optionally donating the completed intent. Apple's example use case is sharing intent types with the app's underlying feature implementation.

Neither the method documentation nor its iOS 27 SDK declaration says that it:

- sends the intent to a system service as a new request;
- selects a different executable process;
- converts an arbitrary extension UI control into a supported App Intents surface; or
- grants foreground activation to an extension that otherwise cannot launch apps.

The iOS 27 public Swift interface makes `callAsFunction` available without an `iOSApplicationExtension` unavailability annotation, so calling it from extension code can compile. Compile availability only supports running intent functionality; it is not evidence of containing-app launch permission.

**Contract result:** Calling a background-capable intent's implementation from the keyboard can be useful for shared domain logic. Using that call as a foreground handoff is undocumented and unsupported.

## 4. What `.foreground(.immediate)` promises—and what it does not

[`AppIntent.supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes) configures the foreground and background modes in which the system can perform an intent. Apple defines [`IntentModes.ForegroundMode.immediate`](https://developer.apple.com/documentation/appintents/intentmodes/foregroundmode/immediate) as bringing the app to the foreground after parameter resolution and before the action runs.

Apple's WWDC25 explanation consistently frames this as behavior when an App Intent is run through App Intents integrations. The examples invoke intents through system experiences, then use the foreground mode to control launch timing. For dynamic foregrounding, Apple explicitly notes that the system or the person can deny the transition. [WWDC25: “Explore new advances in App Intents,” supported modes section](https://developer.apple.com/videos/play/wwdc2025/275/?time=591)

`supportedModes` describes an accepted intent execution. It does not document a new way for arbitrary extension code to originate such an execution. Nothing in the documentation says it supersedes the extension-point policy of `NSExtensionContext.open` or the app-extension unavailability of `UIApplication.shared`.

**Contract result:** `.foreground(.immediate)` is supported when the system invokes the intent from a supported surface. Its effect when reached only through a direct `callAsFunction` inside a custom keyboard is not promised as an app launch.

## 5. What iOS 27's `.main` execution target promises—and what it does not

iOS 27 adds [`AppIntent.allowedExecutionTargets`](https://developer.apple.com/documentation/appintents/appintent/allowedexecutiontargets) and [`IntentExecutionTargets`](https://developer.apple.com/documentation/appintents/intentexecutiontargets). Apple describes these as choosing which target performs an intent or entity query when the same intent implementation is linked into multiple targets. The available choices are:

- `.main` — main app process;
- `.appIntentsExtension` — App Intents extension process;
- `.widgetKitExtension` — WidgetKit extension process; and
- combinations or the default heuristic.

Apple's example is a widget interaction whose write must be performed in the main app rather than in the widget process. The WWDC26 session says the system normally chooses a process when an intent request arrives and that execution targets override those heuristics. [Apple: adopting App Intents, “Control where intents run”](https://developer.apple.com/documentation/appintents/adopting-app-intents-to-support-system-experiences), [WWDC26: “Discover new capabilities in the App Intents framework,” execution targets](https://developer.apple.com/videos/play/wwdc2026/345/?time=927)

Three details are decisive for the keyboard case:

1. `.main` names an **execution target**, not an invocation source or foreground entitlement.
2. A custom keyboard extension is not one of the listed execution targets.
3. Apple provides dedicated system dispatch plumbing for widget buttons, controls, Shortcuts, Siri, and similar experiences. `UIInputViewController` has no corresponding App Intent button/dispatch API.

The API is also marked beta in the current documentation. It needs testing against final iOS 27 software, but the beta status does not create a documented keyboard integration.

**Contract result:** If a supported App Intents surface invokes an intent with `.main`, the system can choose the app process to perform it. The property does not authorize a custom keyboard to foreground that process.

## 6. `OpenURLIntent` is narrower than a general launch primitive

Apple documents [`OpenURLIntent`](https://developer.apple.com/documentation/appintents/openurlintent) as an intent that opens a **universal link**. Its documented placements are:

- as the result of another App Intent; or
- directly on a button in an interactive widget or Live Activity.

Apple explicitly says it does not accept a custom URL scheme. WidgetKit separately documents supported ways to open an app: `Link`, `widgetURL`, or an `OpenIntent` attached to a control, with the required target memberships. [Apple: linking widgets and Live Activities to app scenes](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity), [Apple: creating controls that open an app](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)

Those are extension-point-specific launch contracts. Reusing `OpenURLIntent` from a keyboard controller does not import WidgetKit's activation contract into the keyboard extension.

**Contract result:** `OpenURLIntent` is a supported launcher on its documented system surfaces, not a documented keyboard escape hatch.

## 7. iOS 27 SDK audit

The public interfaces were inspected in Xcode 27 beta, build `27A5228h`, with the iPhoneOS 27.0 SDK on the Agency Mac.

Relevant declarations in `AppIntents.swiftinterface`:

```swift
@available(anyAppleOS 26.0, *)
static var supportedModes: IntentModes { get }

@available(anyAppleOS 27.0, *)
static var allowedExecutionTargets: IntentExecutionTargets { get }

func callAsFunction(donate: Bool = true) async throws

@available(anyAppleOS 27.0, *)
public struct IntentExecutionTargets: OptionSet {
    public static var main: IntentExecutionTargets { get }
    public static var appIntentsExtension: IntentExecutionTargets { get }
    public static var widgetKitExtension: IntentExecutionTargets { get }
}
```

Relevant UIKit evidence:

- `UIApplication.sharedApplication` remains `NS_EXTENSION_UNAVAILABLE_IOS`.
- `UIInputViewController.h` has no new launch or intent-dispatch member.
- `NSExtensionContext.h` still contains the generic `openURL:completionHandler:` declaration, while the online method documentation continues to define support per extension point and does not include custom keyboards.

The SDK therefore explains why the experiment compiles while the handoff remains unauthorized: App Intents types are linkable from extension code, but the keyboard extension point still has no public foreground-launch bridge.

## 8. Supported product options for Hex

Within Apple's documented contract, Hex can:

1. Ask the user to open Hex manually, arm recording, and return to the previous app with the system app-switch gesture.
2. Expose an App Shortcut, Control Center control, Lock Screen control/widget, or Action Button action. Those are supported App Intents surfaces and can legitimately use foreground intent behavior or an `OpenIntent` where Apple documents it.
3. Keep the app's armed background-audio session and App Group mailbox as the supported post-arming path, so per-dictation start/stop and insertion remain inside the keyboard.
4. Optionally notify the user and let a notification tap open Hex. Apple DTS suggests notification as the general attention mechanism for an extension, although notification delivery from each specific extension type still needs device validation.

What Hex cannot claim as supported is “tap a normal button in the custom keyboard and programmatically foreground Hex.” Any implementation that appears to do so is relying on behavior beyond Apple's published custom-keyboard contract and must be isolated as an OS-specific, replaceable experiment.

## Final classification

- **Supported:** App Intent foregrounding and `.main` execution when invoked from a documented system integration; widget/control links; manual app switching; keyboard shared-container coordination.
- **Unsupported:** `NSExtensionContext.open` as a keyboard launcher; `UIApplication` responder/runtime tricks; treating `OpenURLIntent` as a general keyboard URL opener.
- **Ambiguous but not a usable guarantee:** Whether a particular iOS 27 beta build might accidentally honor a direct `callAsFunction` composition from a keyboard. Apple documents neither that invocation path nor a resulting process/foreground transition, so a successful build or isolated device success would not establish a platform contract.
