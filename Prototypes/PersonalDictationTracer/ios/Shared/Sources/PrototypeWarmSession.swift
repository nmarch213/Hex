import Foundation

struct PrototypeWarmSessionRecord: Codable, Equatable, Sendable {
    private static let heartbeatTolerance: TimeInterval = 3

    enum State: String, Codable, Sendable {
        case armed
        case unavailable
    }

    var id: UUID
    var state: State
    var armedAt: Date
    var heartbeatAt: Date
    var expiresAt: Date
    var errorMessage: String?

    func isReady(at date: Date = Date()) -> Bool {
        state == .armed
            && heartbeatAt.timeIntervalSince(date) > -Self.heartbeatTolerance
            && expiresAt > date
    }
}

@MainActor
enum PrototypeWarmSession {
    static let duration: TimeInterval = 15 * 60

    private static let recordKey = "prototype.warm-session"

    static func current() -> PrototypeWarmSessionRecord? {
        guard let data = try? Data(contentsOf: recordURL) else {
            return nil
        }
        return try? JSONDecoder().decode(PrototypeWarmSessionRecord.self, from: data)
    }

    @discardableResult
    static func arm(at date: Date = Date()) -> PrototypeWarmSessionRecord {
        let record = PrototypeWarmSessionRecord(
            id: UUID(),
            state: .armed,
            armedAt: date,
            heartbeatAt: date,
            expiresAt: date.addingTimeInterval(duration),
            errorMessage: nil
        )
        save(record)
        return record
    }

    static func heartbeat(id: UUID, at date: Date = Date()) {
        update(id: id) { record in
            guard record.state == .armed else { return }
            record.heartbeatAt = date
        }
    }

    static func extend(id: UUID, at date: Date = Date()) {
        update(id: id) { record in
            guard record.state == .armed else { return }
            record.heartbeatAt = date
            record.expiresAt = date.addingTimeInterval(duration)
        }
    }

    static func fail(id: UUID, message: String, at date: Date = Date()) {
        update(id: id) { record in
            record.state = .unavailable
            record.heartbeatAt = date
            record.errorMessage = message
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: recordURL)
    }

    private static let recordURL: URL = {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrototypeMailbox.appGroupID
        ) else {
            preconditionFailure(
                "Unable to open prototype App Group container \(PrototypeMailbox.appGroupID)"
            )
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

    private static func update(
        id: UUID,
        mutation: (inout PrototypeWarmSessionRecord) -> Void
    ) {
        guard var record = current(), record.id == id else {
            return
        }
        mutation(&record)
        save(record)
    }

    @discardableResult
    private static func save(_ record: PrototypeWarmSessionRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        guard (try? data.write(to: recordURL, options: .atomic)) != nil else {
            return false
        }
        return current() == record
    }
}
