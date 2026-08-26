---
status: accepted
---

# Make iOS keyboard delivery at-most-once

iOS exposes `UITextDocumentProxy.insertText`, but it does not acknowledge that a host application committed the insertion. The keyboard therefore cannot make transcript delivery exactly once across extension termination: persisting “inserted” after the call permits a crash-window duplicate, while persisting it before the call permits a crash-window loss.

Hex chooses at-most-once delivery. The keyboard atomically consumes and erases the pending Final Transcript before calling `insertText`, then records an insertion timestamp only for diagnostics. This prioritizes never duplicating text in the Owner's active text destination. If iOS terminates the extension in that narrow window, the Owner must dictate again.

A completed transcript is inserted only when Apple's `UITextDocumentProxy.documentIdentifier` still matches the identifier captured when Dictation began. When that document is no longer current, the keyboard offers an explicit discard action rather than retaining an inaccessible transcript or silently inserting it elsewhere. Apple documents this value as a document identity, not a field identity; switching between fields that share a document therefore remains a physical-device acceptance case rather than a stronger guarantee from the API. This tradeoff applies only to iOS delivery; durable server Dictation idempotency remains a separate requirement.

An unconsumed Final Transcript expires after 15 minutes and is erased on the next app or keyboard mailbox transaction. App Group state uses complete file protection and is excluded from device backup. This preserves an ordinary keyboard-eviction handoff without turning the mailbox into transcript history.
