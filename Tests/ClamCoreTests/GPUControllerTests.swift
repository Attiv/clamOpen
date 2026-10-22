import XCTest
@testable import ClamCore

final class GPUControllerTests: XCTestCase {
    private let hardware = GPUHardwareSnapshot(
        mainDisplayDeviceName: "AMD Radeon Pro 5500M",
        devices: [GPUDeviceInfo(name: "Intel UHD 630", isLowPower: true),
                  GPUDeviceInfo(name: "AMD Radeon Pro 5500M", isLowPower: false)],
        supportsLegacySwitching: true)

    private func output(_ battery: Int, _ ac: Int) -> GPUCommandResult {
        GPUCommandResult(status: 0, output: "Battery Power:\n gpuswitch  \(battery)\nAC Power:\n gpuswitch \(ac)\n")
    }

    private func backend() -> FakeGPUBackend {
        FakeGPUBackend(hardware: hardware, reads: [output(2, 2)])
    }

    func testParsesBatteryAndACWithSpacesTabsAndUnrelatedSettings() {
        let policies = GPUPowerPolicies.parse("""
        Battery Power:
          sleep              10
          gpuswitch          1
        AC Power:
        \tgpuswitch\t2
        """)
        XCTAssertEqual(policies.battery, 1)
        XCTAssertEqual(policies.ac, 2)
    }

    func testIgnoresUnknownSectionsAndSimilarKeys() {
        let policies = GPUPowerPolicies.parse("""
        gpuswitch 0
        Battery Power:
          gpuswitch-extra 0
          gpuswitch 1
        UPS Power:
          gpuswitch 0
        AC Power:
          gpuswitch 2
        """)
        XCTAssertEqual(policies, GPUPowerPolicies(battery: 1, ac: 2))
    }

    func testMissingAndMalformedValuesStayUnknown() {
        let policies = GPUPowerPolicies.parse("Battery Power:\n gpuswitch nope\nAC Power:\n sleep 0\n")
        XCTAssertNil(policies.battery)
        XCTAssertNil(policies.ac)
        XCTAssertEqual(GPUPowerPolicies.label(for: nil), "不可用")
        XCTAssertEqual(GPUPowerPolicies.label(for: 9), "未知（9）")
        XCTAssertEqual(GPUPowerPolicies.label(for: 0), "集成显卡")
    }

    func testDuplicatePolicyKeysCannotVerifySuccess() {
        let policies = GPUPowerPolicies.parse("Battery Power:\n gpuswitch 1\n gpuswitch 2\nAC Power:\n gpuswitch 1\n")
        XCTAssertNil(policies.battery)
        XCTAssertFalse(policies.matches(.discrete))
    }

    func testSnapshotIsReadOnlyAndReportsBothPolicies() {
        let fake = backend()
        let state = GPUController(backend: fake).snapshot()
        XCTAssertEqual(state.hardware.mainDisplayDeviceName, hardware.mainDisplayDeviceName)
        XCTAssertTrue(state.canSwitchPolicy)
        XCTAssertEqual(state.policies.battery, 2)
        XCTAssertEqual(state.policies.ac, 2)
        XCTAssertTrue(fake.applied.isEmpty)
    }

    func testSingleGPUIsReadOnly() {
        let fake = backend()
        fake.hardware.devices = [GPUDeviceInfo(name: "Intel UHD 630", isLowPower: true)]
        let result = GPUController(backend: fake).apply(.discrete)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertFalse(result.snapshot.canSwitchPolicy)
        XCTAssertTrue(fake.applied.isEmpty)
    }

    func testUnsupportedPlatformIsReadOnlyEvenWithMultipleGPUs() {
        let fake = backend()
        fake.hardware.supportsLegacySwitching = false
        XCTAssertFalse(GPUController(backend: fake).snapshot().canSwitchPolicy)
        XCTAssertTrue(fake.applied.isEmpty)
    }

    func testNoMetalDeviceRemainsExplicitlyUnavailable() {
        let fake = backend()
        fake.hardware.mainDisplayDeviceName = nil
        fake.hardware.devices = []
        let state = GPUController(backend: fake).snapshot()
        XCTAssertNil(state.hardware.mainDisplayDeviceName)
        XCTAssertFalse(state.canSwitchPolicy)
    }

    func testMissingPolicyDisablesWrites() {
        let fake = backend()
        fake.reads = [GPUCommandResult(status: 0, output: "Battery Power:\n sleep 10\n")]
        let result = GPUController(backend: fake).apply(.discrete)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(fake.applied.isEmpty)
    }

    func testUnknownPolicyDisablesWrites() {
        let fake = backend()
        fake.reads = [output(9, 2)]
        XCTAssertFalse(GPUController(backend: fake).snapshot().canSwitchPolicy)
    }

    func testReadCommandFailureIsNotAnAutomaticPolicy() {
        let fake = backend()
        fake.reads = [GPUCommandResult(status: 1, output: "read denied")]
        let state = GPUController(backend: fake).snapshot()
        XCTAssertNotNil(state.readError)
        XCTAssertNil(state.policies.battery)
        XCTAssertFalse(state.canSwitchPolicy)
    }

    func testThrownReadFailureIsReported() {
        let fake = backend()
        fake.readError = TestError.failed
        let state = GPUController(backend: fake).snapshot()
        XCTAssertNotNil(state.readError)
        XCTAssertFalse(state.canSwitchPolicy)
    }

    func testDiscretePolicyRequiresBothFreshValuesToMatch() {
        let fake = backend()
        fake.reads = [output(2, 2), output(1, 1)]
        let result = GPUController(backend: fake).apply(.discrete)
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertEqual(fake.applied, [.discrete])
        XCTAssertEqual(fake.readCount, 2)
        XCTAssertTrue(result.snapshot.policies.matches(.discrete))
    }

    func testZeroExitWithUnchangedPolicyIsNotSuccess() {
        let fake = backend()
        fake.reads = [output(2, 2), output(2, 2)]
        let result = GPUController(backend: fake).apply(.discrete)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(fake.applied.count, 1)
    }

    func testMixedPowerSourcesAreNotVerified() {
        let fake = backend()
        fake.reads = [output(2, 2), output(1, 2)]
        XCTAssertEqual(GPUController(backend: fake).apply(.discrete).outcome, .failed)
    }

    func testFailedReadBackCannotClaimSuccess() {
        let fake = backend()
        fake.reads = [output(2, 2), GPUCommandResult(status: 1, output: "unreadable")]
        XCTAssertEqual(GPUController(backend: fake).apply(.discrete).outcome, .failed)
    }

    func testAutomaticPolicyDoesNotPretendDisplayGPUBecomesIntegrated() {
        let fake = backend()
        fake.reads = [output(1, 1), output(2, 2)]
        let result = GPUController(backend: fake).apply(.automatic)
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertEqual(result.snapshot.hardware.mainDisplayDeviceName, "AMD Radeon Pro 5500M")
        XCTAssertTrue(result.message.contains("策略"))
    }

    func testAuthenticationCancellationIsDistinctFromFailureAndSuccess() {
        let fake = backend()
        fake.setResult = GPUCommandResult(status: 1, output: "execution error: 用户已取消。 (-128)")
        let result = GPUController(backend: fake).apply(.discrete)
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(fake.applied.count, 1)
        XCTAssertTrue(result.snapshot.policies.matches(.automatic))
    }

    func testAuthorizationFailureIsReportedWithoutRetry() {
        let fake = backend()
        fake.setResult = GPUCommandResult(status: 1, output: "authorization denied")
        let result = GPUController(backend: fake).apply(.discrete)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("authorization denied"))
        XCTAssertEqual(fake.applied.count, 1)
    }

    func testThrownWriteFailureIsReportedWithoutRetry() {
        let fake = backend()
        fake.setError = TestError.failed
        XCTAssertEqual(GPUController(backend: fake).apply(.discrete).outcome, .failed)
        XCTAssertEqual(fake.applied.count, 1)
    }

    func testCancelledQueuedRequestCannotWrite() {
        let fake = backend()
        fake.reads = [output(2, 2), output(1, 1)]
        let request = GPUChangeRequest()
        request.cancel()
        let result = GPUController(backend: fake).apply(.discrete, request: request)
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(fake.applied.isEmpty)
    }

    func testCancellationDuringPreflightReadCannotWrite() {
        let fake = backend()
        fake.reads = [output(2, 2), output(1, 1)]
        let request = GPUChangeRequest()
        fake.onRead = { request.cancel() }
        let result = GPUController(backend: fake).apply(.discrete, request: request)
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(fake.applied.isEmpty)
    }

    func testCancellationDuringAuthorizationCannotBeReportedAsSuccess() {
        let fake = backend()
        fake.reads = [output(2, 2), output(1, 1)]
        let request = GPUChangeRequest()
        fake.onSet = { request.cancel() }
        let result = GPUController(backend: fake).apply(.discrete, request: request)
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(result.snapshot.policies.matches(.discrete), "Read-back must remain honest even if cancellation raced a completed write")
    }

    func testNativeBackendUsesAbsolutePathsAndWhitelistedAllSourceCommands() throws {
        var calls: [(String, [String])] = []
        let native = GPUSystemBackend(runCommand: { path, arguments in
            calls.append((path, arguments))
            return GPUCommandResult(status: 0, output: "")
        })
        _ = try native.readPowerSettings()
        _ = try native.setPreference(.discrete)
        _ = try native.setPreference(.automatic)
        XCTAssertEqual(calls[0].0, "/usr/bin/pmset")
        XCTAssertEqual(calls[0].1, ["-g", "custom"])
        XCTAssertEqual(calls[1].0, "/usr/bin/osascript")
        XCTAssertEqual(calls[1].1.first, "-e")
        XCTAssertTrue(calls[1].1[1].contains("/usr/bin/pmset -a gpuswitch 1"))
        XCTAssertTrue(calls[2].1[1].contains("/usr/bin/pmset -a gpuswitch 2"))
        for call in calls.dropFirst() {
            XCTAssertTrue(call.1[1].contains("/bin/test -f"))
            XCTAssertTrue(call.1[1].contains("/bin/kill -0"))
            XCTAssertTrue(call.1[1].hasSuffix("with administrator privileges"))
        }
    }

    func testCancellationRemovesAuthorizationMarkerAndPreventsLateStart() throws {
        let request = GPUChangeRequest()
        let marker = try request.makeMarker()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        request.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertThrowsError(try request.makeMarker())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try request.start(process))
        XCTAssertFalse(process.isRunning)
    }

    func testNativeBackendDoesNotAuthorizeACancelledRequest() throws {
        var calls = 0
        let native = GPUSystemBackend(runCommand: { _, _ in
            calls += 1
            return GPUCommandResult(status: 0, output: "")
        })
        let request = GPUChangeRequest()
        request.cancel()
        let result = try native.setPreference(.discrete, request: request)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(calls, 0)
    }

    func testCancellingOwnedProcessStopsItWithoutWaitingForUserInput() throws {
        let request = GPUChangeRequest()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try request.start(process)
        let start = Date()
        request.cancel()
        process.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertFalse(process.isRunning)
    }
}

private enum TestError: Error { case failed }

private final class FakeGPUBackend: GPUBackend {
    var hardware: GPUHardwareSnapshot
    var reads: [GPUCommandResult]
    var readCount = 0
    var applied: [GPUPreference] = []
    var readError: Error?
    var setError: Error?
    var onRead: (() -> Void)?
    var onSet: (() -> Void)?
    var setResult = GPUCommandResult(status: 0, output: "")

    init(hardware: GPUHardwareSnapshot, reads: [GPUCommandResult]) {
        self.hardware = hardware
        self.reads = reads
    }
    func hardwareSnapshot() -> GPUHardwareSnapshot { hardware }
    func readPowerSettings() throws -> GPUCommandResult {
        readCount += 1
        onRead?()
        if let readError { throw readError }
        return reads.count > 1 ? reads.removeFirst() : reads[0]
    }
    func setPreference(_ preference: GPUPreference, request: GPUChangeRequest) throws -> GPUCommandResult {
        applied.append(preference)
        onSet?()
        if let setError { throw setError }
        return setResult
    }
}
