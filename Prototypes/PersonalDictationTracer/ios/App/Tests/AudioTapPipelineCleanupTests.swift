import AVFoundation
@testable import HexKeyboardTracer
import XCTest

final class AudioTapPipelineCleanupTests: XCTestCase {
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func testFinishDrainsPublishedAudioBeforeClosingArtifact() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let requestID = UUID()
        let fileURL = fixture.storage.artifactURL(requestID: requestID)
        try fixture.pipeline.begin(requestID: requestID, fileURL: fileURL)
        fixture.pipeline.receive(makeBuffer(marker: 0.25))

        let result = try fixture.pipeline.finish(requestID: requestID)

        XCTAssertEqual(result.fileURL, fileURL)
        XCTAssertEqual(result.durationSeconds, 1_024.0 / 16_000.0, accuracy: 0.001)
        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testPipelineSupportsRepeatedCaptureAfterFinish() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for marker: Float in [0.25, 0.5] {
            let requestID = UUID()
            let fileURL = fixture.storage.artifactURL(requestID: requestID)
            try fixture.pipeline.begin(requestID: requestID, fileURL: fileURL)
            fixture.pipeline.receive(makeBuffer(marker: marker))
            let result = try fixture.pipeline.finish(requestID: requestID)
            XCTAssertGreaterThan(result.byteCount, 0)
            try fixture.storage.removeArtifact(at: result.fileURL)
        }
    }

    func testCancelDeletionFailureRetainsArtifactForRetryAndFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let requestID = UUID()
        let fileURL = fixture.storage.artifactURL(requestID: requestID)
        try fixture.pipeline.begin(requestID: requestID, fileURL: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        fixture.removal.failNextRemoval()
        XCTAssertThrowsError(try fixture.pipeline.cancel(requestID: requestID)) { error in
            XCTAssertEqual(error as? DictationCapture.Failure, .storageUnavailable)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "A failed unlink must leave the private artifact available for retry"
        )

        let laterRequestID = UUID()
        XCTAssertThrowsError(
            try fixture.pipeline.begin(
                requestID: laterRequestID,
                fileURL: fixture.storage.artifactURL(requestID: laterRequestID)
            )
        ) { error in
            XCTAssertEqual(error as? DictationCapture.Failure, .notArmed)
        }

        try fixture.storage.prepareAndRemoveOrphans()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEmptyFinishDeletionFailureRetainsArtifactForRetryAndFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let requestID = UUID()
        let fileURL = fixture.storage.artifactURL(requestID: requestID)
        try fixture.pipeline.begin(requestID: requestID, fileURL: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        fixture.removal.failNextRemoval()
        XCTAssertThrowsError(try fixture.pipeline.finish(requestID: requestID)) { error in
            XCTAssertEqual(error as? DictationCapture.Failure, .storageUnavailable)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "A failed unlink must leave the empty private artifact available for retry"
        )

        let laterRequestID = UUID()
        XCTAssertThrowsError(
            try fixture.pipeline.begin(
                requestID: laterRequestID,
                fileURL: fixture.storage.artifactURL(requestID: laterRequestID)
            )
        ) { error in
            XCTAssertEqual(error as? DictationCapture.Failure, .notArmed)
        }

        try fixture.storage.prepareAndRemoveOrphans()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hex-audio-pipeline-cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        let removal = ControlledRemoval()
        let storage = CapturedAudioStorage(
            directoryURL: root,
            removeItem: removal.remove
        )
        try storage.prepareAndRemoveOrphans()
        let pipeline = try AudioTapPipeline(
            inputFormat: format,
            storage: storage,
            onFailure: { _, _ in }
        )
        return Fixture(
            root: root,
            removal: removal,
            storage: storage,
            pipeline: pipeline
        )
    }

    private func makeBuffer(marker: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 1_024
        )!
        buffer.frameLength = 1_024
        let samples = buffer.floatChannelData![0]
        for index in 0..<1_024 {
            samples[index] = marker
        }
        return buffer
    }
}

private struct Fixture {
    let root: URL
    let removal: ControlledRemoval
    let storage: CapturedAudioStorage
    let pipeline: AudioTapPipeline
}

private final class ControlledRemoval: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailNextRemoval = false

    func failNextRemoval() {
        lock.lock()
        shouldFailNextRemoval = true
        lock.unlock()
    }

    func remove(_ fileURL: URL) throws {
        lock.lock()
        let shouldFail = shouldFailNextRemoval
        shouldFailNextRemoval = false
        lock.unlock()

        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}
