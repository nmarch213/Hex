import Foundation
import Testing
@testable import HexKeyboardTracer

@Suite("Prototype IPC storage")
struct PrototypeIPCStorageTests {
    @Test("App-owned IPC files are excluded from device backup")
    func appOwnedFilesAreExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try PrototypeIPCStore.write(
            Data("{}".utf8),
            file: .mailboxRecord,
            in: directory
        )

        let fileURL = directory.appendingPathComponent(
            PrototypeIPCFile.mailboxRecord.filename
        )
        let values = try fileURL.resourceValues(
            forKeys: [URLResourceKey.isExcludedFromBackupKey]
        )
        #expect(values.isExcludedFromBackup == true)
    }
}
