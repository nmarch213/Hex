import Foundation
import os.log
/// Coordinates the personal iOS Dictation workflow through one typed state/action seam.
///
/// Audio capture, App Group persistence, Ronin I/O, credentials, preferences, and time are
/// adapters supplied at initialization. Views and tests exercise the same `send(_:)` interface.
@MainActor
final class PrototypeDictationWorkflow {
    private(set) var state: State {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }
    var onStateChange: (@MainActor (State) -> Void)?
    private let dependencies: PrototypeDictationWorkflowDependencies
    private var requestID: UUID?
    private var requestPreferences: (requestID: UUID, values: PrototypeDictationPreferences)?
    private var activeWarmSessionID: UUID?
    private var captureUpdateTask: Task<Void, Never>?
    private var warmCommandTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionGeneration: UUID?
    private var lastHeartbeatAt = Date.distantPast
    private var isHandlingIPCFailure = false
    private var captureUpdateFence = DictationCaptureUpdateFence()
    private var didLaunch = false
    private var launchTask: Task<Void, Never>?
    private var credentialEditGeneration = 0
    private var actionTask: Task<Void, Never>?
    private var actionSequence: UInt64 = 0
    init(
        serverURLString: String = "https://ronin.tail451960.ts.net:8443",
        dependencies: PrototypeDictationWorkflowDependencies
    ) {
        self.dependencies = dependencies
        state = State(
            serverURLString: serverURLString,
            token: "",
            credentialStatus: "Loading…",
            transcriptPreferences: dependencies.preferences.load()
        )
    }
    deinit {
        captureUpdateTask?.cancel()
        warmCommandTask?.cancel()
        transcriptionTask?.cancel()
        launchTask?.cancel()
        actionTask?.cancel()
    }
    func start() {
        _ = beginLaunchIfNeeded()
    }
    func setToken(_ token: String) {
        credentialEditGeneration &+= 1
        state.token = token
        state.credentialStatus = "Unsaved"
    }
    func setTranscriptPreferences(_ preferences: PrototypeDictationPreferences) {
        state.transcriptPreferences = preferences
        dependencies.preferences.save(preferences)
    }
    func send(_ action: Action) async {
        let precedingTask = actionTask
        actionSequence &+= 1
        let sequence = actionSequence
        let task = Task { @MainActor [weak self] in
            await precedingTask?.value
            await self?.reduce(action)
        }
        actionTask = task
        await task.value
        if sequence == actionSequence {
            actionTask = nil
        }
    }
    private func reduce(_ action: Action) async {
        await ensureLaunched()
        switch action {
        case .launch:
            return
        case .primaryButtonTapped:
            if state.isRecording {
                await stopAndTranscribe()
            } else if state.isBusy {
                state.status = "Dictation is still processing."
            } else if state.isArmed {
                await disarmWarmSession()
            } else {
                await armWarmSession()
            }
        case .armShortcutRequested:
            if state.isArmed {
                state.status = "Keyboard Dictation is already armed. Swipe back to keep typing."
            } else if state.isBusy {
                state.status = "Hex is already preparing keyboard Dictation."
            } else {
                state.status = "Opened from Arm Hex. Arming automatically…"
                await armWarmSession()
            }
        case .refresh:
            await refreshMailbox()
        case .saveCredential:
            await saveCredential()
        case .resetKeyboardState:
            await resetKeyboardStateAndDisarm()
        case .pollWarmCommands:
            guard let activeWarmSessionID else { return }
            await pollWarmCommands(sessionID: activeWarmSessionID)
        case let .captureUpdated(update):
            await handleCaptureUpdate(update)
        case let .seedMailbox(transcript):
            await seedMailbox(transcript: transcript)
        case .clearMailbox:
            await clearMailbox()
        }
    }
#if DEBUG
    /// Lets deterministic tests observe the completion of the currently owned upload.
    func waitForTranscriptionToFinish() async {
        await transcriptionTask?.value
    }
#endif
    private func reconcileHostRelaunch() async {
        do {
            let launchSnapshot = try await dependencies.ipc.reconcileHostRelaunch()
            state.mailboxRecord = launchSnapshot.mailbox
            state.warmSessionRecord = nil
            state.hasIPCFailure = false
        } catch {
            await handleIPCFailure(error)
        }
    }
    private func beginLaunchIfNeeded() -> Task<Void, Never>? {
        guard !didLaunch else { return nil }
        if let launchTask { return launchTask }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLaunch()
        }
        launchTask = task
        return task
    }
    private func ensureLaunched() async {
        guard let launchTask = beginLaunchIfNeeded() else { return }
        await launchTask.value
    }
    private func performLaunch() async {
        defer {
            didLaunch = true
            launchTask = nil
        }
        observeCaptureUpdates()
        await loadCredential()
        await reconcileHostRelaunch()
    }
    private func loadCredential() async {
        let generation = credentialEditGeneration
        do {
            let keychainToken = try await dependencies.credentials
                .loadAndMigrateLegacyToken()
            guard generation == credentialEditGeneration else { return }
            if let keychainToken {
                state.token = keychainToken
                state.credentialStatus = "Stored in Keychain"
            } else {
                state.token = ""
                state.credentialStatus = "Missing"
            }
        } catch {
            guard generation == credentialEditGeneration else { return }
            state.token = ""
            state.credentialStatus = error.localizedDescription
        }
    }
    private func saveCredential() async {
        let generation = credentialEditGeneration
        let token = state.token
        do {
            try await dependencies.credentials.saveToken(token)
            guard generation == credentialEditGeneration else { return }
            state.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            state.credentialStatus = state.token.isEmpty ? "Missing" : "Stored in Keychain"
        } catch {
            guard generation == credentialEditGeneration else { return }
            state.token = ""
            state.credentialStatus = error.localizedDescription
        }
    }
    private func clearRequest() {
        requestID = nil
        requestPreferences = nil
    }
}
private extension PrototypeDictationWorkflow {
    private func armWarmSession() async {
        guard !state.isBusy, !state.isArmed else { return }
        state.isBusy = true
        state.status = "Checking Ronin…"
        do {
            try await dependencies.ronin.verifyReady(
                state.serverURLString,
                state.token
            )
        } catch {
            state.isBusy = false
            state.status = "Could not arm: \(error.localizedDescription)"
            return
        }
        var armedSessionID: UUID?
        do {
            try await abandonInterruptedRequestIfNeeded()
            // Persisted leases cannot prove that this process still owns an audio resource.
            try await dependencies.ipc.clearWarmSession()
            let now = dependencies.clock.now()
            let sessionRecord = try await dependencies.ipc.armWarmSession(now)
            armedSessionID = sessionRecord.id
            let captureGeneration = dependencies.uuid()
            captureUpdateFence.beginArm(generation: captureGeneration)
            let armUpdateSequence = try await dependencies.capture.arm(captureGeneration)
            guard captureUpdateFence.synchronizeArm(
                generation: captureGeneration,
                through: armUpdateSequence
            ) else {
                state.isBusy = false
                return
            }
            activeWarmSessionID = sessionRecord.id
            state.isArmed = true
            state.isBusy = false
            lastHeartbeatAt = now
            state.warmSessionRecord = try await dependencies.ipc.currentWarmSession()
            state.status =
                "Armed for 15 minutes. Swipe back, then tap Start Voice in the Hex keyboard."
            startWarmCommandLoop()
        } catch {
            state.isBusy = false
            if let armedSessionID {
                guard await recordWarmSessionFailure(
                    id: armedSessionID,
                    message: error.localizedDescription
                ) else {
                    await dependencies.capture.disarm()
                    return
                }
            } else if let ipcError = error as? PrototypeIPCError {
                await handleIPCFailure(ipcError)
                await dependencies.capture.disarm()
                return
            }
            state.status = "Could not arm keyboard Dictation: \(error.localizedDescription)"
            await dependencies.capture.disarm()
        }
    }
    private func abandonInterruptedRequestIfNeeded() async throws(PrototypeIPCError) {
        guard let record = try await dependencies.ipc.currentMailbox() else { return }
        switch record.state {
        case .captureRequested, .capturing, .stopRequested,
             .cancelRequested, .processing:
            try await dependencies.ipc.failMailbox(
                record.id,
                "The previous dictation was interrupted. Tap Start Voice to try again."
            )
        case .completed, .consumed, .failed:
            break
        }
    }
    private func disarmWarmSession(expired: Bool = false) async {
        warmCommandTask?.cancel()
        warmCommandTask = nil
        activeWarmSessionID = nil
        cancelTranscriptionTask()
        let interruptedRequestID = requestID
        clearRequest()
        state.isRecording = false
        state.isBusy = false
        await dependencies.capture.disarm()
        state.isArmed = false
        if let interruptedRequestID,
           !(await recordMailboxFailure(
               id: interruptedRequestID,
               message: "The warm session ended before Dictation completed."
           )) {
            return
        }
        do {
            try await dependencies.ipc.clearWarmSession()
            state.warmSessionRecord = nil
        } catch {
            await handleIPCFailure(error)
            return
        }
        state.status = expired
            ? "Keyboard Dictation expired. Arm it again when you are ready."
            : "Keyboard Dictation disarmed."
    }
    private func startWarmCommandLoop() {
        warmCommandTask?.cancel()
        let sleep = dependencies.clock.sleep
        warmCommandTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.send(.pollWarmCommands)
                do {
                    try await sleep(.milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }
    private func pollWarmCommands(sessionID: UUID) async {
        guard state.isArmed, activeWarmSessionID == sessionID else { return }
        let pollStartedAt = dependencies.clock.now()
        let shouldHeartbeat = pollStartedAt.timeIntervalSince(lastHeartbeatAt) >= 1
        let snapshot: PrototypeIPCSnapshot
        do {
            if shouldHeartbeat {
                try await dependencies.ipc.heartbeatWarmSession(
                    sessionID,
                    pollStartedAt
                )
            }
            snapshot = try await dependencies.ipc.snapshot()
        } catch {
            await handleIPCFailure(error)
            return
        }
        guard !Task.isCancelled,
              state.isArmed,
              activeWarmSessionID == sessionID else { return }
        let observedAt = dependencies.clock.now()
        state.warmSessionRecord = snapshot.warmSession
        if shouldHeartbeat {
            lastHeartbeatAt = observedAt
        }
        guard let liveSession = snapshot.warmSession,
              liveSession.id == sessionID,
              liveSession.isReady(at: observedAt) else {
            await disarmWarmSession(expired: true)
            return
        }
        guard let record = snapshot.mailbox else { return }
        switch record.state {
        case .captureRequested, .capturing, .stopRequested:
            guard record.hasRecentKeyboardHeartbeat(at: observedAt) else {
                let message = "Voice entry was cancelled because the Hex keyboard closed."
                let cancellationWon: Bool
                do {
                    cancellationWon = try await dependencies.ipc
                        .failActiveCaptureIfKeyboardHeartbeatStale(
                            record.id,
                            observedAt,
                            message
                        )
                } catch {
                    await handleIPCFailure(error)
                    return
                }
                guard cancellationWon else {
                    await refreshMailbox()
                    return
                }
                await cancelRecording(requestID: record.id, message: message)
                return
            }
        case .cancelRequested, .processing, .completed, .consumed, .failed:
            break
        }
        switch PrototypeWarmCaptureCommand.nextAction(
            for: record.state,
            isBusy: state.isBusy,
            isRecording: state.isRecording
        ) {
        case .start:
            await startRecording(requestedID: record.id, sessionID: sessionID)
        case .stop:
            await stopAndTranscribe()
        case .startThenStop:
            await startRecording(requestedID: record.id, sessionID: sessionID)
            if state.isRecording {
                await stopAndTranscribe()
            }
        case .cancel:
            await cancelRecording(
                requestID: record.id,
                message: record.errorMessage
                    ?? "Voice entry was cancelled because the Hex keyboard closed."
            )
        case .none:
            break
        }
    }
    private func cancelRecording(
        requestID: UUID,
        message: String
    ) async {
        cancelTranscriptionTask()
        let activeRequestID = self.requestID
        clearRequest()
        state.isRecording = false
        state.isBusy = false
        if activeRequestID == requestID {
            do {
                _ = try await dependencies.capture.cancelIfActive(requestID)
            } catch {
                await dependencies.capture.disarm()
                state.isArmed = false
                activeWarmSessionID = nil
                warmCommandTask?.cancel()
                warmCommandTask = nil
                if let sessionID = state.warmSessionRecord?.id,
                   !(await recordWarmSessionFailure(
                       id: sessionID,
                       message: error.localizedDescription
                   )) {
                    return
                }
            }
        }
        guard await recordMailboxFailure(id: requestID, message: message) else {
            return
        }
        if state.isArmed, let sessionID = state.warmSessionRecord?.id {
            do {
                let now = dependencies.clock.now()
                try await dependencies.ipc.extendWarmSession(sessionID, now)
                state.warmSessionRecord = try await dependencies.ipc.currentWarmSession()
            } catch {
                await handleIPCFailure(error)
                return
            }
        }
        state.status = message
        await refreshMailbox()
    }
    private func startRecording(
        requestedID: UUID,
        sessionID: UUID
    ) async {
        guard !state.isBusy else { return }
        state.isBusy = true
        state.status = "Starting voice capture…"
        var captureStartedFor: UUID?
        do {
            guard state.isArmed else { throw DictationCapture.Failure.notArmed }
            let id = try await dependencies.ipc.beginCapture(requestedID)
            requestID = id
            requestPreferences = (id, state.transcriptPreferences)
            try await dependencies.capture.begin(id)
            captureStartedFor = id
            let liveRecord = try await validateLiveCapture(
                requestID: id,
                sessionID: sessionID
            )
            let liveCaptureState = await dependencies.capture.currentState()
            guard case let .recordingSession(activeRequestID, _, _) = liveCaptureState,
                  activeRequestID == id,
                  requestID == id,
                  state.isArmed else {
                throw DictationCapture.Failure.notArmed
            }
            state.isRecording = true
            if liveRecord.state == .stopRequested {
                try await dependencies.ipc.requestStop(id)
            }
            if let sessionID = state.warmSessionRecord?.id {
                let now = dependencies.clock.now()
                try await dependencies.ipc.extendWarmSession(sessionID, now)
                state.warmSessionRecord = try await dependencies.ipc.currentWarmSession()
            }
            state.status = "Recording English audio…"
            await refreshMailbox()
        } catch {
            var terminalError: Error = error
            state.isBusy = false
            state.isRecording = false
            let failedRequestID = requestID
            clearRequest()
            if let captureStartedFor {
                do {
                    _ = try await dependencies.capture.cancelIfActive(captureStartedFor)
                } catch let cancellationError {
                    terminalError = cancellationError
                }
            }
            if case let PrototypeIPCError.illegalMailboxTransition(
                id,
                from: .cancelRequested,
                to: .capturing
            ) = terminalError,
               id == requestedID {
                state.status = "Voice entry was cancelled because the Hex keyboard closed."
                await refreshMailbox()
                return
            }
            if let failedRequestID,
               !(await recordMailboxFailure(
                   id: failedRequestID,
                   message: terminalError.localizedDescription
               )) {
                return
            }
            if case let PrototypeIPCError.keyboardPresenceExpired(id) = terminalError,
               id == requestedID {
                state.status = "Voice entry was cancelled because the Hex keyboard closed."
                await refreshMailbox()
                return
            }
            if let ipcError = terminalError as? PrototypeIPCError {
                await handleIPCFailure(ipcError)
                return
            }
            state.status = "Could not record: \(terminalError.localizedDescription)"
            await refreshMailbox()
        }
    }
    private func validateLiveCapture(
        requestID: UUID,
        sessionID: UUID
    ) async throws(PrototypeIPCError) -> PrototypeMailboxRecord {
        let snapshot = try await dependencies.ipc.snapshot()
        guard let session = snapshot.warmSession else {
            throw .missingWarmSessionRecord(sessionID)
        }
        guard session.id == sessionID else {
            throw .staleWarmSessionRecord(expected: sessionID, actual: session.id)
        }
        let now = dependencies.clock.now()
        guard session.isReady(at: now) else {
            throw .warmSessionNotReady(sessionID)
        }
        guard let record = snapshot.mailbox else {
            throw .missingMailboxRecord(requestID)
        }
        guard record.id == requestID else {
            throw .staleMailboxRecord(expected: requestID, actual: record.id)
        }
        guard record.hasRecentKeyboardHeartbeat(at: now) else {
            throw .keyboardPresenceExpired(requestID)
        }
        guard record.state == .capturing || record.state == .stopRequested else {
            throw .illegalMailboxTransition(
                id: requestID,
                from: record.state,
                to: .capturing
            )
        }
        return record
    }
    private func stopAndTranscribe() async {
        guard state.isRecording, let requestID else { return }
        do {
            try await dependencies.ipc.requestStop(requestID)
        } catch let PrototypeIPCError.illegalMailboxTransition(
            id,
            from: .cancelRequested,
            to: .stopRequested
        ) where id == requestID {
            await cancelRecording(
                requestID: requestID,
                message: "Voice entry was cancelled because the Hex keyboard closed."
            )
            return
        } catch {
            await handleIPCFailure(error)
            return
        }
        state.isRecording = false
        cancelTranscriptionTask()
        let generation = dependencies.uuid()
        transcriptionGeneration = generation
        transcriptionTask = Task { [weak self] in
            await self?.finishAndTranscribe(generation: generation)
        }
    }
}
private extension PrototypeDictationWorkflow {
    private func finishAndTranscribe(generation: UUID) async {
        guard generation == transcriptionGeneration else { return }
        guard let requestID else {
            state.status = "No active recording."
            state.isBusy = false
            return
        }
        let transcriptPreferences = requestPreferences.flatMap { snapshot in
            snapshot.requestID == requestID ? snapshot.values : nil
        } ?? state.transcriptPreferences
        guard let capture = await finishCapture(requestID, generation: generation) else { return }
        await uploadAndComplete(
            capture.outputURL, recordingStoppedAt: capture.recordingStoppedAt, requestID: requestID,
            transcriptPreferences: transcriptPreferences,
            generation: generation
        )
    }
    private func finishCapture(
        _ requestID: UUID, generation: UUID
    ) async -> (outputURL: URL, recordingStoppedAt: Date)? {
        let mailboxRecord: PrototypeMailboxRecord?
        do {
            mailboxRecord = try await dependencies.ipc.currentMailbox().flatMap { record in
                record.id == requestID ? record : nil
            }
        } catch {
            await handleIPCFailure(error)
            return nil
        }
        let recordingStoppedAt = mailboxRecord?.stopRequestedAt
            ?? dependencies.clock.now()
        let outputURL: URL
        do {
            let capturedAudio = try await dependencies.capture.finish(requestID)
            outputURL = capturedAudio.fileURL
        } catch {
            state.isBusy = false
            clearRequest()
            guard await recordMailboxFailure(
                id: requestID,
                message: error.localizedDescription
            ) else {
                return nil
            }
            state.status = "Could not prepare dictation: \(error.localizedDescription)"
            await refreshMailbox()
            return nil
        }
        guard !Task.isCancelled,
              generation == transcriptionGeneration,
              self.requestID == requestID else {
            _ = await removeCapturedAudio(at: outputURL, requestID: requestID)
            return nil
        }
        let postFinishSnapshot: PrototypeIPCSnapshot
        do {
            postFinishSnapshot = try await dependencies.ipc.snapshot()
        } catch {
            _ = await removeCapturedAudio(at: outputURL, requestID: requestID)
            await handleIPCFailure(error)
            return nil
        }
        guard let liveRecord = postFinishSnapshot.mailbox,
              liveRecord.id == requestID else {
            _ = await removeCapturedAudio(at: outputURL, requestID: requestID)
            clearRequest()
            state.isBusy = false
            state.status = "Voice entry state disappeared before it could be processed."
            await refreshMailbox()
            return nil
        }
        switch liveRecord.state {
        case .capturing, .stopRequested:
            break
        case .cancelRequested, .failed:
            _ = await removeCapturedAudio(at: outputURL, requestID: requestID)
            clearRequest()
            state.isBusy = false
            state.status = liveRecord.errorMessage
                ?? "Voice entry ended before it could be processed."
            await refreshMailbox()
            return nil
        case .captureRequested, .processing, .completed, .consumed:
            _ = await removeCapturedAudio(at: outputURL, requestID: requestID)
            clearRequest()
            state.isBusy = false
            state.status = "Voice entry state changed before it could be processed."
            await refreshMailbox()
            return nil
        }
        do {
            try await dependencies.ipc.markProcessing(
                requestID,
                recordingStoppedAt
            )
        } catch {
            _ = await removeCapturedAudio(at: outputURL, requestID: requestID)
            clearRequest()
            state.isBusy = false
            if case let PrototypeIPCError.illegalMailboxTransition(
                id,
                from,
                to: .processing
            ) = error,
               id == requestID,
               from == .cancelRequested || from == .failed {
                state.status = "Voice entry ended before it could be processed."
                await refreshMailbox()
            } else {
                await handleIPCFailure(error)
            }
            return nil
        }
        await refreshMailbox()
        state.status = "Uploading to Ronin…"
        return (outputURL, recordingStoppedAt)
    }
    private func uploadAndComplete(
        _ outputURL: URL, recordingStoppedAt: Date, requestID: UUID,
        transcriptPreferences: PrototypeDictationPreferences, generation: UUID
    ) async {
        guard !Task.isCancelled,
              generation == transcriptionGeneration,
              self.requestID == requestID else {
            _ = await removeCapturedAudio(at: outputURL, requestID: requestID)
            return
        }
        defer {
            if generation == transcriptionGeneration {
                clearRequest()
                state.isBusy = false
                transcriptionTask = nil
            }
        }
        var shouldRefreshMailbox = true
        var postCompletionIPCFailure: PrototypeIPCError?
        do {
            let response = try await dependencies.ronin.transcribe(
                outputURL,
                state.serverURLString,
                state.token,
                requestID
            )
            try Task.checkCancellation()
            guard generation == transcriptionGeneration else {
                throw CancellationError()
            }
            let rawTranscript = response.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTranscript.isEmpty else {
                throw RecordingError.emptyTranscript
            }
            let finalTranscript = PrototypeTranscriptPipeline.apply(
                rawTranscript,
                removeFillerWords: transcriptPreferences.removeFillerWords,
                spokenPunctuation: transcriptPreferences.spokenPunctuation,
                lowercase: transcriptPreferences.lowercase,
                removePunctuation: transcriptPreferences.removePunctuation
            )
            guard !finalTranscript.isEmpty else {
                throw RecordingError.emptyFinalTranscript
            }
            let elapsed = Int(
                dependencies.clock.now().timeIntervalSince(recordingStoppedAt) * 1_000
            )
            try await dependencies.ipc.complete(
                requestID,
                finalTranscript,
                elapsed,
                response.timings.upstreamMS,
                response.timings.totalMS
            )
            if state.isArmed, let sessionID = state.warmSessionRecord?.id {
                do {
                    state.warmSessionRecord = try await dependencies.ipc
                        .extendWarmSessionIfReady(
                            sessionID,
                            dependencies.clock.now()
                        )
                    if state.warmSessionRecord == nil {
                        warmCommandTask?.cancel()
                        warmCommandTask = nil
                        activeWarmSessionID = nil
                        state.isArmed = false
                    }
                } catch {
                    postCompletionIPCFailure = error
                    shouldRefreshMailbox = false
                }
            }
            if postCompletionIPCFailure == nil {
                state.status = state.isArmed
                    ? "Transcript ready. The Hex keyboard will insert it."
                    : "Transcript ready. Switch to the Hex keyboard to insert it."
            }
        } catch {
            if Task.isCancelled
                || error is CancellationError
                || generation != transcriptionGeneration {
                shouldRefreshMailbox = false
            } else if await recordMailboxFailure(
                id: requestID,
                message: error.localizedDescription
            ) {
                state.status = "Transcription failed: \(error.localizedDescription)"
            } else {
                shouldRefreshMailbox = false
            }
        }
        guard await removeCapturedAudio(at: outputURL, requestID: requestID) else {
            return
        }
        if let postCompletionIPCFailure {
            await handleIPCFailure(postCompletionIPCFailure)
            return
        }
        if shouldRefreshMailbox {
            await refreshMailbox()
        }
    }

    @discardableResult
    private func removeCapturedAudio(
        at fileURL: URL,
        requestID: UUID
    ) async -> Bool {
        do {
            try await dependencies.capture.removeCapturedAudio(fileURL)
            return true
        } catch {
            warmCommandTask?.cancel()
            warmCommandTask = nil
            activeWarmSessionID = nil
            await dependencies.capture.disarm()
            state.isArmed = false
            state.isRecording = false
            if let sessionID = state.warmSessionRecord?.id {
                _ = await recordWarmSessionFailure(
                    id: sessionID,
                    message: "Hex could not remove transient Captured Audio."
                )
            }
            HexLog.recording.error("Could not delete transient iOS capture")
            state.status =
                "Hex could not remove transient audio. Reopen Hex before dictating again."
            return false
        }
    }

    private func cancelTranscriptionTask() {
        transcriptionGeneration = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }
    @discardableResult
    private func recordMailboxFailure(id: UUID, message: String) async -> Bool {
        do {
            try await dependencies.ipc.failMailbox(id, message)
            return true
        } catch {
            await handleIPCFailure(error)
            return false
        }
    }
    @discardableResult
    private func recordWarmSessionFailure(id: UUID, message: String) async -> Bool {
        do {
            try await dependencies.ipc.failWarmSession(id, message)
            state.warmSessionRecord = try await dependencies.ipc.currentWarmSession()
            return true
        } catch {
            await handleIPCFailure(error)
            return false
        }
    }
}
private extension PrototypeDictationWorkflow {
    private func handleIPCFailure(_: PrototypeIPCError) async {
        guard !isHandlingIPCFailure else { return }
        HexLog.app.error("iOS keyboard IPC failed")
        isHandlingIPCFailure = true
        state.hasIPCFailure = true
        warmCommandTask?.cancel()
        warmCommandTask = nil
        activeWarmSessionID = nil
        cancelTranscriptionTask()
        state.isArmed = false
        state.isRecording = false
        state.isBusy = false
        clearRequest()
        state.mailboxRecord = nil
        state.warmSessionRecord = nil
        state.status = "Keyboard state is unavailable. Reopen Hex and arm it again."
        await dependencies.capture.disarm()
        isHandlingIPCFailure = false
    }

    private func resetKeyboardStateAndDisarm() async {
        warmCommandTask?.cancel()
        warmCommandTask = nil
        activeWarmSessionID = nil
        cancelTranscriptionTask()
        await dependencies.capture.disarm()
        do {
            try await dependencies.ipc.clearMailbox()
            try await dependencies.ipc.clearWarmSession()
            state.isArmed = false
            state.isRecording = false
            state.isBusy = false
            clearRequest()
            state.mailboxRecord = nil
            state.warmSessionRecord = nil
            state.hasIPCFailure = false
            state.status = "Keyboard state reset. Arm Hex when you are ready."
        } catch {
            await handleIPCFailure(error)
        }
    }
    private func refreshMailbox() async {
        do {
            state.mailboxRecord = try await dependencies.ipc.currentMailbox()
            state.warmSessionRecord = try await dependencies.ipc.currentWarmSession()
            state.hasIPCFailure = false
        } catch {
            state.mailboxRecord = nil
            state.warmSessionRecord = nil
            await handleIPCFailure(error)
        }
    }
    private func seedMailbox(transcript: String) async {
        do {
            try await dependencies.ipc.seedCompleted(transcript)
            await refreshMailbox()
        } catch {
            await handleIPCFailure(error)
        }
    }
    private func clearMailbox() async {
        do {
            try await dependencies.ipc.clearMailbox()
            await refreshMailbox()
        } catch {
            await handleIPCFailure(error)
        }
    }
    private func observeCaptureUpdates() {
        guard captureUpdateTask == nil else { return }
        let updates = dependencies.capture.updates
        captureUpdateTask = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                await self.send(.captureUpdated(update))
            }
        }
    }
    private func handleCaptureUpdate(_ update: DictationCapture.Update) async {
        guard captureUpdateFence.acceptUpdate(
            generation: update.generation,
            sequence: update.sequence
        ) else {
            return
        }
        switch update.incident {
        case .expired:
            // Expiry owns the same cancellation path as an explicit disarm. In particular,
            // an upload that already started must not complete after its warm lease ended.
            await disarmWarmSession(expired: true)
        case let .cancelled(cancelledRequestID, _):
            guard requestID == cancelledRequestID else { break }
            guard await recordMailboxFailure(
                id: cancelledRequestID,
                message: "The Recording Session was cancelled."
            ) else { return }
            clearRequest()
            state.isRecording = false
            state.isBusy = false
            await refreshMailbox()
        case let .failed(failedRequestID, failure):
            let captureDisarmed: Bool
            if case .disarmed = update.state {
                captureDisarmed = true
            } else {
                captureDisarmed = false
            }
            if let failedRequestID, requestID == failedRequestID {
                cancelTranscriptionTask()
                guard await recordMailboxFailure(
                    id: failedRequestID,
                    message: failure.localizedDescription
                ) else { return }
                clearRequest()
                state.isRecording = false
                state.isBusy = false
            }

            if captureDisarmed {
                warmCommandTask?.cancel()
                warmCommandTask = nil
                activeWarmSessionID = nil
                state.isArmed = false
                if let sessionID = state.warmSessionRecord?.id {
                    guard await recordWarmSessionFailure(
                        id: sessionID,
                        message: failure.localizedDescription
                    ) else { return }
                }
            }
            state.status = failedRequestID == nil && requestID != nil && state.isBusy
                ? "Current Dictation is still processing. Re-arm before the next one."
                : failure.localizedDescription
            await refreshMailbox()

        case nil:
            break
        }
    }
}
