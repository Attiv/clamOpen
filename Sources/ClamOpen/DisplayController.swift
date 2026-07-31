import AppKit
import CoreGraphics
import Foundation

/// 封装对内置 / 外接显示器的启用、禁用与查询。
///
/// 通过 CoreGraphics 私有符号 `CGSConfigureDisplayEnabled` 真正关闭内置面板
/// （停止渲染 + 关闭背光），效果等同合盖（clamshell），但盖子保持打开。
final class DisplayController {

    /// CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool)
    typealias ConfigureDisplayEnabledFn =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    /// CGError CGSGetDisplayList(UInt32, CGDirectDisplayID*, UInt32*)
    typealias GetDisplayListFn =
        @convention(c) (
            UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?
        ) -> CGError

    private let configureEnabled: ConfigureDisplayEnabledFn?
    private let getDisplayList: GetDisplayListFn?

    private var cachedBuiltinDisplayID: CGDirectDisplayID?
    private let builtinIDKey = "BuiltinDisplayID"

    init() {
        // RTLD_DEFAULT (== -2)：符号随 CoreGraphics 已载入本进程，直接取即可
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        if let sym = dlsym(rtldDefault, "CGSConfigureDisplayEnabled") {
            configureEnabled = unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
        } else {
            configureEnabled = nil
        }
        if let sym = dlsym(rtldDefault, "CGSGetDisplayList") {
            getDisplayList = unsafeBitCast(sym, to: GetDisplayListFn.self)
        } else {
            getDisplayList = nil
        }
    }

    /// 私有 API 是否可用（理论上所有现代 macOS 都可用）
    var isAPIAvailable: Bool { configureEnabled != nil }

    // MARK: - 查询

    func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    func allDisplays() -> [CGDirectDisplayID] {
        if let fn = getDisplayList {
            var count: UInt32 = 0
            if fn(0, nil, &count) == .success, count > 0 {
                var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
                if fn(count, &ids, &count) == .success {
                    return Array(ids.prefix(Int(count)))
                }
            }
        }
        return onlineDisplays()
    }

    func builtinDisplay() -> CGDirectDisplayID? {
        // 1. 内存缓存
        if let cached = cachedBuiltinDisplayID {
            return cached
        }

        // 2. UserDefaults 持久化（足够用了）
        if let backup = UserDefaults.standard.object(forKey: builtinIDKey) as? Int {
            cachedBuiltinDisplayID = CGDirectDisplayID(backup)
            return cachedBuiltinDisplayID
        }

        // 3. 实时查询并缓存
        if let builtin = allDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            cachedBuiltinDisplayID = builtin
            UserDefaults.standard.set(Int(builtin), forKey: builtinIDKey)
            return builtin
        }

        // 4. Fallback: 方式2 - NSScreen.screens（只能找到启用的显示器，但更稳定）
        var seenIDs = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID,
                !seenIDs.contains(displayID)
            else { continue }

            seenIDs.insert(displayID)

            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            if isBuiltin {
                cachedBuiltinDisplayID = displayID
                UserDefaults.standard.set(Int(displayID), forKey: builtinIDKey)
                return displayID
            }
        }

        return nil
    }

    /// 外接显示器（非内置且在 NSScreen.screens 中）
    func externalDisplays() -> [CGDirectDisplayID] {
        var externals: [CGDirectDisplayID] = []
        var seenIDs = Set<CGDirectDisplayID>()

        for screen in NSScreen.screens {
            guard
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID,
                !seenIDs.contains(displayID)
            else { continue }

            seenIDs.insert(displayID)

            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let name = screen.localizedName.trimmingCharacters(in: .whitespaces)

            // 排除内置显示器和空名称的显示器（"ghost display"）
            if !isBuiltin && !name.isEmpty {
                externals.append(displayID)
            }
        }

        return externals
    }

    func hasExternalDisplay() -> Bool { !externalDisplays().isEmpty }

    /// 内置屏当前是否处于活动（渲染）状态
    func isBuiltinActive() -> Bool {
        guard let b = builtinDisplay() else { return false }
        return CGDisplayIsActive(b) != 0
    }

    // MARK: - 操作结果

    enum Result: Equatable {
        case ok
        case apiMissing
        case noBuiltin
        case noExternal  // 安全拦截：没有外接显示器，拒绝关闭内置（否则全黑无法操作）
        case beginFailed(Int32)
        case configureFailed(Int32)
        case completeFailed(Int32)

        var isSuccess: Bool { self == .ok }

        var message: String {
            switch self {
            case .ok: return "成功"
            case .apiMissing: return "当前系统不支持该接口"
            case .noBuiltin: return "未找到内置显示器"
            case .noExternal: return "没有外接显示器，已拒绝（否则会全黑）"
            case .beginFailed(let e): return "开始配置失败 (CGError \(e))"
            case .configureFailed(let e): return "设置失败 (CGError \(e))"
            case .completeFailed(let e): return "应用配置失败 (CGError \(e))"
            }
        }
    }

    // MARK: - 操作

    /// 关闭内置屏。**仅当存在在线外接显示器时**才会执行，否则返回 `.noExternal`。
    @discardableResult
    func disableBuiltin() -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        guard let builtin = builtinDisplay() else { return .noBuiltin }
        guard hasExternalDisplay() else { return .noExternal }
        return apply(fn, display: builtin, enabled: false)
    }

    /// 恢复内置屏
    @discardableResult
    func enableBuiltin() -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        guard let builtin = builtinDisplay() else { return .noBuiltin }
        return apply(fn, display: builtin, enabled: true)
    }

    private func apply(
        _ fn: ConfigureDisplayEnabledFn,
        display: CGDirectDisplayID,
        enabled: Bool
    ) -> Result {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        if begin != .success { return .beginFailed(begin.rawValue) }

        let e = fn(config, display, enabled)
        if e != .success {
            CGCancelDisplayConfiguration(config)
            return .configureFailed(e.rawValue)
        }

        // .forSession：当前登录会话内持久（App 退出后仍生效），注销/重启自动恢复 —— 最安全
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        if complete != .success { return .completeFailed(complete.rawValue) }
        return .ok
    }
}
