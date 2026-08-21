import Foundation

enum PrototypeWarmCaptureCommand {
    enum Action: Equatable {
        case none
        case start
        case stop
        case startThenStop
    }

    static func nextAction(
        for state: PrototypeMailboxRecord.State,
        isBusy: Bool,
        isRecording: Bool
    ) -> Action {
        switch state {
        case .captureRequested where !isBusy:
            .start
        case .stopRequested where isRecording:
            .stop
        case .stopRequested where !isBusy:
            .startThenStop
        default:
            .none
        }
    }
}
