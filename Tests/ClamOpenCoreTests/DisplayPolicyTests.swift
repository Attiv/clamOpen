import XCTest
@testable import ClamOpenCore

final class DisplayPolicyTests: XCTestCase {

    private func make(arch: FakeDisplaySystem.Arch = .appleSilicon,
                      externals: Int = 1,
                      autoMode: Bool = false) -> (FakeDisplaySystem, DisplayPolicy) {
        let sys = FakeDisplaySystem(arch: arch, externals: externals)
        let policy = DisplayPolicy(controller: DisplayController(system: sys),
                                   autoMode: autoMode,
                                   reassertDisabledState: arch == .intel)
        return (sys, policy)
    }

    /// 连续执行多次 watchdog（模拟一段时间过去）
    private func tick(_ policy: DisplayPolicy, times: Int = 5) {
        for _ in 0..<times { policy.watchdogTick() }
    }

    // MARK: - 手动开关

    func testManualDisableAndRestore() {
        for arch in [FakeDisplaySystem.Arch.appleSilicon, .intel] {
            let (sys, policy) = make(arch: arch)

            XCTAssertEqual(policy.disable(), .ok)
            XCTAssertTrue(policy.intentDisabled)
            XCTAssertFalse(sys.builtinEnabled)
            XCTAssertTrue(policy.isBuiltinOff)

            XCTAssertEqual(policy.enable(), .ok, "\(arch)")
            XCTAssertFalse(policy.intentDisabled)
            XCTAssertTrue(sys.builtinEnabled)
            XCTAssertFalse(policy.isBuiltinOff)
        }
    }

    func testManualDisableRefusedWithoutExternal() {
        let (sys, policy) = make(externals: 0)

        XCTAssertEqual(policy.disable(), .noExternal)
        XCTAssertFalse(policy.intentDisabled)
        XCTAssertTrue(sys.builtinEnabled)
    }

    func testManualRestoreFailureKeepsIntent() {
        let (sys, policy) = make()
        policy.disable()

        sys.queuedFailures = [.completeFailed(1001)]
        XCTAssertEqual(policy.enable(), .completeFailed(1001))
        XCTAssertTrue(policy.intentDisabled, "恢复失败时菜单应继续显示“恢复内置屏”")
        XCTAssertEqual(policy.enable(), .ok)
        XCTAssertFalse(policy.intentDisabled)
    }

    // MARK: - 拔掉外接 → 安全恢复

    func testUnplugRestoresBuiltinOnAppleSilicon() {
        // 回归：Apple Silicon 上拔掉外接后内置屏不会回来
        let (sys, policy) = make(arch: .appleSilicon)
        policy.disable()

        sys.unplug()
        policy.displaysChanged()

        XCTAssertTrue(sys.builtinEnabled)
        XCTAssertFalse(policy.intentDisabled)
    }

    func testUnplugRestoresBuiltinBehindPlaceholderInAutoMode() {
        // 回归（M1 Max 实测）：拔掉外接后 WindowServer 插入虚拟占位显示器，
        // App 把它当成外接，内置屏一直不恢复
        let (sys, policy) = make(arch: .appleSilicon, autoMode: true)
        policy.start()
        XCTAssertFalse(sys.builtinEnabled)

        sys.unplug()
        XCTAssertTrue(sys.showsPlaceholder)
        policy.displaysChanged()

        XCTAssertTrue(sys.builtinEnabled)
        XCTAssertFalse(policy.intentDisabled)
    }

    func testUnplugRestoresBehindPlaceholderViaWatchdogOnly() {
        let (sys, policy) = make(arch: .appleSilicon)
        policy.disable()

        sys.unplug()
        policy.watchdogTick()

        XCTAssertTrue(sys.builtinEnabled)
    }

    func testUnplugRestoresBuiltinOnIntel() {
        let (sys, policy) = make(arch: .intel)
        policy.disable()

        sys.unplug()
        policy.displaysChanged()

        XCTAssertTrue(sys.builtinEnabled)
    }

    func testWatchdogRestoresWhenReconfigurationEventIsMissed() {
        let (sys, policy) = make()
        policy.disable()

        sys.unplug()                                  // 没有收到任何显示器变化事件
        XCTAssertTrue(policy.watchdogTick(), "状态变化时应通知刷新 UI")
        XCTAssertTrue(sys.builtinEnabled)
    }

    func testFailedRestoreIsRetriedByWatchdog() {
        let (sys, policy) = make()
        policy.disable()

        sys.unplug()
        sys.queuedFailures = [.completeFailed(1001), .completeFailed(1001)]
        policy.displaysChanged()
        XCTAssertFalse(sys.builtinEnabled)
        XCTAssertTrue(policy.intentDisabled, "恢复失败时必须保留意图以便重试")

        policy.watchdogTick()
        XCTAssertFalse(sys.builtinEnabled)
        policy.watchdogTick()
        XCTAssertTrue(sys.builtinEnabled)
        XCTAssertFalse(policy.intentDisabled)
    }

    func testUnplugOneOfTwoExternalsKeepsBuiltinOff() {
        let (sys, policy) = make(externals: 2)
        policy.disable()

        sys.unplug(FakeDisplaySystem.externalID)
        policy.displaysChanged()
        tick(policy)
        XCTAssertFalse(sys.builtinEnabled, "仍有一台外接时不应恢复内置屏")

        sys.unplug(FakeDisplaySystem.secondExternalID)
        policy.displaysChanged()
        XCTAssertTrue(sys.builtinEnabled)
    }

    // MARK: - 自动模式

    func testAutoModeDisablesOnStartWithExternal() {
        let (sys, policy) = make(autoMode: true)
        policy.start()

        XCTAssertFalse(sys.builtinEnabled)
        XCTAssertTrue(policy.intentDisabled)
    }

    func testAutoModePlugUnplugCycle() {
        let (sys, policy) = make(externals: 0, autoMode: true)
        policy.start()
        XCTAssertTrue(sys.builtinEnabled)

        for _ in 0..<3 {
            sys.plug()
            policy.displaysChanged()
            XCTAssertFalse(sys.builtinEnabled, "接上外接应自动关闭内置屏")

            sys.unplug()
            policy.displaysChanged()
            XCTAssertTrue(sys.builtinEnabled, "拔掉外接应自动恢复内置屏")
        }
    }

    func testManualRestoreSticksInAutoMode() {
        // 回归：自动模式每 1.5 s 重新关闭内置屏，手动“恢复内置屏”无效
        let (sys, policy) = make(autoMode: true)
        policy.start()
        XCTAssertFalse(sys.builtinEnabled)

        policy.enable()
        policy.displaysChanged()
        tick(policy, times: 20)

        XCTAssertTrue(sys.builtinEnabled)
        XCTAssertFalse(policy.intentDisabled)
    }

    func testAutoModeResumesAfterReplugFollowingManualRestore() {
        let (sys, policy) = make(autoMode: true)
        policy.start()
        policy.enable()

        sys.unplug()
        policy.displaysChanged()
        sys.plug()
        policy.displaysChanged()

        XCTAssertFalse(sys.builtinEnabled, "重新插上外接后自动模式应再次生效")
    }

    func testAutoModeRetriesWhenDisableFailsRightAfterPlug() {
        let (sys, policy) = make(externals: 0, autoMode: true)
        policy.start()

        sys.plug()
        sys.queuedFailures = [.completeFailed(1001)]   // 刚插上时显示配置尚未稳定
        policy.displaysChanged()
        XCTAssertTrue(sys.builtinEnabled)

        policy.watchdogTick()
        XCTAssertFalse(sys.builtinEnabled)
        XCTAssertTrue(policy.intentDisabled)
    }

    func testEnablingAutoModeWithExternalDisablesImmediately() {
        let (sys, policy) = make()
        policy.start()
        XCTAssertTrue(sys.builtinEnabled)

        policy.setAutoMode(true)
        XCTAssertFalse(sys.builtinEnabled)
    }

    func testDisablingAutoModeCancelsPendingDisable() {
        let (sys, policy) = make()
        sys.queuedFailures = [.completeFailed(1001)]
        policy.setAutoMode(true)                        // 关闭失败 → 待重试
        policy.setAutoMode(false)
        tick(policy)

        XCTAssertTrue(sys.builtinEnabled, "关闭自动模式后不应再自动关闭内置屏")
    }

    func testAutoModeOffDoesNothingOnPlug() {
        let (sys, policy) = make(externals: 0)
        policy.start()

        sys.plug()
        policy.displaysChanged()
        tick(policy)

        XCTAssertTrue(sys.builtinEnabled)
        XCTAssertTrue(sys.calls.isEmpty)
    }

    // MARK: - 合盖（clamshell）

    func testAutoModeWithLidClosedDisablesAfterLidOpens() {
        let (sys, policy) = make(externals: 0, autoMode: true)
        policy.start()

        sys.lidClosed = true
        sys.plug()
        policy.displaysChanged()
        tick(policy)
        XCTAssertTrue(sys.calls.isEmpty, "合盖时不应尝试关闭内置屏")

        sys.lidClosed = false
        policy.displaysChanged()
        XCTAssertFalse(sys.builtinEnabled, "开盖后自动模式应关闭内置屏")
    }

    func testLidClosedWithExternalIsLeftAlone() {
        let (sys, policy) = make()
        sys.lidClosed = true
        policy.start()
        policy.displaysChanged()
        tick(policy, times: 20)
        policy.prepareForQuit()

        XCTAssertTrue(sys.calls.isEmpty)
    }

    func testWatchdogDoesNotChurnWithLidClosedAndNoExternal() {
        let (sys, policy) = make(externals: 0, autoMode: true)
        policy.start()
        sys.lidClosed = true
        sys.resetCalls()

        tick(policy, times: 20)

        XCTAssertTrue(sys.calls.isEmpty, "合盖休眠期间 watchdog 不应反复重配置显示器")
    }

    // MARK: - Intel 偶发唤醒

    func testWatchdogReDisablesSpontaneouslyWokenBuiltin() {
        let (sys, policy) = make(arch: .intel)
        policy.disable()

        sys.spontaneouslyWakeBuiltin()
        XCTAssertTrue(policy.watchdogTick())
        XCTAssertFalse(sys.builtinEnabled)
        XCTAssertTrue(policy.intentDisabled)
    }

    func testExternalRestoreIsRespectedOnAppleSilicon() {
        // 回归：用 ClamRestore / 其他工具恢复内置屏后，App 在 1.5 s 内又把它关掉
        let (sys, policy) = make(arch: .appleSilicon, autoMode: true)
        policy.start()
        XCTAssertFalse(sys.builtinEnabled)

        sys.spontaneouslyWakeBuiltin()                  // 外部恢复
        policy.displaysChanged()
        tick(policy, times: 20)

        XCTAssertTrue(sys.builtinEnabled)
        XCTAssertFalse(policy.intentDisabled)
    }

    func testWatchdogDoesNotDisableAfterManualRestore() {
        let (sys, policy) = make(arch: .intel)
        policy.disable()
        policy.enable()
        sys.resetCalls()

        tick(policy)

        XCTAssertTrue(sys.builtinEnabled)
        XCTAssertTrue(sys.calls.isEmpty)
    }

    // MARK: - 启动 / 退出

    func testQuitRestoresBuiltinWhenDisabledByApp() {
        let (sys, policy) = make()
        policy.disable()

        policy.prepareForQuit()
        XCTAssertTrue(sys.builtinEnabled)
    }

    func testQuitDoesNothingWhenNotDisabledByApp() {
        let (sys, policy) = make()
        policy.prepareForQuit()
        XCTAssertTrue(sys.calls.isEmpty)
    }

    func testStartRestoresBlackScreenLeftByPreviousRun() {
        // 上次运行关闭了内置屏，App 重启后丢失意图，且外接已拔掉 → 整个屏幕是黑的
        let (sys, policy) = make(externals: 0)
        sys.setBuiltinDisabledExternally()

        policy.start()
        XCTAssertTrue(sys.builtinEnabled)
    }

    func testUnplugRestoresBuiltinDisabledByPreviousRun() {
        let (sys, policy) = make()
        sys.setBuiltinDisabledExternally()
        policy.start()
        XCTAssertFalse(sys.builtinEnabled, "有外接时保持现状")

        sys.unplug()
        policy.displaysChanged()
        XCTAssertTrue(sys.builtinEnabled, "即使没有关闭意图，拔掉外接后也必须恢复，避免全黑")
    }

    func testStartWithoutAPIDoesNothing() {
        let (sys, policy) = make(autoMode: true)
        sys.canConfigure = false

        policy.start()
        XCTAssertTrue(sys.calls.isEmpty)
        XCTAssertTrue(sys.builtinEnabled)
    }

    // MARK: - watchdog 返回值

    func testWatchdogReportsNoChangeWhenIdle() {
        let (_, policy) = make(autoMode: true)
        policy.start()

        XCTAssertFalse(policy.watchdogTick())
        XCTAssertFalse(policy.watchdogTick())
    }
}
