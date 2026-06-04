import CoreGraphics
import Darwin
import Foundation

// ---- 列出当前在线显示器 ----
var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)

print("=== Online displays: \(count) ===")
for d in ids {
    let builtin = CGDisplayIsBuiltin(d) != 0
    let main = CGDisplayIsMain(d) != 0
    let active = CGDisplayIsActive(d) != 0
    let online = CGDisplayIsOnline(d) != 0
    let w = CGDisplayPixelsWide(d)
    let h = CGDisplayPixelsHigh(d)
    let vendor = CGDisplayVendorNumber(d)
    let model = CGDisplayModelNumber(d)
    print("  ID=\(d) builtin=\(builtin) main=\(main) active=\(active) online=\(online) \(w)x\(h) vendor=\(vendor) model=\(model)")
}

// ---- 查找私有/相关符号 ----
let symbols = [
    "CGBeginDisplayConfiguration",      // public
    "CGCompleteDisplayConfiguration",   // public
    "CGCancelDisplayConfiguration",     // public
    "CGSConfigureDisplayEnabled",       // private (the key one)
    "CGSGetDisplayList",
    "CGDisplaySetDisplayMode",
]

let frameworks = [
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
]

let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)

print("\n=== Symbol lookup (RTLD_DEFAULT / already-loaded) ===")
for sym in symbols {
    let p = dlsym(RTLD_DEFAULT, sym)
    print("  \(sym): \(p != nil ? "FOUND" : "missing")")
}

for fw in frameworks {
    let handle = dlopen(fw, RTLD_NOW)
    print("\n=== Framework: \(fw) -> \(handle != nil ? "loaded" : "FAILED: \(String(cString: dlerror()))") ===")
    if let handle = handle {
        for sym in symbols {
            let p = dlsym(handle, sym)
            print("  \(sym): \(p != nil ? "FOUND" : "missing")")
        }
    }
}
