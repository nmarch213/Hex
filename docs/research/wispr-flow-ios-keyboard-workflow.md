# Wispr Flow iOS Keyboard Workflow

Research for the mobile Dictation work in [GitHub issue #1](https://github.com/nmarch213/Hex/issues/1) and the glide-typing follow-up in [issue #12](https://github.com/nmarch213/Hex/issues/12), captured 2026-08-20. Sources are limited to Wispr's official product documentation and App Store listing plus Apple's documentation.

## Conclusion

Wispr Flow does not add a microphone overlay to Apple's keyboard and does not route through Apple Dictation. It installs a third-party **Flow Keyboard**. The user either switches between Apple's keyboard and Flow with iOS's globe keyboard picker, or enables Wispr's gradually rolled-out full QWERTY layout and types and dictates inside the same custom keyboard. Wispr describes iOS text delivery as direct insertion into the focused field, not clipboard Paste. [Wispr: iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone), [Wispr: fix text not pasting](https://docs.wisprflow.ai/articles/7971211038-fix-text-not-pasting-after-dictation), [Wispr App Store listing](https://apps.apple.com/us/app/wispr-flow-ai-voice-keyboard/id6497229487)

The microphone cannot belong to the keyboard extension under Apple's public API. Even with Full Access, Apple lists microphone and speaker access as unavailable to a custom keyboard. Wispr's own documentation says its dormant `Start Flow` control launches the main app, and on iOS 26.4 and later the user may have to swipe back manually before continuing. The evidence therefore indicates that Wispr uses its containing app to own a background audio session while the extension provides keyboard controls and text insertion. This is an architectural inference from the two vendors' documented behavior, not a disclosure of Wispr's private implementation. [Apple: configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard), [Wispr: adapting to iOS 26.4](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4)

## What the user does

### One-time setup

1. Install and open Wispr Flow once, complete its first-launch flow, and sign in.
2. In **Settings > General > Keyboard > Keyboards > Add New Keyboard**, add **Wispr Flow**.
3. Open Wispr Flow's entry in that keyboard list, enable **Allow Full Access**, and accept the warning.
4. Grant microphone permission to the main Wispr Flow app. If the permission prompt has not appeared, Wispr directs the user to open the main app and tap its microphone because a keyboard extension cannot present that permission prompt.

Full Access is mandatory for Flow transcription. In Apple's model, Full Access lets a keyboard use the network and write an App Group shared container; it does not add microphone access to the extension. [Wispr: iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone), [Apple: `RequestsOpenAccess`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionattributes/requestsopenaccess), [Apple: configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)

### Moving between normal typing and Flow

- From Apple's keyboard, touch and hold the globe/emoji key and choose **Wispr Flow**. A tap can cycle through installed keyboards. Apple documents the same system picker for all enabled keyboards. [Wispr: iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone), [Apple: add or change keyboards](https://support.apple.com/en-au/guide/iphone/iph73b71eb/ios)
- Flow has a **Show full QWERTY keyboard** option under its own **Settings > General**, but Wispr says the option is still a staged rollout. When enabled, the Flow keyboard contains ordinary letter, number, Shift, Delete, Space, Return, cursor-trackpad, haptic, and optional autocorrect behavior together with the microphone control. Typing and voice therefore coexist without a keyboard change. [Wispr: setup guide](https://docs.wisprflow.ai/articles/3152211871-setup-guide), [Wispr: iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- When full QWERTY is off or unavailable, Flow's keyboard-switch/`ABC` control takes the user back to the next system keyboard. Wispr also notes that iOS can reset to Apple's keyboard when the user opens a new app, after which the globe picker is needed again. [Wispr: setup guide](https://docs.wisprflow.ai/articles/3152211871-setup-guide), [Wispr: app navigation](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android)
- A custom keyboard must expose a keyboard-switch affordance when iOS requests one. A tap advances to the next enabled keyboard; a long press can present the system list. On Face ID iPhones, iOS may render the globe below the extension itself. There is no public API for enumerating enabled keyboards or jumping programmatically to one specific keyboard. [Apple: creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [Apple: `advanceToNextInputMode()`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/advancetonextinputmode%28%29)

### Starting and finishing a dictation

1. With Flow active in a text field, tap its microphone control.
2. If the containing app's audio session is dormant, Flow presents **Start Flow** and briefly launches the main app. Wispr's current release notes say automatic switchback works across supported iOS versions, including iOS 27, for supported host apps. Its iOS 26.4 guidance still documents a fallback screen—**Flow is on — You can start dictating now**—that instructs the user to swipe right across the bottom edge when automatic return is unavailable on a particular build or app.
3. Back in the original app, the Flow keyboard shows a recording waveform. Speak normally.
4. Tap the checkmark/stop control to finish or the `X` to cancel. Keep the Flow keyboard visible while transcription is processing; Wispr warns that dismissing it can lose the pending insertion.
5. The Final Transcript is inserted at the current cursor, or replaces selected text. It does not pass through the clipboard in the normal keyboard workflow.

[Wispr: current iOS switchback release note](https://wisprflow.ai/whats-new), [Wispr: adapting to iOS 26.4](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4), [Wispr: starting a first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation), [Wispr: discreet microphone guide](https://docs.wisprflow.ai/articles/9192039587-using-wispr-flow-discreetly-microphone-guide), [Wispr: fix text not pasting](https://docs.wisprflow.ai/articles/7971211038-fix-text-not-pasting-after-dictation)

Wispr keeps an idle background **Flow session** after a Dictation so subsequent actions can start quickly. Its documented timeout options are immediately, 5 minutes (default), 15 minutes, 1 hour, or never. It says the microphone itself is released at the end of each Dictation; the persistent Dynamic Island/Live Activity represents the keyboard session, not continuous recording. This explains why a cold or expired session needs the app-launch handoff while repeated Dictations can remain in the host app. The last sentence is an inference from the documented session states. [Wispr: microphone indicator and Flow session](https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios)

## Platform constraints Wispr cannot remove

- Apple's custom keyboard runs as a separate, memory-limited process. It manipulates the host field only through `UITextDocumentProxy`; `insertText(_:)` is the supported direct-delivery seam. [Apple: creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [Apple: handling text interactions](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards)
- A host app can reject third-party keyboards. Wispr also deliberately falls back to the system keyboard for phone, number, decimal, email-address, and numbers-and-punctuation fields. [Apple: configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface), [Wispr: iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- Full Access is a meaningful privacy grant: it allows server-bound input and shared-container writes. Hex must fail closed when it is absent and avoid collecting surrounding text merely because the proxy makes limited context available. [Apple: configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)
- Apple's public keyboard API supplies switching and text-proxy primitives, not Apple's keyboard implementation. A third-party keyboard cannot embed Apple's keyboard or reuse its QuickPath recognizer. Gesture-word entry would need to be built and maintained as a separate Hex input method; otherwise the exact Apple typing/QuickPath experience remains one globe tap away. This is an inference from Apple requiring the extension to provide its own interface and interactions, not an explicit Apple statement about QuickPath. [Apple: creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)

## Implication for Hex

The current prototype's full QWERTY plus a prominent Dictate control is the right primary interaction for this personal phone: leave Hex selected for normal tap typing, tap Dictate when speaking, and retain the system globe as the escape hatch to Apple's keyboard and QuickPath. This avoids a keyboard swap for every Dictation and matches Wispr's higher-cohesion QWERTY mode.

The remaining material gap is session activation, not keyboard layout. On iOS 27, Hex should model the same explicit states Wispr exposes:

- **Start Hex** when the containing app's background audio session is unavailable;
- automatic return to the original app where iOS permits it, with a clear bottom-edge swipe-back screen as the fallback;
- **Dictate**, waveform, finish, cancel, processing, and error states while the session is alive;
- direct, one-time insertion through `textDocumentProxy` only after the authenticated Ronin response succeeds;
- a visible globe/system-keyboard path at all times.

Do not promise native Apple swipe typing inside Hex. For the fastest prototype, switching to Apple with the globe is the working glide-typing path; a custom Hex glide engine remains the separately tracked experiment in issue #12.
