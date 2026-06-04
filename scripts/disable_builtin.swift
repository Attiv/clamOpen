import CoreGraphics
import Foundation

// 测试 / 调试用：仅关闭内置屏（带安全检查：必须有外接显示器）。
// 配合独立急救工具 ClamRestore 验证“关闭后由另一进程恢复”的链路。

typealias Fn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
let r = UnsafeMutableRawPointer(bitPattern: -2)
let setEnabled = unsafeBitCast(dlsym(r, "CGSConfigureDisplayEnabled")!, to: Fn.self)

func online() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &n)
    var a = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &a, &n)
    return Array(a.prefix(Int(n)))
}

let ids = online()
guard let b = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) else { print("no builtin"); exit(1) }
guard ids.contains(where: { CGDisplayIsBuiltin($0) == 0 }) else { print("SAFETY: no external, refuse"); exit(1) }

var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg)
let e = setEnabled(cfg, b, false)
CGCompleteDisplayConfiguration(cfg, .forSession)
print("disabled builtin \(b) err=\(e.rawValue) nowActive=\(CGDisplayIsActive(b) != 0)")
