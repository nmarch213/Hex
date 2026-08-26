import Foundation
@testable import HexKeyboardTracer
import XCTest

@MainActor
final class PrototypeDictationWorkflowTests: XCTestCase {
    func testArmWaitsForLaunchReconciliation() async {
        let fixture = makeFixture()
        await fixture.system.setReconcileSuspended(true)
        fixture.workflow.start()
        let armTask = Task { @MainActor in
            await fixture.workflow.send(.armShortcutRequested)
        }
        let reconciliationStarted = await fixture.system.waitForReconcileStart()
        XCTAssertTrue(reconciliationStarted)

        for _ in 0..<10 {
            await Task.yield()
        }
        let armCountBeforeReconciliation = await fixture.system.armCount
        XCTAssertEqual(armCountBeforeReconciliation, 0)

        await fixture.system.resumeReconcile()
        await armTask.value

        XCTAssertTrue(fixture.workflow.state.isArmed)
        let lifecycleEvents = await fixture.system.lifecycleEvents
        XCTAssertEqual(lifecycleEvents, ["reconcile.finished", "capture.arm"])
    }

    func testTwoSequentialDictationsReuseOneArm() async throws {
        let fixture = makeFixture(transcripts: ["first result", "second result"])
        await arm(fixture.workflow)

        let firstID = UUID()
        await fixture.system.requestCapture(id: firstID)
        await fixture.workflow.send(.pollWarmCommands)
        XCTAssertTrue(fixture.workflow.state.isRecording)
        await fixture.system.requestKeyboardStop(id: firstID)
        await fixture.workflow.send(.pollWarmCommands)
        await fixture.workflow.waitForTranscriptionToFinish()

        let firstRecord = await fixture.system.mailboxRecord()
        XCTAssertEqual(firstRecord?.transcript, "first result")
        XCTAssertTrue(fixture.workflow.state.isArmed)
        XCTAssertFalse(fixture.workflow.state.isBusy)

        let secondID = UUID()
        await fixture.system.requestCapture(id: secondID)
        await fixture.workflow.send(.pollWarmCommands)
        XCTAssertTrue(fixture.workflow.state.isRecording)
        await fixture.system.requestKeyboardStop(id: secondID)
        await fixture.workflow.send(.pollWarmCommands)
        await fixture.workflow.waitForTranscriptionToFinish()

        let secondRecord = await fixture.system.mailboxRecord()
        let armCount = await fixture.system.armCount
        let beginCount = await fixture.system.beginCount
        let completedRequestIDs = await fixture.system.completedRequestIDs
        let removedRequestIDs = await fixture.system.removedRequestIDs
        XCTAssertEqual(secondRecord?.transcript, "second result")
        XCTAssertEqual(armCount, 1)
        XCTAssertEqual(beginCount, 2)
        XCTAssertEqual(completedRequestIDs, [firstID, secondID])
        XCTAssertEqual(removedRequestIDs, [firstID, secondID])
        XCTAssertTrue(fixture.workflow.state.isArmed)
    }

    func testDisarmWinsRaceWithSuspendedUpload() async throws {
        let captureGeneration = UUID()
        let fixture = makeFixture(
            transcripts: ["must not complete"],
            uuidValues: [captureGeneration, UUID()]
        )
        await fixture.system.setUploadSuspended(true)
        await arm(fixture.workflow)

        let requestID = UUID()
        await fixture.system.requestCapture(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)
        await fixture.system.requestKeyboardStop(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)
        let uploadStarted = await fixture.system.waitForUploadStart()
        XCTAssertTrue(uploadStarted)

        await fixture.workflow.send(
            .captureUpdated(
                DictationCapture.Update(
                    generation: captureGeneration,
                    sequence: 2,
                    occurredAt: fixture.now,
                    state: .disarmed,
                    incident: .expired
                )
            )
        )
        XCTAssertFalse(fixture.workflow.state.isArmed)
        let recordAfterDisarm = await fixture.system.mailboxRecord()
        XCTAssertEqual(recordAfterDisarm?.state, .failed)

        await fixture.system.resumeUpload()
        let removalFinished = await fixture.system.waitForRemoval(requestID: requestID)
        XCTAssertTrue(removalFinished)

        let finalRecord = await fixture.system.mailboxRecord()
        let completedRequestIDs = await fixture.system.completedRequestIDs
        let removedRequestIDs = await fixture.system.removedRequestIDs
        XCTAssertEqual(finalRecord?.state, .failed)
        XCTAssertTrue(completedRequestIDs.isEmpty)
        XCTAssertEqual(removedRequestIDs, [requestID])
    }

    func testKeyboardCancelResetsDictationWhileUploadIsProcessing() async throws {
        let fixture = makeFixture(transcripts: ["must not complete"])
        await fixture.system.setUploadSuspended(true)
        await arm(fixture.workflow)

        let requestID = UUID()
        await fixture.system.requestCapture(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)
        await fixture.system.requestKeyboardStop(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)
        let uploadStarted = await fixture.system.waitForUploadStart()
        XCTAssertTrue(uploadStarted)

        try await fixture.system.requestKeyboardCancel(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)

        let cancelledRecord = await fixture.system.mailboxRecord()
        XCTAssertNil(cancelledRecord)
        XCTAssertTrue(fixture.workflow.state.isArmed)
        XCTAssertFalse(fixture.workflow.state.isRecording)
        XCTAssertFalse(fixture.workflow.state.isBusy)

        await fixture.system.resumeUpload()
        let removalFinished = await fixture.system.waitForRemoval(requestID: requestID)
        XCTAssertTrue(removalFinished)

        let completedRequestIDs = await fixture.system.completedRequestIDs
        let removedRequestIDs = await fixture.system.removedRequestIDs
        XCTAssertTrue(completedRequestIDs.isEmpty)
        XCTAssertEqual(removedRequestIDs, [requestID])
    }

    func testDictationUsesPreferencesCapturedWhenRecordingStarts() async {
        let fixture = makeFixture(transcripts: ["um hello comma"])
        await fixture.system.setUploadSuspended(true)
        await arm(fixture.workflow)

        let requestID = UUID()
        await fixture.system.requestCapture(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)
        await fixture.system.requestKeyboardStop(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)
        let uploadStarted = await fixture.system.waitForUploadStart()
        XCTAssertTrue(uploadStarted)

        fixture.workflow.setTranscriptPreferences(
            PrototypeDictationPreferences(
                removeFillerWords: false,
                spokenPunctuation: false,
                lowercase: false,
                removePunctuation: false
            )
        )
        await fixture.system.resumeUpload()
        await fixture.workflow.waitForTranscriptionToFinish()

        let record = await fixture.system.mailboxRecord()
        XCTAssertEqual(record?.transcript, "hello ,")
    }

    func testStaleCaptureUpdateCannotDisarmRearmedWorkflow() async {
        let firstGeneration = UUID()
        let secondGeneration = UUID()
        let fixture = makeFixture(
            uuidValues: [firstGeneration, secondGeneration]
        )
        await arm(fixture.workflow)
        await fixture.workflow.send(.primaryButtonTapped)
        await arm(fixture.workflow)

        await fixture.workflow.send(
            .captureUpdated(
                DictationCapture.Update(
                    generation: firstGeneration,
                    sequence: 10_000,
                    occurredAt: fixture.now,
                    state: .disarmed,
                    incident: .failed(
                        requestID: nil,
                        failure: .audioResourceUnavailable
                    )
                )
            )
        )

        XCTAssertTrue(fixture.workflow.state.isArmed)
        XCTAssertEqual(
            fixture.workflow.state.status,
            "Armed for 15 minutes. Swipe back, then tap Start Voice in the Hex keyboard."
        )
    }

    func testIPCFailureFailsClosedAndDisarmsCapture() async {
        let fixture = makeFixture()
        await arm(fixture.workflow)
        await fixture.system.setSnapshotFailure(true)

        await fixture.workflow.send(.pollWarmCommands)

        XCTAssertTrue(fixture.workflow.state.hasIPCFailure)
        XCTAssertFalse(fixture.workflow.state.isArmed)
        XCTAssertFalse(fixture.workflow.state.isBusy)
        let disarmCount = await fixture.system.disarmCount
        XCTAssertEqual(disarmCount, 1)
        XCTAssertEqual(
            fixture.workflow.state.status,
            "Keyboard state is unavailable. Reopen Hex and arm it again."
        )
    }

    func testUploadFailureFailsMailboxAndDeletesCapturedAudio() async {
        let fixture = makeFixture()
        await fixture.system.setUploadFailure(true)
        await arm(fixture.workflow)

        let requestID = UUID()
        await fixture.system.requestCapture(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)
        await fixture.system.requestKeyboardStop(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)
        await fixture.workflow.waitForTranscriptionToFinish()

        let record = await fixture.system.mailboxRecord()
        let removedRequestIDs = await fixture.system.removedRequestIDs
        XCTAssertEqual(record?.state, .failed)
        XCTAssertEqual(removedRequestIDs, [requestID])
        XCTAssertTrue(fixture.workflow.state.isArmed)
        XCTAssertTrue(fixture.workflow.state.status.hasPrefix("Transcription failed:"))
    }

    func testFinishedCaptureFlowsThroughProcessingToMailboxCompletion() async {
        let fixture = makeFixture(transcripts: ["um hello comma"])
        await arm(fixture.workflow)

        let requestID = UUID()
        await fixture.system.requestCapture(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)
        await fixture.system.requestKeyboardStop(id: requestID)
        await fixture.workflow.send(.pollWarmCommands)
        await fixture.workflow.waitForTranscriptionToFinish()

        let record = await fixture.system.mailboxRecord()
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.transcript, "hello ,")
        let events = await fixture.system.events
        XCTAssertEqual(
            events,
            [
                "capture.finish",
                "mailbox.processing",
                "ronin.transcribe",
                "mailbox.complete",
                "capture.remove",
            ]
        )
    }

    private func arm(_ workflow: PrototypeDictationWorkflow) async {
        await workflow.send(.primaryButtonTapped)
        for _ in 0..<5 {
            await Task.yield()
        }
        XCTAssertTrue(workflow.state.isArmed)
    }

    private func makeFixture(
        transcripts: [String] = ["hello"],
        uuidValues: [UUID] = []
    ) -> WorkflowFixture {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let system = WorkflowTestSystem(now: now, transcripts: transcripts)
        let credentials = LockedValue(String(repeating: "a", count: 64))
        let preferences = LockedValue(PrototypeDictationPreferences())
        let uuidSource = UUIDSource(values: uuidValues)
        let updates = AsyncStream<DictationCapture.Update> { continuation in
            continuation.finish()
        }

        let dependencies = PrototypeDictationWorkflowDependencies(
            capture: PrototypeCaptureClient(
                updates: updates,
                arm: { generation in
                    try await system.armCapture(generation: generation)
                },
                begin: { requestID in
                    try await system.beginCapture(requestID: requestID)
                },
                currentState: {
                    await system.captureState
                },
                finish: { requestID in
                    try await system.finishCapture(requestID: requestID)
                },
                cancelIfActive: { requestID in
                    try await system.cancelCaptureIfActive(requestID: requestID)
                },
                disarm: {
                    await system.disarmCapture()
                },
                removeCapturedAudio: { fileURL in
                    try await system.removeCapturedAudio(fileURL: fileURL)
                }
            ),
            ipc: PrototypeIPCClient(
                reconcileHostRelaunch: {
                    () async throws(PrototypeIPCError) -> PrototypeIPCSnapshot in
                    try await system.reconcileHostRelaunch()
                },
                snapshot: {
                    () async throws(PrototypeIPCError) -> PrototypeIPCSnapshot in
                    try await system.snapshot()
                },
                currentMailbox: {
                    () async throws(PrototypeIPCError) -> PrototypeMailboxRecord? in
                    await system.mailboxRecord()
                },
                currentWarmSession: {
                    () async throws(PrototypeIPCError) -> PrototypeWarmSessionRecord? in
                    await system.warmSessionRecord()
                },
                armWarmSession: {
                    (date: Date) async throws(PrototypeIPCError)
                        -> PrototypeWarmSessionRecord in
                    try await system.armWarmSession(at: date)
                },
                heartbeatWarmSession: {
                    (id: UUID, date: Date) async throws(PrototypeIPCError) in
                    try await system.heartbeatWarmSession(id: id, at: date)
                },
                extendWarmSession: {
                    (id: UUID, date: Date) async throws(PrototypeIPCError) in
                    try await system.extendWarmSession(id: id, at: date)
                },
                extendWarmSessionIfReady: {
                    (id: UUID, date: Date) async throws(PrototypeIPCError)
                        -> PrototypeWarmSessionRecord? in
                    try await system.extendWarmSessionIfReady(id: id, at: date)
                },
                failWarmSession: {
                    (id: UUID, message: String) async throws(PrototypeIPCError) in
                    try await system.failWarmSession(id: id, message: message)
                },
                clearWarmSession: {
                    () async throws(PrototypeIPCError) in
                    await system.clearWarmSession()
                },
                beginCapture: {
                    (id: UUID) async throws(PrototypeIPCError) -> UUID in
                    try await system.beginMailboxCapture(id: id)
                },
                requestStop: {
                    (id: UUID) async throws(PrototypeIPCError) in
                    try await system.requestHostStop(id: id)
                },
                failActiveCaptureIfKeyboardHeartbeatStale: {
                    (id: UUID, date: Date, message: String)
                        async throws(PrototypeIPCError) -> Bool in
                    try await system.failActiveCaptureIfKeyboardHeartbeatStale(
                        id: id,
                        at: date,
                        message: message
                    )
                },
                markProcessing: {
                    (id: UUID, stoppedAt: Date) async throws(PrototypeIPCError) in
                    try await system.markProcessing(id: id, stoppedAt: stoppedAt)
                },
                complete: {
                    (
                        id: UUID,
                        transcript: String,
                        roundTrip: Int,
                        upstream: Int?,
                        service: Int
                    ) async throws(PrototypeIPCError) in
                    try await system.complete(
                        id: id,
                        transcript: transcript,
                        roundTrip: roundTrip,
                        upstream: upstream,
                        service: service
                    )
                },
                failMailbox: {
                    (id: UUID, message: String) async throws(PrototypeIPCError) in
                    try await system.failMailbox(id: id, message: message)
                },
                clearMailbox: {
                    () async throws(PrototypeIPCError) in
                    await system.clearMailbox()
                },
                seedCompleted: {
                    (transcript: String) async throws(PrototypeIPCError) in
                    await system.seedCompleted(transcript: transcript)
                }
            ),
            ronin: PrototypeRoninClientDependency(
                verifyReady: { _, _ in },
                transcribe: { _, _, _, requestID in
                    try await system.transcribe(requestID: requestID)
                }
            ),
            credentials: PrototypeCredentialClient(
                loadAndMigrateLegacyToken: { credentials.value },
                saveToken: { credentials.value = $0 }
            ),
            preferences: PrototypeDictationPreferencesClient(
                load: { preferences.value },
                save: { preferences.value = $0 }
            ),
            clock: PrototypeWorkflowClock(
                now: { now },
                sleep: { duration in
                    try await Task.sleep(for: duration)
                }
            ),
            uuid: uuidSource.next
        )
        let workflow = PrototypeDictationWorkflow(dependencies: dependencies)
        return WorkflowFixture(workflow: workflow, system: system, now: now)
    }
}

private struct WorkflowFixture {
    let workflow: PrototypeDictationWorkflow
    let system: WorkflowTestSystem
    let now: Date
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get {
            lock.withLock { storedValue }
        }
        set {
            lock.withLock { storedValue = newValue }
        }
    }
}

private final class UUIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            values.isEmpty ? UUID() : values.removeFirst()
        }
    }
}

private enum WorkflowTestError: LocalizedError {
    case uploadFailed

    var errorDescription: String? {
        "Test upload failed."
    }
}

private actor WorkflowTestSystem {
    let now: Date
    private var transcripts: [String]
    private var mailbox: PrototypeMailboxRecord?
    private var warmSession: PrototypeWarmSessionRecord?
    private var activeCaptureID: UUID?
    private(set) var captureState: DictationCapture.State = .disarmed
    private var captureSequence: UInt64 = 0
    private var shouldFailSnapshot = false
    private var shouldFailUpload = false
    private var shouldSuspendUpload = false
    private var uploadStarted = false
    private var suspendedUpload: CheckedContinuation<Void, Never>?
    private var shouldSuspendReconcile = false
    private var reconcileStarted = false
    private var suspendedReconcile: CheckedContinuation<Void, Never>?

    private(set) var armCount = 0
    private(set) var beginCount = 0
    private(set) var disarmCount = 0
    private(set) var completedRequestIDs: [UUID] = []
    private(set) var removedRequestIDs: [UUID] = []
    private(set) var events: [String] = []
    private(set) var lifecycleEvents: [String] = []

    init(now: Date, transcripts: [String]) {
        self.now = now
        self.transcripts = transcripts
    }

    func setSnapshotFailure(_ value: Bool) {
        shouldFailSnapshot = value
    }

    func setUploadFailure(_ value: Bool) {
        shouldFailUpload = value
    }

    func setUploadSuspended(_ value: Bool) {
        shouldSuspendUpload = value
    }

    func setReconcileSuspended(_ value: Bool) {
        shouldSuspendReconcile = value
    }

    func waitForReconcileStart() async -> Bool {
        for _ in 0..<1_000 {
            if reconcileStarted { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumeReconcile() {
        suspendedReconcile?.resume()
        suspendedReconcile = nil
    }

    func waitForUploadStart() async -> Bool {
        for _ in 0..<1_000 {
            if uploadStarted { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumeUpload() {
        suspendedUpload?.resume()
        suspendedUpload = nil
    }

    func waitForRemoval(requestID: UUID) async -> Bool {
        for _ in 0..<1_000 {
            if removedRequestIDs.contains(requestID) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func requestCapture(id: UUID) {
        mailbox = makeMailbox(
            id: id,
            state: .captureRequested,
            keyboardHeartbeatAt: now
        )
    }

    func requestKeyboardStop(id: UUID) {
        guard var mailbox, mailbox.id == id else { return }
        mailbox.state = .stopRequested
        mailbox.stopRequestedAt = now
        mailbox.keyboardHeartbeatAt = now
        self.mailbox = mailbox
    }

    func mailboxRecord() -> PrototypeMailboxRecord? {
        mailbox
    }

    func warmSessionRecord() -> PrototypeWarmSessionRecord? {
        warmSession
    }

    func armCapture(generation _: UUID) throws -> UInt64 {
        lifecycleEvents.append("capture.arm")
        armCount += 1
        captureSequence += 1
        captureState = .armed(expiresAt: now.addingTimeInterval(15 * 60))
        return captureSequence
    }

    func beginCapture(requestID: UUID) throws {
        guard activeCaptureID == nil else {
            throw DictationCapture.Failure.busy(activeRequestID: activeCaptureID!)
        }
        beginCount += 1
        activeCaptureID = requestID
        captureState = .recordingSession(
            requestID: requestID,
            startedAt: now,
            armExpiresAt: now.addingTimeInterval(15 * 60)
        )
    }

    func finishCapture(requestID: UUID) throws -> DictationCapture.CapturedAudio {
        guard activeCaptureID == requestID else {
            throw DictationCapture.Failure.stale(
                expectedRequestID: activeCaptureID,
                receivedRequestID: requestID
            )
        }
        events.append("capture.finish")
        activeCaptureID = nil
        captureState = .armed(expiresAt: now.addingTimeInterval(15 * 60))
        return DictationCapture.CapturedAudio(
            requestID: requestID,
            fileURL: URL(fileURLWithPath: "/tmp/\(requestID.uuidString).wav"),
            duration: .seconds(1),
            byteCount: 32_000
        )
    }

    func cancelCaptureIfActive(requestID: UUID) throws -> Bool {
        guard let activeCaptureID else { return false }
        guard activeCaptureID == requestID else {
            throw DictationCapture.Failure.stale(
                expectedRequestID: activeCaptureID,
                receivedRequestID: requestID
            )
        }
        self.activeCaptureID = nil
        captureState = .armed(expiresAt: now.addingTimeInterval(15 * 60))
        return true
    }

    func disarmCapture() {
        disarmCount += 1
        activeCaptureID = nil
        captureState = .disarmed
    }

    func removeCapturedAudio(fileURL: URL) throws {
        events.append("capture.remove")
        guard let requestID = UUID(
            uuidString: fileURL.deletingPathExtension().lastPathComponent
        ) else {
            throw DictationCapture.Failure.storageUnavailable
        }
        removedRequestIDs.append(requestID)
    }

    func reconcileHostRelaunch() async throws(PrototypeIPCError) -> PrototypeIPCSnapshot {
        reconcileStarted = true
        if shouldSuspendReconcile {
            await withCheckedContinuation { continuation in
                suspendedReconcile = continuation
            }
        }
        lifecycleEvents.append("reconcile.finished")
        warmSession = nil
        if var mailbox,
           [.captureRequested, .capturing, .stopRequested, .cancelRequested, .processing]
            .contains(mailbox.state) {
            mailbox.state = .failed
            self.mailbox = mailbox
        }
        return PrototypeIPCSnapshot(mailbox: mailbox, warmSession: nil)
    }

    func snapshot() throws(PrototypeIPCError) -> PrototypeIPCSnapshot {
        if shouldFailSnapshot {
            throw .containerUnavailable
        }
        return PrototypeIPCSnapshot(mailbox: mailbox, warmSession: warmSession)
    }

    func armWarmSession(at date: Date) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord {
        let record = PrototypeWarmSessionRecord(
            id: UUID(),
            state: .armed,
            armedAt: date,
            heartbeatAt: date,
            expiresAt: date.addingTimeInterval(15 * 60),
            errorMessage: nil
        )
        warmSession = record
        return record
    }

    func heartbeatWarmSession(id: UUID, at date: Date) throws(PrototypeIPCError) {
        guard var warmSession, warmSession.id == id else {
            throw .missingWarmSessionRecord(id)
        }
        warmSession.heartbeatAt = date
        self.warmSession = warmSession
    }

    func extendWarmSession(id: UUID, at date: Date) throws(PrototypeIPCError) {
        guard var warmSession, warmSession.id == id else {
            throw .missingWarmSessionRecord(id)
        }
        warmSession.heartbeatAt = date
        warmSession.expiresAt = date.addingTimeInterval(15 * 60)
        self.warmSession = warmSession
    }

    func extendWarmSessionIfReady(
        id: UUID,
        at date: Date
    ) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord? {
        guard var warmSession,
              warmSession.id == id,
              warmSession.isReady(at: date) else { return nil }
        warmSession.heartbeatAt = date
        warmSession.expiresAt = date.addingTimeInterval(15 * 60)
        self.warmSession = warmSession
        return warmSession
    }

    func failWarmSession(id: UUID, message: String) throws(PrototypeIPCError) {
        guard var warmSession, warmSession.id == id else {
            throw .missingWarmSessionRecord(id)
        }
        warmSession.state = .unavailable
        warmSession.errorMessage = message
        self.warmSession = warmSession
    }

    func clearWarmSession() {
        warmSession = nil
    }

    func beginMailboxCapture(id: UUID) throws(PrototypeIPCError) -> UUID {
        guard var mailbox else { throw .missingMailboxRecord(id) }
        guard mailbox.id == id else {
            throw .staleMailboxRecord(expected: id, actual: mailbox.id)
        }
        guard mailbox.state == .captureRequested else {
            throw .illegalMailboxTransition(id: id, from: mailbox.state, to: .capturing)
        }
        mailbox.state = .capturing
        self.mailbox = mailbox
        return id
    }

    func requestHostStop(id: UUID) throws(PrototypeIPCError) {
        guard var mailbox else { throw .missingMailboxRecord(id) }
        guard mailbox.id == id else {
            throw .staleMailboxRecord(expected: id, actual: mailbox.id)
        }
        switch mailbox.state {
        case .capturing, .stopRequested:
            mailbox.state = .stopRequested
            mailbox.stopRequestedAt = mailbox.stopRequestedAt ?? now
            self.mailbox = mailbox
        default:
            throw .illegalMailboxTransition(id: id, from: mailbox.state, to: .stopRequested)
        }
    }

    func requestKeyboardCancel(id: UUID) throws(PrototypeIPCError) {
        guard var mailbox else { throw .missingMailboxRecord(id) }
        guard mailbox.id == id else {
            throw .staleMailboxRecord(expected: id, actual: mailbox.id)
        }
        mailbox.state = .cancelRequested
        mailbox.transcript = ""
        mailbox.errorMessage = "Voice entry cancelled."
        self.mailbox = mailbox
    }

    func failActiveCaptureIfKeyboardHeartbeatStale(
        id: UUID,
        at date: Date,
        message: String
    ) throws(PrototypeIPCError) -> Bool {
        guard var mailbox, mailbox.id == id else { return false }
        guard !mailbox.hasRecentKeyboardHeartbeat(at: date) else { return false }
        mailbox.state = .failed
        mailbox.errorMessage = message
        self.mailbox = mailbox
        return true
    }

    func markProcessing(id: UUID, stoppedAt: Date) throws(PrototypeIPCError) {
        guard var mailbox else { throw .missingMailboxRecord(id) }
        guard mailbox.id == id else {
            throw .staleMailboxRecord(expected: id, actual: mailbox.id)
        }
        guard mailbox.state == .capturing || mailbox.state == .stopRequested else {
            throw .illegalMailboxTransition(id: id, from: mailbox.state, to: .processing)
        }
        events.append("mailbox.processing")
        mailbox.state = .processing
        mailbox.recordingStoppedAt = stoppedAt
        self.mailbox = mailbox
    }

    func complete(
        id: UUID,
        transcript: String,
        roundTrip: Int,
        upstream: Int?,
        service: Int
    ) throws(PrototypeIPCError) {
        guard var mailbox else { throw .missingMailboxRecord(id) }
        guard mailbox.id == id else {
            throw .staleMailboxRecord(expected: id, actual: mailbox.id)
        }
        guard mailbox.state == .processing else {
            throw .illegalMailboxTransition(id: id, from: mailbox.state, to: .completed)
        }
        events.append("mailbox.complete")
        mailbox.state = .completed
        mailbox.transcript = transcript
        mailbox.roundTripMilliseconds = roundTrip
        mailbox.upstreamMilliseconds = upstream
        mailbox.serviceMilliseconds = service
        mailbox.completedAt = now
        self.mailbox = mailbox
        completedRequestIDs.append(id)
    }

    func failMailbox(id: UUID, message: String) throws(PrototypeIPCError) {
        guard var mailbox else { throw .missingMailboxRecord(id) }
        guard mailbox.id == id else {
            throw .staleMailboxRecord(expected: id, actual: mailbox.id)
        }
        if mailbox.state == .completed || mailbox.state == .consumed {
            throw .illegalMailboxTransition(id: id, from: mailbox.state, to: .failed)
        }
        mailbox.state = .failed
        mailbox.errorMessage = message
        self.mailbox = mailbox
    }

    func clearMailbox() {
        mailbox = nil
    }

    func seedCompleted(transcript: String) {
        var record = makeMailbox(id: UUID(), state: .completed, keyboardHeartbeatAt: nil)
        record.transcript = transcript
        mailbox = record
    }

    func transcribe(requestID: UUID) async throws -> PrototypeRoninResponse {
        events.append("ronin.transcribe")
        uploadStarted = true
        if shouldSuspendUpload {
            await withCheckedContinuation { continuation in
                suspendedUpload = continuation
            }
        }
        if shouldFailUpload {
            throw WorkflowTestError.uploadFailed
        }
        let transcript = transcripts.isEmpty ? "hello" : transcripts.removeFirst()
        return PrototypeRoninResponse(
            requestID: requestID.uuidString,
            transcript: transcript,
            timings: .init(upstreamMS: 20, totalMS: 30)
        )
    }

    private func makeMailbox(
        id: UUID,
        state: PrototypeMailboxRecord.State,
        keyboardHeartbeatAt: Date?
    ) -> PrototypeMailboxRecord {
        PrototypeMailboxRecord(
            id: id,
            documentIdentifier: UUID(),
            createdAt: now,
            keyboardHeartbeatAt: keyboardHeartbeatAt,
            stopRequestedAt: nil,
            state: state,
            transcript: "",
            roundTripMilliseconds: nil,
            upstreamMilliseconds: nil,
            serviceMilliseconds: nil,
            recordingStoppedAt: nil,
            completedAt: nil,
            insertedAt: nil,
            errorMessage: nil
        )
    }
}
