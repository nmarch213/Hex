import Foundation

@main
struct PrototypeMailboxSmoke {
    @MainActor
    static func main() {
        PrototypeMailbox.clear()

        let documentIdentifier = UUID()
        let requestID = PrototypeMailbox.requestCapture(
            documentIdentifier: documentIdentifier
        )
        require(state: .captureRequested, id: requestID)
        precondition(PrototypeMailbox.current()?.documentIdentifier == documentIdentifier)

        let captureID = PrototypeMailbox.beginCapture(id: requestID)
        precondition(captureID == requestID)
        require(state: .capturing, id: requestID)
        precondition(PrototypeMailbox.current()?.documentIdentifier == documentIdentifier)

        PrototypeMailbox.requestStop(id: requestID)
        require(state: .stopRequested, id: requestID)

        PrototypeMailbox.markProcessing(id: requestID)
        require(state: .processing, id: requestID)

        PrototypeMailbox.complete(
            id: requestID,
            rawTranscript: "raw",
            transcript: "final",
            roundTripMilliseconds: 12,
            upstreamMilliseconds: 8,
            serviceMilliseconds: 9
        )
        require(state: .completed, id: requestID)

        let firstConsumption = PrototypeMailbox.consumeCompleted()
        precondition(firstConsumption?.id == requestID)
        precondition(firstConsumption?.transcript == "final")
        require(state: .consumed, id: requestID)
        PrototypeMailbox.markInserted(id: requestID)
        precondition(PrototypeMailbox.current()?.stopToInsertionMilliseconds != nil)
        precondition(PrototypeMailbox.current()?.returnToInsertionMilliseconds != nil)
        precondition(PrototypeMailbox.consumeCompleted() == nil)

        PrototypeMailbox.clear()
        precondition(PrototypeMailbox.current() == nil)

        PrototypeWarmSession.clear()
        let session = PrototypeWarmSession.arm()
        precondition(PrototypeWarmSession.current()?.isReady() == true)
        PrototypeWarmSession.extend(id: session.id)
        guard let extendedSession = PrototypeWarmSession.current() else {
            preconditionFailure("Warm session disappeared after extension")
        }
        precondition(extendedSession.expiresAt >= session.expiresAt)
        PrototypeWarmSession.fail(id: session.id, message: "interrupted")
        precondition(PrototypeWarmSession.current()?.state == .unavailable)
        PrototypeWarmSession.clear()
        precondition(PrototypeWarmSession.current() == nil)

        print("Prototype mailbox smoke test passed")
    }

    @MainActor
    private static func require(state: PrototypeMailboxRecord.State, id: UUID) {
        guard let record = PrototypeMailbox.current() else {
            preconditionFailure("Mailbox unexpectedly empty")
        }
        precondition(record.id == id)
        precondition(record.state == state)
    }
}
