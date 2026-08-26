import Foundation

struct PrototypeWarmSessionRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    private static let heartbeatTolerance: TimeInterval = 10

    enum State: String, Codable, Equatable, Sendable {
        case armed
        case unavailable
    }

    var schemaVersion: Int? = currentSchemaVersion
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

enum PrototypeWarmSession {
    static let duration: TimeInterval = 15 * 60

    private enum StaleDatePolicy {
        case ignore
        case clamp
    }

    static func current() throws(PrototypeIPCError) -> PrototypeWarmSessionRecord? {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord? in
            try current(in: directory)
        }
    }

    static func current(
        in directory: URL
    ) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord? {
        guard let data = try PrototypeIPCStore.boundedData(
            .warmSession,
            in: directory
        ) else {
            return nil
        }
        if let schemaVersion = try PrototypeIPCStore.schemaVersion(
            in: data,
            file: .warmSession
        ), schemaVersion != PrototypeWarmSessionRecord.currentSchemaVersion {
            throw .unsupportedSchema(
                file: .warmSession,
                found: schemaVersion,
                supported: PrototypeWarmSessionRecord.currentSchemaVersion
            )
        }
        var record: PrototypeWarmSessionRecord = try PrototypeIPCStore.decode(
            PrototypeWarmSessionRecord.self,
            from: data,
            file: .warmSession
        )
        if let schemaVersion = record.schemaVersion,
           schemaVersion != PrototypeWarmSessionRecord.currentSchemaVersion {
            throw .unsupportedSchema(
                file: .warmSession,
                found: schemaVersion,
                supported: PrototypeWarmSessionRecord.currentSchemaVersion
            )
        }
        if record.schemaVersion == nil {
            record.schemaVersion = PrototypeWarmSessionRecord.currentSchemaVersion
            try PrototypeIPCStore.write(
                record,
                file: .warmSession,
                in: directory
            )
        }
        return record
    }

    @discardableResult
    static func arm(
        at date: Date = Date()
    ) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord in
            let existing = try current(in: directory)
            if let existing, existing.isReady(at: date) {
                throw .illegalWarmSessionTransition(
                    id: existing.id,
                    from: existing.state,
                    to: .armed
                )
            }

            let record = PrototypeWarmSessionRecord(
                id: UUID(),
                state: .armed,
                armedAt: date,
                heartbeatAt: date,
                expiresAt: date.addingTimeInterval(duration),
                errorMessage: nil
            )
            try PrototypeIPCStore.write(
                record,
                file: .warmSession,
                in: directory
            )
            return record
        }
    }

    static func heartbeat(
        id: UUID,
        at date: Date = Date()
    ) throws(PrototypeIPCError) {
        try mutateArmed(id: id, at: date, staleDatePolicy: .ignore) {
            record, effectiveDate in
            record.heartbeatAt = effectiveDate
        }
    }

    static func extend(
        id: UUID,
        at date: Date = Date()
    ) throws(PrototypeIPCError) {
        try mutateArmed(id: id, at: date, staleDatePolicy: .clamp) {
            record, effectiveDate in
            record.heartbeatAt = effectiveDate
            record.expiresAt = effectiveDate.addingTimeInterval(duration)
        }
    }

    /// Renews only the same live lease. Expected expiry, disarm, and replacement
    /// races are normal no-ops after a Recording Session has already been sealed.
    @discardableResult
    static func extendIfReady(
        id: UUID,
        at date: Date = Date()
    ) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord? {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord? in
            guard var record = try current(in: directory),
                  record.id == id,
                  record.isReady(at: date) else {
                return nil
            }
            let effectiveDate = max(date, record.heartbeatAt)
            record.heartbeatAt = effectiveDate
            record.expiresAt = effectiveDate.addingTimeInterval(duration)
            try PrototypeIPCStore.write(
                record,
                file: .warmSession,
                in: directory
            )
            return record
        }
    }

    static func fail(
        id: UUID,
        message: String,
        at date: Date = Date()
    ) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            var record = try requireRecord(id: id, in: directory)
            switch record.state {
            case .armed:
                let effectiveDate = max(date, record.heartbeatAt)
                record.state = .unavailable
                record.heartbeatAt = effectiveDate
                record.errorMessage = message
                try PrototypeIPCStore.write(
                    record,
                    file: .warmSession,
                    in: directory
                )
            case .unavailable:
                break
            }
        }
    }

    static func clear() throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            try PrototypeIPCStore.remove(.warmSession, in: directory)
        }
    }

    private static func mutateArmed(
        id: UUID,
        at date: Date,
        staleDatePolicy: StaleDatePolicy,
        mutation: (inout PrototypeWarmSessionRecord, Date) -> Void
    ) throws(PrototypeIPCError) {
        try PrototypeIPCStore.withExclusiveLock {
            (directory: URL) throws(PrototypeIPCError) -> Void in
            var record = try requireRecord(id: id, in: directory)
            guard record.state == .armed else {
                throw .illegalWarmSessionTransition(
                    id: record.id,
                    from: record.state,
                    to: .armed
                )
            }
            let effectiveDate: Date
            if date >= record.heartbeatAt {
                effectiveDate = date
            } else {
                switch staleDatePolicy {
                case .ignore:
                    // A detached poll may arrive after a foreground extension. Treat
                    // that delayed heartbeat as an idempotent no-op.
                    return
                case .clamp:
                    // An extension can capture its wall time before waiting for the
                    // IPC lock. Preserve the operation while keeping persisted time
                    // monotonic if a newer heartbeat won the lock first.
                    effectiveDate = record.heartbeatAt
                }
            }
            mutation(&record, effectiveDate)
            try PrototypeIPCStore.write(
                record,
                file: .warmSession,
                in: directory
            )
        }
    }

    private static func requireRecord(
        id: UUID,
        in directory: URL
    ) throws(PrototypeIPCError) -> PrototypeWarmSessionRecord {
        let record = try current(in: directory)
        guard let record else {
            throw .missingWarmSessionRecord(id)
        }
        guard record.id == id else {
            throw .staleWarmSessionRecord(expected: id, actual: record.id)
        }
        return record
    }
}
