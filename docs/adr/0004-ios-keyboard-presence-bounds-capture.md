---
status: accepted
---

# Bound iOS capture by keyboard presence

The containing iOS app owns microphone capture because a custom keyboard cannot. A warm app session alone is therefore insufficient proof that the Owner can still see and control the keyboard that requested a Recording Session.

While capture is requested or active, the keyboard records a bounded heartbeat in the transactional App Group mailbox. The containing app cancels the Recording Session and erases its partial Captured Audio when that heartbeat is more than two seconds old. `viewWillDisappear` also writes an explicit cancel request as a best-effort fast path. A change to the originating Text Destination requests the same cancellation.

An intentional Stop fixes the user's intent: once `stopRequested` is durably stored, keyboard disappearance cannot reinterpret it as Cancel. The keyboard continues its presence heartbeat until the containing app seals the Recording Session. If that heartbeat becomes stale for two seconds before sealing, the containing app discards the partial capture instead of allowing a stalled Stop to record until the five-minute safety cap.

This is a fail-closed presence lease, not a background keepalive guarantee. Extension eviction, switching keyboards, changing Apple's text-document identity, or losing mailbox access may discard the current Dictation; none may leave the microphone recording until the five-minute Recording Session limit. Apple does not document that identity as field-specific, so switching fields within one document remains a physical-device acceptance case rather than a guarantee of this lease.
