import AppKit
import ClamCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = DisplayController()
    private let powerManager = PowerManager()
    private var statusItem: NSStatusItem!

    private let recoveryLatch = FileRecoveryLatch()
    private lazy var safety = DisplaySafetyCoordinator(
        backend: controller, latch: recoveryLatch, log: RecoveryDiagnostics.record)
    private var hotKey: RecoveryHotKey?
    private var hotKeyAvailable = false
    private var terminating = false
    private var terminationDeadline: TimeInterval = 0
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 自动模式：检测到外接显示器自动关闭内置，拔掉自动恢复
    private var autoMode = false {
        didSet {
            UserDefaults.standard.set(autoMode, forKey: "autoMode")
            safety.autoMode = autoMode
        }
    }

    private var watchdog: Timer?

    /// CoreGraphics 显示重配置回调（拔插显示器时即时触发，比 NSNotification 更底层、更早）。
    /// 闭包不捕获 self，AppDelegate 通过 userInfo 指针传入。
    private let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }
        if flags.contains(.beginConfigurationFlag) { return }   // 配置开始阶段状态未稳定，跳过
        let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async { delegate.enforceSafety() }
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 仅菜单栏，无 Dock 图标
        autoMode = UserDefaults.standard.bool(forKey: "autoMode")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 底层显示重配置回调：拔外接的瞬间即时恢复内置屏（与上面的通知互为双保险）
        let registration = CGDisplayRegisterReconfigurationCallback(
            reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        if registration != .success {
            RecoveryDiagnostics.record("display callback registration failed: \(registration.rawValue)")
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(powerEvent(_:)), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(emergencyRequested), name: FileRecoveryLatch.notificationName,
            object: nil, suspensionBehavior: .deliverImmediately)
        hotKey = RecoveryHotKey { [weak self] in self?.enable() }
        hotKeyAvailable = hotKey?.register() == true
        RecoveryDiagnostics.record("ClamOpen started; auto=\(autoMode) hotkey=\(hotKeyAvailable); \(controller.snapshot())")

        startWatchdog()
        rebuildMenu()
        updateIcon()

        if !controller.isAPIAvailable {
            notify("当前系统不支持", "无法调用 CGSConfigureDisplayEnabled 私有接口。")
        } else {
            let snapshot = controller.snapshot()
            // A restarted app must not inherit an untracked disabled display.
            if !snapshot.builtinActive && !snapshot.screensAppearAsleep {
                safety.requestRecovery(now: now, forceAwake: false)
            }
            enforceSafety()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        safety.requestRecovery(now: now)
        if safety.recoveryStatus == .verified { return .terminateNow }
        terminating = true
        terminationDeadline = now + 12
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdog?.invalidate()
        hotKey?.unregister()
        CGDisplayRemoveReconfigurationCallback(reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        RecoveryDiagnostics.record("ClamOpen stopped; recovery=\(safety.recoveryStatus)")
    }

    // MARK: - 动作

    @objc private func disable() {
        let result = safety.disableByUser(now: now)
        if case .failed = result { notify("未关闭内置屏", result.message) }
        refresh()
    }

    @objc private func enable() {
        safety.requestRecovery(now: now)
        // No synchronous pmset/menu rebuild on the emergency path; retries need
        // the main run loop. The menu gets fresh state when it is next opened.
        updateIcon()
    }

    @objc private func toggleAuto() {
        let enabled = !autoMode
        let result = safety.setAutoModeByUser(enabled, now: now)
        autoMode = enabled
        if case .failed = result {
            notify("自动模式已开启，但暂不能关屏", result.message)
        }
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showPowerSettings() {
        let summary = powerManager.getPowerSettingsSummary()
        let needsOpt = powerManager.needsOptimization()

        let a = NSAlert()
        a.messageText = "电源管理 —— 防止休眠耗电"
        a.informativeText = """
        \(summary)

        \(needsOpt ? "\n⚠️ 检测到可能导致夜间耗电的设置。" : "\n✓ 当前设置已优化。")

        问题说明：
        TCP 保活会导致 Mac 在休眠时每分钟唤醒一次维护网络连接，
        造成电池在夜间快速耗尽。

        建议操作：
        • 禁用 TCP 保活、网络唤醒、靠近唤醒
        • 调整待机延迟为 1 小时（更省电）

        不影响正常使用：
        打开盖子、按键盘、点触控板等正常唤醒方式不受影响。
        """

        if needsOpt {
            a.addButton(withTitle: "应用省电设置（需管理员权限）")
            a.addButton(withTitle: "取消")
        } else {
            a.addButton(withTitle: "恢复默认设置")
            a.addButton(withTitle: "关闭")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = a.runModal()

        if response == .alertFirstButtonReturn {
            applyPowerOptimization(restore: !needsOpt)
        }
    }

    private func applyPowerOptimization(restore: Bool) {
        let result = restore ? powerManager.restoreDefaultSettings() : powerManager.applyPowerSavingSettings()

        let a = NSAlert()
        a.messageText = result.success ? "设置成功" : "设置失败"
        a.informativeText = result.message

        if result.success && !restore {
            a.informativeText += """


            已应用的优化：
            • TCP 保活：已禁用
            • 网络唤醒：已禁用
            • 靠近唤醒：已禁用
            • 待机延迟：1 小时（电池模式）

            明天早上可以检查效果：
            打开终端，运行以下命令查看昨晚的唤醒情况：
            pmset -g log | grep -E "DarkWake" | tail -20
            """
        }

        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()

        // 刷新菜单（更新电源设置状态）
        rebuildMenu()
    }

    // MARK: - 睡眠、唤醒与安全恢复（统一状态机）

    @objc private func screensChanged() { enforceSafety() }

    @objc private func powerEvent(_ notification: Notification) {
        RecoveryDiagnostics.record("workspace event: \(notification.name.rawValue)")
        switch notification.name {
        case NSWorkspace.willSleepNotification:
            safety.systemWillSleep()
        case NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification:
            safety.screensDidSleep()
        case NSWorkspace.didWakeNotification:
            safety.systemDidWake(now: now)
        case NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification:
            safety.screensDidWake(now: now)
        default: break
        }
        updateIcon()
    }

    @objc private func emergencyRequested() {
        DispatchQueue.main.async { [weak self] in self?.enable() }
    }

    func enforceSafety() {
        safety.tick(now: now)
        updateIcon()
        if terminating && (safety.recoveryStatus == .verified || safety.recoveryStatus == .failed
                           || now >= terminationDeadline) {
            RecoveryDiagnostics.record("quit recovery finished: \(safety.recoveryStatus)")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    private func startWatchdog() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.enforceSafety() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    // MARK: - UI

    private func refresh() {
        rebuildMenu()
        updateIcon()
    }

    private func updateIcon() {
        let off = !controller.snapshot().builtinActive
        let symbol = off ? "laptopcomputer.slash" : "laptopcomputer"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClamOpen") {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = off ? "▣" : "▢"
        }
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let snapshot = controller.snapshot()
        let externalCount = snapshot.displays.filter { !$0.builtin && $0.online }.count
        let hasExt = snapshot.hasUsableExternal

        // —— 状态信息 ——
        let statusText: String
        if !controller.isAPIAvailable {
            statusText = "⚠︎ 当前系统不支持"
        } else if safety.isSleeping {
            statusText = "等待显示器唤醒（暂停关屏）"
        } else if safety.recoveryStatus == .failed {
            statusText = "⚠︎ 未确认恢复，请再次急救"
        } else if safety.recoveryStatus == .recovering {
            statusText = "正在恢复内置屏…"
        } else if safety.isRecoveryHeld {
            statusText = "安全模式：保持内置屏开启"
        } else {
            statusText = snapshot.builtinActive ? "内置屏：开启中" : "内置屏：已关闭（仅外接）"
        }
        addInfo(menu, statusText)
        addInfo(menu, "外接：\(externalCount) 台在线，\(hasExt ? "可用" : "未确认已唤醒")")
        if let error = safety.lastError { addInfo(menu, error) }
        if safety.isRecoveryHeld { addInfo(menu, "主动关屏或重新开启自动模式可解除安全暂停") }
        menu.addItem(.separator())

        let disableItem = NSMenuItem(title: "关闭内置屏（只用外接）", action: #selector(disable), keyEquivalent: "d")
        disableItem.target = self
        disableItem.isEnabled = hasExt && controller.isAPIAvailable && !safety.isSleeping
            && safety.recoveryStatus != .recovering && !terminating
        menu.addItem(disableItem)

        let restoreTitle = hotKeyAvailable ? "紧急恢复内置屏（⌃⌥⌘R）" : "紧急恢复内置屏（快捷键不可用）"
        let restoreItem = NSMenuItem(title: restoreTitle, action: #selector(enable), keyEquivalent: "e")
        restoreItem.target = self
        menu.addItem(restoreItem)
        menu.addItem(.separator())

        // —— 自动模式 ——
        let autoTitle = autoMode && safety.isRecoveryHeld
            ? "自动：已暂停（关闭后重新开启可恢复）" : "自动：接外接关、拔掉恢复"
        let auto = NSMenuItem(title: autoTitle,
                              action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = autoMode ? .on : .off
        auto.isEnabled = !terminating
        menu.addItem(auto)

        menu.addItem(.separator())

        // —— 电源管理 ——
        let needsOpt = powerManager.needsOptimization()
        let powerTitle = needsOpt ? "⚠️ 电源管理（夜间耗电优化）" : "电源管理"
        let powerItem = NSMenuItem(title: powerTitle, action: #selector(showPowerSettings), keyEquivalent: "")
        powerItem.target = self
        menu.addItem(powerItem)

        menu.addItem(.separator())

        // —— 其它 ——
        let about = NSMenuItem(title: "关于 / 如何恢复", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quitItem = NSMenuItem(title: "退出（自动恢复内置屏）",
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "ClamOpen — 开盖合盖"
        a.informativeText = """
        盖子开着也能只用外接显示器（等效合盖）。

        原理：调用 CoreGraphics 私有接口 CGSConfigureDisplayEnabled，
        关闭内置面板的渲染与背光。

        安全保障：
        • 没有外接显示器时不会关闭内置屏
        • 拔掉外接显示器会自动恢复内置屏
        • 唤醒或急救后保持内置屏开启，直到你主动关屏或重新开启自动模式
        • 退出时尝试恢复并验证，失败会记录日志

        万一屏幕异常 / 全黑：
        按 Control + Option + Command + R，或启动「恢复内置屏」。
        全局快捷键需要主程序运行；锁屏/登录界面不保证可用。
        独立恢复 App 不依赖主程序运行；两者都不能修复系统/GPU 硬死机。

        诊断日志：运行项目 scripts/diagnose_wake.sh。
        """
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func notify(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}
