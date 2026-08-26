import Foundation

/// Keeps delayed capture updates from mutating a newer armed session.
struct DictationCaptureUpdateFence {
    private(set) var generation: UUID?
    private(set) var latestSequence: UInt64 = 0

    /// Establishes ownership before the actor hop so buffered updates from the
    /// previous arm cannot race the new arm response.
    mutating func beginArm(generation: UUID) {
        self.generation = generation
    }

    /// Records the update sequence published atomically by a successful arm.
    /// Returns false when a newer update already invalidated that arm response.
    mutating func synchronizeArm(
        generation: UUID,
        through sequence: UInt64
    ) -> Bool {
        guard self.generation == generation,
              sequence >= latestSequence else {
            return false
        }
        latestSequence = sequence
        return true
    }

    /// Accepts each actor update once and rejects buffered updates from older arms.
    mutating func acceptUpdate(generation: UUID, sequence: UInt64) -> Bool {
        guard self.generation == generation,
              sequence > latestSequence else {
            return false
        }
        latestSequence = sequence
        return true
    }
}
