import XCTest
@testable import ClamCore

final class ApplicationGPURecoveryTests: XCTestCase {
    func testCachedRecoveryIdentityDetectsNewEmergencyEvenWhenStatusStaysVerified() throws {
        let display = FakeDisplay()
        let latch = MemoryLatch()
        let safety = DisplaySafetyCoordinator(backend: display, latch: latch)
        safety.requestRecovery(now: 0)
        let firstID = safety.lastObservedRecoveryRequestID
        XCTAssertEqual(firstID, latch.requestID)
        XCTAssertTrue(safety.isRecoveryHeld)
        XCTAssertEqual(safety.recoveryStatus, .verified)
        try latch.request() // Simulate independent restore with a lost notification.
        safety.tick(now: 1)
        XCTAssertTrue(safety.isRecoveryHeld)
        XCTAssertEqual(safety.recoveryStatus, .verified)
        XCTAssertEqual(safety.lastObservedRecoveryRequestID, latch.requestID)
        XCTAssertNotEqual(safety.lastObservedRecoveryRequestID, firstID)
        XCTAssertTrue(display.operations.isEmpty, "This observational field must not alter recovery decisions")
    }
}
