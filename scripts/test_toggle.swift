import CoreGraphics
import Darwin
import Foundation

// dlsym 取私有函数：CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool)
typealias ConfigureDisplayEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
guard let sym = dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled") else {
    FileHandle.standardError.write("CGSConfigureDisplayEnabled not found\n".data(using: .utf8)!)
    exit(2)
}
let CGSConfigureDisplayEnabled = unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func setDisplay(_ id: CGDirectDisplayID, enabled: Bool) -> CGError {
    var config: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&config)
    if begin != .success { return begin }
    let e = CGSConfigureDisplayEnabled(config, id, enabled)
    if e != .success { CGCancelDisplayConfiguration(config); return e }
    return CGCompleteDisplayConfiguration(config, .forSession)
}

let ids = onlineDisplays()
let builtin = ids.first { CGDisplayIsBuiltin($0) != 0 }
let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }
print("online=\(ids) builtin=\(builtin.map(String.init) ?? "none") external=\(external)")

guard let b = builtin else { print("No builtin display, nothing to test"); exit(0) }
guard !external.isEmpty else { print("SAFETY: no external display online → refuse to disable builtin"); exit(1) }

print("[t+0] Disabling builtin \(b) in 1s (will auto-restore) ..."); fflush(stdout)
Thread.sleep(forTimeInterval: 1)

let r1 = setDisplay(b, enabled: false)
print("[t+1] disable -> CGError \(r1.rawValue) (\(r1 == .success ? "OK" : "FAIL"))"); fflush(stdout)
Thread.sleep(forTimeInterval: 3)

let mid = onlineDisplays()
print("[t+4] during-disable: online=\(mid) builtinActive=\(CGDisplayIsActive(b) != 0) builtinOnline=\(CGDisplayIsOnline(b) != 0)"); fflush(stdout)

let r2 = setDisplay(b, enabled: true)
print("[t+4] re-enable -> CGError \(r2.rawValue) (\(r2 == .success ? "OK" : "FAIL"))"); fflush(stdout)
Thread.sleep(forTimeInterval: 1)
print("[t+5] after-restore: online=\(onlineDisplays())")
