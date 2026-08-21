# Hex

Hex turns spoken input into text intended for insertion at a text destination. The domain distinguishes the user's complete dictation from audio capture, speech recognition, transcript processing, delivery, and optional history.

## Dictation

**Dictation**:
The complete interaction that begins with an activation gesture and ends when resulting text is delivered, cancelled, or discarded.
_Avoid_: Transcription session, recording

**Recording Session**:
The portion of a Dictation during which spoken audio is being captured.
_Avoid_: Recording, transcription

**Captured Audio**:
The audio produced by a completed Recording Session and used as input to Transcription.
_Avoid_: Recording session, transcript

**Source App**:
The application active when a Recording Session begins, retained as context for that Dictation.
_Avoid_: Target app, destination app

**Text Destination**:
The place where a Final Transcript is intended to be inserted.
_Avoid_: Source app

## Activation

**Recording Hotkey**:
The global keyboard gesture that controls a Recording Session.
_Avoid_: Shortcut, trigger key

**Modifier-Only Hotkey**:
A Recording Hotkey composed only of modifier keys and therefore subject to stronger accidental-activation protection.
_Avoid_: Regular hotkey

**Keyed Hotkey**:
A Recording Hotkey that includes a non-modifier key.
_Avoid_: Regular hotkey, printable-key hotkey, key-plus-modifier hotkey

**Press-and-Hold**:
An activation mode in which holding the Recording Hotkey keeps the Recording Session active and releasing it requests completion.
_Avoid_: Push to talk

**Double-Tap Lock**:
An activation mode in which a double tap starts a Locked Recording that continues without holding the Recording Hotkey.
_Avoid_: Hands-free mode

**Locked Recording**:
A Recording Session that remains active until the user explicitly stops or cancels it.
_Avoid_: Double-tap session

**Stop**:
An intentional end to a Recording Session that requests Transcription of its Captured Audio.
_Avoid_: Cancel, discard

**Cancel**:
An explicit interruption that produces no transcript and gives cancellation feedback.
_Avoid_: Stop, discard

**Discard**:
A silent rejection of an accidental or invalid Recording Session that produces no transcript.
_Avoid_: Cancel, stop

## Speech recognition

**Transcription**:
The process of converting Captured Audio into text using a Transcription Model.
_Avoid_: Dictation, transcript

**Transcription Model**:
A speech-recognition model available to perform Transcription.
_Avoid_: Engine, provider

**Downloaded Model**:
A Transcription Model whose required assets are stored locally.
_Avoid_: Loaded model, ready model

**Selected Model**:
The Transcription Model chosen for new transcriptions.
_Avoid_: Active model

**Loaded Model**:
A Transcription Model whose assets are resident in the speech-recognition engine.
_Avoid_: Downloaded model, selected model

**Ready Model**:
A Selected Model judged available for Transcription; readiness does not imply that it is already loaded.
_Avoid_: Loaded model, installed model

**Output Language**:
The language selection or automatic-detection preference applied when the Selected Model supports it.
_Avoid_: Input language

## Transcript processing

**Transcript Profile**:
The versioned collection of transcript policy shared across Hex clients, including the Selected Model, Transcript Transforms, and Output Formatting.
_Avoid_: Shared settings, device settings

**Raw Transcript**:
The text produced directly by Transcription before user-defined transforms.
_Avoid_: Transcript, result

**Transcript Transform**:
A deterministic rule that modifies a Raw Transcript before delivery or storage.
_Avoid_: Mode, transformation

**Word Removal**:
A Transcript Transform that removes matching words or phrases.
_Avoid_: Filter

**Word Remapping**:
A Transcript Transform that replaces matching words or phrases with configured text.
_Avoid_: Replacement mode

**Output Formatting**:
Transcript Transforms that alter broad text presentation, such as casing or punctuation.
_Avoid_: Word rule

**Final Transcript**:
The non-empty text remaining after all applicable Transcript Transforms have been applied.
_Avoid_: Raw transcript, transcription

## Delivery and history

**Paste**:
Insertion of a Final Transcript into its Text Destination.
_Avoid_: Copy

**Clipboard Insertion**:
A paste behavior that temporarily uses the system clipboard to deliver a Final Transcript.
_Avoid_: Copy to clipboard

**Clipboard Retention**:
The preference that determines whether the Final Transcript remains in the clipboard after delivery.
_Avoid_: Clipboard paste

**History Entry**:
A saved record of a completed Dictation containing its Final Transcript and available contextual material.
_Avoid_: Transcript

**Transcription History**:
The newest-first collection of saved History Entries.
_Avoid_: History list

**Last Transcript**:
The most recent Final Transcript available for repeat delivery.
_Avoid_: Last history entry

**Paste Last Transcript**:
The action that delivers the Last Transcript again without making a new Recording Session.
_Avoid_: Copy last transcript

## Environment

**Device Interaction Settings**:
Preferences governing how one device activates, captures, signals, and delivers a Dictation without changing the meaning of its Final Transcript.
_Avoid_: Transcript Profile, shared settings

**Input Device**:
The microphone used to capture a Recording Session, either explicitly selected or inherited from the system default.
_Avoid_: Audio source

**Recording Audio Behavior**:
The preference governing how other system audio is treated during a Recording Session.
_Avoid_: Audio mode

**Super Fast Mode**:
A capture preference that keeps audio capture armed so the beginning of speech is available immediately.
_Avoid_: Fast Mode

**Recording Feedback**:
Visual or audible confirmation of recording start, recording completion, successful delivery, or cancellation.
_Avoid_: Notification
