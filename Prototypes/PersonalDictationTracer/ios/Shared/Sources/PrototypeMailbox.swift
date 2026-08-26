import Darwin
import Foundation

enum PrototypeIPCFile: String, Equatable, Sendable {
    case mailboxRecord
    case stopRequest
    case warmSession
    case lock

    var filename: String {
        switch self {
        case .mailboxRecord:
            "prototype.final-transcript.json"
        case .stopRequest:
            "prototype.stop-request.json"
        case .warmSession:
            "prototype.warm-session.json"
        case .lock:
            "prototype.ipc.lock"
        }
    }

    fileprivate var maximumJSONBytes: Int {
        switch self {
        case .mailboxRecord:
            256 * 1_024
        case .stopRequest, .warmSession:
            16 * 1_024
        case .lock:
            0
        }
    }
}

enum PrototypeIPCError: Error, Equatable, LocalizedError, Sendable {
    case containerUnavailable
    case ioFailure(operation: String, file: PrototypeIPCFile, code: Int)
    case encodingFailed(PrototypeIPCFile)
    case payloadTooLarge(file: PrototypeIPCFile, maximumBytes: Int, actualBytes: Int)
    case corruptedFile(PrototypeIPCFile)
    case missingMailboxRecord(UUID)
    case missingWarmSessionRecord(UUID)
    case staleMailboxRecord(expected: UUID, actual: UUID)
    case staleWarmSessionRecord(expected: UUID, actual: UUID)
    case unsupportedSchema(file: PrototypeIPCFile, found: Int, supported: Int)
    case warmSessionNotReady(UUID)
    case keyboardPresenceExpired(UUID)
    case illegalMailboxTransition(
        id: UUID,
        from: PrototypeMailboxRecord.State,
        to: PrototypeMailboxRecord.State
    )
    case illegalWarmSessionTransition(
        id: UUID,
        from: PrototypeWarmSessionRecord.State,
        to: PrototypeWarmSessionRecord.State
    )
    case nonMonotonicWarmSessionTime(UUID)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            "Unable to open the prototype App Group container."
        case let .ioFailure(operation, file, code):
            "IPC \(operation) failed for \(file.rawValue) (code \(code))."
        case let .encodingFailed(file):
            "IPC encoding failed for \(file.rawValue)."
        case let .payloadTooLarge(file, maximumBytes, actualBytes):
            "IPC payload for \(file.rawValue) is \(actualBytes) bytes; the limit is \(maximumBytes) bytes."
        case let .corruptedFile(file):
            "Persisted IPC state is corrupt for \(file.rawValue)."
        case let .missingMailboxRecord(id):
            "Mailbox record \(id) is missing."
        case let .missingWarmSessionRecord(id):
            "Warm session \(id) is missing."
        case let .staleMailboxRecord(expected, actual):
            "Mailbox command targets \(expected), but \(actual) is current."
        case let .staleWarmSessionRecord(expected, actual):
            "Warm-session command targets \(expected), but \(actual) is current."
        case let .unsupportedSchema(file, found, supported):
            "Persisted \(file.rawValue) schema \(found) is newer than supported schema \(supported)."
        case let .warmSessionNotReady(id):
            "Warm session \(id) is no longer ready."
        case let .keyboardPresenceExpired(id):
            "Keyboard presence expired for mailbox \(id)."
        case let .illegalMailboxTransition(id, from, to):
            "Mailbox \(id) cannot transition from \(from.rawValue) to \(to.rawValue)."
        case let .illegalWarmSessionTransition(id, from, to):
            "Warm session \(id) cannot transition from \(from.rawValue) to \(to.rawValue)."
        case let .nonMonotonicWarmSessionTime(id):
            "Warm session \(id) received a heartbeat older than its current heartbeat."
        }
    }
}

enum PrototypeIPCStore {
    static let appGroupID = "group.com.nmarch213.HexKeyboardTracer"

    private static let smokeDirectoryEnvironmentKey = "HEX_IPC_SMOKE_DIRECTORY"

    static func withExclusiveLock<Result>(
        _ operation: (URL) throws(PrototypeIPCError) -> Result
    ) throws(PrototypeIPCError) -> Result {
        let directory = try containerDirectory()
        let lockURL = directory.appendingPathComponent(PrototypeIPCFile.lock.filename)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw .ioFailure(operation: "open lock", file: .lock, code: Int(errno))
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw .ioFailure(
                    operation: "acquire lock",
                    file: .lock,
                    code: Int(errno)
                )
            }
        }
        return try operation(directory)
    }

    static func read<Value: Decodable>(
        _ type: Value.Type,
        file: PrototypeIPCFile,
        in directory: URL
    ) throws(PrototypeIPCError) -> Value? {
        guard let data = try boundedData(file, in: directory) else {
            return nil
        }
        return try decode(type, from: data, file: file)
    }

    static func boundedData(
        _ file: PrototypeIPCFile,
        in directory: URL
    ) throws(PrototypeIPCError) -> Data? {
        let url = directory.appendingPathComponent(file.filename)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw .ioFailure(
                operation: "open bounded read",
                file: file,
                code: Int(errno)
            )
        }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw .ioFailure(
                operation: "inspect bounded read",
                file: file,
                code: Int(errno)
            )
        }
        let maximumBytes = file.maximumJSONBytes
        guard
            (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_size >= 0,
            metadata.st_size <= maximumBytes
        else {
            throw .corruptedFile(file)
        }

        let expectedBytes = Int(metadata.st_size)
        var data = Data(count: expectedBytes)
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard expectedBytes > 0, let baseAddress = buffer.baseAddress else {
                return 0
            }
            var total = 0
            while total < expectedBytes {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: total),
                    expectedBytes - total
                )
                if count > 0 {
                    total += count
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    return -Int(errno)
                }
            }
            return total
        }
        guard bytesRead == expectedBytes else {
            let code = bytesRead < 0 ? -bytesRead : Int(EIO)
            throw .ioFailure(
                operation: "read bounded data",
                file: file,
                code: code
            )
        }
        return data
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        file: PrototypeIPCFile
    ) throws(PrototypeIPCError) -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .corruptedFile(file)
        }
    }

    /// Reads the tiny persistence envelope before decoding the full record so a
    /// downgrade reports version skew even when the newer payload added enum cases.
    static func schemaVersion(
        in data: Data,
        file: PrototypeIPCFile
    ) throws(PrototypeIPCError) -> Int? {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw PrototypeIPCError.corruptedFile(file)
            }
            guard let encodedVersion = object["schemaVersion"] else {
                return nil
            }
            guard let version = encodedVersion as? Int else {
                throw PrototypeIPCError.corruptedFile(file)
            }
            return version
        } catch let error as PrototypeIPCError {
            throw error
        } catch {
            throw .corruptedFile(file)
        }
    }

    static func write<Value: Encodable>(
        _ value: Value,
        file: PrototypeIPCFile,
        in directory: URL
    ) throws(PrototypeIPCError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw .encodingFailed(file)
        }
        try write(data, file: file, in: directory)
    }

    static func write(
        _ data: Data,
        file: PrototypeIPCFile,
        in directory: URL
    ) throws(PrototypeIPCError) {
        let maximumBytes = file.maximumJSONBytes
        guard data.count <= maximumBytes else {
            throw .payloadTooLarge(
                file: file,
                maximumBytes: maximumBytes,
                actualBytes: data.count
            )
        }
        let url = directory.appendingPathComponent(file.filename)
        do {
#if os(iOS)
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtection]
            )
#else
            try data.write(to: url, options: .atomic)
#endif
        } catch {
            throw .ioFailure(
                operation: "write",
                file: file,
                code: (error as NSError).code
            )
        }
#if os(iOS)
        var metadataURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        do {
            try metadataURL.setResourceValues(resourceValues)
        } catch {
            let metadataError = error as NSError
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw .ioFailure(
                    operation: "rollback_backup_exclusion",
                    file: file,
                    code: (error as NSError).code
                )
            }
            throw .ioFailure(
                operation: "exclude_from_backup",
                file: file,
                code: metadataError.code
            )
        }
#endif
    }

    static func remove(
        _ file: PrototypeIPCFile,
        in directory: URL
    ) throws(PrototypeIPCError) {
        let url = directory.appendingPathComponent(file.filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == NSFileNoSuchFileError {
                return
            }
            throw .ioFailure(
                operation: "remove",
                file: file,
                code: cocoaError.code
            )
        }
    }

    private static func containerDirectory() throws(PrototypeIPCError) -> URL {
#if os(macOS)
        if let smokeDirectory = ProcessInfo.processInfo.environment[
            smokeDirectoryEnvironmentKey
        ], !smokeDirectory.isEmpty {
            let directory = URL(fileURLWithPath: smokeDirectory, isDirectory: true)
            try createDirectory(directory)
            return directory
        }
#endif

        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw .containerUnavailable
        }
        try createDirectory(directory)
        return directory
    }

    private static func createDirectory(_ directory: URL) throws(PrototypeIPCError) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw .ioFailure(
                operation: "create container",
                file: .lock,
                code: (error as NSError).code
            )
        }
    }
}

struct PrototypeMailboxRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    enum State: String, Codable, Equatable, Sendable {
        case captureRequested
        case capturing
        case stopRequested
        case cancelRequested
        case processing
        case completed
        case consumed
        case failed
    }

    var schemaVersion: Int? = currentSchemaVersion
    var id: UUID
    var documentIdentifier: UUID?
    var createdAt: Date
    var keyboardHeartbeatAt: Date?
    var stopRequestedAt: Date?
    var state: State
    var transcript: String
    var roundTripMilliseconds: Int?
    var upstreamMilliseconds: Int?
    var serviceMilliseconds: Int?
    var recordingStoppedAt: Date?
    var completedAt: Date?
    var insertedAt: Date?
    var errorMessage: String?

    var stopToInsertionMilliseconds: Int? {
        guard let recordingStoppedAt, let insertedAt else { return nil }
        return Int(insertedAt.timeIntervalSince(recordingStoppedAt) * 1_000)
    }

    var returnToInsertionMilliseconds: Int? {
        guard let completedAt, let insertedAt else { return nil }
        return Int(insertedAt.timeIntervalSince(completedAt) * 1_000)
    }

    func hasRecentKeyboardHeartbeat(at date: Date = Date()) -> Bool {
        guard let keyboardHeartbeatAt else { return false }
        let age = date.timeIntervalSince(keyboardHeartbeatAt)
        return age >= -1 && age <= 2
    }
}

struct PrototypeInsertionPayload: Equatable, Sendable {
    var id: UUID
    var documentIdentifier: UUID?
    var transcript: String
}

enum PrototypeDestinationIdentityFence {
    static func permitsInsertion(
        expected: UUID?,
        beforeConsume: UUID?,
        afterConsume: UUID?
    ) -> Bool {
        guard let expected, let beforeConsume, let afterConsume else {
            return false
        }
        return expected == beforeConsume && beforeConsume == afterConsume
    }
}

struct PrototypeIPCSnapshot: Equatable, Sendable {
    var mailbox: PrototypeMailboxRecord?
    var warmSession: PrototypeWarmSessionRecord?
}

enum PrototypeMailbox {
    static let appGroupID = PrototypeIPCStore.appGroupID
    private static let keyboardHeartbeatWriteInterval: TimeInterval = 0.5
    private static let completedTranscriptLifetime: TimeInterval = 15 * 60

    private struct StopRequest: Codable {
        var id: UUID
        var requestedAt: Date
    }

    static func current() throws(PrototypeIPCError) -> PrototypeMailboxRecord? {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> PrototypeMailboxRecord? in
            try current(in: directory)
        }
    }

    static func snapshot() throws(PrototypeIPCError) -> PrototypeIPCSnapshot {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> PrototypeIPCSnapshot in
            let warmSession = try PrototypeWarmSession.current(in: directory)
            let mailbox = try current(in: directory)
            return PrototypeIPCSnapshot(mailbox: mailbox, warmSession: warmSession)
        }
    }

    /// Invalidates persisted ownership that cannot survive containing-app termination.
    ///
    /// A fresh controller has a fresh audio actor, so even a recent persisted heartbeat
    /// cannot prove that a live process still owns the microphone. Reconcile the mailbox
    /// and warm lease in one transaction before the keyboard can accept another command.
    static func reconcileHostRelaunch() throws(PrototypeIPCError) -> PrototypeIPCSnapshot {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> PrototypeIPCSnapshot in
            var mailbox = try current(in: directory)
            try PrototypeIPCStore.remove(.stopRequest, in: directory)
            try PrototypeIPCStore.remove(.warmSession, in: directory)
            if var activeMailbox = mailbox {
                switch activeMailbox.state {
                case .captureRequested, .capturing, .stopRequested,
                     .cancelRequested, .processing:
                    activeMailbox.state = .failed
                    activeMailbox.transcript = ""
                    activeMailbox.errorMessage =
                        "The previous Dictation was interrupted when Hex restarted."
                    try PrototypeIPCStore.write(
                        activeMailbox,
                        file: .mailboxRecord,
                        in: directory
                    )
                    mailbox = activeMailbox
                case .completed, .consumed, .failed:
                    break
                }
            }
            return PrototypeIPCSnapshot(mailbox: mailbox, warmSession: nil)
        }
    }

    /// Reads the keyboard's complete view of IPC state under one lock and fails
    /// an in-flight request when its owning warm session is no longer usable.
    static func keyboardSnapshot(
        documentIdentifier: UUID? = nil,
        at date: Date = Date()
    ) throws(PrototypeIPCError) -> PrototypeIPCSnapshot {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> PrototypeIPCSnapshot in
            let warmSession = try PrototypeWarmSession.current(in: directory)
            var mailbox = try current(in: directory, at: date)

            if warmSession?.isReady(at: date) != true,
               var activeMailbox = mailbox {
                switch activeMailbox.state {
                case .captureRequested, .capturing, .stopRequested,
                     .cancelRequested:
                    // The keyboard cannot cancel the app-owned audio actor
                    // directly. Persist a command the host must acknowledge
                    // if it resumes after its warm heartbeat went stale.
                    activeMailbox.state = .cancelRequested
                    activeMailbox.transcript = ""
                    activeMailbox.errorMessage =
                        "Hex is no longer armed. Use the Arm Hex shortcut."
                    try PrototypeIPCStore.remove(.stopRequest, in: directory)
                    try PrototypeIPCStore.write(
                        activeMailbox,
                        file: .mailboxRecord,
                        in: directory
                    )
                    mailbox = activeMailbox
                case .processing, .completed, .consumed, .failed:
                    break
                }
            }

            if warmSession?.isReady(at: date) == true,
               var activeMailbox = mailbox {
                switch activeMailbox.state {
                case .captureRequested, .capturing, .stopRequested:
                    if !isSameTextDestination(
                        activeMailbox.documentIdentifier,
                        documentIdentifier
                    ) {
                        try cancelForUnavailableTextDestination(
                            &activeMailbox,
                            in: directory
                        )
                        mailbox = activeMailbox
                    } else if activeMailbox.keyboardHeartbeatAt.map({
                        date.timeIntervalSince($0) >= keyboardHeartbeatWriteInterval
                    }) != false {
                        activeMailbox.keyboardHeartbeatAt = date
                        try PrototypeIPCStore.write(
                            activeMailbox,
                            file: .mailboxRecord,
                            in: directory
                        )
                        mailbox = activeMailbox
                    }
                case .cancelRequested, .processing,
                     .completed, .consumed, .failed:
                    break
                }
            }

            return PrototypeIPCSnapshot(
                mailbox: mailbox,
                warmSession: warmSession
            )
        }
    }

    @discardableResult
    static func requestCapture(
        documentIdentifier: UUID
    ) throws(PrototypeIPCError) -> UUID {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> UUID in
            if let existing = try current(in: directory),
               !canReplace(existing.state) {
                throw .illegalMailboxTransition(
                    id: existing.id,
                    from: existing.state,
                    to: .captureRequested
                )
            }

            let id = UUID()
            try PrototypeIPCStore.remove(.stopRequest, in: directory)
            try PrototypeIPCStore.write(
                emptyRecord(
                    id: id,
                    documentIdentifier: documentIdentifier,
                    state: .captureRequested
                ),
                file: .mailboxRecord,
                in: directory
            )
            return id
        }
    }

    @discardableResult
    static func beginCapture(
        id requestedID: UUID
    ) throws(PrototypeIPCError) -> UUID {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> UUID in
            var record = try requireRecord(id: requestedID, in: directory)
            switch record.state {
            case .captureRequested:
                record.state = .capturing
            case .stopRequested, .capturing:
                break
            case .cancelRequested, .processing, .completed, .consumed, .failed:
                throw .illegalMailboxTransition(
                    id: record.id,
                    from: record.state,
                    to: .capturing
                )
            }
            try PrototypeIPCStore.write(
                record,
                file: .mailboxRecord,
                in: directory
            )
            return record.id
        }
    }

    /// Writes a keyboard Stop only when the same concrete text destination still owns
    /// the request. A missing or changed destination wins a durable cancellation.
    @discardableResult
    static func requestKeyboardStop(
        id: UUID,
        documentIdentifier: UUID?
    ) throws(PrototypeIPCError) -> Bool {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Bool in
            var record = try requireRecord(id: id, in: directory)
            switch record.state {
            case .captureRequested, .capturing, .stopRequested:
                guard isSameTextDestination(
                    record.documentIdentifier,
                    documentIdentifier
                ) else {
                    try cancelForUnavailableTextDestination(&record, in: directory)
                    return false
                }
                if record.state != .stopRequested {
                    let request = StopRequest(id: id, requestedAt: Date())
                    try PrototypeIPCStore.write(
                        request,
                        file: .stopRequest,
                        in: directory
                    )
                }
                return true
            case .cancelRequested, .processing, .completed, .consumed, .failed:
                throw .illegalMailboxTransition(
                    id: record.id,
                    from: record.state,
                    to: .stopRequested
                )
            }
        }
    }

    static func requestStop(id: UUID) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            let record = try requireRecord(id: id, in: directory)
            switch record.state {
            case .captureRequested, .capturing:
                let requestedAt = Date()
                let request = StopRequest(id: id, requestedAt: requestedAt)
                // The sidecar is the authoritative stop intent. `current(in:at:)`
                // projects it into the mailbox under the same lock, so this
                // transition has one commit point instead of two fallible writes.
                try PrototypeIPCStore.write(
                    request,
                    file: .stopRequest,
                    in: directory
                )
            case .stopRequested:
                break
            case .cancelRequested, .processing, .completed, .consumed, .failed:
                throw .illegalMailboxTransition(
                    id: record.id,
                    from: record.state,
                    to: .stopRequested
                )
            }
        }
    }

    static func requestCancel(id: UUID) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            var record = try requireRecord(id: id, in: directory)
            switch record.state {
            case .captureRequested, .capturing, .stopRequested, .processing:
                record.state = .cancelRequested
                record.transcript = ""
                record.errorMessage = "Voice entry cancelled."
                try PrototypeIPCStore.remove(.stopRequest, in: directory)
                try PrototypeIPCStore.write(
                    record,
                    file: .mailboxRecord,
                    in: directory
                )
            case .cancelRequested:
                break
            case .completed, .consumed, .failed:
                try PrototypeIPCStore.remove(.stopRequest, in: directory)
                try PrototypeIPCStore.remove(.mailboxRecord, in: directory)
            }
        }
    }

    /// Atomically lets a stale keyboard heartbeat win cancellation only while
    /// the same request is still capturing. A delayed host poll must never
    /// cancel a request that has already advanced to processing.
    @discardableResult
    static func failActiveCaptureIfKeyboardHeartbeatStale(
        id: UUID,
        at date: Date = Date(),
        message: String
    ) throws(PrototypeIPCError) -> Bool {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Bool in
            guard var record = try current(in: directory),
                  record.id == id else {
                return false
            }
            switch record.state {
            case .captureRequested, .capturing, .stopRequested:
                if record.hasRecentKeyboardHeartbeat(at: date) {
                    return false
                }
                record.state = .failed
                record.transcript = ""
                record.errorMessage = message
                try PrototypeIPCStore.remove(.stopRequest, in: directory)
                try PrototypeIPCStore.write(
                    record,
                    file: .mailboxRecord,
                    in: directory
                )
                return true
            case .cancelRequested, .processing, .completed, .consumed, .failed:
                return false
            }
        }
    }

    static func markProcessing(
        id: UUID,
        recordingStoppedAt: Date = Date()
    ) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            var record = try requireRecord(id: id, in: directory)
            switch record.state {
            case .capturing, .stopRequested:
                record.state = .processing
                record.recordingStoppedAt = recordingStoppedAt
                try PrototypeIPCStore.remove(.stopRequest, in: directory)
                try PrototypeIPCStore.write(
                    record,
                    file: .mailboxRecord,
                    in: directory
                )
            case .processing:
                break
            case .captureRequested, .cancelRequested, .completed, .consumed, .failed:
                throw .illegalMailboxTransition(
                    id: record.id,
                    from: record.state,
                    to: .processing
                )
            }
        }
    }

    static func complete(
        id: UUID,
        transcript: String,
        roundTripMilliseconds: Int,
        upstreamMilliseconds: Int?,
        serviceMilliseconds: Int
    ) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            var record = try requireRecord(id: id, in: directory)
            guard record.state == .processing else {
                throw .illegalMailboxTransition(
                    id: record.id,
                    from: record.state,
                    to: .completed
                )
            }
            record.state = .completed
            record.transcript = transcript
            record.roundTripMilliseconds = roundTripMilliseconds
            record.upstreamMilliseconds = upstreamMilliseconds
            record.serviceMilliseconds = serviceMilliseconds
            record.completedAt = Date()
            record.errorMessage = nil
            try PrototypeIPCStore.remove(.stopRequest, in: directory)
            try PrototypeIPCStore.write(
                record,
                file: .mailboxRecord,
                in: directory
            )
        }
    }

    static func fail(id: UUID, message: String) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            var record = try requireRecord(id: id, in: directory)
            switch record.state {
            case .captureRequested, .capturing, .stopRequested,
                 .cancelRequested, .processing:
                record.state = .failed
                record.errorMessage = message
                try PrototypeIPCStore.remove(.stopRequest, in: directory)
                try PrototypeIPCStore.write(
                    record,
                    file: .mailboxRecord,
                    in: directory
                )
            case .failed:
                break
            case .completed, .consumed:
                throw .illegalMailboxTransition(
                    id: record.id,
                    from: record.state,
                    to: .failed
                )
            }
        }
    }

    static func seedCompleted(
        transcript: String,
        at date: Date = Date()
    ) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            if let existing = try current(in: directory),
               !canReplace(existing.state) {
                throw .illegalMailboxTransition(
                    id: existing.id,
                    from: existing.state,
                    to: .completed
                )
            }

            var record = emptyRecord(
                id: UUID(),
                documentIdentifier: nil,
                state: .completed
            )
            record.transcript = transcript
            record.roundTripMilliseconds = 0
            record.upstreamMilliseconds = 0
            record.serviceMilliseconds = 0
            record.recordingStoppedAt = date
            record.completedAt = date
            try PrototypeIPCStore.remove(.stopRequest, in: directory)
            try PrototypeIPCStore.write(
                record,
                file: .mailboxRecord,
                in: directory
            )
        }
    }

    static func consumeCompleted(
        id: UUID,
        documentIdentifier: UUID?
    ) throws(PrototypeIPCError) -> PrototypeInsertionPayload? {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> PrototypeInsertionPayload? in
            guard var record = try current(in: directory) else {
                return nil
            }
            guard record.id == id,
                  record.state == .completed,
                  isSameTextDestination(
                      record.documentIdentifier,
                      documentIdentifier
                  ) else {
                return nil
            }
            let payload = PrototypeInsertionPayload(
                id: record.id,
                documentIdentifier: record.documentIdentifier,
                transcript: record.transcript
            )
            record.state = .consumed
            record.transcript = ""
            try PrototypeIPCStore.write(
                record,
                file: .mailboxRecord,
                in: directory
            )
            return payload
        }
    }

    static func discardCompleted(id: UUID) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            var record = try requireRecord(id: id, in: directory)
            guard record.state == .completed else {
                throw .illegalMailboxTransition(
                    id: record.id,
                    from: record.state,
                    to: .failed
                )
            }
            record.state = .failed
            record.transcript = ""
            record.errorMessage = "The pending transcript was discarded."
            try PrototypeIPCStore.write(
                record,
                file: .mailboxRecord,
                in: directory
            )
        }
    }

    static func discardConsumed(id: UUID) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            var record = try requireRecord(id: id, in: directory)
            guard record.state == .consumed, record.insertedAt == nil else {
                throw .illegalMailboxTransition(
                    id: record.id,
                    from: record.state,
                    to: .failed
                )
            }
            record.state = .failed
            record.transcript = ""
            record.errorMessage = "The text destination changed before insertion. Dictate again."
            try PrototypeIPCStore.write(
                record,
                file: .mailboxRecord,
                in: directory
            )
        }
    }

    static func markInserted(id: UUID) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            var record = try requireRecord(id: id, in: directory)
            guard record.state == .consumed else {
                throw .illegalMailboxTransition(
                    id: record.id,
                    from: record.state,
                    to: .consumed
                )
            }
            guard record.insertedAt == nil else { return }
            record.insertedAt = Date()
            try PrototypeIPCStore.write(
                record,
                file: .mailboxRecord,
                in: directory
            )
        }
    }

    static func clear() throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            try PrototypeIPCStore.remove(.mailboxRecord, in: directory)
            try PrototypeIPCStore.remove(.stopRequest, in: directory)
        }
    }

    private static func current(
        in directory: URL,
        at date: Date = Date()
    ) throws(PrototypeIPCError) -> PrototypeMailboxRecord? {
        let mailboxData = try PrototypeIPCStore.boundedData(
            .mailboxRecord,
            in: directory
        )
        if let mailboxData,
           let schemaVersion = try PrototypeIPCStore.schemaVersion(
               in: mailboxData,
               file: .mailboxRecord
           ), schemaVersion != PrototypeMailboxRecord.currentSchemaVersion {
            throw .unsupportedSchema(
                file: .mailboxRecord,
                found: schemaVersion,
                supported: PrototypeMailboxRecord.currentSchemaVersion
            )
        }
        let stored: PrototypeMailboxRecord?
        if let mailboxData {
            stored = try PrototypeIPCStore.decode(
                PrototypeMailboxRecord.self,
                from: mailboxData,
                file: .mailboxRecord
            )
        } else {
            stored = nil
        }
        let stopRequest: StopRequest? = try PrototypeIPCStore.read(
            StopRequest.self,
            file: .stopRequest,
            in: directory
        )

        guard var record = stored else {
            if stopRequest != nil {
                try PrototypeIPCStore.remove(.stopRequest, in: directory)
            }
            return nil
        }
        if let schemaVersion = record.schemaVersion,
           schemaVersion != PrototypeMailboxRecord.currentSchemaVersion {
            throw .unsupportedSchema(
                file: .mailboxRecord,
                found: schemaVersion,
                supported: PrototypeMailboxRecord.currentSchemaVersion
            )
        }
        if record.schemaVersion == nil {
            record.schemaVersion = PrototypeMailboxRecord.currentSchemaVersion
            try PrototypeIPCStore.write(
                record,
                file: .mailboxRecord,
                in: directory
            )
        }
        if let stopRequest {
            if stopRequest.id == record.id,
               (record.state == .captureRequested || record.state == .capturing) {
                record.state = .stopRequested
                record.stopRequestedAt = record.stopRequestedAt ?? stopRequest.requestedAt
                try PrototypeIPCStore.write(
                    record,
                    file: .mailboxRecord,
                    in: directory
                )
            } else if stopRequest.id != record.id || !isCaptureActive(record.state) {
                try PrototypeIPCStore.remove(.stopRequest, in: directory)
            }
        }

        if record.state == .completed,
           let completedAt = record.completedAt,
           date >= completedAt.addingTimeInterval(completedTranscriptLifetime) {
            record.state = .failed
            record.transcript = ""
            record.errorMessage =
                "The pending transcript expired. Dictate it again when you are ready."
            try PrototypeIPCStore.write(
                record,
                file: .mailboxRecord,
                in: directory
            )
        }
        return record
    }

    private static func requireRecord(
        id: UUID,
        in directory: URL
    ) throws(PrototypeIPCError) -> PrototypeMailboxRecord {
        guard let record = try current(in: directory) else {
            throw .missingMailboxRecord(id)
        }
        guard record.id == id else {
            throw .staleMailboxRecord(expected: id, actual: record.id)
        }
        return record
    }

    private static func emptyRecord(
        id: UUID,
        documentIdentifier: UUID?,
        state: PrototypeMailboxRecord.State
    ) -> PrototypeMailboxRecord {
        let now = Date()
        return PrototypeMailboxRecord(
            id: id,
            documentIdentifier: documentIdentifier,
            createdAt: now,
            keyboardHeartbeatAt: state == .captureRequested ? now : nil,
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

    private static func canReplace(_ state: PrototypeMailboxRecord.State) -> Bool {
        state == .consumed || state == .failed
    }

    private static func isSameTextDestination(
        _ expected: UUID?,
        _ current: UUID?
    ) -> Bool {
        guard let expected, let current else { return false }
        return expected == current
    }

    private static func cancelForUnavailableTextDestination(
        _ record: inout PrototypeMailboxRecord,
        in directory: URL
    ) throws(PrototypeIPCError) {
        record.state = .cancelRequested
        record.transcript = ""
        record.errorMessage = "The original text destination is no longer active."
        try PrototypeIPCStore.remove(.stopRequest, in: directory)
        try PrototypeIPCStore.write(
            record,
            file: .mailboxRecord,
            in: directory
        )
    }

    private static func isCaptureActive(_ state: PrototypeMailboxRecord.State) -> Bool {
        switch state {
        case .captureRequested, .capturing, .stopRequested, .cancelRequested:
            true
        case .processing, .completed, .consumed, .failed:
            false
        }
    }
}

#if os(macOS)
enum PrototypeIPCSmokeSupport {
    static func overwrite(
        _ file: PrototypeIPCFile,
        with data: Data
    ) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            try PrototypeIPCStore.write(data, file: file, in: directory)
        }
    }

    static func data(
        _ file: PrototypeIPCFile
    ) throws(PrototypeIPCError) -> Data? {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Data? in
            return try PrototypeIPCStore.boundedData(file, in: directory)
        }
    }

    /// Deliberately bypasses the production write path so the smoke test can
    /// prove that a pre-existing oversized file is rejected on read.
    static func injectUnvalidatedFile(
        _ file: PrototypeIPCFile,
        with data: Data
    ) throws {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            let url = directory.appendingPathComponent(file.filename)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw PrototypeIPCError.ioFailure(
                    operation: "inject smoke fixture",
                    file: file,
                    code: (error as NSError).code
                )
            }
        }
    }
}
#endif
