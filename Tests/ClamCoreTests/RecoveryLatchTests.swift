import XCTest
@testable import ClamCore

final class RecoveryLatchTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
    func testRequestIsVisibleToAnotherInstanceAndSurvivesRestart() throws {
        let writer = FileRecoveryLatch(directory: directory)
        let reader = FileRecoveryLatch(directory: directory)
        XCTAssertEqual(reader.state, .clear)
        try writer.request()
        XCTAssertEqual(reader.state, .requested)
        XCTAssertEqual(FileRecoveryLatch(directory: directory).state, .requested)
    }
    func testExplicitClearReleasesRequestForAllReaders() throws {
        let writer = FileRecoveryLatch(directory: directory)
        let reader = FileRecoveryLatch(directory: directory)
        try writer.request()
        XCTAssertEqual(reader.state, .requested)
        try reader.clear(acknowledging: reader.requestID)
        XCTAssertEqual(writer.state, .clear)
        XCTAssertNoThrow(try reader.clear(acknowledging: reader.requestID))
    }
    func testInvalidDirectoryIsUnavailableNotClear() throws {
        try Data("not a directory".utf8).write(to: directory)
        let latch = FileRecoveryLatch(directory: directory)
        XCTAssertEqual(latch.state, .unavailable)
        XCTAssertThrowsError(try latch.request())
        XCTAssertThrowsError(try latch.clear(acknowledging: latch.requestID))
    }
    func testRequestUsesPrivateDirectoryPermissions() throws {
        try FileRecoveryLatch(directory: directory).request()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testAcknowledgingOldRequestCannotEraseConcurrentNewRequest() throws {
        let writer = FileRecoveryLatch(directory: directory)
        let reader = FileRecoveryLatch(directory: directory)
        try writer.request()
        let consumed = reader.requestID
        XCTAssertNotNil(consumed)
        try writer.request() // arrives between reader's state check and clear
        XCTAssertNotEqual(consumed, writer.requestID)
        try reader.clear(acknowledging: consumed)
        XCTAssertEqual(writer.state, .requested)
        try reader.clear(acknowledging: reader.requestID)
        XCTAssertEqual(writer.state, .clear)
    }

    func testAcknowledgingNoRequestCannotEraseFirstConcurrentRequest() throws {
        let latch = FileRecoveryLatch(directory: directory)
        try latch.request()
        try latch.clear(acknowledging: nil)
        XCTAssertEqual(latch.state, .requested)
    }
}
