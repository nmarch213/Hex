import Foundation

/// Owns the private, non-backed-up directory used for transient Dictation audio.
///
/// Completed artifacts are handed to the caller, which removes them after upload. Any WAV
/// left behind by a terminated process is an orphan and is removed when the next process starts.
struct CapturedAudioStorage: Sendable {
    let directoryURL: URL
    private let removeItem: @Sendable (URL) throws -> Void

    init(
        directoryURL: URL,
        removeItem: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) {
        self.directoryURL = directoryURL
        self.removeItem = removeItem
    }

    func prepareAndRemoveOrphans(
        fileManager: FileManager = .default
    ) throws {
        var directoryAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o700,
        ]
#if os(iOS) || os(tvOS) || os(watchOS)
        directoryAttributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
#endif
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
        try fileManager.setAttributes(
            directoryAttributes,
            ofItemAtPath: directoryURL.path
        )

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedDirectory = directoryURL
        try protectedDirectory.setResourceValues(resourceValues)

        let artifacts = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for artifact in artifacts where artifact.pathExtension.lowercased() == "wav" {
            let values = try artifact.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            try removeArtifact(at: artifact)
        }
    }

    /// Removes only a direct WAV child owned by this transient storage directory.
    /// A concurrent or repeated removal is an idempotent success.
    func removeArtifact(at artifactURL: URL) throws {
        let normalizedDirectory = directoryURL.standardizedFileURL
        let normalizedArtifact = artifactURL.standardizedFileURL
        guard
            normalizedArtifact.deletingLastPathComponent() == normalizedDirectory,
            normalizedArtifact.pathExtension.lowercased() == "wav"
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        do {
            try removeItem(normalizedArtifact)
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == NSFileNoSuchFileError {
                return
            }
            throw error
        }
    }

    func artifactURL(requestID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            "\(requestID.uuidString).wav",
            isDirectory: false
        )
    }
}
