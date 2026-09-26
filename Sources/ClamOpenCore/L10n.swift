import Foundation

/// 界面语言：系统首选语言为中文时显示中文，其余一律显示英文。
/// 可单独为本 App 指定语言，例如：
///   defaults write com.clamopen.app AppleLanguages '("en")'
public enum L10n {
    public static let isChinese: Bool = isChinese(preferredLanguages: Locale.preferredLanguages)

    /// 首选语言列表的第一项为中文（zh、zh-Hans、zh-Hant-TW 等）时返回 true
    public static func isChinese(preferredLanguages: [String]) -> Bool {
        let lang = preferredLanguages.first?.lowercased() ?? "en"
        return lang.hasPrefix("zh")
    }
}

/// 按当前界面语言返回英文或中文文案
public func tr(_ en: String, _ zh: String) -> String {
    L10n.isChinese ? zh : en
}
