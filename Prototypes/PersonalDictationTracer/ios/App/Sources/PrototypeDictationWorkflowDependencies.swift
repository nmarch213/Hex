import Foundation

struct PrototypeCaptureClient: Sendable {
    var updates: AsyncStream<DictationCapture.Update>
    var arm: @Sendable (_ generation: UUID) async throws -> UInt64
    var begin: @Sendable (_ requestID: UUID) async throws -> Void
    var currentState: @Sendable () async -> DictationCapture.State
    var finish: @Sendable (_ requestID: UUID) async throws -> DictationCapture.CapturedAudio
    var cancelIfActive: @Sendable (_ requestID: UUID) async throws -> Bool
    var disarm: @Sendable () async -> Void
    var removeCapturedAudio: @Sendable (_ fileURL: URL) async throws -> Void
}

extension PrototypeCaptureClient {
    static func live(capture: DictationCapture = DictationCapture()) -> Self {
        Self(
            updates: capture.updates,
            arm: { generation in
                try await capture.arm(generation: generation)
            },
            begin: { requestID in
                try await capture.begin(requestID: requestID)
            },
            currentState: {
                await capture.currentState()
            },
            finish: { requestID in
                try await capture.finish(requestID: requestID)
            },
            cancelIfActive: { requestID in
                try await capture.cancelIfActive(requestID: requestID)
            },
            disarm: {
                await capture.disarm()
            },
            removeCapturedAudio: { fileURL in
                try await capture.removeCapturedAudio(at: fileURL)
            }
        )
    }
}

struct PrototypeIPCClient: Sendable {
    var reconcileHostRelaunch: @Sendable () async throws(PrototypeIPCError)
        -> PrototypeIPCSnapshot
    var snapshot: @Sendable () async throws(PrototypeIPCError) -> PrototypeIPCSnapshot
    var currentMailbox: @Sendable () async throws(PrototypeIPCError)
        -> PrototypeMailboxRecord?
    var currentWarmSession: @Sendable () async throws(PrototypeIPCError)
        -> PrototypeWarmSessionRecord?
    var armWarmSession: @Sendable (_ date: Date) async throws(PrototypeIPCError)
        -> PrototypeWarmSessionRecord
    var heartbeatWarmSession: @Sendable (_ id: UUID, _ date: Date) async throws(PrototypeIPCError)
        -> Void
    var extendWarmSession: @Sendable (_ id: UUID, _ date: Date) async throws(PrototypeIPCError)
        -> Void
    var extendWarmSessionIfReady: @Sendable (_ id: UUID, _ date: Date)
        async throws(PrototypeIPCError) -> PrototypeWarmSessionRecord?
    var failWarmSession: @Sendable (_ id: UUID, _ message: String)
        async throws(PrototypeIPCError) -> Void
    var clearWarmSession: @Sendable () async throws(PrototypeIPCError) -> Void
    var beginCapture: @Sendable (_ id: UUID) async throws(PrototypeIPCError) -> UUID
    var requestStop: @Sendable (_ id: UUID) async throws(PrototypeIPCError) -> Void
    var failActiveCaptureIfKeyboardHeartbeatStale: @Sendable (
        _ id: UUID,
        _ date: Date,
        _ message: String
    ) async throws(PrototypeIPCError) -> Bool
    var markProcessing: @Sendable (_ id: UUID, _ recordingStoppedAt: Date)
        async throws(PrototypeIPCError) -> Void
    var complete: @Sendable (
        _ id: UUID,
        _ transcript: String,
        _ roundTripMilliseconds: Int,
        _ upstreamMilliseconds: Int?,
        _ serviceMilliseconds: Int
    ) async throws(PrototypeIPCError) -> Void
    var failMailbox: @Sendable (_ id: UUID, _ message: String)
        async throws(PrototypeIPCError) -> Void
    var clearMailbox: @Sendable () async throws(PrototypeIPCError) -> Void
    var seedCompleted: @Sendable (_ transcript: String) async throws(PrototypeIPCError) -> Void
}

extension PrototypeIPCClient {
    private static let worker = PrototypeIPCWorker()

    static let live = Self(
        reconcileHostRelaunch: { () async throws(PrototypeIPCError) -> PrototypeIPCSnapshot in
            try await worker.reconcileHostRelaunch()
        },
        snapshot: { () async throws(PrototypeIPCError) -> PrototypeIPCSnapshot in
            try await worker.snapshot()
        },
        currentMailbox: { () async throws(PrototypeIPCError) -> PrototypeMailboxRecord? in
            try await worker.currentMailbox()
        },
        currentWarmSession: { () async throws(PrototypeIPCError) -> PrototypeWarmSessionRecord? in
            try await worker.currentWarmSession()
        },
        armWarmSession: { (date: Date) async throws(PrototypeIPCError) -> PrototypeWarmSessionRecord in
            try await worker.armWarmSession(at: date)
        },
        heartbeatWarmSession: { (id: UUID, date: Date) async throws(PrototypeIPCError) in
            try await worker.heartbeatWarmSession(id: id, at: date)
        },
        extendWarmSession: { (id: UUID, date: Date) async throws(PrototypeIPCError) in
            try await worker.extendWarmSession(id: id, at: date)
        },
        extendWarmSessionIfReady: {
            (id: UUID, date: Date) async throws(PrototypeIPCError)
                -> PrototypeWarmSessionRecord? in
            try await worker.extendWarmSessionIfReady(id: id, at: date)
        },
        failWarmSession: {
            (id: UUID, message: String) async throws(PrototypeIPCError) in
            try await worker.failWarmSession(id: id, message: message)
        },
        clearWarmSession: { () async throws(PrototypeIPCError) in
            try await worker.clearWarmSession()
        },
        beginCapture: { (id: UUID) async throws(PrototypeIPCError) -> UUID in
            try await worker.beginCapture(id: id)
        },
        requestStop: { (id: UUID) async throws(PrototypeIPCError) in
            try await worker.requestStop(id: id)
        },
        failActiveCaptureIfKeyboardHeartbeatStale: {
            (id: UUID, date: Date, message: String) async throws(PrototypeIPCError) -> Bool in
            try await worker.failActiveCaptureIfKeyboardHeartbeatStale(
                id: id,
                at: date,
                message: message
            )
        },
        markProcessing: {
            (id: UUID, recordingStoppedAt: Date) async throws(PrototypeIPCError) in
            try await worker.markProcessing(
                id: id,
                recordingStoppedAt: recordingStoppedAt
            )
        },
        complete: { (
            id: UUID,
            transcript: String,
            roundTripMilliseconds: Int,
            upstreamMilliseconds: Int?,
            serviceMilliseconds: Int
        ) async throws(PrototypeIPCError) in
            try await worker.complete(
                id: id,
                transcript: transcript,
                roundTripMilliseconds: roundTripMilliseconds,
                upstreamMilliseconds: upstreamMilliseconds,
                serviceMilliseconds: serviceMilliseconds
            )
        },
        failMailbox: { (id: UUID, message: String) async throws(PrototypeIPCError) in
            try await worker.failMailbox(id: id, message: message)
        },
        clearMailbox: { () async throws(PrototypeIPCError) in
            try await worker.clearMailbox()
        },
        seedCompleted: { (transcript: String) async throws(PrototypeIPCError) in
            try await worker.seedCompleted(transcript: transcript)
        }
    )
}

/// Serializes synchronous App Group filesystem work away from the main actor.
private actor PrototypeIPCWorker {
    func reconcileHostRelaunch() throws(PrototypeIPCError) -> PrototypeIPCSnapshot {
        try PrototypeMailbox.reconcileHostRelaunch()
    }

    func snapshot() throws(PrototypeIPCError) -> PrototypeIPCSnapshot {
        try PrototypeMailbox.snapshot()
    }

    func currentMailbox() throws(PrototypeIPCError) -> PrototypeMailboxRecord? {
        try PrototypeMailbox.current()
    }

    func currentWarmSession() throws(PrototypeIPCError) -> PrototypeWarmSessionRecord? {
        try PrototypeWarmSession.current()
    }

    func armWarmSession(
        at date: Date
    ) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord {
        try PrototypeWarmSession.arm(at: date)
    }

    func heartbeatWarmSession(id: UUID, at date: Date) throws(PrototypeIPCError) {
        try PrototypeWarmSession.heartbeat(id: id, at: date)
    }

    func extendWarmSession(id: UUID, at date: Date) throws(PrototypeIPCError) {
        try PrototypeWarmSession.extend(id: id, at: date)
    }

    func extendWarmSessionIfReady(
        id: UUID,
        at date: Date
    ) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord? {
        try PrototypeWarmSession.extendIfReady(id: id, at: date)
    }

    func failWarmSession(id: UUID, message: String) throws(PrototypeIPCError) {
        try PrototypeWarmSession.fail(id: id, message: message)
    }

    func clearWarmSession() throws(PrototypeIPCError) {
        try PrototypeWarmSession.clear()
    }

    func beginCapture(id: UUID) throws(PrototypeIPCError) -> UUID {
        try PrototypeMailbox.beginCapture(id: id)
    }

    func requestStop(id: UUID) throws(PrototypeIPCError) {
        try PrototypeMailbox.requestStop(id: id)
    }

    func failActiveCaptureIfKeyboardHeartbeatStale(
        id: UUID,
        at date: Date,
        message: String
    ) throws(PrototypeIPCError) -> Bool {
        try PrototypeMailbox.failActiveCaptureIfKeyboardHeartbeatStale(
            id: id,
            at: date,
            message: message
        )
    }

    func markProcessing(
        id: UUID,
        recordingStoppedAt: Date
    ) throws(PrototypeIPCError) {
        try PrototypeMailbox.markProcessing(
            id: id,
            recordingStoppedAt: recordingStoppedAt
        )
    }

    func complete(
        id: UUID,
        transcript: String,
        roundTripMilliseconds: Int,
        upstreamMilliseconds: Int?,
        serviceMilliseconds: Int
    ) throws(PrototypeIPCError) {
        try PrototypeMailbox.complete(
            id: id,
            transcript: transcript,
            roundTripMilliseconds: roundTripMilliseconds,
            upstreamMilliseconds: upstreamMilliseconds,
            serviceMilliseconds: serviceMilliseconds
        )
    }

    func failMailbox(id: UUID, message: String) throws(PrototypeIPCError) {
        try PrototypeMailbox.fail(id: id, message: message)
    }

    func clearMailbox() throws(PrototypeIPCError) {
        try PrototypeMailbox.clear()
    }

    func seedCompleted(transcript: String) throws(PrototypeIPCError) {
        try PrototypeMailbox.seedCompleted(transcript: transcript)
    }
}

struct PrototypeRoninClientDependency: Sendable {
    var verifyReady: @Sendable (_ serverURLString: String, _ token: String) async throws -> Void
    var transcribe: @Sendable (
        _ recordingURL: URL,
        _ serverURLString: String,
        _ token: String,
        _ requestID: UUID
    ) async throws -> PrototypeRoninResponse
}

extension PrototypeRoninClientDependency {
    static let live = Self(
        verifyReady: { serverURLString, token in
            try await PrototypeRoninClient.verifyReady(
                serverURLString: serverURLString,
                token: token
            )
        },
        transcribe: { recordingURL, serverURLString, token, requestID in
            try await PrototypeRoninClient.transcribe(
                recordingURL: recordingURL,
                serverURLString: serverURLString,
                token: token,
                requestID: requestID
            )
        }
    )
}

struct PrototypeCredentialClient {
    var loadAndMigrateLegacyToken: @Sendable () async throws -> String?
    var saveToken: @Sendable (_ token: String) async throws -> Void
}

extension PrototypeCredentialClient {
    static let live = Self(
        loadAndMigrateLegacyToken: {
            try await offMain {
                let preferences = UserDefaults.standard
                let legacyToken = preferences.string(
                    forKey: PrototypeDictationPreferencesClient.legacyServerTokenKey
                ) ?? ""
                return try PrototypeCredentialStore.loadAndMigrateLegacyToken(
                    legacyToken: legacyToken,
                    removeLegacyToken: {
                        preferences.removeObject(
                            forKey: PrototypeDictationPreferencesClient.legacyServerTokenKey
                        )
                    }
                )
            }
        },
        saveToken: { token in
            try await offMain {
                let preferences = UserDefaults.standard
                try PrototypeCredentialStore.saveToken(token)
                preferences.removeObject(
                    forKey: PrototypeDictationPreferencesClient.legacyServerTokenKey
                )
            }
        }
    )

    private static func offMain<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: .utility, operation: operation).value
    }
}

struct PrototypeDictationPreferences: Equatable, Sendable {
    var removeFillerWords = true
    var spokenPunctuation = true
    var lowercase = false
    var removePunctuation = false
}

struct PrototypeDictationPreferencesClient {
    static let legacyServerTokenKey = "prototype.server-token"

    var load: @MainActor @Sendable () -> PrototypeDictationPreferences
    var save: @MainActor @Sendable (_ preferences: PrototypeDictationPreferences) -> Void
}

extension PrototypeDictationPreferencesClient {
    @MainActor
    static func live(preferences: UserDefaults = .standard) -> Self {
        Self(
            load: {
                PrototypeDictationPreferences(
                    removeFillerWords: storedBool(
                        in: preferences,
                        forKey: Keys.removeFillerWords,
                        default: true
                    ),
                    spokenPunctuation: storedBool(
                        in: preferences,
                        forKey: Keys.spokenPunctuation,
                        default: true
                    ),
                    lowercase: storedBool(
                        in: preferences,
                        forKey: Keys.lowercase,
                        default: false
                    ),
                    removePunctuation: storedBool(
                        in: preferences,
                        forKey: Keys.removePunctuation,
                        default: false
                    )
                )
            },
            save: { values in
                preferences.set(values.removeFillerWords, forKey: Keys.removeFillerWords)
                preferences.set(values.spokenPunctuation, forKey: Keys.spokenPunctuation)
                preferences.set(values.lowercase, forKey: Keys.lowercase)
                preferences.set(values.removePunctuation, forKey: Keys.removePunctuation)
            }
        )
    }

    private static func storedBool(
        in preferences: UserDefaults,
        forKey key: String,
        default defaultValue: Bool
    ) -> Bool {
        guard preferences.object(forKey: key) != nil else {
            return defaultValue
        }
        return preferences.bool(forKey: key)
    }

    private enum Keys {
        static let removeFillerWords = "prototype.remove-filler-words"
        static let spokenPunctuation = "prototype.spoken-punctuation"
        static let lowercase = "prototype.lowercase"
        static let removePunctuation = "prototype.remove-punctuation"
    }
}

struct PrototypeWorkflowClock: Sendable {
    var now: @Sendable () -> Date
    var sleep: @Sendable (_ duration: Duration) async throws -> Void
}

extension PrototypeWorkflowClock {
    static let live = Self(
        now: Date.init,
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )
}

struct PrototypeDictationWorkflowDependencies {
    var capture: PrototypeCaptureClient
    var ipc: PrototypeIPCClient
    var ronin: PrototypeRoninClientDependency
    var credentials: PrototypeCredentialClient
    var preferences: PrototypeDictationPreferencesClient
    var clock: PrototypeWorkflowClock
    var uuid: @Sendable () -> UUID
}

extension PrototypeDictationWorkflowDependencies {
    @MainActor
    static func live() -> Self {
        let preferences = UserDefaults.standard
        return Self(
            capture: .live(),
            ipc: .live,
            ronin: .live,
            credentials: .live,
            preferences: .live(preferences: preferences),
            clock: .live,
            uuid: UUID.init
        )
    }
}
