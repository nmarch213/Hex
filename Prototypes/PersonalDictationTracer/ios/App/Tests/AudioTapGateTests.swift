import AVFoundation
@testable import HexKeyboardTracer
import XCTest

final class AudioTapRingTests: XCTestCase {
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func testIdleInputIsDiscardedAndNeverCarriedIntoBegin() throws {
        let ring = try AudioTapRing(inputFormat: format)
        for marker in 0..<10 {
            XCTAssertEqual(ring.push(makeBuffer(marker: Float(marker))), .ignored)
        }
        try ring.beginCapture(requestID: UUID())
        XCTAssertNil(ring.peek())
    }

    func testDisarmRejectsAnotherBegin() throws {
        let ring = try AudioTapRing(inputFormat: format)
        ring.disarm()
        XCTAssertEqual(ring.push(makeBuffer(marker: 1)), .ignored)
        XCTAssertThrowsError(try ring.beginCapture(requestID: UUID())) { error in
            XCTAssertEqual(error as? DictationCapture.Failure, .notArmed)
        }
    }

    func testPreallocatedRingPreservesFIFOOrder() throws {
        let ring = try AudioTapRing(inputFormat: format)
        let requestID = UUID()
        try ring.beginCapture(requestID: requestID)
        for marker in 0..<32 {
            XCTAssertEqual(ring.push(makeBuffer(marker: Float(marker))), .enqueued)
        }
        for marker in 0..<32 {
            XCTAssertEqual(firstSample(in: ring.peek()), Float(marker))
            ring.consumePeeked()
        }
        XCTAssertNil(ring.peek())
        try ring.stopCapture(requestID: requestID)
    }

    func testProducerFailsClosedAtHardRingLimit() throws {
        let ring = try AudioTapRing(inputFormat: format)
        let requestID = UUID()
        try ring.beginCapture(requestID: requestID)
        for marker in 0..<32 {
            XCTAssertEqual(ring.push(makeBuffer(marker: Float(marker))), .enqueued)
        }
        XCTAssertEqual(ring.push(makeBuffer(marker: 33)), .failed)
        XCTAssertEqual(ring.pendingFailure(), .writerBackpressureExceeded)
        XCTAssertEqual(ring.push(makeBuffer(marker: 34)), .ignored)
        for _ in 0..<32 {
            XCTAssertNotNil(ring.peek())
            ring.consumePeeked()
        }
        try ring.stopCapture(requestID: requestID)
    }

    func testOversizedTapFailsAsBackpressureWithoutAllocation() throws {
        let ring = try AudioTapRing(inputFormat: format)
        try ring.beginCapture(requestID: UUID())
        XCTAssertEqual(
            ring.push(makeBuffer(marker: 1, frameCount: 1_025)),
            .failed
        )
        XCTAssertEqual(ring.pendingFailure(), .writerBackpressureExceeded)
        XCTAssertNil(ring.peek())
    }

    func testStopPublishesNoLaterInputButRetainsAlreadyPublishedAudio() throws {
        let ring = try AudioTapRing(inputFormat: format)
        let requestID = UUID()
        try ring.beginCapture(requestID: requestID)
        XCTAssertEqual(ring.push(makeBuffer(marker: 1)), .enqueued)
        try ring.stopCapture(requestID: requestID)
        XCTAssertEqual(ring.push(makeBuffer(marker: 2)), .ignored)
        XCTAssertEqual(firstSample(in: ring.peek()), 1)
        ring.consumePeeked()
        XCTAssertNil(ring.peek())
    }

    func testStopRejectsStaleRequest() throws {
        let ring = try AudioTapRing(inputFormat: format)
        let activeRequestID = UUID()
        let staleRequestID = UUID()
        try ring.beginCapture(requestID: activeRequestID)
        XCTAssertThrowsError(try ring.stopCapture(requestID: staleRequestID)) { error in
            XCTAssertEqual(
                error as? DictationCapture.Failure,
                .stale(
                    expectedRequestID: activeRequestID,
                    receivedRequestID: staleRequestID
                )
            )
        }
    }

    private func makeBuffer(
        marker: Float,
        frameCount: AVAudioFrameCount = 1_024
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        )!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frameCount) {
            samples[index] = marker
        }
        return buffer
    }

    private func firstSample(in buffer: AVAudioPCMBuffer?) -> Float? {
        buffer?.floatChannelData?[0][0]
    }
}
