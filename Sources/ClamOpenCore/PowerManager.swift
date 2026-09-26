import Foundation

/// 电源管理器 —— 管理休眠相关的 pmset 设置，防止夜间频繁唤醒耗电
public final class PowerManager {

    public enum PowerSetting {
        case tcpKeepAlive
        case wakeOnMagicPacket  // womp - Wake on Magic Packet
        case proximityWake
        case standbyDelay

        public var key: String {
            switch self {
            case .tcpKeepAlive: return "tcpkeepalive"
            case .wakeOnMagicPacket: return "womp"
            case .proximityWake: return "proximitywake"
            case .standbyDelay: return "standbydelay"
            }
        }

        public var description: String {
            switch self {
            case .tcpKeepAlive: return tr("TCP Keep Alive (prevents frequent wake-ups)", "TCP 保活（防频繁唤醒）")
            case .wakeOnMagicPacket: return tr("Wake on Network", "网络唤醒")
            case .proximityWake: return tr("Proximity Wake", "靠近唤醒")
            case .standbyDelay: return tr("Standby Delay", "待机延迟")
            }
        }
    }

    // MARK: - 读取当前设置

    /// 读取 `pmset -g` 的输出（测试时可注入固定文本）
    private let readPmset: () -> String?

    public init(readPmset: @escaping () -> String? = PowerManager.runPmset) {
        self.readPmset = readPmset
    }

    /// 执行 `pmset -g` 并返回输出
    public static func runPmset() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            print(tr("Failed to read pmset: \(error)", "读取 pmset 失败: \(error)"))
            return nil
        }
    }

    /// 从 `pmset -g` 输出中解析某个 key 的值。
    /// 格式：` tcpkeepalive         0`（空格 / Tab 数量不定）。key 必须整词匹配，
    /// 否则 `standbydelay` 会误匹配 Intel 机型上的 `standbydelayhigh` / `standbydelaylow`。
    public static func parseValue(forKey key: String, in output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == key {
                return String(parts[1])
            }
        }
        return nil
    }

    /// 获取指定电源设置的当前值
    public func getCurrentValue(_ setting: PowerSetting) -> String? {
        guard let output = readPmset() else { return nil }
        return PowerManager.parseValue(forKey: setting.key, in: output)
    }

    /// 检查 TCP Keep Alive 是否启用（导致频繁唤醒的主要原因）
    public func isTCPKeepAliveEnabled() -> Bool {
        guard let value = getCurrentValue(.tcpKeepAlive) else { return true }
        return value != "0"
    }

    /// 检查网络唤醒是否启用
    public func isWakeOnMagicPacketEnabled() -> Bool {
        guard let value = getCurrentValue(.wakeOnMagicPacket) else { return true }
        return value != "0"
    }

    /// 检查靠近唤醒是否启用
    public func isProximityWakeEnabled() -> Bool {
        guard let value = getCurrentValue(.proximityWake) else { return true }
        return value != "0"
    }

    // MARK: - 设置管理

    /// 应用推荐的省电设置（需要管理员权限）
    /// - Returns: (成功, 错误信息)
    @discardableResult
    public func applyPowerSavingSettings() -> (success: Bool, message: String) {
        var results: [(String, Bool)] = []

        // 1. 禁用 TCP Keep Alive（最重要）
        let r1 = setSetting(.tcpKeepAlive, value: "0", scope: "a")
        results.append((tr("TCP Keep Alive", "TCP 保活"), r1))

        // 2. 禁用网络唤醒
        let r2 = setSetting(.wakeOnMagicPacket, value: "0", scope: "a")
        results.append((tr("Wake on Network", "网络唤醒"), r2))

        // 3. 禁用靠近唤醒
        let r3 = setSetting(.proximityWake, value: "0", scope: "a")
        results.append((tr("Proximity Wake", "靠近唤醒"), r3))

        // 4. 调整电池模式下的 standby 延迟为 1 小时
        let r4 = setSetting(.standbyDelay, value: "3600", scope: "b")
        results.append((tr("Standby Delay", "待机延迟"), r4))

        let successCount = results.filter { $0.1 }.count
        let failedItems = results.filter { !$0.1 }.map { $0.0 }

        if successCount == results.count {
            return (true, tr("All power saving settings were applied successfully", "已成功应用所有省电设置"))
        } else if successCount > 0 {
            return (true, tr("Some settings were applied (\(successCount)/\(results.count))\nFailed: \(failedItems.joined(separator: ", "))",
                              "部分设置成功（\(successCount)/\(results.count)）\n失败项：\(failedItems.joined(separator: ", "))"))
        } else {
            return (false, tr("Failed to apply settings. Please check administrator privileges.", "设置失败，请检查管理员权限"))
        }
    }

    /// 恢复默认设置
    @discardableResult
    public func restoreDefaultSettings() -> (success: Bool, message: String) {
        var results: [(String, Bool)] = []

        // 恢复为 macOS 默认值
        let r1 = setSetting(.tcpKeepAlive, value: "1", scope: "a")
        results.append((tr("TCP Keep Alive", "TCP 保活"), r1))

        let r2 = setSetting(.wakeOnMagicPacket, value: "1", scope: "a")
        results.append((tr("Wake on Network", "网络唤醒"), r2))

        let r3 = setSetting(.proximityWake, value: "1", scope: "a")
        results.append((tr("Proximity Wake", "靠近唤醒"), r3))

        let r4 = setSetting(.standbyDelay, value: "10800", scope: "b")
        results.append((tr("Standby Delay", "待机延迟"), r4))

        let successCount = results.filter { $0.1 }.count

        if successCount == results.count {
            return (true, tr("Default settings restored", "已恢复为默认设置"))
        } else {
            return (false, tr("Failed to restore. Please check administrator privileges.", "恢复失败，请检查管理员权限"))
        }
    }

    // MARK: - 底层设置

    /// 设置单个电源管理参数
    /// - Parameters:
    ///   - setting: 要设置的项
    ///   - value: 值
    ///   - scope: 作用域（"a" = 全部，"b" = 电池，"c" = 充电）
    private func setSetting(_ setting: PowerSetting, value: String, scope: String) -> Bool {
        // 使用 AuthorizationExecuteWithPrivileges 的替代方案：
        // 通过 osascript 弹出管理员权限对话框
        let script = """
        do shell script "pmset -\(scope) \(setting.key) \(value)" with administrator privileges
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        let pipe = Pipe()
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                return true
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let errorMsg = String(data: data, encoding: .utf8) {
                    print(tr("Failed to set \(setting.key): \(errorMsg)", "设置 \(setting.key) 失败: \(errorMsg)"))
                }
                return false
            }
        } catch {
            print(tr("Failed to run pmset: \(error)", "执行 pmset 失败: \(error)"))
            return false
        }
    }

    // MARK: - 诊断信息

    /// 获取当前电源设置摘要
    public func getPowerSettingsSummary() -> String {
        var lines: [String] = []
        lines.append(tr("Current power settings:", "当前电源设置："))
        lines.append("")

        let tcpKeepAlive = getCurrentValue(.tcpKeepAlive) ?? "?"
        let womp = getCurrentValue(.wakeOnMagicPacket) ?? "?"
        let proximity = getCurrentValue(.proximityWake) ?? "?"
        let standby = getCurrentValue(.standbyDelay) ?? "?"

        let disabled = tr("✓ Disabled", "✓ 已禁用")
        let enabled = tr("Enabled", "启用中")
        lines.append(tr("TCP Keep Alive: ", "TCP 保活：") + "\(tcpKeepAlive) \(tcpKeepAlive == "0" ? disabled : tr("⚠️ Enabled (causes frequent wake-ups)", "⚠️ 启用中（会导致频繁唤醒）"))")
        lines.append(tr("Wake on Network: ", "网络唤醒：") + "\(womp) \(womp == "0" ? disabled : enabled)")
        lines.append(tr("Proximity Wake: ", "靠近唤醒：") + "\(proximity) \(proximity == "0" ? disabled : enabled)")
        lines.append(tr("Standby Delay: \(standby) s", "待机延迟：\(standby) 秒"))

        return lines.joined(separator: "\n")
    }

    /// 检查是否需要优化（有潜在的耗电问题）
    public func needsOptimization() -> Bool {
        return isTCPKeepAliveEnabled() || isWakeOnMagicPacketEnabled()
    }
}
