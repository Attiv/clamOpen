import AppKit
import CoreGraphics
import Foundation

// ClamRestore —— 独立急救工具：启用所有显示器（重点恢复内置屏）。
// 不依赖主程序 ClamOpen，可在主程序崩溃 / 退出 / 全黑时单独运行。
// 设计为“粗暴可靠”：枚举所有能找到的显示器（含被禁用的），逐个执行 enable，
// 对已启用的显示器执行 enable 无副作用。
//
// 若 ClamOpen 仍在运行（尤其开了自动模式），它会通过显示重配置回调 /
// 看门狗把刚恢复的内置屏再次关闭（表现为“闪一下又黑屏”）。
// 因此先优雅退出 ClamOpen：其 applicationWillTerminate 会自行恢复内置屏，
// 本工具的 enable 循环再兜底。

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

// MARK: - 退出 ClamOpen（自动模式下它会立刻再次关闭内置屏）

/// 查找正在运行的 ClamOpen：首选 bundle id（打包 .app），兜底可执行文件名（SwiftPM 裸二进制无 bundle id）
func runningClamOpens() -> [NSRunningApplication] {
    var apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.clamopen.app")
    if apps.isEmpty {
        apps = NSWorkspace.shared.runningApplications.filter {
            $0 != .current && $0.executableURL?.lastPathComponent == "ClamOpen"
        }
    }
    return apps
}

/// 进程是否仍存在。用 kill(pid, 0) 探测而非 NSRunningApplication.isTerminated——
/// 后者的状态靠 RunLoop 刷新，纯 CLI 工具不用 RunLoop，永远读到陈旧的 false。
func processAlive(_ pid: pid_t) -> Bool {
    if pid <= 0 { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM  // 无权限发信号也说明进程存在
}

func waitForTermination(_ pid: pid_t, timeout: TimeInterval) -> Bool {
    var waited = 0.0
    while processAlive(pid), waited < timeout {
        Thread.sleep(forTimeInterval: 0.1)
        waited += 0.1
    }
    return !processAlive(pid)
}

/// 优雅退出 ClamOpen：terminate() → 最多等 3 秒 → forceTerminate() 兜底。
/// 优雅退出会触发其 applicationWillTerminate，ClamOpen 自己就会恢复内置屏；
/// 强杀则不做任何善后，恢复完全交给下方的 enable 循环。
func quitClamOpen() {
    let apps = runningClamOpens()
    guard !apps.isEmpty else { return }

    FileHandle.standardError.write(
        "检测到 ClamOpen 正在运行，先退出它（否则会立刻再次关闭内置屏）\n"
            .data(using: .utf8)!)

    var quitAll = true
    for app in apps {
        let pid = app.processIdentifier
        app.terminate()
        if waitForTermination(pid, timeout: 3.0) { continue }

        app.forceTerminate()
        if waitForTermination(pid, timeout: 1.0) {
            FileHandle.standardError.write("ClamOpen 无响应，已强制退出\n".data(using: .utf8)!)
            continue
        }

        quitAll = false
        FileHandle.standardError.write(
            "警告：无法退出 ClamOpen（可能权限受限），将继续尝试直接恢复显示器\n"
                .data(using: .utf8)!)
    }

    if quitAll {
        FileHandle.standardError.write(
            "提示：ClamOpen 的“自动模式”设置仍保留，下次启动会重新关闭内置屏\n"
                .data(using: .utf8)!)
    }
}

quitClamOpen()
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

// macOS 26 起，对已激活的显示器执行 enable 会被判为 no-op 并在 complete 阶段
// 返回 kCGErrorInvalidArgument(1001)。“已恢复 0/N”不代表失败——可能本来就全亮。
let alreadyActive = displays.filter { CGDisplayIsActive($0) != 0 }.count
var summary = "ClamRestore: 已恢复 \(restored)/\(displays.count) 台显示器"
if alreadyActive > 0 {
    summary += "（其中 \(alreadyActive) 台本已激活，无需变更）"
}
FileHandle.standardError.write("\(summary)\n".data(using: .utf8)!)
if restored == 0 && alreadyActive == displays.count {
    FileHandle.standardError.write("所有显示器均已激活，无需恢复\n".data(using: .utf8)!)
}
