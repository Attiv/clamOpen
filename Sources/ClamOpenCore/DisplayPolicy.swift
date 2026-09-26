import Foundation

/// 内置屏开关的状态机：手动开关、自动模式、安全恢复与 watchdog 逻辑。
/// 不依赖 AppKit，便于单元测试；AppDelegate 只负责 UI 与事件转发。
public final class DisplayPolicy {

    public let controller: DisplayController

    /// 当前“意图”：用户或自动逻辑希望内置屏保持关闭
    public private(set) var intentDisabled = false

    /// 自动模式：接上外接显示器时自动关闭内置，拔掉自动恢复
    public private(set) var autoMode: Bool

    /// 自动模式只在外接显示器插拔时动作，手动“恢复内置屏”后不会被立刻再次关闭
    private var lastHasExternal: Bool?
    /// 刚接上外接、尚未成功关闭内置屏（关闭失败或盖子合上时由 watchdog 重试）
    private var autoDisablePending = false

    /// 意图关闭时内置屏又被点亮：true → 重新关闭（Intel 上系统偶尔会自行点亮内置屏）；
    /// false → 视为被外部恢复（ClamRestore、其他工具等），接受并放弃关闭意图（Apple Silicon）
    private let reassertDisabledState: Bool

    public init(controller: DisplayController,
                autoMode: Bool = false,
                reassertDisabledState: Bool = DisplayPolicy.isIntel) {
        self.controller = controller
        self.autoMode = autoMode
        self.reassertDisabledState = reassertDisabledState
    }

    public static var isIntel: Bool {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }

    /// 菜单栏图标是否显示为“内置屏已关闭”
    public var isBuiltinOff: Bool { intentDisabled || !controller.isBuiltinActive() }

    // MARK: - 生命周期

    /// App 启动：自动模式下按当前状态立即评估
    public func start() {
        guard controller.isAPIAvailable else { return }
        restoreIfNoScreenVisible()
        if autoMode { evaluateAuto(force: true) }
    }

    /// 退出前务必恢复内置屏，避免用户退出后找不到开关
    public func prepareForQuit() {
        if intentDisabled { restoreBuiltin() }
    }

    // MARK: - 用户动作

    /// 手动关闭内置屏
    @discardableResult
    public func disable() -> DisplayController.Result {
        let r = controller.disableBuiltin()
        if r == .ok { intentDisabled = true }
        return r
    }

    /// 手动恢复内置屏：自动模式不会立刻再次关闭它
    @discardableResult
    public func enable() -> DisplayController.Result {
        autoDisablePending = false
        let r = controller.enableBuiltin()
        if r == .ok { intentDisabled = false }
        return r
    }

    public func setAutoMode(_ on: Bool) {
        autoMode = on
        if on { evaluateAuto(force: true) } else { autoDisablePending = false }
    }

    // MARK: - 事件

    /// 安全收敛：任何显示器变化后调用。
    /// 硬规则：处于关闭意图但已无外接 → 立即恢复内置屏，杜绝全黑死局。
    public func displaysChanged() {
        if intentDisabled && !controller.hasExternalDisplay() {
            restoreBuiltin()
        } else {
            restoreIfNoScreenVisible()
        }
        if autoMode { evaluateAuto() }
    }

    /// 定时巡检（每 1.5 s），返回状态是否有变化（需要刷新 UI）
    @discardableResult
    public func watchdogTick() -> Bool {
        let before = (intentDisabled, controller.isBuiltinActive())

        // 1) 安全恢复：意图关闭却已无外接
        if intentDisabled && !controller.hasExternalDisplay() {
            restoreBuiltin()
        }
        // 2) 意图关闭但内置又被点亮：Intel 偶发唤醒 → 重新关闭；否则视为被外部恢复
        else if intentDisabled && controller.isBuiltinActive() {
            if reassertDisabledState {
                controller.disableBuiltin()
            } else {
                intentDisabled = false
            }
        }
        // 3) 自动模式：处理插拔与待重试的关闭
        if autoMode { evaluateAuto() }

        return before != (intentDisabled, controller.isBuiltinActive())
    }

    // MARK: - 内部

    /// 没有外接、内置屏也不活动（例如上次运行时被关闭、App 重启后丢失了意图）→ 恢复，避免全黑。
    /// 只在事件驱动时调用，不放进 watchdog，避免合盖休眠时反复重配置。
    private func restoreIfNoScreenVisible() {
        if !controller.hasExternalDisplay() && !controller.isBuiltinActive() {
            restoreBuiltin()
        }
    }

    /// 恢复内置屏；失败时保留关闭意图，由 watchdog 继续重试
    private func restoreBuiltin() {
        if controller.enableBuiltin() == .ok { intentDisabled = false }
    }

    /// - Parameter force: 启动 / 开启自动模式时为 true，按当前状态立即评估
    private func evaluateAuto(force: Bool = false) {
        guard autoMode else { return }
        let hasExt = controller.hasExternalDisplay()
        if force || hasExt != lastHasExternal {
            autoDisablePending = hasExt
            if !hasExt, intentDisabled || !controller.isBuiltinActive() {
                restoreBuiltin()
            }
        }
        lastHasExternal = hasExt

        // 内置屏不活动时（例如接外接时盖子是合上的）保留待关闭状态，开盖后再关闭；
        // 只有关闭成功、拔掉外接或用户手动恢复才会清除
        if autoDisablePending && hasExt && controller.isBuiltinActive() {
            if controller.disableBuiltin() == .ok {
                intentDisabled = true
                autoDisablePending = false
            }
        }
    }
}
