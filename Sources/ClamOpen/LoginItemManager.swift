import AppKit
import CoreServices
import ServiceManagement

/// 管理「登录时启动」：
/// - macOS 13+：SMAppService.mainApp（系统设置 → 通用 → 登录项 中可见、可关闭）
/// - macOS 12：LSSharedFileList 会话登录项（App 未沙盒，无需内嵌 helper）
enum LoginItemManager {

    /// 当前是否已注册为登录项（以系统实际状态为准，菜单打开时实时查询）
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return legacyContains()
    }

    /// 设置/取消登录项，失败返回错误信息，成功返回 nil
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        if #available(macOS 13.0, *) {
            do {
                switch (enabled, SMAppService.mainApp.status) {
                case (true, .enabled), (false, .notRegistered):
                    return nil
                case (true, _):
                    try SMAppService.mainApp.register()
                    return nil
                case (false, _):
                    try SMAppService.mainApp.unregister()
                    return nil
                }
            } catch {
                return error.localizedDescription
            }
        }
        return legacySet(enabled)
    }

    // MARK: - macOS 12 回退：LSSharedFileList

    private static func legacyList() -> LSSharedFileList? {
        LSSharedFileListCreate(
            kCFAllocatorDefault, kLSSharedFileListSessionLoginItems.takeRetainedValue(), nil
        )?.takeRetainedValue()
    }

    private static func legacySnapshot(_ list: LSSharedFileList) -> [LSSharedFileListItem] {
        (LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem]) ?? []
    }

    private static func legacySelfItem(in list: LSSharedFileList) -> LSSharedFileListItem? {
        let selfURL = Bundle.main.bundleURL.standardizedFileURL
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        return legacySnapshot(list).first { item in
            guard
                let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?
                    .takeRetainedValue() as URL?
            else { return false }
            return url.standardizedFileURL == selfURL
        }
    }

    private static func legacyContains() -> Bool {
        guard let list = legacyList() else { return false }
        return legacySelfItem(in: list) != nil
    }

    private static func legacySet(_ enabled: Bool) -> String? {
        guard let list = legacyList() else { return "无法访问系统登录项列表" }
        if enabled {
            // 先移除可能的旧条目再插入，保证状态唯一
            if let old = legacySelfItem(in: list) {
                LSSharedFileListItemRemove(list, old)
            }
            LSSharedFileListInsertItemURL(
                list, kLSSharedFileListItemLast.takeUnretainedValue(), nil, nil,
                Bundle.main.bundleURL as CFURL, nil, nil)
            return legacyContains() ? nil : "添加登录项失败"
        } else {
            guard let item = legacySelfItem(in: list) else { return nil }
            LSSharedFileListItemRemove(list, item)
            return legacyContains() ? "移除登录项失败" : nil
        }
    }
}
