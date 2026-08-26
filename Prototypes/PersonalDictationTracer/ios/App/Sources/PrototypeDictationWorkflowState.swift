import Foundation

extension PrototypeDictationWorkflow {
    struct State: Equatable {
        let serverURLString: String
        var token: String
        var credentialStatus: String
        var transcriptPreferences: PrototypeDictationPreferences
        var isRecording = false
        var isBusy = false
        var isArmed = false
        var status = "Ready to record."
        var mailboxRecord: PrototypeMailboxRecord?
        var warmSessionRecord: PrototypeWarmSessionRecord?
        var hasIPCFailure = false
    }

    enum Action {
        case launch
        case primaryButtonTapped
        case armShortcutRequested
        case refresh
        case saveCredential
        case resetKeyboardState
        case pollWarmCommands
        case captureUpdated(DictationCapture.Update)
        case seedMailbox(String)
        case clearMailbox
    }

    enum RecordingError: LocalizedError {
        case emptyTranscript
        case emptyFinalTranscript

        var errorDescription: String? {
            switch self {
            case .emptyTranscript:
                "Parakeet returned an empty transcript."
            case .emptyFinalTranscript:
                "Hex transcript transforms removed the entire transcript."
            }
        }
    }
}
