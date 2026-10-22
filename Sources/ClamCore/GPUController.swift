import Foundation
import CoreGraphics
import Metal

/// Only the two explicitly supported user actions; force-integrated is intentionally absent.
public enum GPUPreference: Int, CaseIterable {
    case discrete = 1
    case automatic = 2

    public var title: String { self == .discrete ? "独立显卡优先" : "自动切换" }
}

public struct GPUDeviceInfo: Equatable {
    public var name: String
    public var isLowPower: Bool

    public init(name: String, isLowPower: Bool) {
        self.name = name
        self.isLowPower = isLowPower
    }
}

public struct GPUHardwareSnapshot: Equatable {
    public var mainDisplayDeviceName: String?
    public var devices: [GPUDeviceInfo]
    public var supportsLegacySwitching: Bool

    public init(mainDisplayDeviceName: String?, devices: [GPUDeviceInfo], supportsLegacySwitching: Bool) {
        self.mainDisplayDeviceName = mainDisplayDeviceName
        self.devices = devices
        self.supportsLegacySwitching = supportsLegacySwitching
    }
}

public struct GPUPowerPolicies: Equatable {
    public var battery: Int?
    public var ac: Int?

    public init(battery: Int? = nil, ac: Int? = nil) {
        self.battery = battery
        self.ac = ac
    }

    public static func parse(_ output: String) -> GPUPowerPolicies {
        enum Source: Hashable { case battery, ac }
        var source: Source?
        var seen: Set<Source> = []
        var policies = GPUPowerPolicies()
        for line in output.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(":") {
                switch text {
                case "Battery Power:": source = .battery
                case "AC Power:": source = .ac
                default: source = nil
                }
                continue
            }
            let parts = text.split(whereSeparator: \.isWhitespace)
            guard let source, parts.first == "gpuswitch" else { continue }
            // Missing/malformed/duplicate values must never become a verified policy.
            let first = seen.insert(source).inserted
            let value = first && parts.count == 2 ? Int(parts[1]) : nil
            switch source {
            case .battery: policies.battery = value
            case .ac: policies.ac = value
            }
        }
        return policies
    }

    public static func label(for value: Int?) -> String {
        switch value {
        case 0: return "集成显卡"
        case 1: return "独立显卡优先"
        case 2: return "自动切换"
        case .some(let raw): return "未知（\(raw)）"
        case .none: return "不可用"
        }
    }

    public func matches(_ preference: GPUPreference) -> Bool {
        battery == preference.rawValue && ac == preference.rawValue
    }

    var hasKnownValues: Bool {
        guard let battery, let ac else { return false }
        return (0...2).contains(battery) && (0...2).contains(ac)
    }
}

public struct GPUSnapshot: Equatable {
    public var hardware: GPUHardwareSnapshot
    public var policies: GPUPowerPolicies
    public var readError: String?

    public var switchingUnavailableReason: String? {
        guard hardware.supportsLegacySwitching,
              hardware.devices.contains(where: { $0.isLowPower }),
              hardware.devices.contains(where: { !$0.isLowPower }) else {
            return "当前设备不支持集成／独立双显卡策略切换"
        }
        if readError != nil { return "无法读取显卡策略，请刷新后重试" }
        guard policies.hasKnownValues else { return "系统未提供可识别的电池与插电显卡策略" }
        return nil
    }

    public var canSwitchPolicy: Bool { switchingUnavailableReason == nil }
}

public struct GPUCommandResult {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public protocol GPUBackend {
    func hardwareSnapshot() -> GPUHardwareSnapshot
    func readPowerSettings() throws -> GPUCommandResult
    func setPreference(_ preference: GPUPreference, request: GPUChangeRequest) throws -> GPUCommandResult
}

extension GPUBackend {
    public func setPreference(_ preference: GPUPreference) throws -> GPUCommandResult {
        try setPreference(preference, request: GPUChangeRequest())
    }
}

public enum GPUChangeOutcome { case applied, cancelled, failed }

public struct GPUChangeResult {
    public let outcome: GPUChangeOutcome
    public let message: String
    public let snapshot: GPUSnapshot
}

public final class GPUChangeRequest {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var directory: URL?
    private var process: Process?

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        removeMarker()
        if let process, process.isRunning { process.terminate() }
    }

    /// Called on the worker before authentication. Cancellation and marker creation are
    /// serialized so a queued request cannot recreate its permission to write after cancel.
    func makeMarker() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !finished else { throw GPURequestCancelled.cancelled }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClamOpenGPU-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        directory = folder
        let marker = folder.appendingPathComponent("pending")
        guard FileManager.default.createFile(atPath: marker.path, contents: Data(),
                                             attributes: [.posixPermissions: 0o600]) else {
            removeMarker()
            throw CocoaError(.fileWriteUnknown)
        }
        return marker
    }

    /// Start while holding the same lock used by cancel, closing the cancel-before-run race.
    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !finished else { throw GPURequestCancelled.cancelled }
        try process.run()
        self.process = process
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        process = nil
        removeMarker()
    }

    private func removeMarker() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

private enum GPURequestCancelled: Error { case cancelled }

/// Synchronous, injectable operations. The app runs these on its GPU worker queue, not its
/// main run loop: administrator authentication may wait for user input for an arbitrary time.
public final class GPUController {
    private let backend: GPUBackend

    public init(backend: GPUBackend = GPUSystemBackend()) { self.backend = backend }

    public func snapshot() -> GPUSnapshot {
        let hardware = backend.hardwareSnapshot()
        do {
            let result = try backend.readPowerSettings()
            guard result.status == 0 else {
                return GPUSnapshot(hardware: hardware, policies: GPUPowerPolicies(),
                                   readError: "读取 pmset 失败：\(detail(result.output))")
            }
            return GPUSnapshot(hardware: hardware, policies: .parse(result.output))
        } catch {
            return GPUSnapshot(hardware: hardware, policies: GPUPowerPolicies(),
                               readError: "读取 pmset 失败：\(error.localizedDescription)")
        }
    }

    public func apply(_ preference: GPUPreference, request: GPUChangeRequest = GPUChangeRequest()) -> GPUChangeResult {
        let before = snapshot()
        guard !request.isCancelled else { return cancelledResult(before) }
        if let reason = before.switchingUnavailableReason {
            return GPUChangeResult(outcome: .failed, message: reason, snapshot: before)
        }
        do {
            let command = try backend.setPreference(preference, request: request)
            let after = snapshot()
            if request.isCancelled { return cancelledResult(after) }
            guard command.status == 0 else {
                if command.output.contains("(-128)") {
                    return cancelledResult(after)
                }
                return GPUChangeResult(outcome: .failed,
                    message: "设置显卡策略失败：\(detail(command.output))", snapshot: after)
            }
            guard after.readError == nil, after.policies.matches(preference) else {
                return GPUChangeResult(outcome: .failed,
                    message: "命令已执行，但未能确认电池和插电策略均为「\(preference.title)」。请刷新后检查。", snapshot: after)
            }
            return GPUChangeResult(outcome: .applied, message: """
                已确认电池和插电策略均为「\(preference.title)」。
                主显示器当前 GPU：\(after.hardware.mainDisplayDeviceName ?? "不可用")

                这确认的是系统策略，不代表每个应用已切换显卡。应用可能自行选卡，已运行的应用可能需要重启。
                """, snapshot: after)
        } catch {
            if request.isCancelled { return cancelledResult(snapshot()) }
            return GPUChangeResult(outcome: .failed,
                message: "执行显卡策略切换失败：\(error.localizedDescription)", snapshot: snapshot())
        }
    }

    private func cancelledResult(_ snapshot: GPUSnapshot) -> GPUChangeResult {
        GPUChangeResult(outcome: .cancelled,
            message: "显卡切换请求已取消；以当前读取的策略为准", snapshot: snapshot)
    }

    private func detail(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "进程未返回错误详情" : String(text.prefix(1_000))
    }
}

/// The only GPU backend that invokes pmset. Reads are unprivileged and writes are explicit,
/// whitelisted, all-source commands behind the system's administrator authentication dialog.
public final class GPUSystemBackend: GPUBackend {
    private let runCommand: (String, [String], GPUChangeRequest?) throws -> GPUCommandResult

    public init() { runCommand = Self.run }

    init(runCommand: @escaping (String, [String]) throws -> GPUCommandResult) {
        self.runCommand = { path, arguments, _ in try runCommand(path, arguments) }
    }

    public func hardwareSnapshot() -> GPUHardwareSnapshot {
        #if arch(x86_64)
        let legacy = true
        #else
        let legacy = false
        #endif
        // Do not use the default-device API here: on switching Macs that API can
        // activate the high-power GPU. Observe the GPU already driving the main display.
        return GPUHardwareSnapshot(mainDisplayDeviceName: CGDirectDisplayCopyCurrentMetalDevice(CGMainDisplayID())?.name,
            devices: MTLCopyAllDevices().map { GPUDeviceInfo(name: $0.name, isLowPower: $0.isLowPower) },
            supportsLegacySwitching: legacy)
    }

    public func readPowerSettings() throws -> GPUCommandResult {
        try runCommand("/usr/bin/pmset", ["-g", "custom"], nil)
    }

    public func setPreference(_ preference: GPUPreference, request: GPUChangeRequest) throws -> GPUCommandResult {
        do {
            let marker = try request.makeMarker()
            defer { request.finish() }
            let quotedPath = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            // This guard runs as part of the privileged command AFTER authentication. It
            // still prevents a late write if the authorization helper outlives osascript.
            let command = "if /bin/test -f \(quotedPath) && /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; then /usr/bin/pmset -a gpuswitch \(preference.rawValue); else exit 125; fi"
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escaped)\" with administrator privileges"
            let result = try runCommand("/usr/bin/osascript", ["-e", script], request)
            if request.isCancelled || result.output.contains("(125)") {
                return GPUCommandResult(status: 1, output: "GPU request cancelled (-128)")
            }
            return result
        } catch GPURequestCancelled.cancelled {
            return GPUCommandResult(status: 1, output: "GPU request cancelled (-128)")
        }
    }

    private static func run(_ path: String, _ arguments: [String], request: GPUChangeRequest?) throws -> GPUCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // Drain one combined pipe before waiting, so neither output stream can fill a pipe
        // while the child is waiting for us. These operations never run on the app's main queue.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        if let request { try request.start(process) } else { try process.run() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GPUCommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
