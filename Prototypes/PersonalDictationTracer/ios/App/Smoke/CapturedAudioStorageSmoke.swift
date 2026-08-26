import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("CapturedAudioStorage smoke failure: \(message)\n", stderr)
        exit(1)
    }
}

private final class FailingRemoval: @unchecked Sendable {
    private let lock = NSLock()
    private var failuresRemaining: Int

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func remove(_ url: URL) throws {
        lock.lock()
        let shouldFail = failuresRemaining > 0
        if shouldFail {
            failuresRemaining -= 1
        }
        lock.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }
}

@main
private enum CapturedAudioStorageSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hex-captured-audio-storage-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = CapturedAudioStorage(directoryURL: root)
        try storage.prepareAndRemoveOrphans()

        let orphan = storage.artifactURL(requestID: UUID())
        let unrelated = root.appendingPathComponent("keep.txt")
        let nestedDirectory = root.appendingPathComponent("keep.wav", isDirectory: true)
        try Data("audio".utf8).write(to: orphan)
        try Data("settings".utf8).write(to: unrelated)
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: false
        )

        try storage.prepareAndRemoveOrphans()

        require(
            !FileManager.default.fileExists(atPath: orphan.path),
            "orphan WAV was retained"
        )
        require(
            FileManager.default.fileExists(atPath: unrelated.path),
            "unrelated file was removed"
        )
        var isDirectory: ObjCBool = false
        require(
            FileManager.default.fileExists(
                atPath: nestedDirectory.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue,
            "WAV-named directory was removed"
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        require(permissions == 0o700, "storage directory is not private")

        let retryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hex-captured-audio-removal-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: retryRoot) }
        let failingRemoval = FailingRemoval(failuresRemaining: 1)
        let retryStorage = CapturedAudioStorage(
            directoryURL: retryRoot,
            removeItem: failingRemoval.remove
        )
        try retryStorage.prepareAndRemoveOrphans()
        let retainedAfterFailure = retryStorage.artifactURL(requestID: UUID())
        try Data("private audio".utf8).write(to: retainedAfterFailure)
        do {
            try retryStorage.prepareAndRemoveOrphans()
            require(false, "injected deletion failure was swallowed")
        } catch {
            require(
                FileManager.default.fileExists(atPath: retainedAfterFailure.path),
                "failed deletion unexpectedly removed the artifact"
            )
        }
        try retryStorage.prepareAndRemoveOrphans()
        require(
            !FileManager.default.fileExists(atPath: retainedAfterFailure.path),
            "a later cleanup did not retry the retained artifact"
        )
        try retryStorage.removeArtifact(at: retainedAfterFailure)

        let outsideArtifact = root.appendingPathComponent("outside.wav")
        try Data("outside".utf8).write(to: outsideArtifact)
        do {
            try retryStorage.removeArtifact(at: outsideArtifact)
            require(false, "storage accepted an artifact outside its directory")
        } catch {
            require(
                FileManager.default.fileExists(atPath: outsideArtifact.path),
                "storage removed an artifact it did not own"
            )
        }

        print("CapturedAudioStorage smoke passed")
    }
}
