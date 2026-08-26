# Wispr Flow iOS 27 arming and switchback

Research for Hex's keyboard-to-companion-app arming handoff, captured 2026-08-21. Sources are limited to Apple's public documentation and iOS 27 SDK plus Wispr's first-party help center and release notes. Statements about Wispr's internal implementation are explicitly labeled as inference because Wispr does not publish that code or architecture.

## Answer

| Question | Finding |
| --- | --- |
| Can a custom keyboard open its containing app from a tap? | **Not through a documented keyboard-extension API.** Apple's URL-opening API for extensions explicitly names Today and iMessage extensions, not custom keyboards. Wispr demonstrably makes tapping **Start Flow** take some users to its app, so it is using behavior beyond the documented keyboard contract. |
| Can the containing app return to whichever app was previously active? | **Not generically through a documented API.** An ordinary app can open a *known URL*, including another app's custom scheme or universal link. Apple exposes no “previous app” token or return method. |
| Did iOS 27 add a supported API for either transition? | **No documented addition was found.** The iOS 27 SDK's public `UIInputViewController` surface still contains keyboard switching, dismissal, and text-proxy APIs, but no app-opening, host-identification, or switchback API. Apple's iOS 27 beta release notes do not announce one. |
| What did Wispr change? | Wispr says its own **auto-switchback** now supports more named host apps and works on every supported iOS version, including the iOS 27 beta. That wording points to a Wispr compatibility implementation, not a new iOS 27 platform feature. |

For Hex, the smoothest honest prototype is therefore: make **Start Hex** attempt the existing best-effort launch handoff; have the containing app arm immediately when launched; attempt automatic return only for an explicitly known destination with a URL it can open; and always show the bottom-edge swipe-back instruction as the fallback. Once the background session is armed, dictation should remain entirely controllable from the keyboard.

## Supported Apple API boundary

### Keyboard extension to containing app

Apple's current `NSExtensionContext.open(_:completionHandler:)` documentation says each extension point decides whether URL opening is supported, then specifically lists the Today and iMessage extension points on iOS. It does not list custom keyboards. Apple's extension architecture guide is stronger: it says a Today widget, “and no other app extension type,” can request that the system open its containing app. It also says extensions cannot access `UIApplication.shared`. Therefore, a keyboard button invoking `extensionContext.open(hextracer://arm)` is a reasonable device experiment for a private build, but success is **not** guaranteed by the public contract. [Apple: `NSExtensionContext.open`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)), [Apple: app-extension communication and restrictions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)

This matches the current physical Hex result—iOS rejected the handoff—but that device observation is corroborating evidence, not the basis of the platform conclusion.

### Containing app to previous app

From a foreground app, `UIApplication.open(_:options:completionHandler:)` can open a resource represented by a URL. If another installed app handles that URL scheme, iOS launches that app and brings it forward. The call therefore supports a return to a **known destination with a known URL**, not a generic return to the app that happened to be in front before Hex. [Apple: `UIApplication.open`](https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:))

Apple's documented custom-keyboard surface provides the text destination proxy plus actions to dismiss the keyboard or move to another enabled keyboard. It exposes neither the host application's bundle identifier nor a durable host-app handle. [Apple: `UIInputViewController`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller), [Apple: creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)

Consequently, there is no supported general implementation of either:

- “return to the previously active app”; or
- “return to the app that owns this `UITextDocumentProxy`.”

Hex could use `UIApplication.open` for a small explicit allowlist of destination apps with stable deep links. That still requires Hex to know which destination to choose; the public keyboard API does not provide that identity.

### iOS 27 check

The public header in Xcode 27.0 beta (`27A5228h`, iPhoneOS 27.0 SDK) was inspected directly. `UIInputViewController.h` still declares `dismissKeyboard`, `advanceToNextInputMode`, `handleInputModeList`, the lexicon request, and text-proxy properties; it adds no URL-opening, containing-app, host-identity, or return API. `NSExtensionContext.h` retains the generic `openURL` declaration, whose extension-point restriction remains documented as above. Apple's current iOS 27 beta release notes contain no custom-keyboard launch or app-switchback feature. [Apple: iOS & iPadOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes), [Apple: `UIInputViewController`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller)

This supports the narrow conclusion that **there is no documented iOS 27 solution**. It cannot prove that every undocumented behavior or private entitlement is absent.

## What Wispr officially documents

Wispr's current help center says that on iOS 26.4 and later, activating the microphone from its keyboard **may take the user to the Wispr Flow app**. Its fallback tells the user to swipe right on the bottom bar to return; Wispr notes that some users still see older automatic switchback behavior. [Wispr: iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)

Wispr's iOS 26.4 article describes the launch more directly: tapping **Start Flow** used to briefly open Flow and return automatically; on some iOS 26.4 builds, the user instead swipes back. The arming screen says **Flow is on** and **You can start dictating now**. Wispr also reports fixes for returning to the wrong app and for failing to start dictation after the manual swipe. [Wispr: adapting to iOS 26.4](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4)

Wispr subsequently announced that auto-switchback works across all its supported iOS versions, including the iOS 27 beta, and that it added “native switchback support” for a named list of apps such as Claude, ChatGPT, Gemini, Grok, Perplexity, LinkedIn, and others. The same first-party page describes auto-switchback as returning to the host app. [Wispr: What's new, “Flow now switches back automatically for more apps”](https://wisprflow.ai/whats-new)

Those sources describe partially overlapping, rollout-dependent experiences rather than one universal guarantee:

- **Start handoff:** the keyboard can take the user to Flow to activate its session;
- **automatic switchback:** available for supported combinations of Flow version, iOS build, and host app;
- **fallback:** a manual right-edge/bottom-bar swipe remains documented for some iOS 26.4-and-later users.

Wispr also documents an idle background Flow session with a configurable timeout and says it releases the microphone after each dictation even while its Live Activity can persist. This is consistent with a containing-app-owned audio session that stays ready between keyboard dictations. [Wispr: iOS microphone indicator and Flow session](https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios)

## Likely Wispr implementation — inference, not sourced fact

The following is the smallest architecture consistent with both vendors' published behavior:

1. The keyboard writes an activation request into shared state and uses an undocumented or otherwise keyboard-specific launch technique to foreground Flow. Apple does not document that transition for custom keyboards, and Wispr does not disclose its mechanism.
2. Flow's containing app activates or refreshes its background audio session.
3. For a host app Wispr explicitly supports, Flow opens a known deep link or URL scheme for that app. The named-app nature of Wispr's release note makes an app-specific URL mapping the most plausible explanation for “native switchback support.” This is an inference; Wispr may use a different compatibility mechanism.
4. When the host is unknown or the mechanism fails on that iOS build, Flow leaves the user on its armed screen and relies on the system's manual swipe-back gesture.
5. After return, the keyboard sends start/stop commands through shared state while the containing app owns audio in the background.

Two pieces remain unknown and should not be presented as established Wispr behavior: how its keyboard discovers the host app, and precisely how its keyboard launches Flow. Neither capability appears on Apple's public custom-keyboard API surface.

## Implementation implications for Hex

1. Keep session arming separate from per-dictation recording. A successful cold handoff should open Hex directly into an arming route; no second tap in the app should be required.
2. Keep the keyboard's launch call behind a replaceable adapter and treat a `false` completion or no foreground transition as an ordinary unsupported-path result, not as an audio failure.
3. Show a full-screen **Hex is ready — swipe back to continue** fallback immediately after arming. It remains necessary even if an automatic path works on the owner's current beta.
4. Add automatic return only where Hex has an explicit, tested destination URL. Do not imply this works for arbitrary apps.
5. Preserve the current warm-session UX: after returning, **Start Voice** and **Stop Voice** must work in the keyboard without reopening Hex until the configured arm window expires.
6. Re-run the exact physical-device handoff test after each iOS beta update. Wispr's own documentation shows that this behavior can vary by OS build, app, and rollout.
