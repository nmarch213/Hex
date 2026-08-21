import Foundation

struct PrototypeMailboxRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case captureRequested
        case capturing
        case stopRequested
        case processing
        case completed
        case consumed
        case failed
    }

    var id: UUID
    var documentIdentifier: UUID?
    var createdAt: Date
    var stopRequestedAt: Date?
    var state: State
    var rawTranscript: String
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
}

@MainActor
enum PrototypeMailbox {
    static let appGroupID = "group.com.nmarch213.HexKeyboardTracer"
    private static let recordKey = "prototype.final-transcript"
    private static let stopRequestKey = "prototype.stop-request"

    private struct StopRequest: Codable {
        var id: UUID
        var requestedAt: Date
    }

    static func current() -> PrototypeMailboxRecord? {
        guard var record = storedRecord() else { return nil }
        if let stopRequest = currentStopRequest(),
           stopRequest.id == record.id,
           record.state == .captureRequested || record.state == .capturing {
            record.state = .stopRequested
            record.stopRequestedAt = record.stopRequestedAt ?? stopRequest.requestedAt
        }
        return record
    }

    @discardableResult
    static func requestCapture(documentIdentifier: UUID? = nil) -> UUID {
        let id = UUID()
        save(
            PrototypeMailboxRecord(
                id: id,
                documentIdentifier: documentIdentifier,
                createdAt: Date(),
                stopRequestedAt: nil,
                state: .captureRequested,
                rawTranscript: "",
                transcript: "",
                roundTripMilliseconds: nil,
                upstreamMilliseconds: nil,
                serviceMilliseconds: nil,
                recordingStoppedAt: nil,
                completedAt: nil,
                insertedAt: nil,
                errorMessage: nil
            )
        )
        return id
    }

    @discardableResult
    static func beginCapture(id requestedID: UUID? = nil) -> UUID {
        let id = requestedID ?? UUID()
        let existingRecord = current().flatMap { $0.id == id ? $0 : nil }
        let createdAt = existingRecord?.createdAt ?? Date()
        save(
            PrototypeMailboxRecord(
                id: id,
                documentIdentifier: existingRecord?.documentIdentifier,
                createdAt: createdAt,
                stopRequestedAt: existingRecord?.stopRequestedAt,
                state: .capturing,
                rawTranscript: "",
                transcript: "",
                roundTripMilliseconds: nil,
                upstreamMilliseconds: nil,
                serviceMilliseconds: nil,
                recordingStoppedAt: nil,
                completedAt: nil,
                insertedAt: nil,
                errorMessage: nil
            )
        )
        return id
    }

    static func requestStop(id: UUID) {
        let requestedAt = Date()
        saveStopRequest(StopRequest(id: id, requestedAt: requestedAt))
        update(id: id) { record in
            guard record.state == .captureRequested || record.state == .capturing else {
                return
            }
            record.state = .stopRequested
            if record.stopRequestedAt == nil {
                record.stopRequestedAt = requestedAt
            }
        }
    }

    static func markProcessing(id: UUID, recordingStoppedAt: Date = Date()) {
        update(id: id) { record in
            record.state = .processing
            record.recordingStoppedAt = recordingStoppedAt
        }
    }

    static func complete(
        id: UUID,
        rawTranscript: String,
        transcript: String,
        roundTripMilliseconds: Int,
        upstreamMilliseconds: Int?,
        serviceMilliseconds: Int
    ) {
        update(id: id) { record in
            record.state = .completed
            record.rawTranscript = rawTranscript
            record.transcript = transcript
            record.roundTripMilliseconds = roundTripMilliseconds
            record.upstreamMilliseconds = upstreamMilliseconds
            record.serviceMilliseconds = serviceMilliseconds
            record.completedAt = Date()
            record.errorMessage = nil
        }
    }

    static func fail(id: UUID, message: String) {
        update(id: id) { record in
            record.state = .failed
            record.errorMessage = message
        }
    }

    static func seedCompleted(transcript: String) {
        save(
            PrototypeMailboxRecord(
                id: UUID(),
                documentIdentifier: nil,
                createdAt: Date(),
                stopRequestedAt: nil,
                state: .completed,
                rawTranscript: transcript,
                transcript: transcript,
                roundTripMilliseconds: 0,
                upstreamMilliseconds: 0,
                serviceMilliseconds: 0,
                recordingStoppedAt: Date(),
                completedAt: Date(),
                insertedAt: nil,
                errorMessage: nil
            )
        )
    }

    static func consumeCompleted() -> PrototypeMailboxRecord? {
        guard var record = current(), record.state == .completed else {
            return nil
        }
        record.state = .consumed
        guard save(record) else { return nil }
        return record
    }

    static func markInserted(id: UUID) {
        update(id: id) { record in
            guard record.state == .consumed else { return }
            record.insertedAt = Date()
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: recordURL)
        try? FileManager.default.removeItem(at: stopRequestURL)
    }

    private static let recordURL: URL = {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            preconditionFailure("Unable to open prototype App Group container \(appGroupID)")
        }
        do {
            try FileManager.default.createDirectory(
                at: containerURL,
                withIntermediateDirectories: true
            )
        } catch {
            preconditionFailure("Unable to prepare prototype App Group container: \(error)")
        }
        return containerURL.appendingPathComponent("\(recordKey).json")
    }()

    private static let stopRequestURL = recordURL
        .deletingLastPathComponent()
        .appendingPathComponent("\(stopRequestKey).json")

    private static func storedRecord() -> PrototypeMailboxRecord? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(PrototypeMailboxRecord.self, from: data)
    }

    private static func currentStopRequest() -> StopRequest? {
        guard let data = try? Data(contentsOf: stopRequestURL) else { return nil }
        return try? JSONDecoder().decode(StopRequest.self, from: data)
    }

    private static func saveStopRequest(_ request: StopRequest) {
        guard let data = try? JSONEncoder().encode(request) else { return }
        try? data.write(to: stopRequestURL, options: .atomic)
    }

    private static func update(id: UUID, mutation: (inout PrototypeMailboxRecord) -> Void) {
        guard var record = current(), record.id == id else {
            return
        }
        mutation(&record)
        save(record)
    }

    @discardableResult
    private static func save(_ record: PrototypeMailboxRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        guard (try? data.write(to: recordURL, options: .atomic)) != nil else {
            return false
        }
        return storedRecord() == record
    }
}
