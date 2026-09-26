import CoreGraphics
import Foundation

// ClamRestore —— 独立急救工具：启用所有显示器（重点恢复内置屏）。
// 不依赖主程序 ClamOpen，可在主程序崩溃 / 退出 / 全黑时单独运行。
// 设计为“粗暴可靠”：枚举所有能找到的显示器（含被禁用的），逐个执行 enable，
// 对已启用的显示器执行 enable 无副作用。

typealias SetEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
typealias GetListFn    = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

let rtld = UnsafeMutableRawPointer(bitPattern: -2)

// 系统首选语言为中文时输出中文，否则输出英文
let isChinese = (Locale.preferredLanguages.first?.lowercased() ?? "en").hasPrefix("zh")
func tr(_ en: String, _ zh: String) -> String { isChinese ? zh : en }

guard let sEnabled = dlsym(rtld, "CGSConfigureDisplayEnabled") else {
    FileHandle.standardError.write(tr("ERROR: CGSConfigureDisplayEnabled is unavailable\n", "ERROR: CGSConfigureDisplayEnabled 不可用\n").data(using: .utf8)!)
    exit(2)
}
let setEnabled = unsafeBitCast(sEnabled, to: SetEnabledFn.self)
// CGSGetDisplayList 能列出包括“被禁用”的显示器；拿不到就退回 online list
let getCGSList = dlsym(rtld, "CGSGetDisplayList").map { unsafeBitCast($0, to: GetListFn.self) }

func allDisplays() -> [CGDirectDisplayID] {
    if let getCGSList {
        var count: UInt32 = 0
        if getCGSList(0, nil, &count) == .success, count > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if getCGSList(count, &ids, &count) == .success {
                return Array(ids.prefix(Int(count)))
            }
        }
    }
    var n: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &n)
    var a = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &a, &n)
    return Array(a.prefix(Int(n)))
}

func enable(_ id: CGDirectDisplayID) -> Bool {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
    if setEnabled(cfg, id, true) != .success {
        CGCancelDisplayConfiguration(cfg)
        return false
    }
    return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
}

// 内置屏已禁用且外接已拔掉时，CGSGetDisplayList 只剩一台虚拟占位显示器，内置屏不在其中。
// 因此额外尝试 ClamOpen 记住的内置屏 ID，以及内置屏的常见 ID 1。
let savedBuiltin = UserDefaults(suiteName: "com.clamopen.app")?.integer(forKey: "builtinDisplayID") ?? 0
var displays = allDisplays()
for id in [CGDirectDisplayID(savedBuiltin), 1] where id > 0 && !displays.contains(id) {
    displays.append(id)
}
var restored = 0
for d in displays {
    let builtin = CGDisplayIsBuiltin(d) != 0 || d == CGDirectDisplayID(savedBuiltin)
    if enable(d) {
        restored += 1
        let tag = builtin ? tr("(internal)", "(内置)") : tr("(external)", "(外接)")
        FileHandle.standardError.write(tr("Enabled \(d) \(tag)\n", "已启用 \(d) \(tag)\n").data(using: .utf8)!)
    }
}
FileHandle.standardError.write(tr("ClamRestore: restored \(restored)/\(displays.count) display(s)\n", "ClamRestore: 已恢复 \(restored)/\(displays.count) 台显示器\n").data(using: .utf8)!)
