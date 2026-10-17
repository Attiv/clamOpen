import XCTest
@testable import ClamCore

final class MemoryLatch: RecoveryLatch {
    var state: RecoveryLatchState = .clear
    var requestID: String?
    func request() throws { state = .requested; requestID = UUID().uuidString }
    func clear(acknowledging requestID: String?) throws {
        if requestID == self.requestID { state = .clear }
    }
}

final class FakeDisplay: DisplayBackend {
    var builtinActive = true
    var externalOnline = true
    var externalActive = true
    var asleep = false
    var externalAsleep = false
    var reliable = true
    var enableSucceeds = true
    var enableChangesState = true
    var operations: [Bool] = []
    var onDisable: (() -> Void)?
    func snapshot() -> DisplaySnapshot {
        DisplaySnapshot(displays: [
            DisplayState(id: 1, builtin: true, online: true, active: builtinActive, asleep: asleep),
            DisplayState(id: 2, builtin: false, online: externalOnline, active: externalActive, asleep: asleep || externalAsleep)
        ], isReliable: reliable)
    }
    func setBuiltinEnabled(_ enabled: Bool) -> DisplayResult {
        operations.append(enabled)
        if enabled {
            if !enableSucceeds { return .failed("模拟配置失败") }
            if enableChangesState { builtinActive = true }
        } else {
            builtinActive = false
            onDisable?()
        }
        return .ok
    }
}

final class DisplaySafetyTests: XCTestCase {
    func make() -> (DisplaySafetyCoordinator, FakeDisplay, MemoryLatch) {
        let display = FakeDisplay()
        let latch = MemoryLatch()
        return (DisplaySafetyCoordinator(backend: display, latch: latch), display, latch)
    }

    func testManualDisableRequiresUsableExternal() {
        let (s, d, _) = make()
        d.externalActive = false // connected but black/not drawable
        XCTAssertNotEqual(s.disableByUser(now: 0), .ok)
        XCTAssertTrue(d.operations.isEmpty)
    }

    func testManualDisableRecordsIntent() {
        let (s, d, _) = make()
        XCTAssertEqual(s.disableByUser(now: 0), .ok)
        XCTAssertTrue(s.intentDisabled)
        XCTAssertEqual(d.operations, [false])
    }

    func testWakeRecoversEvenWhenAutoModeIsOff() {
        let (s, d, latch) = make()
        _ = s.disableByUser(now: 0)
        s.screensDidSleep()
        d.asleep = true
        s.tick(now: 100)
        XCTAssertEqual(d.operations, [false])
        d.asleep = false
        s.screensDidWake(now: 101)
        s.tick(now: 102)
        XCTAssertTrue(d.builtinActive)
        XCTAssertFalse(s.intentDisabled)
        XCTAssertTrue(s.isRecoveryHeld)
        XCTAssertEqual(latch.state, .requested)
        XCTAssertEqual(s.recoveryStatus, .verified)
    }

    func testSystemWakeAloneDoesNotConfigureSleepingScreens() {
        let (s, d, _) = make()
        _ = s.disableByUser(now: 0)
        s.systemWillSleep()
        d.asleep = true
        s.systemDidWake(now: 10)
        for t in 11...20 { s.tick(now: Double(t)) }
        XCTAssertEqual(d.operations, [false])
        XCTAssertTrue(s.isSleeping)
    }

    func testReversedWakeNotificationOrderDoesNotSuspendAgain() {
        let (s, d, _) = make()
        _ = s.disableByUser(now: 0)
        s.systemWillSleep()
        s.screensDidWake(now: 10)
        s.systemDidWake(now: 11)
        s.tick(now: 12)
        XCTAssertFalse(s.isSleeping)
        XCTAssertTrue(d.builtinActive)
        XCTAssertEqual(s.recoveryStatus, .verified)
    }

    func testEmergencyRecoveryWinsAgainstAutoAndWatchdog() {
        let (s, d, _) = make()
        s.autoMode = true
        _ = s.disableByUser(now: 0)
        s.requestRecovery(now: 1)
        for t in 2...10 { s.tick(now: Double(t)) }
        XCTAssertTrue(d.builtinActive)
        XCTAssertEqual(d.operations, [false, true])
        XCTAssertFalse(s.intentDisabled)
        XCTAssertTrue(s.isRecoveryHeld)
    }

    func testPersistentRecoveryWorksWithoutNotification() throws {
        let (s, d, latch) = make()
        _ = s.disableByUser(now: 0)
        try latch.request() // independent process; no notification delivered
        s.tick(now: 1)
        s.tick(now: 2)
        XCTAssertTrue(d.builtinActive)
        XCTAssertTrue(s.isRecoveryHeld)
    }

    func testRecoveryPersistsAcrossCoordinatorRestart() throws {
        let d = FakeDisplay()
        let latch = MemoryLatch()
        try latch.request()
        let s = DisplaySafetyCoordinator(backend: d, latch: latch)
        s.autoMode = true
        s.tick(now: 0)
        XCTAssertTrue(d.operations.isEmpty)
        XCTAssertTrue(d.builtinActive)
        XCTAssertTrue(s.isRecoveryHeld)
    }

    func testExplicitDisableCanReleaseVerifiedRecovery() {
        let (s, d, latch) = make()
        s.requestRecovery(now: 0)
        s.tick(now: 1)
        XCTAssertEqual(s.disableByUser(now: 2), .ok)
        XCTAssertFalse(s.isRecoveryHeld)
        XCTAssertEqual(latch.state, .clear)
        XCTAssertFalse(d.builtinActive)
    }

    func testRecoveryArrivingDuringDisableWins() {
        let (s, d, latch) = make()
        d.onDisable = { try! latch.request() }
        _ = s.disableByUser(now: 0)
        s.tick(now: 1)
        XCTAssertTrue(d.builtinActive)
        XCTAssertTrue(s.isRecoveryHeld)
        XCTAssertFalse(s.intentDisabled)
    }

    func testUnexpectedBuiltinActivationIsNotReDisabled() {
        let (s, d, _) = make()
        s.autoMode = true
        _ = s.disableByUser(now: 0)
        d.builtinActive = true // system or an old independent recovery tool
        s.tick(now: 1)
        s.tick(now: 2)
        XCTAssertEqual(d.operations, [false])
        XCTAssertTrue(s.isRecoveryHeld)
    }

    func testConfigurationSuccessIsNotRecoveryVerification() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.enableChangesState = false
        s.requestRecovery(now: 0)
        XCTAssertEqual(s.recoveryStatus, .recovering)
        s.tick(now: 0.5)
        XCTAssertNotEqual(s.recoveryStatus, .verified)
        d.builtinActive = true
        s.tick(now: 1)
        XCTAssertEqual(s.recoveryStatus, .verified)
    }

    func testFailedRestoreRetriesAndEventuallyVerifies() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.enableSucceeds = false
        s.requestRecovery(now: 0)
        s.tick(now: 1)
        XCTAssertEqual(d.operations, [true, true])
        XCTAssertEqual(s.recoveryStatus, .recovering)
        d.enableSucceeds = true
        s.tick(now: 3)
        s.tick(now: 4)
        XCTAssertEqual(s.recoveryStatus, .verified)
        XCTAssertTrue(s.isRecoveryHeld)
    }

    func testRetriesAreBoundedEvenWithRepeatedCallbacks() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.enableSucceeds = false
        s.requestRecovery(now: 0)
        for t in 1...1000 { s.tick(now: Double(t) / 10) }
        XCTAssertEqual(d.operations.count, 4)
        XCTAssertEqual(s.recoveryStatus, .failed)
        XCTAssertTrue(s.isRecoveryHeld)
        XCTAssertNotNil(s.lastError)
        s.requestRecovery(now: 101)
        XCTAssertEqual(d.operations.count, 5) // explicit retry starts a new bounded run
    }

    func testUnreliableSnapshotNeverDisables() {
        let (s, d, _) = make()
        d.reliable = false
        s.autoMode = true
        XCTAssertNotEqual(s.disableByUser(now: 0), .ok)
        s.tick(now: 1)
        XCTAssertFalse(d.operations.contains(false))
    }

    func testDisconnectedExternalRecoversWithoutAuto() {
        let (s, d, _) = make()
        _ = s.disableByUser(now: 0)
        d.externalOnline = false
        s.tick(now: 1)
        s.tick(now: 2)
        XCTAssertTrue(d.builtinActive)
        XCTAssertFalse(s.intentDisabled)
    }

    func testUnavailableLatchBlocksAllDisablePaths() {
        let (s, d, latch) = make()
        latch.state = .unavailable
        s.autoMode = true
        XCTAssertNotEqual(s.disableByUser(now: 0), .ok)
        s.tick(now: 1)
        XCTAssertFalse(d.operations.contains(false))
    }

    func testDuplicateWakeNotificationsCannotRestartExhaustedRecovery() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.enableSucceeds = false
        s.screensDidSleep()
        for t in 1...30 {
            s.screensDidWake(now: Double(t))
            s.tick(now: Double(t))
        }
        XCTAssertEqual(d.operations.count, 4)
        XCTAssertEqual(s.recoveryStatus, .failed)
    }

    func testExplicitRescueRetriesEvenIfAllScreensRemainAsleep() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.asleep = true
        d.enableSucceeds = false
        s.systemWillSleep()
        s.requestRecovery(now: 1)
        for t in 2...15 { s.tick(now: Double(t)) }
        XCTAssertEqual(d.operations.count, 4)
        XCTAssertEqual(s.recoveryStatus, .failed)
    }

    func testDisabledBuiltinAndSleepingExternalMustNotBeWokenByPolling() {
        let (s, d, _) = make()
        _ = s.disableByUser(now: 0)
        d.externalActive = false
        d.externalAsleep = true // disabled built-in is inactive, NOT marked asleep
        s.tick(now: 1) // sleep notification has not arrived yet
        s.tick(now: 2)
        XCTAssertEqual(d.operations, [false])
        XCTAssertTrue(s.isSleeping)
        d.externalAsleep = false
        d.externalActive = true
        s.tick(now: 3) // recover on awake observation if wake notification is lost
        s.tick(now: 4)
        XCTAssertTrue(d.builtinActive)
        XCTAssertTrue(s.isRecoveryHeld)
    }

    func testUnconsumedExternalRescueCannotBeClearedByManualDisable() throws {
        let (s, d, latch) = make()
        try latch.request()
        XCTAssertNotEqual(s.disableByUser(now: 0), .ok)
        XCTAssertTrue(d.builtinActive)
        XCTAssertEqual(latch.state, .requested)
    }

    func testOrdinaryAutoModeStillDisablesWhenSafe() {
        let (s, d, _) = make()
        s.autoMode = true
        s.tick(now: 0)
        s.tick(now: 1)
        XCTAssertEqual(d.operations, [false])
        XCTAssertTrue(s.intentDisabled)
    }

    func testSleepSuspendsPendingRecoveryUntilNextScreenWake() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.enableSucceeds = false
        s.requestRecovery(now: 0)
        s.systemWillSleep()
        for t in 1...20 { s.tick(now: Double(t)) }
        XCTAssertEqual(d.operations, [true])
        s.screensDidWake(now: 21)
        XCTAssertEqual(d.operations, [true, true])
    }

    func testUnreliableSnapshotCannotVerifyRecovery() {
        let (s, d, _) = make()
        d.reliable = false
        s.requestRecovery(now: 0)
        s.tick(now: 1)
        XCTAssertEqual(s.recoveryStatus, .recovering)
    }

    func testNewRescueWhileAlreadyHeldCannotBeAcknowledgedBeforeConsumption() throws {
        let (s, d, latch) = make()
        s.requestRecovery(now: 0)
        s.tick(now: 1)
        try latch.request() // a new independent emergency request
        XCTAssertNotEqual(s.disableByUser(now: 2), .ok)
        XCTAssertTrue(d.builtinActive)
        XCTAssertEqual(latch.state, .requested)
    }

    func testSystemWakeWithoutPriorSleepOrAwakeEvidenceWaits() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.externalActive = false // transient enumeration, neither marked asleep
        s.systemDidWake(now: 0)
        s.tick(now: 1)
        XCTAssertTrue(d.operations.isEmpty)
        XCTAssertTrue(s.isSleeping)
        s.screensDidWake(now: 2)
        XCTAssertEqual(d.operations, [true])
    }

    func testLateSuccessfulActivationCanVerifyAfterRetryExhaustion() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.enableSucceeds = false
        s.requestRecovery(now: 0)
        for t in 1...10 { s.tick(now: Double(t)) }
        XCTAssertEqual(s.recoveryStatus, .failed)
        d.builtinActive = true
        s.tick(now: 11)
        XCTAssertEqual(s.recoveryStatus, .verified)
        XCTAssertEqual(d.operations.count, 4)
        XCTAssertNil(s.lastError)
    }

    func testReversedWakeOrderKeepsRetryingWhenFirstEnableFails() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.externalActive = false
        d.enableSucceeds = false
        s.systemWillSleep()
        s.screensDidWake(now: 10) // actual screen wake evidence, first enable fails
        s.systemDidWake(now: 11) // late system notification must not suspend retries
        d.enableSucceeds = true
        for t in 12...16 { s.tick(now: Double(t)) }
        XCTAssertFalse(s.isSleeping)
        XCTAssertEqual(s.recoveryStatus, .verified)
        XCTAssertTrue(d.builtinActive)
        XCTAssertGreaterThan(d.operations.count, 1)
    }

    func testScreenWakeEvidenceSurvivesTemporarilyStaleAsleepFlags() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.asleep = true
        d.enableSucceeds = false
        s.systemWillSleep()
        s.screensDidWake(now: 10)
        s.systemDidWake(now: 10.5)
        s.tick(now: 11)
        XCTAssertEqual(d.operations.count, 2)
        XCTAssertFalse(s.isSleeping)
        d.enableSucceeds = true
        d.asleep = false
        s.tick(now: 13)
        s.tick(now: 14)
        XCTAssertEqual(s.recoveryStatus, .verified)
    }

    func testExplicitAutoEnableImmediatelyReleasesVerifiedSafetyHold() {
        let (s, d, latch) = make()
        s.requestRecovery(now: 0)
        XCTAssertEqual(s.recoveryStatus, .verified)

        XCTAssertEqual(s.setAutoModeByUser(true, now: 1), .ok)

        XCTAssertTrue(s.autoMode)
        XCTAssertFalse(s.isRecoveryHeld)
        XCTAssertTrue(s.intentDisabled)
        XCTAssertEqual(latch.state, .clear)
        XCTAssertEqual(d.operations, [false]) // no watchdog tick needed
    }

    func testExplicitAutoCanResumeAfterWakeButPassiveAutoCannot() {
        let (s, d, _) = make()
        s.autoMode = true
        s.tick(now: 0)
        s.systemWillSleep()
        s.screensDidWake(now: 10)
        s.tick(now: 11)
        XCTAssertTrue(d.builtinActive)
        XCTAssertTrue(s.isRecoveryHeld)
        XCTAssertEqual(d.operations, [false, true])

        XCTAssertEqual(s.setAutoModeByUser(true, now: 12), .ok)
        XCTAssertFalse(s.isRecoveryHeld)
        XCTAssertEqual(d.operations, [false, true, false])
    }

    func testTurningAutoOffDoesNotChangeDisplaysOrReleaseHold() {
        let (s, d, latch) = make()
        s.autoMode = true
        s.requestRecovery(now: 0)
        XCTAssertEqual(s.setAutoModeByUser(false, now: 1), .ok)
        XCTAssertFalse(s.autoMode)
        XCTAssertTrue(s.isRecoveryHeld)
        XCTAssertEqual(latch.state, .requested)
        XCTAssertTrue(d.operations.isEmpty)
    }

    func testExplicitAutoWithoutExternalArmsPreferenceWithoutDisabling() {
        let (s, d, _) = make()
        d.externalOnline = false
        XCTAssertEqual(s.setAutoModeByUser(true, now: 0), .ok)
        XCTAssertTrue(s.autoMode)
        XCTAssertTrue(d.operations.isEmpty)
        d.externalOnline = true
        s.tick(now: 1)
        XCTAssertEqual(d.operations, [false])
    }

    func testExplicitAutoWithoutUsableExternalRetainsExistingHold() {
        let (s, d, latch) = make()
        s.requestRecovery(now: 0)
        d.externalAsleep = true
        XCTAssertEqual(s.setAutoModeByUser(true, now: 1), .ok)
        s.tick(now: 2)
        XCTAssertTrue(s.autoMode)
        XCTAssertTrue(s.isRecoveryHeld)
        XCTAssertEqual(latch.state, .requested)
        XCTAssertTrue(d.operations.isEmpty)
    }

    func testExplicitAutoEnableCannotOverrideSleepSuspension() {
        let (s, d, _) = make()
        s.systemWillSleep()
        // CG can temporarily still report an active external display.
        XCTAssertNotEqual(s.setAutoModeByUser(true, now: 1), .ok)
        XCTAssertTrue(s.isSleeping)
        XCTAssertTrue(s.isRecoveryHeld)
        XCTAssertTrue(d.operations.isEmpty)
    }

    func testExplicitAutoEnableCannotInterruptUnverifiedRecovery() {
        let (s, d, _) = make()
        d.builtinActive = false
        d.enableChangesState = false
        s.requestRecovery(now: 0)
        XCTAssertNotEqual(s.setAutoModeByUser(true, now: 0.5), .ok)
        XCTAssertEqual(s.recoveryStatus, .recovering)
        XCTAssertTrue(s.isRecoveryHeld)
        XCTAssertEqual(d.operations, [true])
    }

    func testNewEmergencyRequestTakesPriorityOverExplicitAutoEnable() throws {
        let (s, d, latch) = make()
        s.requestRecovery(now: 0)
        try latch.request()
        XCTAssertNotEqual(s.setAutoModeByUser(true, now: 1), .ok)
        XCTAssertTrue(s.isRecoveryHeld)
        XCTAssertEqual(latch.state, .requested)
        XCTAssertTrue(d.builtinActive)
        XCTAssertTrue(d.operations.isEmpty)
    }

    func testEmergencyDuringExplicitAutoDisableStillWins() {
        let (s, d, latch) = make()
        s.requestRecovery(now: 0)
        d.onDisable = { try! latch.request() }
        XCTAssertNotEqual(s.setAutoModeByUser(true, now: 1), .ok)
        s.tick(now: 2)
        XCTAssertTrue(s.isRecoveryHeld)
        XCTAssertFalse(s.intentDisabled)
        XCTAssertTrue(d.builtinActive)
        XCTAssertEqual(d.operations, [false, true])
    }
}
