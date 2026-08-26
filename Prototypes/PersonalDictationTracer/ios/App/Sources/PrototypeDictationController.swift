import Combine
import Foundation

/// Publishes workflow state to SwiftUI and translates UI callbacks into typed actions.
@MainActor
final class PrototypeDictationController: ObservableObject {
    @Published private(set) var state: PrototypeDictationWorkflow.State

    private let workflow: PrototypeDictationWorkflow

    init(
        workflow: PrototypeDictationWorkflow = PrototypeDictationWorkflow(
            dependencies: .live()
        )
    ) {
        self.workflow = workflow
        state = workflow.state
        workflow.onStateChange = { [weak self] state in
            self?.state = state
        }
        workflow.start()
    }

    func toggleRecording() {
        send(.primaryButtonTapped)
    }

    func handleArmShortcut() {
        send(.armShortcutRequested)
    }

    func refreshMailbox() {
        send(.refresh)
    }

    func saveCredential() {
        send(.saveCredential)
    }

    func resetKeyboardState() {
        send(.resetKeyboardState)
    }

    func setToken(_ token: String) {
        workflow.setToken(token)
    }

    func setTranscriptPreferences(_ preferences: PrototypeDictationPreferences) {
        workflow.setTranscriptPreferences(preferences)
    }

#if DEBUG
    func seedMailbox(transcript: String) {
        send(.seedMailbox(transcript))
    }

    func clearMailbox() {
        send(.clearMailbox)
    }
#endif

    private func send(_ action: PrototypeDictationWorkflow.Action) {
        Task { [weak workflow] in
            await workflow?.send(action)
        }
    }
}
