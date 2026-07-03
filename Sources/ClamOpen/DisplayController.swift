import CoreGraphics
import Foundation

/// 封装对内置 / 外接显示器的启用、禁用与查询。
///
/// 通过 CoreGraphics 私有符号 `CGSConfigureDisplayEnabled` 真正关闭内置面板
/// （停止渲染 + 关闭背光），效果等同合盖（clamshell），但盖子保持打开。
///
/// 注意：`CGDisplayConfigurationFlags` 是私有 typedef UInt32，SDK 不暴露。
/// 所有涉及配置标志的地方都用 UInt32 代替：
///   0 = .forSession（默认，不触发完整重配置）
///   1 = .forceConfiguration（强制 WindowServer 重配显示管线）

final class DisplayController {

    // MARK: - 私有 API 签名

    /// CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool)
    typealias ConfigureDisplayEnabledFn =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    /// CGError CGSGetDisplayList(UInt32, CGDirectDisplayID*, UInt32*) — 能拿到被禁用的显示器
    typealias GetDisplayListFn =
        @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    /// CGError CGCompleteDisplayConfiguration(CGDisplayConfigRef, UInt32)
    /// UInt32 == CGDisplayConfigurationFlags (0=forSession, 1=forceConfiguration)
    typealias CompleteDisplayConfigurationFn =
        @convention(c) (CGDisplayConfigRef?, UInt32) -> CGError

    /// CGError CGDisplayRestoreDisplayConfiguration(CGDirectDisplayID, UInt32)
    typealias RestoreDisplayConfigurationFn =
        @convention(c) (CGDirectDisplayID, UInt32) -> CGError

    private var configureEnabled: ConfigureDisplayEnabledFn? = nil
    private var getDisplayList: GetDisplayListFn? = nil
    private var completeDisplayConfiguration: CompleteDisplayConfigurationFn? = nil
    private var restoreDisplayConfiguration: RestoreDisplayConfigurationFn? = nil

    init() {
        let rtldDefault: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(bitPattern: -2)

        if let s = rtldDefault.flatMap({ dlsym($0, "CGSConfigureDisplayEnabled") }) {
            self.configureEnabled = unsafeBitCast(s, to: ConfigureDisplayEnabledFn.self)
        }

        if let s = rtldDefault.flatMap({ dlsym($0, "CGSGetDisplayList") }) {
            self.getDisplayList = unsafeBitCast(s, to: GetDisplayListFn.self)
        }

        if let s = rtldDefault.flatMap({ dlsym($0, "CGCompleteDisplayConfiguration") }) {
            self.completeDisplayConfiguration = unsafeBitCast(s, to: CompleteDisplayConfigurationFn.self)
        }

        if let s = rtldDefault.flatMap({ dlsym($0, "CGDisplayRestoreDisplayConfiguration") }) {
            self.restoreDisplayConfiguration = unsafeBitCast(s, to: RestoreDisplayConfigurationFn.self)
        }
    }

    /// 私有 API 是否可用
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

    /// 获取所有显示器（包括被禁用的），用于恢复场景。
    func allDisplays() -> [CGDirectDisplayID] {
        guard let getDisplayList else { return onlineDisplays() }
        var count: UInt32 = 0
        if getDisplayList(0, nil, &count) == .success, count > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if getDisplayList(count, &ids, &count) == .success {
                return Array(ids.prefix(Int(count)))
            }
        }
        return onlineDisplays()
    }

    func builtinDisplay() -> CGDirectDisplayID? {
        onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 从 allDisplays 中查找内置屏（包括被禁用的）
    func findBuiltinInAll() -> CGDirectDisplayID? {
        allDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 在线的外接显示器（非内置）
    func externalDisplays() -> [CGDirectDisplayID] {
        onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
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
        case noExternal
        case beginFailed(Int32)
        case configureFailed(Int32)
        case completeFailed(Int32)

        var isSuccess: Bool { self == .ok }

        var message: String {
            switch self {
            case .ok:                   return "成功"
            case .apiMissing:           return "当前系统不支持该接口"
            case .noBuiltin:            return "未找到内置显示器"
            case .noExternal:           return "没有外接显示器，已拒绝（否则会全黑）"
            case .beginFailed(let e):   return "开始配置失败 (CGError \(e))"
            case .configureFailed(let e): return "设置失败 (CGError \(e))"
            case .completeFailed(let e):  return "应用配置失败 (CGError \(e))"
            }
        }
    }

    // MARK: - 操作

    /// 关闭内置屏。
    /// 两阶段提交：先镜像到外接屏（forceConfiguration），等待生效后再禁用内置屏。
    /// 使用 forceConfiguration 确保 WindowServer 完整迁移窗口，防止画中画。
    /// 仅当存在在线外接显示器时才会执行，否则返回 .noExternal。
    @discardableResult
    func disableBuiltin() -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        guard let completeFn = completeDisplayConfiguration else { return .apiMissing }

        var lastError: Result = .ok

        for _ in 0..<3 {
            guard let builtin = builtinDisplay() ?? findBuiltinInAll() else { return .noBuiltin }
            guard let external = externalDisplays().first else { return .noExternal }

            // 阶段 1：镜像到外接屏（forceConfiguration）
            var mirrorConfig: CGDisplayConfigRef?
            let begin1 = CGBeginDisplayConfiguration(&mirrorConfig)
            if begin1 != .success {
                lastError = .beginFailed(begin1.rawValue)
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let mirrorOK = CGConfigureDisplayMirrorOfDisplay(mirrorConfig, builtin, external) == .success
            if !mirrorOK {
                print("[ClamOpen] Mirror failed before disable, continuing")
            }
            let mirrorComplete = completeFn(mirrorConfig, 1) // forceConfiguration
            if mirrorComplete != .success {
                print("[ClamOpen] Mirror commit failed: CGError \(mirrorComplete.rawValue)")
            }
            mirrorConfig = nil

            // 等待镜像完全生效（macOS 12.x 上需要更长时间）
            Thread.sleep(forTimeInterval: 0.5)

            // 阶段 2：禁用内置屏（forceConfiguration）
            var config: CGDisplayConfigRef?
            let begin2 = CGBeginDisplayConfiguration(&config)
            if begin2 != .success {
                lastError = .beginFailed(begin2.rawValue)
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }

            let e = fn(config, builtin, false)
            if e != .success {
                CGCancelDisplayConfiguration(config)
                lastError = .configureFailed(e.rawValue)
                print("[ClamOpen] disableBuiltin attempt failed: CGError \(e.rawValue)")
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }

            let complete = completeFn(config, 1) // forceConfiguration
            if complete == .success {
                print("[ClamOpen] disableBuiltin succeeded")
                return .ok
            }
            lastError = .completeFailed(complete.rawValue)
            print("[ClamOpen] disableBuiltin complete failed: CGError \(complete.rawValue)")

            Thread.sleep(forTimeInterval: 0.5)
        }

        print("[ClamOpen] disableBuiltin all retries exhausted: \(lastError.message)")
        return lastError
    }


    /// 恢复内置屏。带重试机制，最多重试 5 次，每次间隔 0.8 秒。
    /// 始终使用 forceConfiguration（1）强制 WindowServer 重配显示管线。
    /// 通过 CGSGetDisplayList 查找已被禁用的内置屏（onlineDisplays 找不到它）。
    @discardableResult
    func enableBuiltin() -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        guard let completeFn = completeDisplayConfiguration else { return .apiMissing }

        let maxRetries = 5

        for attempt in 0..<maxRetries {
            // 每次重试都重新查找内置屏（display ID 可能在热插拔或休眠唤醒后变化）
            let displayId = builtinDisplay() ?? findBuiltinInAll()

            if let d = displayId {
                let result = applyEnable(fn, completeFn: completeFn, display: d)
                if result.isSuccess {
                    print("[ClamOpen] enableBuiltin succeeded on attempt \(attempt + 1)")
                    return .ok
                }
            } else {
                print("[ClamOpen] enableBuiltin attempt \(attempt + 1): no builtin display found")
            }

            if attempt < maxRetries - 1 {
                Thread.sleep(forTimeInterval: 0.8)
            }
        }

        // 所有 CGSConfigure 重试都失败后，尝试 CGDisplayRestoreDisplayConfiguration 兜底
        if let d = findBuiltinInAll(), let rc = restoreDisplayConfiguration {
            if rc(d, 0) == .success {
                print("[ClamOpen] enableBuiltin: CGSConfigure all failed, restoreDisplayConfiguration succeeded")
                return .ok
            }
        }

        print("[ClamOpen] enableBuiltin all retries exhausted")
        return .noBuiltin
    }

    /// 单次启用操作，始终使用 forceConfiguration。
    private func applyEnable(_ fn: ConfigureDisplayEnabledFn,
                              completeFn: CompleteDisplayConfigurationFn,
                              display: CGDirectDisplayID) -> Result {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        if begin != .success { return .beginFailed(begin.rawValue) }

        // 先取消镜像（如果有），再启用
        CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay)

        let e = fn(config, display, true)
        if e != .success {
            CGCancelDisplayConfiguration(config)
            return .configureFailed(e.rawValue)
        }

        let complete = completeFn(config, 1) // forceConfiguration
        if complete != .success { return .completeFailed(complete.rawValue) }
        return .ok
    }

    /// 恢复所有显示器（包括被禁用的），用于唤醒后的全面恢复。
    /// 返回成功恢复的数量。
    @discardableResult
    func enableAllDisplays() -> Int {
        guard let fn = configureEnabled else { return 0 }
        guard let completeFn = completeDisplayConfiguration else { return 0 }

        let displays = allDisplays()
        print("[ClamOpen] enableAllDisplays: found \(displays.count) displays")
        var restored = 0

        for d in displays {
            var displayRestored = false
            for _ in 0..<3 {
                var config: CGDisplayConfigRef?
                CGBeginDisplayConfiguration(&config)
                CGConfigureDisplayMirrorOfDisplay(config, d, kCGNullDirectDisplay)
                let e = fn(config, d, true)
                if e == .success {
                    let c = completeFn(config, 1)
                    if c == .success {
                        displayRestored = true
                        break
                    }
                }
                if config != nil { CGCancelDisplayConfiguration(config) }
                Thread.sleep(forTimeInterval: 0.5)
            }

            // CGSConfigure 失败时，尝试 CGDisplayRestoreDisplayConfiguration 兜底
            if !displayRestored, let rc = restoreDisplayConfiguration {
                if rc(d, 0) == .success {
                    displayRestored = true
                    print("[ClamOpen] enableAllDisplays: display \(d) restored via CGDisplayRestoreDisplayConfiguration")
                }
            }

            if displayRestored {
                restored += 1
            } else {
                print("[ClamOpen] enableAllDisplays: display \(d) failed to restore")
            }
        }

        print("[ClamOpen] enableAllDisplays: restored \(restored)/\(displays.count) displays")
        return restored
    }
}
