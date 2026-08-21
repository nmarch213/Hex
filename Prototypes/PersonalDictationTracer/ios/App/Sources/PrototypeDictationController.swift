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
    @Published private(set) var status = "Ready to record."
    @Published private(set) var mailboxRecord: PrototypeMailboxRecord?

    private let preferences = UserDefaults.standard
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var requestID: UUID?

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
        } else {
            Task { await startRecording() }
        }
    }

    func handleKeyboardLaunch(_ url: URL) {
        guard
            url.scheme == "hextracer",
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

    func refreshMailbox() {
        mailboxRecord = PrototypeMailbox.current()
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
            let id = PrototypeMailbox.beginCapture(id: requestedID)
            requestID = id
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("hex-\(id.uuidString).wav")
            recordingURL = fileURL
            try? FileManager.default.removeItem(at: fileURL)

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)

            let recorder = try AVAudioRecorder(
                url: fileURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                ]
            )
            guard recorder.prepareToRecord(), recorder.record() else {
                throw RecordingError.couldNotStart
            }

            self.recorder = recorder
            isRecording = true
            status = "Recording English audio…"
            refreshMailbox()
        } catch {
            isBusy = false
            status = "Could not record: \(error.localizedDescription)"
            if let requestID {
                PrototypeMailbox.fail(id: requestID, message: error.localizedDescription)
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            if let recordingURL {
                try? FileManager.default.removeItem(at: recordingURL)
            }
            recordingURL = nil
            requestID = nil
            refreshMailbox()
        }
    }

    private func stopAndTranscribe() {
        guard
            let recorder,
            let recordingURL,
            let requestID
        else {
            status = "No active recording."
            return
        }

        recorder.stop()
        self.recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let recordingStoppedAt = Date()
        PrototypeMailbox.markProcessing(id: requestID, recordingStoppedAt: recordingStoppedAt)
        refreshMailbox()
        status = "Uploading to Ronin…"

        Task {
            defer {
                try? FileManager.default.removeItem(at: recordingURL)
                self.recordingURL = nil
                self.requestID = nil
                isBusy = false
            }

            do {
                let response = try await PrototypeRoninClient.transcribe(
                    recordingURL: recordingURL,
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
                status = "Transcript ready. Switch to the Hex Prototype keyboard to insert it."
            } catch {
                PrototypeMailbox.fail(id: requestID, message: error.localizedDescription)
                status = "Transcription failed: \(error.localizedDescription)"
            }
            refreshMailbox()
        }
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
        case emptyTranscript
        case emptyFinalTranscript

        var errorDescription: String? {
            switch self {
            case .couldNotStart:
                "The audio recorder could not start."
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
