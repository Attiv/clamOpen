import Foundation

/// 电源管理器 —— 管理休眠相关的 pmset 设置，防止夜间频繁唤醒耗电
final class PowerManager {

    enum PowerSetting {
        case tcpKeepAlive
        case wakeOnMagicPacket  // womp - Wake on Magic Packet
        case proximityWake
        case standbyDelay

        var key: String {
            switch self {
            case .tcpKeepAlive: return "tcpkeepalive"
            case .wakeOnMagicPacket: return "womp"
            case .proximityWake: return "proximitywake"
            case .standbyDelay: return "standbydelay"
            }
        }

        var description: String {
            switch self {
            case .tcpKeepAlive: return "TCP 保活（防频繁唤醒）"
            case .wakeOnMagicPacket: return "网络唤醒"
            case .proximityWake: return "靠近唤醒"
            case .standbyDelay: return "待机延迟"
            }
        }
    }

    // MARK: - 读取当前设置

    /// 获取指定电源设置的当前值
    func getCurrentValue(_ setting: PowerSetting) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // 解析输出，查找 key
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(setting.key) {
                    // 格式：tcpkeepalive 0
                    let parts = trimmed.split(separator: " ", maxSplits: 1)
                    if parts.count >= 2 {
                        return String(parts[1])
                    }
                }
            }
            return nil
        } catch {
            print("读取 pmset 失败: \(error)")
            return nil
        }
    }

    /// 检查 TCP Keep Alive 是否启用（导致频繁唤醒的主要原因）
    func isTCPKeepAliveEnabled() -> Bool {
        guard let value = getCurrentValue(.tcpKeepAlive) else { return true }
        return value != "0"
    }

    /// 检查网络唤醒是否启用
    func isWakeOnMagicPacketEnabled() -> Bool {
        guard let value = getCurrentValue(.wakeOnMagicPacket) else { return true }
        return value != "0"
    }

    /// 检查靠近唤醒是否启用
    func isProximityWakeEnabled() -> Bool {
        guard let value = getCurrentValue(.proximityWake) else { return true }
        return value != "0"
    }

    // MARK: - 设置管理

    /// 应用推荐的省电设置（需要管理员权限）
    /// - Returns: (成功, 错误信息)
    @discardableResult
    func applyPowerSavingSettings() -> (success: Bool, message: String) {
        var results: [(String, Bool)] = []

        // 1. 禁用 TCP Keep Alive（最重要）
        let r1 = setSetting(.tcpKeepAlive, value: "0", scope: "a")
        results.append(("TCP 保活", r1))

        // 2. 禁用网络唤醒
        let r2 = setSetting(.wakeOnMagicPacket, value: "0", scope: "a")
        results.append(("网络唤醒", r2))

        // 3. 禁用靠近唤醒
        let r3 = setSetting(.proximityWake, value: "0", scope: "a")
        results.append(("靠近唤醒", r3))

        // 4. 调整电池模式下的 standby 延迟为 1 小时
        let r4 = setSetting(.standbyDelay, value: "3600", scope: "b")
        results.append(("待机延迟", r4))

        let successCount = results.filter { $0.1 }.count
        let failedItems = results.filter { !$0.1 }.map { $0.0 }

        if successCount == results.count {
            return (true, "已成功应用所有省电设置")
        } else if successCount > 0 {
            return (true, "部分设置成功（\(successCount)/\(results.count)）\n失败项：\(failedItems.joined(separator: ", "))")
        } else {
            return (false, "设置失败，请检查管理员权限")
        }
    }

    /// 恢复默认设置
    @discardableResult
    func restoreDefaultSettings() -> (success: Bool, message: String) {
        var results: [(String, Bool)] = []

        // 恢复为 macOS 默认值
        let r1 = setSetting(.tcpKeepAlive, value: "1", scope: "a")
        results.append(("TCP 保活", r1))

        let r2 = setSetting(.wakeOnMagicPacket, value: "1", scope: "a")
        results.append(("网络唤醒", r2))

        let r3 = setSetting(.proximityWake, value: "1", scope: "a")
        results.append(("靠近唤醒", r3))

        let r4 = setSetting(.standbyDelay, value: "10800", scope: "b")
        results.append(("待机延迟", r4))

        let successCount = results.filter { $0.1 }.count

        if successCount == results.count {
            return (true, "已恢复为默认设置")
        } else {
            return (false, "恢复失败，请检查管理员权限")
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
                    print("设置 \(setting.key) 失败: \(errorMsg)")
                }
                return false
            }
        } catch {
            print("执行 pmset 失败: \(error)")
            return false
        }
    }

    // MARK: - 诊断信息

    /// 获取当前电源设置摘要
    func getPowerSettingsSummary() -> String {
        var lines: [String] = []
        lines.append("当前电源设置：")
        lines.append("")

        let tcpKeepAlive = getCurrentValue(.tcpKeepAlive) ?? "?"
        let womp = getCurrentValue(.wakeOnMagicPacket) ?? "?"
        let proximity = getCurrentValue(.proximityWake) ?? "?"
        let standby = getCurrentValue(.standbyDelay) ?? "?"

        lines.append("TCP 保活：\(tcpKeepAlive) \(tcpKeepAlive == "0" ? "✓ 已禁用" : "⚠️ 启用中（会导致频繁唤醒）")")
        lines.append("网络唤醒：\(womp) \(womp == "0" ? "✓ 已禁用" : "启用中")")
        lines.append("靠近唤醒：\(proximity) \(proximity == "0" ? "✓ 已禁用" : "启用中")")
        lines.append("待机延迟：\(standby) 秒")

        return lines.joined(separator: "\n")
    }

    /// 检查是否需要优化（有潜在的耗电问题）
    func needsOptimization() -> Bool {
        return isTCPKeepAliveEnabled() || isWakeOnMagicPacketEnabled()
    }
}
