import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = DisplayController()
    private let powerManager = PowerManager()
    private var statusItem: NSStatusItem!

    /// 当前“意图”：用户或自动逻辑希望内置屏保持关闭
    private var intentDisabled = false

    /// 自动模式：检测到外接显示器自动关闭内置，拔掉自动恢复
    private var autoMode = false {
        didSet { UserDefaults.standard.set(autoMode, forKey: "autoMode") }
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
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 底层显示重配置回调：拔外接的瞬间即时恢复内置屏（与上面的通知互为双保险）
        CGDisplayRegisterReconfigurationCallback(
            reconfigCallback, Unmanaged.passUnretained(self).toOpaque())

        startWatchdog()
        rebuildMenu()
        updateIcon()

        if !controller.isAPIAvailable {
            notify("当前系统不支持", "无法调用 CGSConfigureDisplayEnabled 私有接口。")
        } else if autoMode {
            evaluateAuto()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前务必恢复内置屏，避免用户退出后找不到开关
        if intentDisabled { controller.enableBuiltin() }
    }

    // MARK: - 动作

    @objc private func disable() {
        let r = controller.disableBuiltin()
        switch r {
        case .ok:
            intentDisabled = true
        case .noExternal:
            notify("无法关闭内置屏", "请先连接外接显示器，否则屏幕会全黑、无法操作。")
        default:
            notify("关闭失败", r.message)
        }
        refresh()
    }

    @objc private func enable() {
        controller.enableBuiltin()
        intentDisabled = false
        refresh()
    }

    @objc private func toggleAuto() {
        autoMode.toggle()
        if autoMode { evaluateAuto() }
        refresh()
    }

    @objc private func quit() {
        if intentDisabled { controller.enableBuiltin() }
        NSApp.terminate(nil)
    }

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

    // MARK: - 自动模式 & 安全恢复

    @objc private func screensChanged() {
        enforceSafety()
    }

    /// 安全收敛：任何显示器变化后调用。
    /// 硬规则：处于关闭意图但已无外接 → 立即恢复内置屏，杜绝全黑死局。
    func enforceSafety() {
        if intentDisabled && !controller.hasExternalDisplay() {
            controller.enableBuiltin()
            intentDisabled = false
        } else if autoMode {
            evaluateAuto()
        }
        refresh()
    }

    private func evaluateAuto() {
        guard autoMode else { return }
        if controller.hasExternalDisplay() {
            if controller.isBuiltinActive(), controller.disableBuiltin() == .ok {
                intentDisabled = true
            }
        } else if intentDisabled || !controller.isBuiltinActive() {
            controller.enableBuiltin()
            intentDisabled = false
        }
    }

    private func startWatchdog() {
        // 用 .common 模式，确保菜单打开时也持续运行
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }

            // 1) 安全恢复：意图关闭却已无外接
            if self.intentDisabled && !self.controller.hasExternalDisplay() {
                self.controller.enableBuiltin()
                self.intentDisabled = false
                self.refresh()
                return
            }
            // 2) Intel 偶发唤醒：意图关闭但内置又被点亮 → 重新关闭
            if self.intentDisabled && self.controller.hasExternalDisplay()
                && self.controller.isBuiltinActive() {
                self.controller.disableBuiltin()
                self.updateIcon()
            }
            // 3) 自动模式常态评估
            if self.autoMode { self.evaluateAuto() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    // MARK: - UI

    private func refresh() {
        rebuildMenu()
        updateIcon()
    }

    private func updateIcon() {
        let off = intentDisabled || !controller.isBuiltinActive()
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

        let hasExt = controller.hasExternalDisplay()
        let builtinActive = controller.isBuiltinActive()

        // —— 状态信息 ——
        let statusText: String
        if !controller.isAPIAvailable {
            statusText = "⚠︎ 当前系统不支持"
        } else if !builtinActive && intentDisabled {
            statusText = "内置屏：已关闭（仅外接）"
        } else {
            statusText = "内置屏：开启中"
        }
        addInfo(menu, statusText)
        addInfo(menu, hasExt ? "外接显示器：\(controller.externalDisplays().count) 台已连接"
                             : "外接显示器：未连接")

        menu.addItem(.separator())

        // —— 主开关 ——
        if builtinActive {
            let item = NSMenuItem(title: "关闭内置屏（只用外接）",
                                  action: #selector(disable), keyEquivalent: "d")
            item.target = self
            item.isEnabled = hasExt && controller.isAPIAvailable
            if !hasExt { item.toolTip = "需要先连接外接显示器" }
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "恢复内置屏",
                                  action: #selector(enable), keyEquivalent: "e")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // —— 自动模式 ——
        let auto = NSMenuItem(title: "自动：接外接关、拔掉恢复",
                              action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = autoMode ? .on : .off
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
        • 退出本 App 会自动恢复内置屏

        万一屏幕异常 / 全黑：
        拔掉外接显示器，或注销、重启 Mac 即可恢复（设置只在本次登录会话生效）。
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
