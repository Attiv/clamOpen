import CoreGraphics
import Foundation

/// 封装对内置 / 外接显示器的启用、禁用与查询。
///
/// 通过 CoreGraphics 私有符号 `CGSConfigureDisplayEnabled` 真正关闭内置面板
/// （停止渲染 + 关闭背光），效果等同合盖（clamshell），但盖子保持打开。
public final class DisplayController {

    private let system: DisplaySystem

    /// 最近一次见到的内置屏 ID（兜底：禁用后枚举不到时仍能恢复）
    private var lastBuiltinID: CGDirectDisplayID?

    /// - Parameter knownBuiltinID: 上次运行时记住的内置屏 ID（App 重启后仍能恢复）
    public init(system: DisplaySystem = CGDisplaySystem(), knownBuiltinID: CGDirectDisplayID? = nil) {
        self.system = system
        self.lastBuiltinID = knownBuiltinID
        rememberBuiltin()
    }

    /// 已知的内置屏 ID（供持久化）
    public var knownBuiltinID: CGDirectDisplayID? { lastBuiltinID }

    /// 趁内置屏还能枚举到时记住它的 ID：
    /// 内置屏已禁用且拔掉外接后，它会从所有列表中消失（只剩虚拟占位显示器）
    private func rememberBuiltin() {
        if let id = system.onlineDisplays().first(where: { system.isBuiltin($0) })
            ?? system.allDisplays()?.first(where: { system.isBuiltin($0) }) {
            lastBuiltinID = id
        }
    }

    /// 私有 API 是否可用（理论上所有现代 macOS 都可用）
    public var isAPIAvailable: Bool { system.canConfigure }

    // MARK: - 查询

    public func onlineDisplays() -> [CGDirectDisplayID] {
        system.onlineDisplays()
    }

    /// 在线的内置屏（可被关闭的那个）
    public func builtinDisplay() -> CGDirectDisplayID? {
        let id = onlineDisplays().first { system.isBuiltin($0) }
        if let id { lastBuiltinID = id }
        return id
    }

    /// 内置屏 ID，即使当前已被禁用（用于恢复）。
    /// Apple Silicon 上内置屏被禁用后会从 online 列表中消失，只能从完整列表中找回。
    func builtinDisplayIncludingDisabled() -> CGDirectDisplayID? {
        if let id = builtinDisplay() { return id }
        if let id = system.allDisplays()?.first(where: { system.isBuiltin($0) }) {
            lastBuiltinID = id
            return id
        }
        return lastBuiltinID
    }

    /// 在线的外接显示器（非内置、非虚拟占位）
    public func externalDisplays() -> [CGDirectDisplayID] {
        rememberBuiltin()
        return onlineDisplays().filter { !system.isBuiltin($0) && !system.isVirtualPlaceholder($0) }
    }

    public func hasExternalDisplay() -> Bool { !externalDisplays().isEmpty }

    /// 内置屏当前是否处于活动（渲染）状态
    public func isBuiltinActive() -> Bool {
        guard let b = builtinDisplay() else { return false }
        return system.isActive(b)
    }

    // MARK: - 操作结果

    public enum Result: Equatable {
        case ok
        case apiMissing
        case noBuiltin
        case noExternal           // 安全拦截：没有外接显示器，拒绝关闭内置（否则全黑无法操作）
        case beginFailed(Int32)
        case configureFailed(Int32)
        case completeFailed(Int32)

        public var isSuccess: Bool { self == .ok }

        public var message: String {
            switch self {
            case .ok:                   return tr("Success", "成功")
            case .apiMissing:           return tr("This API is not supported on this system", "当前系统不支持该接口")
            case .noBuiltin:            return tr("No internal display found", "未找到内置显示器")
            case .noExternal:           return tr("No external display — refused (the screen would go black)", "没有外接显示器，已拒绝（否则会全黑）")
            case .beginFailed(let e):   return tr("Failed to begin configuration (CGError \(e))", "开始配置失败 (CGError \(e))")
            case .configureFailed(let e): return tr("Failed to configure display (CGError \(e))", "设置失败 (CGError \(e))")
            case .completeFailed(let e):  return tr("Failed to apply configuration (CGError \(e))", "应用配置失败 (CGError \(e))")
            }
        }
    }

    // MARK: - 操作

    /// 关闭内置屏。**仅当存在在线外接显示器时**才会执行，否则返回 `.noExternal`。
    @discardableResult
    public func disableBuiltin() -> Result {
        guard isAPIAvailable else { return .apiMissing }
        guard let builtin = builtinDisplay() else { return .noBuiltin }
        guard hasExternalDisplay() else { return .noExternal }
        return system.setEnabled(builtin, false)
    }

    /// 恢复内置屏（也能找回已被禁用、不在 online 列表中的内置屏）
    @discardableResult
    public func enableBuiltin() -> Result {
        guard isAPIAvailable else { return .apiMissing }
        if isBuiltinActive() { return .ok }
        guard let builtin = builtinDisplayIncludingDisabled() else { return .noBuiltin }
        return system.setEnabled(builtin, true)
    }
}
