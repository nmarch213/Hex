import Darwin
import Foundation

@main
struct PrototypeMailboxSmoke {
    private struct Worker {
        var process: Process
        var errorPipe: Pipe
    }

    static func main() throws {
        if CommandLine.arguments.count > 1 {
            try runWorker()
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-ipc-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        setenv("HEX_IPC_SMOKE_DIRECTORY", directory.path, 1)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                fputs("Unable to remove smoke directory: \(error)\n", stderr)
            }
        }

        try testMissingAndCorruptFiles()
        try testOversizedWritesAreTransactional()
        try testSchemaMigrationAndRejection()
        try testMailboxTransitionsAndPayloadErasure()
        try testCompletedConsumptionRequiresSnapshotIdentity()
        try testPendingTranscriptExpiry()
        try testWarmSessionTransitions()
        try testHostRelaunchReconciliation()
        try testKeyboardSnapshotReconcilesLostWarmSession()
        try testKeyboardPresenceAndCancellation()
        try testStaleHeartbeatCancellationIsTransactional()
        try testCrossProcessStartStopRace(in: directory)

        print("Prototype transactional IPC smoke test passed")
    }

    private static func testMissingAndCorruptFiles() throws {
        try PrototypeMailbox.clear()
        let missingRecord = try PrototypeMailbox.current()
        precondition(missingRecord == nil)

        try PrototypeIPCSmokeSupport.overwrite(
            .mailboxRecord,
            with: Data("not-json".utf8)
        )
        requireError(.corruptedFile(.mailboxRecord)) {
            _ = try PrototypeMailbox.current()
        }
        try PrototypeMailbox.clear()

        try PrototypeIPCSmokeSupport.injectUnvalidatedFile(
            .mailboxRecord,
            with: Data(repeating: 0x20, count: 256 * 1_024 + 1)
        )
        requireError(.corruptedFile(.mailboxRecord)) {
            _ = try PrototypeMailbox.current()
        }
        try PrototypeMailbox.clear()

        _ = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        try PrototypeIPCSmokeSupport.overwrite(
            .stopRequest,
            with: Data("not-json".utf8)
        )
        requireError(.corruptedFile(.stopRequest)) {
            _ = try PrototypeMailbox.current()
        }
        try PrototypeMailbox.clear()

        try PrototypeWarmSession.clear()
        let missingSession = try PrototypeWarmSession.current()
        precondition(missingSession == nil)
        try PrototypeIPCSmokeSupport.overwrite(
            .warmSession,
            with: Data("not-json".utf8)
        )
        requireError(.corruptedFile(.warmSession)) {
            _ = try PrototypeWarmSession.current()
        }
        try PrototypeWarmSession.clear()
    }

    private static func testOversizedWritesAreTransactional() throws {
        try PrototypeMailbox.clear()
        let mailboxID = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        let mailboxBefore = try requiredData(.mailboxRecord)
        let oversizedMailbox = Data(repeating: 0x20, count: 256 * 1_024 + 1)
        requireError(
            .payloadTooLarge(
                file: .mailboxRecord,
                maximumBytes: 256 * 1_024,
                actualBytes: oversizedMailbox.count
            )
        ) {
            try PrototypeIPCSmokeSupport.overwrite(
                .mailboxRecord,
                with: oversizedMailbox
            )
        }
        let mailboxAfter = try requiredData(.mailboxRecord)
        precondition(mailboxAfter == mailboxBefore)
        try require(state: .captureRequested, id: mailboxID)

        try PrototypeMailbox.requestStop(id: mailboxID)
        let stopRequestBefore = try requiredData(.stopRequest)
        let oversizedCommand = Data(repeating: 0x20, count: 16 * 1_024 + 1)
        requireError(
            .payloadTooLarge(
                file: .stopRequest,
                maximumBytes: 16 * 1_024,
                actualBytes: oversizedCommand.count
            )
        ) {
            try PrototypeIPCSmokeSupport.overwrite(
                .stopRequest,
                with: oversizedCommand
            )
        }
        let stopRequestAfter = try requiredData(.stopRequest)
        precondition(stopRequestAfter == stopRequestBefore)
        try require(state: .stopRequested, id: mailboxID)

        try PrototypeWarmSession.clear()
        let warmSession = try PrototypeWarmSession.arm()
        let warmSessionBefore = try requiredData(.warmSession)
        requireError(
            .payloadTooLarge(
                file: .warmSession,
                maximumBytes: 16 * 1_024,
                actualBytes: oversizedCommand.count
            )
        ) {
            try PrototypeIPCSmokeSupport.overwrite(
                .warmSession,
                with: oversizedCommand
            )
        }
        let warmSessionAfter = try requiredData(.warmSession)
        precondition(warmSessionAfter == warmSessionBefore)
        let currentWarmSession = try PrototypeWarmSession.current()
        precondition(currentWarmSession?.id == warmSession.id)

        try PrototypeMailbox.clear()
        try PrototypeWarmSession.clear()
    }

    private static func testSchemaMigrationAndRejection() throws {
        try PrototypeMailbox.clear()
        let mailboxID = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        var legacyMailbox = try jsonObject(for: .mailboxRecord)
        legacyMailbox.removeValue(forKey: "schemaVersion")
        try overwriteJSON(.mailboxRecord, object: legacyMailbox)

        let migratedMailbox = try PrototypeMailbox.current()
        precondition(migratedMailbox?.id == mailboxID)
        precondition(
            migratedMailbox?.schemaVersion
                == PrototypeMailboxRecord.currentSchemaVersion
        )
        var futureMailbox = try jsonObject(for: .mailboxRecord)
        futureMailbox["schemaVersion"] = 2
        futureMailbox["state"] = "futureState"
        try overwriteJSON(.mailboxRecord, object: futureMailbox)
        requireError(
            .unsupportedSchema(file: .mailboxRecord, found: 2, supported: 1)
        ) {
            _ = try PrototypeMailbox.current()
        }
        try PrototypeMailbox.clear()

        try PrototypeWarmSession.clear()
        let warmSession = try PrototypeWarmSession.arm()
        var legacyWarmSession = try jsonObject(for: .warmSession)
        legacyWarmSession.removeValue(forKey: "schemaVersion")
        try overwriteJSON(.warmSession, object: legacyWarmSession)

        let migratedWarmSession = try PrototypeWarmSession.current()
        precondition(migratedWarmSession?.id == warmSession.id)
        precondition(
            migratedWarmSession?.schemaVersion
                == PrototypeWarmSessionRecord.currentSchemaVersion
        )
        var futureWarmSession = try jsonObject(for: .warmSession)
        futureWarmSession["schemaVersion"] = 2
        futureWarmSession["state"] = "futureState"
        try overwriteJSON(.warmSession, object: futureWarmSession)
        requireError(
            .unsupportedSchema(file: .warmSession, found: 2, supported: 1)
        ) {
            _ = try PrototypeWarmSession.current()
        }
        try PrototypeWarmSession.clear()
    }

    private static func testMailboxTransitionsAndPayloadErasure() throws {
        try PrototypeMailbox.clear()

        let missingID = UUID()
        requireError(.missingMailboxRecord(missingID)) {
            try PrototypeMailbox.requestStop(id: missingID)
        }

        let documentIdentifier = UUID()
        var requestID = try PrototypeMailbox.requestCapture(
            documentIdentifier: documentIdentifier
        )
        try require(state: .captureRequested, id: requestID)

        let staleID = UUID()
        requireError(.staleMailboxRecord(expected: staleID, actual: requestID)) {
            try PrototypeMailbox.requestStop(id: staleID)
        }
        requireError(
            .illegalMailboxTransition(
                id: requestID,
                from: .captureRequested,
                to: .completed
            )
        ) {
            try PrototypeMailbox.complete(
                id: requestID,
                transcript: "illegal",
                roundTripMilliseconds: 0,
                upstreamMilliseconds: nil,
                serviceMilliseconds: 0
            )
        }
        requireError(
            .illegalMailboxTransition(
                id: requestID,
                from: .captureRequested,
                to: .captureRequested
            )
        ) {
            _ = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        }

        try PrototypeMailbox.requestStop(id: requestID)
        try PrototypeMailbox.requestCancel(id: requestID)
        try require(state: .cancelRequested, id: requestID)
        precondition(
            PrototypeWarmCaptureCommand.nextAction(
                for: .cancelRequested,
                isBusy: false,
                isRecording: false
            ) == .cancel
        )

        try PrototypeMailbox.clear()
        requestID = try PrototypeMailbox.requestCapture(
            documentIdentifier: documentIdentifier
        )
        try PrototypeMailbox.requestStop(id: requestID)
        let earlyStop = try require(state: .stopRequested, id: requestID)
        guard let earlyStopRequestedAt = earlyStop.stopRequestedAt else {
            preconditionFailure("Early Stop timestamp was not preserved")
        }

        let captureID = try PrototypeMailbox.beginCapture(id: requestID)
        precondition(captureID == requestID)
        let startedAfterStop = try require(state: .stopRequested, id: requestID)
        precondition(startedAfterStop.stopRequestedAt == earlyStopRequestedAt)
        precondition(startedAfterStop.documentIdentifier == documentIdentifier)

        let recordingStoppedAt = Date()
        try PrototypeMailbox.markProcessing(
            id: requestID,
            recordingStoppedAt: recordingStoppedAt
        )
        try require(state: .processing, id: requestID)
        let clearedStopRequest = try PrototypeIPCSmokeSupport.data(.stopRequest)
        precondition(clearedStopRequest == nil)

        let finalTranscript = "FINAL_ONLY_\(UUID().uuidString)"
        try PrototypeMailbox.complete(
            id: requestID,
            transcript: finalTranscript,
            roundTripMilliseconds: 12,
            upstreamMilliseconds: 8,
            serviceMilliseconds: 9
        )
        try require(state: .completed, id: requestID)

        let completedData = try requiredData(.mailboxRecord)
        let completedJSON = String(decoding: completedData, as: UTF8.self)
        precondition(completedJSON.contains(finalTranscript))
        precondition(!completedJSON.contains("rawTranscript"))
        precondition(!completedJSON.contains("AMBIENT_RAW_AUDIO"))

        let payload = try PrototypeMailbox.consumeCompleted(
            id: requestID,
            documentIdentifier: documentIdentifier
        )
        precondition(payload?.id == requestID)
        precondition(payload?.documentIdentifier == documentIdentifier)
        precondition(payload?.transcript == finalTranscript)
        let consumed = try require(state: .consumed, id: requestID)
        precondition(consumed.transcript.isEmpty)

        let consumedData = try requiredData(.mailboxRecord)
        let consumedJSON = String(decoding: consumedData, as: UTF8.self)
        precondition(!consumedJSON.contains(finalTranscript))
        let secondConsumption = try PrototypeMailbox.consumeCompleted(
            id: requestID,
            documentIdentifier: documentIdentifier
        )
        precondition(secondConsumption == nil)

        try PrototypeMailbox.markInserted(id: requestID)
        let inserted = try require(state: .consumed, id: requestID)
        precondition(inserted.stopToInsertionMilliseconds != nil)
        precondition(inserted.returnToInsertionMilliseconds != nil)

        let secondID = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        _ = try PrototypeMailbox.beginCapture(id: secondID)
        try PrototypeMailbox.requestStop(id: secondID)
        try PrototypeMailbox.markProcessing(id: secondID)
        try PrototypeMailbox.complete(
            id: secondID,
            transcript: "second dictation",
            roundTripMilliseconds: 10,
            upstreamMilliseconds: nil,
            serviceMilliseconds: 7
        )
        try PrototypeMailbox.discardCompleted(id: secondID)
        let discarded = try require(state: .failed, id: secondID)
        precondition(discarded.transcript.isEmpty)
        precondition(discarded.errorMessage == "The pending transcript was discarded.")

        let thirdID = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        precondition(thirdID != secondID)

        try PrototypeMailbox.clear()

        let processingID = try PrototypeMailbox.requestCapture(
            documentIdentifier: UUID()
        )
        _ = try PrototypeMailbox.beginCapture(id: processingID)
        try PrototypeMailbox.requestStop(id: processingID)
        try PrototypeMailbox.markProcessing(id: processingID)
        try PrototypeMailbox.requestCancel(id: processingID)
        let cancelledProcessing = try require(state: .cancelRequested, id: processingID)
        precondition(cancelledProcessing.transcript.isEmpty)

        try PrototypeMailbox.clear()
        let completedID = try completeRequest(
            documentIdentifier: UUID(),
            transcript: "discard me"
        )
        try PrototypeMailbox.requestCancel(id: completedID)
        let resetMailbox = try PrototypeMailbox.current()
        precondition(resetMailbox == nil)
    }

    private static func testCompletedConsumptionRequiresSnapshotIdentity() throws {
        try PrototypeMailbox.clear()

        let firstDocument = UUID()
        let firstID = try completeRequest(
            documentIdentifier: firstDocument,
            transcript: "first"
        )
        let staleSnapshot = try require(state: .completed, id: firstID)
        _ = try PrototypeMailbox.consumeCompleted(
            id: firstID,
            documentIdentifier: firstDocument
        )

        let secondDocument = UUID()
        let secondID = try completeRequest(
            documentIdentifier: secondDocument,
            transcript: "second"
        )
        let staleConsumption = try PrototypeMailbox.consumeCompleted(
            id: staleSnapshot.id,
            documentIdentifier: firstDocument
        )
        precondition(staleConsumption == nil)
        let afterStaleSnapshot = try require(state: .completed, id: secondID)
        precondition(afterStaleSnapshot.transcript == "second")

        let wrongDestination = try PrototypeMailbox.consumeCompleted(
            id: secondID,
            documentIdentifier: UUID()
        )
        precondition(wrongDestination == nil)
        let stillCompleted = try require(state: .completed, id: secondID)
        precondition(stillCompleted.transcript == "second")

        let payload = try PrototypeMailbox.consumeCompleted(
            id: secondID,
            documentIdentifier: secondDocument
        )
        precondition(payload?.transcript == "second")
        precondition(
            PrototypeDestinationIdentityFence.permitsInsertion(
                expected: secondDocument,
                beforeConsume: secondDocument,
                afterConsume: secondDocument
            )
        )
        precondition(
            !PrototypeDestinationIdentityFence.permitsInsertion(
                expected: secondDocument,
                beforeConsume: secondDocument,
                afterConsume: UUID()
            )
        )
        try PrototypeMailbox.discardConsumed(id: secondID)
        let destinationChanged = try require(state: .failed, id: secondID)
        precondition(destinationChanged.transcript.isEmpty)

        try PrototypeMailbox.seedCompleted(transcript: "legacy destination")
        guard let legacyRecord = try PrototypeMailbox.current() else {
            preconditionFailure("Missing seeded legacy mailbox record")
        }
        precondition(legacyRecord.state == .completed)
        let legacyID = legacyRecord.id
        let legacyPayload = try PrototypeMailbox.consumeCompleted(
            id: legacyID,
            documentIdentifier: UUID()
        )
        precondition(legacyPayload == nil)
        let unboundLegacyRecord = try require(state: .completed, id: legacyID)
        precondition(unboundLegacyRecord.transcript == "legacy destination")
        try PrototypeMailbox.clear()
    }

    private static func testStaleHeartbeatCancellationIsTransactional() throws {
        try PrototypeMailbox.clear()

        let staleID = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        _ = try PrototypeMailbox.beginCapture(id: staleID)
        let staleRecord = try require(state: .capturing, id: staleID)
        let staleAt = (staleRecord.keyboardHeartbeatAt ?? Date())
            .addingTimeInterval(3)
        let cancellationWon = try PrototypeMailbox
            .failActiveCaptureIfKeyboardHeartbeatStale(
                id: staleID,
                at: staleAt,
                message: "keyboard closed"
            )
        precondition(cancellationWon)
        try require(state: .failed, id: staleID)

        let processingID = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        _ = try PrototypeMailbox.beginCapture(id: processingID)
        try PrototypeMailbox.requestStop(id: processingID)
        try PrototypeMailbox.markProcessing(id: processingID)
        let delayedPollWon = try PrototypeMailbox
            .failActiveCaptureIfKeyboardHeartbeatStale(
                id: processingID,
                at: Date().addingTimeInterval(10),
                message: "stale poll"
            )
        precondition(!delayedPollWon)
        try require(state: .processing, id: processingID)

        try PrototypeMailbox.fail(id: processingID, message: "test cleanup")
        let currentID = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        let staleIdentityWon = try PrototypeMailbox
            .failActiveCaptureIfKeyboardHeartbeatStale(
                id: processingID,
                at: Date().addingTimeInterval(10),
                message: "stale identity"
            )
        precondition(!staleIdentityWon)
        try require(state: .captureRequested, id: currentID)
        try PrototypeMailbox.clear()
    }

    private static func completeRequest(
        documentIdentifier: UUID,
        transcript: String
    ) throws -> UUID {
        let id = try PrototypeMailbox.requestCapture(
            documentIdentifier: documentIdentifier
        )
        _ = try PrototypeMailbox.beginCapture(id: id)
        try PrototypeMailbox.requestStop(id: id)
        try PrototypeMailbox.markProcessing(id: id)
        try PrototypeMailbox.complete(
            id: id,
            transcript: transcript,
            roundTripMilliseconds: 1,
            upstreamMilliseconds: 1,
            serviceMilliseconds: 1
        )
        return id
    }

    private static func testWarmSessionTransitions() throws {
        try PrototypeWarmSession.clear()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = try PrototypeWarmSession.arm(at: start)
        let current = try PrototypeWarmSession.current()
        precondition(current?.isReady(at: start) == true)

        requireError(
            .illegalWarmSessionTransition(
                id: session.id,
                from: .armed,
                to: .armed
            )
        ) {
            _ = try PrototypeWarmSession.arm(at: start.addingTimeInterval(1))
        }

        let staleID = UUID()
        requireError(
            .staleWarmSessionRecord(expected: staleID, actual: session.id)
        ) {
            try PrototypeWarmSession.extend(
                id: staleID,
                at: start.addingTimeInterval(1)
            )
        }
        try PrototypeWarmSession.heartbeat(
            id: session.id,
            at: start.addingTimeInterval(-1)
        )
        let afterDelayedHeartbeat = try PrototypeWarmSession.current()
        precondition(afterDelayedHeartbeat == current)

        try PrototypeWarmSession.extend(
            id: session.id,
            at: start.addingTimeInterval(2)
        )
        guard let extended = try PrototypeWarmSession.current() else {
            preconditionFailure("Warm session disappeared after extension")
        }
        precondition(extended.expiresAt > session.expiresAt)

        let newerHeartbeat = start.addingTimeInterval(5)
        try PrototypeWarmSession.heartbeat(id: session.id, at: newerHeartbeat)
        try PrototypeWarmSession.extend(
            id: session.id,
            at: start.addingTimeInterval(4)
        )
        guard let lockOrderedExtension = try PrototypeWarmSession.current() else {
            preconditionFailure("Warm session disappeared after lock-ordered extension")
        }
        precondition(lockOrderedExtension.heartbeatAt == newerHeartbeat)
        precondition(
            lockOrderedExtension.expiresAt
                == newerHeartbeat.addingTimeInterval(PrototypeWarmSession.duration)
        )

        try PrototypeWarmSession.fail(
            id: session.id,
            message: "interrupted",
            at: start.addingTimeInterval(4)
        )
        let unavailable = try PrototypeWarmSession.current()
        precondition(unavailable?.state == .unavailable)
        precondition(unavailable?.heartbeatAt == newerHeartbeat)
        requireError(
            .illegalWarmSessionTransition(
                id: session.id,
                from: .unavailable,
                to: .armed
            )
        ) {
            try PrototypeWarmSession.heartbeat(
                id: session.id,
                at: start.addingTimeInterval(4)
            )
        }

        let replacement = try PrototypeWarmSession.arm(
            at: start.addingTimeInterval(4)
        )
        precondition(replacement.id != session.id)
        try PrototypeWarmSession.clear()

        let expiring = try PrototypeWarmSession.arm(at: start)
        let afterExpiry = expiring.expiresAt.addingTimeInterval(1)
        let expiredExtension = try PrototypeWarmSession.extendIfReady(
            id: expiring.id,
            at: afterExpiry
        )
        precondition(expiredExtension == nil)
        let renewed = try PrototypeWarmSession.arm(at: afterExpiry)
        precondition(renewed.id != expiring.id)
        try PrototypeWarmSession.clear()
    }

    private static func testPendingTranscriptExpiry() throws {
        try PrototypeMailbox.clear()
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try PrototypeMailbox.seedCompleted(
            transcript: "must not remain in backup",
            at: completedAt
        )

        let snapshot = try PrototypeMailbox.keyboardSnapshot(
            at: completedAt.addingTimeInterval(15 * 60)
        )
        precondition(snapshot.mailbox?.state == .failed)
        precondition(snapshot.mailbox?.transcript.isEmpty == true)
        precondition(
            snapshot.mailbox?.errorMessage ==
                "The pending transcript expired. Dictate it again when you are ready."
        )
        try PrototypeMailbox.clear()
    }

    private static func testHostRelaunchReconciliation() throws {
        try PrototypeMailbox.clear()
        try PrototypeWarmSession.clear()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try PrototypeWarmSession.arm(at: start)
        let requestID = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        _ = try PrototypeMailbox.beginCapture(id: requestID)
        try PrototypeMailbox.requestStop(id: requestID)

        let snapshot = try PrototypeMailbox.reconcileHostRelaunch()
        precondition(snapshot.warmSession == nil)
        precondition(snapshot.mailbox?.id == requestID)
        precondition(snapshot.mailbox?.state == .failed)
        precondition(snapshot.mailbox?.transcript.isEmpty == true)
        let persistedWarmSession = try PrototypeWarmSession.current()
        precondition(persistedWarmSession == nil)

        try PrototypeMailbox.clear()
    }

    private static func testKeyboardSnapshotReconcilesLostWarmSession() throws {
        try PrototypeMailbox.clear()
        try PrototypeWarmSession.clear()

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try PrototypeWarmSession.arm(at: start)
        let documentIdentifier = UUID()
        let requestID = try PrototypeMailbox.requestCapture(
            documentIdentifier: documentIdentifier
        )

        let readySnapshot = try PrototypeMailbox.keyboardSnapshot(
            documentIdentifier: documentIdentifier,
            at: start.addingTimeInterval(1)
        )
        precondition(readySnapshot.mailbox?.id == requestID)
        precondition(readySnapshot.mailbox?.state == .captureRequested)
        precondition(readySnapshot.warmSession?.isReady(at: start) == true)

        let interruptedSnapshot = try PrototypeMailbox.keyboardSnapshot(
            documentIdentifier: documentIdentifier,
            at: start.addingTimeInterval(11)
        )
        precondition(interruptedSnapshot.mailbox?.id == requestID)
        precondition(interruptedSnapshot.mailbox?.state == .cancelRequested)
        precondition(interruptedSnapshot.mailbox?.transcript.isEmpty == true)
        precondition(
            interruptedSnapshot.mailbox?.errorMessage ==
                "Hex is no longer armed. Use the Arm Hex shortcut."
        )
        guard let sessionID = interruptedSnapshot.warmSession?.id else {
            preconditionFailure("Expected the stale warm-session record")
        }
        try PrototypeWarmSession.heartbeat(
            id: sessionID,
            at: start.addingTimeInterval(11.1)
        )
        let resumedHostSnapshot = try PrototypeMailbox.snapshot()
        precondition(resumedHostSnapshot.mailbox?.state == .cancelRequested)
        precondition(
            PrototypeWarmCaptureCommand.nextAction(
                for: resumedHostSnapshot.mailbox?.state ?? .failed,
                isBusy: true,
                isRecording: true
            ) == .cancel
        )
        try PrototypeMailbox.fail(
            id: requestID,
            message: "Host acknowledged the durable cancellation."
        )

        let processingID = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
        _ = try PrototypeMailbox.beginCapture(id: processingID)
        try PrototypeMailbox.requestStop(id: processingID)
        try PrototypeMailbox.markProcessing(id: processingID)
        let sealedSnapshot = try PrototypeMailbox.keyboardSnapshot(
            at: start.addingTimeInterval(12)
        )
        precondition(sealedSnapshot.mailbox?.id == processingID)
        precondition(sealedSnapshot.mailbox?.state == .processing)

        try PrototypeMailbox.clear()
        try PrototypeWarmSession.clear()
    }

    private static func testKeyboardPresenceAndCancellation() throws {
        try PrototypeMailbox.clear()
        try PrototypeWarmSession.clear()

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try PrototypeWarmSession.arm(at: start)
        let originalDocument = UUID()
        let requestID = try PrototypeMailbox.requestCapture(
            documentIdentifier: originalDocument
        )

        let present = try PrototypeMailbox.keyboardSnapshot(
            documentIdentifier: originalDocument,
            at: start.addingTimeInterval(1)
        )
        precondition(present.mailbox?.state == .captureRequested)
        precondition(
            present.mailbox?.hasRecentKeyboardHeartbeat(
                at: start.addingTimeInterval(2.5)
            ) == true
        )
        precondition(
            present.mailbox?.hasRecentKeyboardHeartbeat(
                at: start.addingTimeInterval(3.1)
            ) == false
        )

        let movedDestination = try PrototypeMailbox.keyboardSnapshot(
            documentIdentifier: UUID(),
            at: start.addingTimeInterval(1.1)
        )
        precondition(movedDestination.mailbox?.state == .cancelRequested)
        precondition(
            PrototypeWarmCaptureCommand.nextAction(
                for: .cancelRequested,
                isBusy: false,
                isRecording: false
            ) == .cancel
        )
        requireError(
            .illegalMailboxTransition(
                id: requestID,
                from: .cancelRequested,
                to: .capturing
            )
        ) {
            _ = try PrototypeMailbox.beginCapture(id: requestID)
        }
        try PrototypeMailbox.requestCancel(id: requestID)
        try PrototypeMailbox.fail(id: requestID, message: "cancelled")

        let secondID = try PrototypeMailbox.requestCapture(
            documentIdentifier: originalDocument
        )
        _ = try PrototypeMailbox.beginCapture(id: secondID)
        let unavailableDestination = try PrototypeMailbox.keyboardSnapshot(
            documentIdentifier: nil,
            at: start.addingTimeInterval(1.2)
        )
        precondition(unavailableDestination.mailbox?.state == .cancelRequested)
        try PrototypeMailbox.fail(id: secondID, message: "destination unavailable")

        let thirdID = try PrototypeMailbox.requestCapture(
            documentIdentifier: originalDocument
        )
        let matchingStop = try PrototypeMailbox.requestKeyboardStop(
            id: thirdID,
            documentIdentifier: originalDocument
        )
        precondition(matchingStop)
        try require(state: .stopRequested, id: thirdID)
        try PrototypeMailbox.markProcessing(id: thirdID)
        try PrototypeMailbox.fail(id: thirdID, message: "test cleanup")

        let fourthID = try PrototypeMailbox.requestCapture(
            documentIdentifier: originalDocument
        )
        let unavailableStop = try PrototypeMailbox.requestKeyboardStop(
            id: fourthID,
            documentIdentifier: nil
        )
        precondition(!unavailableStop)
        let unavailableStopRecord = try require(state: .cancelRequested, id: fourthID)
        precondition(unavailableStopRecord.transcript.isEmpty)
        try PrototypeMailbox.fail(id: fourthID, message: "destination unavailable")

        let fifthID = try PrototypeMailbox.requestCapture(
            documentIdentifier: originalDocument
        )
        let mismatchedStop = try PrototypeMailbox.requestKeyboardStop(
            id: fifthID,
            documentIdentifier: UUID()
        )
        precondition(!mismatchedStop)
        try require(state: .cancelRequested, id: fifthID)

        try PrototypeMailbox.clear()
        try PrototypeWarmSession.clear()
    }

    private static func testCrossProcessStartStopRace(in directory: URL) throws {
        for iteration in 0..<12 {
            try PrototypeMailbox.clear()
            let requestID = try PrototypeMailbox.requestCapture(documentIdentifier: UUID())
            let gate = directory.appendingPathComponent("race-gate-\(iteration)")
            let beginWorker = try launchWorker(
                command: "worker-begin",
                id: requestID,
                gate: gate
            )
            let stopWorker = try launchWorker(
                command: "worker-stop",
                id: requestID,
                gate: gate
            )

            try Data().write(to: gate, options: .atomic)
            try requireSuccessful(beginWorker)
            try requireSuccessful(stopWorker)
            try FileManager.default.removeItem(at: gate)

            let final = try require(state: .stopRequested, id: requestID)
            precondition(final.stopRequestedAt != nil)
        }
        try PrototypeMailbox.clear()
    }

    private static func launchWorker(
        command: String,
        id: UUID,
        gate: URL
    ) throws -> Worker {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [command, id.uuidString, gate.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        return Worker(process: process, errorPipe: errorPipe)
    }

    private static func requireSuccessful(_ worker: Worker) throws {
        worker.process.waitUntilExit()
        let errorData = worker.errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(decoding: errorData, as: UTF8.self)
        precondition(
            worker.process.terminationStatus == 0,
            "IPC race worker failed: \(errorOutput)"
        )
    }

    private static func runWorker() throws {
        precondition(CommandLine.arguments.count == 4)
        let command = CommandLine.arguments[1]
        guard let id = UUID(uuidString: CommandLine.arguments[2]) else {
            preconditionFailure("Worker received an invalid UUID")
        }
        let gate = CommandLine.arguments[3]
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: gate) {
            precondition(Date() < deadline, "Timed out waiting for race gate")
            usleep(1_000)
        }

        switch command {
        case "worker-begin":
            _ = try PrototypeMailbox.beginCapture(id: id)
        case "worker-stop":
            try PrototypeMailbox.requestStop(id: id)
        default:
            preconditionFailure("Unknown race worker command: \(command)")
        }
    }

    @discardableResult
    private static func require(
        state: PrototypeMailboxRecord.State,
        id: UUID
    ) throws -> PrototypeMailboxRecord {
        guard let record = try PrototypeMailbox.current() else {
            preconditionFailure("Mailbox unexpectedly empty")
        }
        precondition(record.id == id)
        precondition(record.state == state)
        return record
    }

    private static func requiredData(
        _ file: PrototypeIPCFile
    ) throws -> Data {
        guard let data = try PrototypeIPCSmokeSupport.data(file) else {
            preconditionFailure("Expected persisted \(file.rawValue)")
        }
        return data
    }

    private static func jsonObject(
        for file: PrototypeIPCFile
    ) throws -> [String: Any] {
        let data = try requiredData(file)
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            preconditionFailure("Expected JSON object for \(file.rawValue)")
        }
        return object
    }

    private static func overwriteJSON(
        _ file: PrototypeIPCFile,
        object: [String: Any]
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try PrototypeIPCSmokeSupport.overwrite(file, with: data)
    }

    private static func requireError(
        _ expected: PrototypeIPCError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            preconditionFailure("Expected \(expected)")
        } catch let error as PrototypeIPCError {
            precondition(error == expected, "Expected \(expected), got \(error)")
        } catch {
            preconditionFailure("Expected \(expected), got \(error)")
        }
    }
}
