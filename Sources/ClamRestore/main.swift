import CoreGraphics
import Foundation

// ClamRestore —— 独立急救工具：启用所有显示器（重点恢复内置屏）。
// 设计为"粗暴可靠"：枚举所有能找到的显示器（含被禁用的），逐个执行 enable。
//
// 关键：CGDisplayConfigurationFlags 是私有类型（typedef UInt32），SDK 不暴露。
// 我们通过 dlsym 调用 CGCompleteDisplayConfiguration，手动传入 flag 值：
//   0 = .forSession（默认）
//   1 = .forceConfiguration（强制重配置）

// MARK: - 函数类型 typealias

typealias SetEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
typealias GetListFn    = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
typealias CompleteFn   = @convention(c) (CGDisplayConfigRef?, UInt32) -> CGError
typealias RestoreFn    = @convention(c) (CGDirectDisplayID, UInt32) -> CGError

let rtld = UnsafeMutableRawPointer(bitPattern: -2)

// CGSConfigureDisplayEnabled
guard let sEnabled = dlsym(rtld, "CGSConfigureDisplayEnabled") else {
    let msg = "ERROR: CGSConfigureDisplayEnabled 不可用\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(2)
}
let setEnabled = unsafeBitCast(sEnabled, to: SetEnabledFn.self)

// CGCompleteDisplayConfiguration
guard let sComplete = dlsym(rtld, "CGCompleteDisplayConfiguration") else {
    let msg = "ERROR: CGCompleteDisplayConfiguration 不可用\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(3)
}
let completeConfig = unsafeBitCast(sComplete, to: CompleteFn.self)

// CGSGetDisplayList — 能列出被禁用的显示器
let getCGSList = dlsym(rtld, "CGSGetDisplayList").map {
    unsafeBitCast($0, to: GetListFn.self)
}

// CGDisplayRestoreDisplayConfiguration — 系统默认配置恢复
let restoreConfig = dlsym(rtld, "CGDisplayRestoreDisplayConfiguration").map {
    unsafeBitCast($0, to: RestoreFn.self)
}

// MARK: - 显示列表

func allDisplays() -> [CGDirectDisplayID] {
    if let g = getCGSList {
        var count: UInt32 = 0
        if g(0, nil, &count) == .success, count > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if g(count, &ids, &count) == .success {
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


// MARK: - 主流程

// 策略：优先通知正在运行的 ClamOpen 来恢复（它的逻辑已经验证可靠），
// 如果 ClamOpen 没运行或恢复失败，再自己动手。

let notifName = NSNotification.Name("com.clamopen.restore-builtin")
DistributedNotificationCenter.default().postNotificationName(notifName, object: nil, deliverImmediately: true)

// 等待 ClamOpen 处理通知
Thread.sleep(forTimeInterval: 1.5)

// 检查内置屏是否已被恢复
let onlineDisplays = CGOnlineDisplayList()
if onlineDisplays.contains(where: { CGDisplayIsBuiltin($0) != 0 }) {
    let msg = "ClamRestore: 通过 ClamOpen 成功恢复内置屏\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(0)
}

// ClamOpen 未运行或恢复失败，自己动手
let msg = "ClamRestore: ClamOpen 未响应，尝试直接恢复...\n"
FileHandle.standardError.write(msg.data(using: .utf8)!)

let displays = allDisplays()
var restored = 0

for d in displays {
    let builtin = CGDisplayIsBuiltin(d) != 0
    let tag = builtin ? "(内置)" : "(外接)"

    // 跳过已经处于活动状态的显示器
    if CGDisplayIsActive(d) != 0 {
        restored += 1
        continue
    }

    let maxRetries = builtin ? 5 : 3
    var success = false
    var attempt = 0

    while !success && attempt < maxRetries {
        var cfg: CGDisplayConfigRef?

        // 每次重试重新查找内置屏 ID
        let currentId: CGDirectDisplayID = builtin
            ? (allDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? d)
            : d

        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayMirrorOfDisplay(cfg, currentId, kCGNullDirectDisplay)
        let e = setEnabled(cfg, currentId, true)

        if e == .success {
            let c = completeConfig(cfg, UInt32(1)) // forceConfiguration
            if c == .success {
                success = true
            } else {
                CGCancelDisplayConfiguration(cfg)
            }
        } else {
            CGCancelDisplayConfiguration(cfg)
        }

        if !success && attempt < maxRetries - 1 {
            Thread.sleep(forTimeInterval: 0.8)
        }
        attempt += 1
    }

    if !success {
        if let rc = restoreConfig, rc(d, UInt32(1)) == .success {
            success = true
        }
    }

    if success {
        restored += 1
        let m = "已启用 \(d) \(tag)\n"
        FileHandle.standardError.write(m.data(using: .utf8)!)
    } else {
        let m = "未启用 \(d) \(tag)\n"
        FileHandle.standardError.write(m.data(using: .utf8)!)
    }
}

let finalMsg = "\nClamRestore: 已恢复 \(restored)/\(displays.count) 台显示器\n"
FileHandle.standardError.write(finalMsg.data(using: .utf8)!)

if restored == 0 {
    let help = """
    \n=== 所有显示器都未能恢复 ===
    建议：
    1. 检查 ClamOpen 是否在菜单栏运行
    2. 尝试重启 WindowServer: killall WindowServer
    3. 最后手段：重启 Mac
    """
    FileHandle.standardError.write(help.data(using: .utf8)!)
    exit(1)
}

// 辅助函数：在线显示器列表
func CGOnlineDisplayList() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    guard count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}
