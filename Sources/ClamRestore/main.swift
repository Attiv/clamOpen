import CoreGraphics
import Foundation

// ClamRestore —— 独立急救工具：启用所有显示器（重点恢复内置屏）。
// 不依赖主程序 ClamOpen，可在主程序崩溃 / 退出 / 全黑时单独运行。
// 设计为“粗暴可靠”：枚举所有能找到的显示器（含被禁用的），逐个执行 enable，
// 对已启用的显示器执行 enable 无副作用。

typealias SetEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
typealias GetListFn    = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

let rtld = UnsafeMutableRawPointer(bitPattern: -2)

guard let sEnabled = dlsym(rtld, "CGSConfigureDisplayEnabled") else {
    FileHandle.standardError.write("ERROR: CGSConfigureDisplayEnabled 不可用\n".data(using: .utf8)!)
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

let displays = allDisplays()
var restored = 0
for d in displays {
    let builtin = CGDisplayIsBuiltin(d) != 0
    if enable(d) {
        restored += 1
        let tag = builtin ? "(内置)" : "(外接)"
        FileHandle.standardError.write("已启用 \(d) \(tag)\n".data(using: .utf8)!)
    }
}
FileHandle.standardError.write("ClamRestore: 已恢复 \(restored)/\(displays.count) 台显示器\n".data(using: .utf8)!)
