import AVFoundation
import Combine
import Foundation

@MainActor
final class PrototypeDictationController: NSObject, ObservableObject {
    let serverURLString = "https://ronin.tail451960.ts.net:8443"
    @Published var token: String {
        didSet { PrototypeCredentialStore.saveToken(token) }
    }
    @Published var removeFillerWords: Bool {
        didSet { preferences.set(removeFillerWords, forKey: Keys.removeFillerWords) }
    }
    @Published var spokenPunctuation: Bool {
        didSet { preferences.set(spokenPunctuation, forKey: Keys.spokenPunctuation) }
    }
    @Published var lowercase: Bool {
        didSet { preferences.set(lowercase, forKey: Keys.lowercase) }
    }
    @Published var removePunctuation: Bool {
        didSet { preferences.set(removePunctuation, forKey: Keys.removePunctuation) }
    }
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var isArmed = false
    @Published private(set) var status = "Ready to record."
    @Published private(set) var mailboxRecord: PrototypeMailboxRecord?
    @Published private(set) var warmSessionRecord: PrototypeWarmSessionRecord?

    private let preferences = UserDefaults.standard
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var requestID: UUID?
    private var warmRecorder: AVAudioRecorder?
    private var warmRecordingURL: URL?
    private var warmRecordingStartedAt: Date?
    private var captureRequestedAt: Date?
    private var captureUsesWarmRecorder = false
    private var warmCommandTask: Task<Void, Never>?
    private var lastHeartbeatAt = Date.distantPast

    override init() {
        let keychainToken = PrototypeCredentialStore.loadToken()
        let legacyToken = UserDefaults.standard.string(forKey: "prototype.server-token") ?? ""
        token = keychainToken.isEmpty ? legacyToken : keychainToken
        removeFillerWords = Self.storedBool(forKey: Keys.removeFillerWords, default: true)
        spokenPunctuation = Self.storedBool(forKey: Keys.spokenPunctuation, default: true)
        lowercase = Self.storedBool(forKey: Keys.lowercase, default: false)
        removePunctuation = Self.storedBool(forKey: Keys.removePunctuation, default: false)
        super.init()
        if keychainToken.isEmpty, !legacyToken.isEmpty {
            PrototypeCredentialStore.saveToken(legacyToken)
            UserDefaults.standard.removeObject(forKey: "prototype.server-token")
        }
    }

    func toggleRecording() {
        if isRecording {
            stopAndTranscribe()
        } else if isArmed {
            disarmWarmSession()
        } else {
            Task { await armWarmSession() }
        }
    }

    func handleKeyboardLaunch(_ url: URL) {
        guard url.scheme == "hextracer" else {
            status = "Ignored an invalid keyboard handoff URL."
            return
        }

        if url.host == "arm" {
            if isArmed {
                status = "Keyboard Dictation is already armed. Swipe back to keep typing."
            } else if isBusy {
                status = "Hex is already preparing keyboard Dictation."
            } else {
                status = "Opening from the keyboard. Arming automatically…"
                Task { await armWarmSession() }
            }
            return
        }

        guard
            url.host == "record",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let rawID = components.queryItems?.first(where: { $0.name == "id" })?.value,
            let requestedID = UUID(uuidString: rawID)
        else {
            status = "Ignored an invalid keyboard handoff URL."
            return
        }

        guard !isBusy else {
            PrototypeMailbox.fail(id: requestedID, message: "Hex is already recording or transcribing.")
            refreshMailbox()
            return
        }

        Task { await startRecording(requestedID: requestedID) }
    }

    func handleArmShortcut() {
        if isArmed {
            status = "Keyboard Dictation is already armed. Swipe back to keep typing."
        } else if isBusy {
            status = "Hex is already preparing keyboard Dictation."
        } else {
            status = "Opened from Arm Hex. Arming automatically…"
            Task { await armWarmSession() }
        }
    }

    func refreshMailbox() {
        mailboxRecord = PrototypeMailbox.current()
        warmSessionRecord = PrototypeWarmSession.current()
    }

    private func armWarmSession() async {
        guard !isBusy, !isArmed else { return }
        isBusy = true
        status = "Checking Ronin…"

        do {
            try await PrototypeRoninClient.verifyReady(
                serverURLString: serverURLString,
                token: token
            )
        } catch {
            isBusy = false
            status = "Could not arm: \(error.localizedDescription)"
            return
        }

        status = "Checking microphone permission…"

        guard await hasMicrophonePermission() else {
            isBusy = false
            status = "Microphone permission is required."
            return
        }

        abandonInterruptedRequestIfNeeded()
        let sessionRecord = PrototypeWarmSession.arm()
        do {
            try configureAudioSession()
            try startWarmRecorder(sessionID: sessionRecord.id)
            isArmed = true
            isBusy = false
            lastHeartbeatAt = Date()
            warmSessionRecord = PrototypeWarmSession.current()
            status = "Armed for 15 minutes. Swipe back, then tap Start Voice in the Hex keyboard."
            startWarmCommandLoop(sessionID: sessionRecord.id)
        } catch {
            isBusy = false
            PrototypeWarmSession.fail(id: sessionRecord.id, message: error.localizedDescription)
            warmSessionRecord = PrototypeWarmSession.current()
            status = "Could not arm keyboard Dictation: \(error.localizedDescription)"
            stopWarmRecorder()
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func abandonInterruptedRequestIfNeeded() {
        guard let record = PrototypeMailbox.current() else { return }
        switch record.state {
        case .captureRequested, .capturing, .stopRequested, .processing:
            PrototypeMailbox.fail(
                id: record.id,
                message: "The previous dictation was interrupted. Tap Start Voice to try again."
            )
            refreshMailbox()
        case .completed, .consumed, .failed:
            break
        }
    }

    private func disarmWarmSession(expired: Bool = false) {
        guard !isRecording else { return }
        warmCommandTask?.cancel()
        warmCommandTask = nil
        stopWarmRecorder()
        isArmed = false
        PrototypeWarmSession.clear()
        warmSessionRecord = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        status = expired
            ? "Keyboard Dictation expired. Arm it again when you are ready."
            : "Keyboard Dictation disarmed."
    }

    private func startWarmCommandLoop(sessionID: UUID) {
        warmCommandTask?.cancel()
        warmCommandTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollWarmCommands(sessionID: sessionID)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func pollWarmCommands(sessionID: UUID) async {
        guard isArmed else { return }

        let now = Date()
        if now.timeIntervalSince(lastHeartbeatAt) >= 1 {
            PrototypeWarmSession.heartbeat(id: sessionID, at: now)
            warmSessionRecord = PrototypeWarmSession.current()
            lastHeartbeatAt = now
        }

        if let session = PrototypeWarmSession.current(),
           session.id == sessionID,
           session.expiresAt <= now,
           !isBusy {
            disarmWarmSession(expired: true)
            return
        }

        guard let record = PrototypeMailbox.current() else { return }
        switch PrototypeWarmCaptureCommand.nextAction(
            for: record.state,
            isBusy: isBusy,
            isRecording: isRecording
        ) {
        case .start:
            await startRecording(requestedID: record.id)
        case .stop:
            stopAndTranscribe()
        case .startThenStop:
            await startRecording(requestedID: record.id)
            if isRecording {
                stopAndTranscribe()
            }
        case .none:
            break
        }
    }

    private func startRecording(requestedID: UUID? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        status = "Checking microphone permission…"

        guard await hasMicrophonePermission() else {
            isBusy = false
            status = "Microphone permission is required."
            if let requestedID {
                PrototypeMailbox.fail(id: requestedID, message: status)
                refreshMailbox()
            }
            return
        }

        do {
            if !(isArmed && warmRecorder?.isRecording == true) {
                try configureAudioSession()
            }

            let pendingRecord = requestedID.flatMap { requestedID in
                PrototypeMailbox.current().flatMap { record in
                    record.id == requestedID ? record : nil
                }
            }
            let shouldStopAfterStart = pendingRecord?.state == .stopRequested
            let id = PrototypeMailbox.beginCapture(id: requestedID)
            requestID = id
            captureRequestedAt = pendingRecord?.createdAt ?? Date()

            if isArmed {
                guard
                    warmRecorder?.isRecording == true,
                    warmRecordingURL != nil,
                    warmRecordingStartedAt != nil
                else {
                    throw RecordingError.couldNotStart
                }
                captureUsesWarmRecorder = true
                isRecording = true
                if shouldStopAfterStart {
                    PrototypeMailbox.requestStop(id: id)
                }
                if let sessionID = warmSessionRecord?.id {
                    PrototypeWarmSession.extend(id: sessionID)
                    warmSessionRecord = PrototypeWarmSession.current()
                }
                status = "Recording English audio…"
                refreshMailbox()
                return
            }

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("hex-\(id.uuidString).wav")
            recordingURL = fileURL
            try? FileManager.default.removeItem(at: fileURL)

            let recorder = try AVAudioRecorder(
                url: fileURL,
                settings: recordingSettings
            )
            guard recorder.prepareToRecord(), recorder.record() else {
                throw RecordingError.couldNotStart
            }

            self.recorder = recorder
            captureUsesWarmRecorder = false
            isRecording = true
            if shouldStopAfterStart {
                PrototypeMailbox.requestStop(id: id)
            }
            if let sessionID = warmSessionRecord?.id {
                PrototypeWarmSession.extend(id: sessionID)
                warmSessionRecord = PrototypeWarmSession.current()
            }
            status = "Recording English audio…"
            refreshMailbox()
        } catch {
            isBusy = false
            status = "Could not record: \(error.localizedDescription)"
            if let requestID {
                PrototypeMailbox.fail(id: requestID, message: error.localizedDescription)
            }
            if isArmed {
                restoreWarmRecorderOrDisarm()
            } else {
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
            if let recordingURL {
                try? FileManager.default.removeItem(at: recordingURL)
            }
            recordingURL = nil
            requestID = nil
            captureRequestedAt = nil
            captureUsesWarmRecorder = false
            refreshMailbox()
        }
    }

    private func stopAndTranscribe() {
        guard let requestID else {
            status = "No active recording."
            return
        }

        let mailboxRecord = PrototypeMailbox.current().flatMap { record in
            record.id == requestID ? record : nil
        }
        let recordingStoppedAt = mailboxRecord?.stopRequestedAt ?? Date()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-\(requestID.uuidString).wav")

        do {
            if captureUsesWarmRecorder {
                guard
                    let warmRecorder,
                    let warmRecordingURL,
                    let warmRecordingStartedAt,
                    let captureRequestedAt
                else {
                    throw RecordingError.couldNotStart
                }

                warmRecorder.stop()
                self.warmRecorder = nil
                self.warmRecordingURL = nil
                self.warmRecordingStartedAt = nil
                defer { try? FileManager.default.removeItem(at: warmRecordingURL) }
                try? FileManager.default.removeItem(at: outputURL)
                try extractWarmCapture(
                    from: warmRecordingURL,
                    warmStartedAt: warmRecordingStartedAt,
                    captureStartedAt: captureRequestedAt,
                    captureStoppedAt: recordingStoppedAt,
                    to: outputURL
                )
            } else {
                guard let recorder, let recordingURL else {
                    throw RecordingError.couldNotStart
                }
                recorder.stop()
                self.recorder = nil
                guard recordingURL == outputURL else {
                    throw RecordingError.couldNotPrepareAudio
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            self.recorder = nil
            self.recordingURL = nil
            isRecording = false
            isBusy = false
            captureRequestedAt = nil
            captureUsesWarmRecorder = false
            PrototypeMailbox.fail(id: requestID, message: error.localizedDescription)
            status = "Could not prepare dictation: \(error.localizedDescription)"
            if isArmed {
                stopWarmRecorder()
                restoreWarmRecorderOrDisarm()
            } else {
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
            refreshMailbox()
            return
        }

        recordingURL = outputURL
        isRecording = false
        PrototypeMailbox.markProcessing(id: requestID, recordingStoppedAt: recordingStoppedAt)
        refreshMailbox()
        status = "Uploading to Ronin…"

        if isArmed {
            restoreWarmRecorderOrDisarm()
        } else {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }

        Task {
            defer {
                try? FileManager.default.removeItem(at: outputURL)
                self.recordingURL = nil
                self.requestID = nil
                captureRequestedAt = nil
                captureUsesWarmRecorder = false
                isBusy = false
            }

            do {
                let response = try await PrototypeRoninClient.transcribe(
                    recordingURL: outputURL,
                    serverURLString: serverURLString,
                    token: token,
                    requestID: requestID
                )
                let rawTranscript = response.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawTranscript.isEmpty else {
                    throw RecordingError.emptyTranscript
                }
                let finalTranscript = PrototypeTranscriptPipeline.apply(
                    rawTranscript,
                    removeFillerWords: removeFillerWords,
                    spokenPunctuation: spokenPunctuation,
                    lowercase: lowercase,
                    removePunctuation: removePunctuation
                )
                guard !finalTranscript.isEmpty else {
                    throw RecordingError.emptyFinalTranscript
                }
                let elapsed = Int(Date().timeIntervalSince(recordingStoppedAt) * 1_000)
                PrototypeMailbox.complete(
                    id: requestID,
                    rawTranscript: rawTranscript,
                    transcript: finalTranscript,
                    roundTripMilliseconds: elapsed,
                    upstreamMilliseconds: response.timings.upstreamMS,
                    serviceMilliseconds: response.timings.totalMS
                )
                if let sessionID = warmSessionRecord?.id {
                    PrototypeWarmSession.extend(id: sessionID)
                    warmSessionRecord = PrototypeWarmSession.current()
                }
                status = isArmed
                    ? "Transcript ready. The Hex keyboard will insert it."
                    : "Transcript ready. Switch to the Hex Prototype keyboard to insert it."
            } catch {
                PrototypeMailbox.fail(id: requestID, message: error.localizedDescription)
                status = "Transcription failed: \(error.localizedDescription)"
            }
            refreshMailbox()
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true)
    }

    private func startWarmRecorder(sessionID: UUID) throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-warm-\(sessionID.uuidString).wav")
        try? FileManager.default.removeItem(at: fileURL)

        let recorder = try AVAudioRecorder(url: fileURL, settings: recordingSettings)
        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecordingError.couldNotStart
        }

        warmRecorder = recorder
        warmRecordingURL = fileURL
        warmRecordingStartedAt = Date()
    }

    private func stopWarmRecorder() {
        warmRecorder?.stop()
        warmRecorder = nil
        if let warmRecordingURL {
            try? FileManager.default.removeItem(at: warmRecordingURL)
        }
        warmRecordingURL = nil
        warmRecordingStartedAt = nil
    }

    private func extractWarmCapture(
        from sourceURL: URL,
        warmStartedAt: Date,
        captureStartedAt: Date,
        captureStoppedAt: Date,
        to outputURL: URL
    ) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        let sampleRate = source.processingFormat.sampleRate
        let startSeconds = max(0, captureStartedAt.timeIntervalSince(warmStartedAt))
        let stopSeconds = max(startSeconds, captureStoppedAt.timeIntervalSince(warmStartedAt))
        let startFrame = min(
            source.length,
            AVAudioFramePosition(startSeconds * sampleRate)
        )
        let stopFrame = min(
            source.length,
            AVAudioFramePosition(stopSeconds * sampleRate)
        )
        let frameCount = stopFrame - startFrame
        guard frameCount > 0, frameCount <= AVAudioFramePosition(UInt32.max) else {
            throw RecordingError.emptyRecording
        }

        source.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw RecordingError.couldNotPrepareAudio
        }
        try source.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
        guard buffer.frameLength > 0 else {
            throw RecordingError.emptyRecording
        }

        let output = try AVAudioFile(forWriting: outputURL, settings: recordingSettings)
        try output.write(from: buffer)
    }

    private func restoreWarmRecorderOrDisarm() {
        guard isArmed, let sessionID = warmSessionRecord?.id else { return }
        do {
            try startWarmRecorder(sessionID: sessionID)
            PrototypeWarmSession.extend(id: sessionID)
            warmSessionRecord = PrototypeWarmSession.current()
        } catch {
            PrototypeWarmSession.fail(id: sessionID, message: error.localizedDescription)
            warmSessionRecord = PrototypeWarmSession.current()
            warmCommandTask?.cancel()
            warmCommandTask = nil
            isArmed = false
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private var recordingSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    private func hasMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private static func storedBool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    private enum RecordingError: LocalizedError {
        case couldNotStart
        case couldNotPrepareAudio
        case emptyRecording
        case emptyTranscript
        case emptyFinalTranscript

        var errorDescription: String? {
            switch self {
            case .couldNotStart:
                "The audio recorder could not start."
            case .couldNotPrepareAudio:
                "Hex could not prepare the recorded audio."
            case .emptyRecording:
                "No speech was captured. Tap Start Voice before speaking."
            case .emptyTranscript:
                "Parakeet returned an empty transcript."
            case .emptyFinalTranscript:
                "Hex transcript transforms removed the entire transcript."
            }
        }
    }

    private enum Keys {
        static let removeFillerWords = "prototype.remove-filler-words"
        static let spokenPunctuation = "prototype.spoken-punctuation"
        static let lowercase = "prototype.lowercase"
        static let removePunctuation = "prototype.remove-punctuation"
    }
}
