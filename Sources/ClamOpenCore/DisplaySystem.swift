import CoreGraphics
import Foundation

/// 对底层显示 API 的抽象：真实环境使用 `CGDisplaySystem`，单元测试注入模拟实现。
public protocol DisplaySystem: AnyObject {
    /// 私有接口 CGSConfigureDisplayEnabled 是否可用
    var canConfigure: Bool { get }
    /// 在线显示器（CGGetOnlineDisplayList）
    func onlineDisplays() -> [CGDirectDisplayID]
    /// 所有显示器，包括被禁用的（CGSGetDisplayList）；不可用时返回 nil
    func allDisplays() -> [CGDirectDisplayID]?
    func isBuiltin(_ id: CGDirectDisplayID) -> Bool
    func isActive(_ id: CGDirectDisplayID) -> Bool
    /// WindowServer 在没有任何物理显示器在线时插入的虚拟占位显示器
    func isVirtualPlaceholder(_ id: CGDirectDisplayID) -> Bool
    /// 启用 / 禁用单个显示器（一次完整的 begin → configure → complete 事务）
    func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> DisplayController.Result
}

/// 基于 CoreGraphics / SkyLight 私有符号的真实实现
public final class CGDisplaySystem: DisplaySystem {

    /// CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool)
    typealias ConfigureDisplayEnabledFn =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    /// CGError CGSGetDisplayList(uint32_t max, CGDirectDisplayID *list, uint32_t *count)
    /// 与 CGGetOnlineDisplayList 不同，它也会列出被禁用的显示器
    typealias GetDisplayListFn =
        @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    private let configureEnabled: ConfigureDisplayEnabledFn?
    private let getDisplayList: GetDisplayListFn?

    public init() {
        // RTLD_DEFAULT (== -2)：符号随 CoreGraphics 已载入本进程，直接取即可
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        configureEnabled = dlsym(rtldDefault, "CGSConfigureDisplayEnabled")
            .map { unsafeBitCast($0, to: ConfigureDisplayEnabledFn.self) }
        getDisplayList = dlsym(rtldDefault, "CGSGetDisplayList")
            .map { unsafeBitCast($0, to: GetDisplayListFn.self) }
    }

    public var canConfigure: Bool { configureEnabled != nil }

    public func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    public func allDisplays() -> [CGDirectDisplayID]? {
        guard let getDisplayList else { return nil }
        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard getDisplayList(count, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    public func isBuiltin(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(id) != 0 }

    public func isActive(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsActive(id) != 0 }

    /// 占位显示器的 vendor / model 为 FourCC 'unkn' / 'virt'（实测 Apple Silicon，macOS 26）。
    /// 例如：内置屏已禁用时拔掉外接，在线列表里只剩这台 1920x1080 的虚拟显示器。
    static let placeholderVendor: UInt32 = 0x756E_6B6E   // 'unkn'
    static let placeholderModel: UInt32 = 0x7669_7274    // 'virt'

    public func isVirtualPlaceholder(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == Self.placeholderVendor
            && CGDisplayModelNumber(id) == Self.placeholderModel
    }

    public func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> DisplayController.Result {
        guard let fn = configureEnabled else { return .apiMissing }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        if begin != .success { return .beginFailed(begin.rawValue) }

        let e = fn(config, id, enabled)
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
