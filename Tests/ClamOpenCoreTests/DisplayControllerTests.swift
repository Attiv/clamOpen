import XCTest
@testable import ClamOpenCore

final class DisplayControllerTests: XCTestCase {

    // MARK: - 关闭 / 恢复

    func testAppleSiliconDisabledBuiltinDropsOfflineAndCanBeRestored() {
        let sys = FakeDisplaySystem(arch: .appleSilicon)
        let c = DisplayController(system: sys)

        XCTAssertEqual(c.disableBuiltin(), .ok)
        XCTAssertFalse(sys.onlineDisplays().contains(FakeDisplaySystem.builtinID),
                       "Apple Silicon 上被禁用的内置屏应从 online 列表消失")
        XCTAssertNil(c.builtinDisplay())
        XCTAssertFalse(c.isBuiltinActive())

        // 回归：以前只在 online 列表中找内置屏 → .noBuiltin，恢复失败
        XCTAssertEqual(c.enableBuiltin(), .ok)
        XCTAssertTrue(c.isBuiltinActive())
    }

    func testIntelDisabledBuiltinStaysOnlineButInactive() {
        let sys = FakeDisplaySystem(arch: .intel)
        let c = DisplayController(system: sys)

        XCTAssertEqual(c.disableBuiltin(), .ok)
        XCTAssertEqual(c.builtinDisplay(), FakeDisplaySystem.builtinID)
        XCTAssertFalse(c.isBuiltinActive())

        XCTAssertEqual(c.enableBuiltin(), .ok)
        XCTAssertTrue(c.isBuiltinActive())
    }

    func testRestoreFallsBackToLastSeenIDWhenFullListUnavailable() {
        let sys = FakeDisplaySystem(arch: .appleSilicon)
        sys.supportsFullList = false
        let c = DisplayController(system: sys)

        XCTAssertEqual(c.disableBuiltin(), .ok)   // 此时记住内置屏 ID
        XCTAssertEqual(c.enableBuiltin(), .ok)
        XCTAssertTrue(c.isBuiltinActive())
    }

    func testRestoreFailsWhenBuiltinWasNeverSeenAndFullListUnavailable() {
        let sys = FakeDisplaySystem(arch: .appleSilicon)
        sys.setBuiltinDisabledExternally()
        sys.supportsFullList = false
        let c = DisplayController(system: sys)

        XCTAssertEqual(c.enableBuiltin(), .noBuiltin)
    }

    func testEnableIsNoOpWhenBuiltinAlreadyActive() {
        let sys = FakeDisplaySystem()
        let c = DisplayController(system: sys)

        XCTAssertEqual(c.enableBuiltin(), .ok)
        XCTAssertTrue(sys.calls.isEmpty, "内置屏已活动时不应触发显示重配置")
    }

    // MARK: - 虚拟占位显示器

    func testPlaceholderIsNotCountedAsExternal() {
        let sys = FakeDisplaySystem(arch: .appleSilicon)
        let c = DisplayController(system: sys)
        c.disableBuiltin()
        sys.unplug()

        XCTAssertEqual(sys.onlineDisplays(), [FakeDisplaySystem.placeholderID])
        XCTAssertFalse(c.hasExternalDisplay(), "虚拟占位显示器不是外接显示器")
        XCTAssertEqual(c.externalDisplays(), [])
    }

    func testRestoreWhenBuiltinVanishedBehindPlaceholder() {
        // 回归（M1 Max 实测）：内置屏已禁用时拔掉外接，内置屏从所有列表中消失，只剩占位显示器
        let sys = FakeDisplaySystem(arch: .appleSilicon)
        let c = DisplayController(system: sys)
        c.disableBuiltin()
        sys.unplug()
        XCTAssertEqual(sys.allDisplays(), [FakeDisplaySystem.placeholderID])

        XCTAssertEqual(c.enableBuiltin(), .ok)
        XCTAssertTrue(c.isBuiltinActive())
        XCTAssertFalse(sys.showsPlaceholder)
    }

    func testRemembersDisabledBuiltinAtInit() {
        // App 启动时内置屏已被禁用（例如上次运行留下的），此时仍能从完整列表记住它的 ID
        let sys = FakeDisplaySystem(arch: .appleSilicon)
        sys.setBuiltinDisabledExternally()
        let c = DisplayController(system: sys)
        XCTAssertEqual(c.knownBuiltinID, FakeDisplaySystem.builtinID)

        sys.unplug()
        XCTAssertEqual(c.enableBuiltin(), .ok)
    }

    func testSavedBuiltinIDRestoresAfterRestartBehindPlaceholder() {
        // App 在“内置屏已禁用 + 外接已拔掉”的状态下重启：只能靠持久化的 ID 恢复
        let sys = FakeDisplaySystem(arch: .appleSilicon)
        sys.setBuiltinDisabledExternally()
        sys.unplug()

        XCTAssertEqual(DisplayController(system: sys).enableBuiltin(), .noBuiltin)

        let c = DisplayController(system: sys, knownBuiltinID: FakeDisplaySystem.builtinID)
        XCTAssertEqual(c.enableBuiltin(), .ok)
        XCTAssertTrue(c.isBuiltinActive())
    }

    // MARK: - 安全拦截

    func testDisableRefusedWithoutExternalDisplay() {
        let sys = FakeDisplaySystem(externals: 0)
        let c = DisplayController(system: sys)

        XCTAssertEqual(c.disableBuiltin(), .noExternal)
        XCTAssertTrue(sys.calls.isEmpty)
        XCTAssertTrue(c.isBuiltinActive())
    }

    func testDisableRefusedAfterExternalUnplugged() {
        let sys = FakeDisplaySystem()
        sys.unplug()
        let c = DisplayController(system: sys)

        XCTAssertEqual(c.disableBuiltin(), .noExternal)
        XCTAssertTrue(sys.calls.isEmpty)
    }

    func testAPIMissing() {
        let sys = FakeDisplaySystem()
        sys.canConfigure = false
        let c = DisplayController(system: sys)

        XCTAssertFalse(c.isAPIAvailable)
        XCTAssertEqual(c.disableBuiltin(), .apiMissing)
        sys.setBuiltinDisabledExternally()
        XCTAssertEqual(c.enableBuiltin(), .apiMissing)
        XCTAssertTrue(sys.calls.isEmpty)
    }

    func testMacWithoutBuiltinDisplay() {
        let sys = FakeDisplaySystem(hasBuiltin: false)
        let c = DisplayController(system: sys)

        XCTAssertEqual(c.disableBuiltin(), .noBuiltin)
        XCTAssertEqual(c.enableBuiltin(), .noBuiltin)
        XCTAssertFalse(c.isBuiltinActive())
    }

    func testLidClosedBuiltinCannotBeDisabled() {
        let sys = FakeDisplaySystem()
        sys.lidClosed = true
        let c = DisplayController(system: sys)

        XCTAssertEqual(c.disableBuiltin(), .noBuiltin)
        XCTAssertTrue(sys.calls.isEmpty)
    }

    // MARK: - 错误传递

    func testConfigurationErrorsArePropagated() {
        let sys = FakeDisplaySystem()
        let c = DisplayController(system: sys)

        sys.queuedFailures = [.completeFailed(1001)]
        XCTAssertEqual(c.disableBuiltin(), .completeFailed(1001))
        XCTAssertTrue(c.isBuiltinActive())

        XCTAssertEqual(c.disableBuiltin(), .ok)
        sys.queuedFailures = [.beginFailed(1000), .configureFailed(1004)]
        XCTAssertEqual(c.enableBuiltin(), .beginFailed(1000))
        XCTAssertEqual(c.enableBuiltin(), .configureFailed(1004))
        XCTAssertFalse(c.isBuiltinActive())
        XCTAssertEqual(c.enableBuiltin(), .ok)
    }

    // MARK: - 外接显示器

    func testExternalDisplaysExcludeBuiltin() {
        let sys = FakeDisplaySystem(externals: 2)
        let c = DisplayController(system: sys)

        XCTAssertEqual(c.externalDisplays(), [FakeDisplaySystem.externalID, FakeDisplaySystem.secondExternalID])
        XCTAssertTrue(c.hasExternalDisplay())

        sys.unplug(FakeDisplaySystem.externalID)
        XCTAssertEqual(c.externalDisplays(), [FakeDisplaySystem.secondExternalID])
        sys.unplug(FakeDisplaySystem.secondExternalID)
        XCTAssertFalse(c.hasExternalDisplay())
    }

    // MARK: - 文案

    func testResultMessages() {
        let all: [DisplayController.Result] = [
            .ok, .apiMissing, .noBuiltin, .noExternal,
            .beginFailed(1000), .configureFailed(1001), .completeFailed(1002),
        ]
        for r in all { XCTAssertFalse(r.message.isEmpty, "\(r)") }
        XCTAssertTrue(DisplayController.Result.beginFailed(1000).message.contains("1000"))
        XCTAssertTrue(DisplayController.Result.configureFailed(1001).message.contains("1001"))
        XCTAssertTrue(DisplayController.Result.completeFailed(1002).message.contains("1002"))
        XCTAssertTrue(DisplayController.Result.ok.isSuccess)
        XCTAssertFalse(DisplayController.Result.noExternal.isSuccess)
    }
}
