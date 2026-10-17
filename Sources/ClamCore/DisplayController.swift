import CoreGraphics
import Foundation

/// The only production backend that changes hardware configuration.
public final class DisplayController: DisplayBackend {
    private typealias SetEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private typealias GetList = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    private let setEnabled: SetEnabled?
    private let getAll: GetList?

    public init() {
        let rtld = UnsafeMutableRawPointer(bitPattern: -2)
        setEnabled = dlsym(rtld, "CGSConfigureDisplayEnabled").map { unsafeBitCast($0, to: SetEnabled.self) }
        getAll = dlsym(rtld, "CGSGetDisplayList").map { unsafeBitCast($0, to: GetList.self) }
    }

    public var isAPIAvailable: Bool { setEnabled != nil }

    public func snapshot() -> DisplaySnapshot {
        let online = readList(CGGetOnlineDisplayList)
        let all = getAll.flatMap(readList) ?? []
        let ids = Set(all + (online ?? [])).sorted()
        return DisplaySnapshot(displays: ids.map {
            DisplayState(id: $0, builtin: CGDisplayIsBuiltin($0) != 0,
                         online: CGDisplayIsOnline($0) != 0,
                         active: CGDisplayIsActive($0) != 0,
                         asleep: CGDisplayIsAsleep($0) != 0)
        }, isReliable: online != nil)
    }

    private func readList(_ get: GetList) -> [CGDirectDisplayID]? {
        // Topology can change between the size query and the list query.
        for _ in 0..<3 {
            var count: UInt32 = 0
            guard get(0, nil, &count) == .success, count <= 128 else { return nil }
            guard count > 0 else { return [] }
            let capacity = count
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
            guard get(capacity, &ids, &count) == .success else { continue }
            if count <= capacity { return Array(ids.prefix(Int(count))) }
        }
        return nil
    }

    @discardableResult
    public func setBuiltinEnabled(_ enabled: Bool) -> DisplayResult {
        guard let setEnabled else { return .failed("CGSConfigureDisplayEnabled 私有接口不可用") }
        let current = snapshot()
        guard let builtin = current.displays.first(where: \.builtin) else {
            return .failed("未找到内置显示器，将等待重新枚举")
        }
        // Keep a safety check here even when called outside the coordinator.
        guard enabled || current.hasUsableExternal else {
            return .failed("没有处于活动且已唤醒状态的外接显示器，已拒绝关闭")
        }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            return .failed("开始配置失败 (CGError \(begin.rawValue))")
        }
        let change = setEnabled(config, builtin.id, enabled)
        guard change == .success else {
            CGCancelDisplayConfiguration(config)
            return .failed("设置显示器失败 (CGError \(change.rawValue))")
        }
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        guard complete == .success else {
            return .failed("应用配置失败 (CGError \(complete.rawValue))")
        }
        // This is only submission success. Coordinator verifies a fresh snapshot.
        return .ok
    }
}
