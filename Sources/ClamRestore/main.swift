import ClamCore
import Foundation

// Persist before enabling: the main app polls this even if notification delivery
// is missed, and retains safe mode after either executable exits/restarts.
let latch = FileRecoveryLatch()
let backend = DisplayController()
func report(_ message: String) {
    RecoveryDiagnostics.record("ClamRestore: \(message)")
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
do { try latch.request() }
catch { report("无法写入恢复标记（仍会尝试恢复）：\(error)") }
DistributedNotificationCenter.default().postNotificationName(
    FileRecoveryLatch.notificationName, object: nil, userInfo: nil, deliverImmediately: true)

let safety = DisplaySafetyCoordinator(backend: backend, latch: latch, log: report)
let started = ProcessInfo.processInfo.systemUptime
safety.requestRecovery(now: started)
while safety.recoveryStatus == .recovering && ProcessInfo.processInfo.systemUptime - started < 12 {
    Thread.sleep(forTimeInterval: 0.25)
    safety.tick(now: ProcessInfo.processInfo.systemUptime)
}
if safety.recoveryStatus == .verified {
    report("已验证内置屏处于活动状态；安全模式保持开启。")
    exit(0)
}
report("未能确认恢复：\(safety.lastError ?? "恢复超时")；\(backend.snapshot())")
exit(1)
