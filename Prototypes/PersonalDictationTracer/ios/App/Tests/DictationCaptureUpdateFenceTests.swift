@testable import HexKeyboardTracer
import XCTest

final class DictationCaptureUpdateFenceTests: XCTestCase {
    func testRearmRejectsBufferedFailureFromPreviousArm() {
        var fence = DictationCaptureUpdateFence()
        var isArmed = false
        let previousGeneration = UUID()
        let rearmGeneration = UUID()

        fence.beginArm(generation: previousGeneration)
        if fence.synchronizeArm(generation: previousGeneration, through: 3) {
            isArmed = true
        }

        fence.beginArm(generation: rearmGeneration)
        if fence.acceptUpdate(generation: previousGeneration, sequence: 4) {
            isArmed = false
        }
        XCTAssertTrue(isArmed)

        if fence.synchronizeArm(generation: rearmGeneration, through: 5) {
            isArmed = true
        }
        XCTAssertTrue(isArmed)
    }

    func testNewerFailurePreventsDelayedArmResponseFromRearming() {
        var fence = DictationCaptureUpdateFence()
        let generation = UUID()

        fence.beginArm(generation: generation)
        XCTAssertTrue(fence.acceptUpdate(generation: generation, sequence: 4))
        XCTAssertFalse(
            fence.synchronizeArm(generation: generation, through: 3)
        )
    }
}
