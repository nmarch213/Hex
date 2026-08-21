import Foundation

@main
struct PrototypeMailboxSmoke {
    @MainActor
    static func main() {
        PrototypeMailbox.clear()

        let requestID = PrototypeMailbox.requestCapture()
        require(state: .captureRequested, id: requestID)

        let captureID = PrototypeMailbox.beginCapture(id: requestID)
        precondition(captureID == requestID)
        require(state: .capturing, id: requestID)

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
