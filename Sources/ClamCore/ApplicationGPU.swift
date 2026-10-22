import Foundation

public enum ApplicationGPUSupport: String {
    case browser, experimentalElectron, readOnly

    public var title: String {
        switch self {
        case .browser: return "可设置（浏览器）"
        case .experimentalElectron: return "实验性（Electron）"
        case .readOnly: return "仅查看"
        }
    }

    public var allowsHighPerformanceRequest: Bool { self != .readOnly }
}

public struct ApplicationGPUApp: Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let url: URL
    public let support: ApplicationGPUSupport
    public let id: String

    public init(name: String, bundleIdentifier: String, url: URL, support: ApplicationGPUSupport) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.id = self.url.path
        self.support = support
    }
}

public struct RunningGPUApplication {
    public let url: URL
    public let bundleIdentifier: String?
    public let pid: Int32

    public init(url: URL, bundleIdentifier: String?, pid: Int32) {
        // NSWorkspace snapshots are taken on the main thread. Never resolve filesystem
        // symlinks here; unresolved aliases conservatively fall back to the bundle-ID guard.
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
    }
}

public final class ApplicationGPUInventory {
    private let roots: [URL]

    public init(roots: [URL] = [URL(fileURLWithPath: "/Applications"),
                                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                                URL(fileURLWithPath: "/System/Applications")]) {
        self.roots = roots
    }

    public func application(at url: URL) -> ApplicationGPUApp? {
        guard url.isFileURL else { return nil }
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let parentComponents = url.deletingLastPathComponent().pathComponents
        guard !parentComponents.contains(where: { ["app", "framework", "bundle", "xpc"].contains(($0 as NSString).pathExtension.lowercased()) }) else { return nil }
        guard url.pathExtension.lowercased() == "app",
              let data = try? readApplicationGPUFile(url.appendingPathComponent("Contents/Info.plist"), limit: 1_048_576),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any], info["CFBundlePackageType"] as? String == "APPL",
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty,
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty else { return nil }
        let browsers: Set<String> = ["com.google.Chrome", "company.thebrowser.Browser", "com.citrolabs.ego.lite"]
        let electron = FileManager.default.fileExists(atPath:
            url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        let support: ApplicationGPUSupport = browsers.contains(id) ? .browser : (electron ? .experimentalElectron : .readOnly)
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ApplicationGPUApp(name: name, bundleIdentifier: id, url: url, support: support)
    }

    public func scan(additionalURLs: [URL] = [], running: [RunningGPUApplication] = []) -> [ApplicationGPUApp] {
        var found: [String: ApplicationGPUApp] = [:]
        func include(_ url: URL) {
            if let app = application(at: url) { found[app.id] = app }
        }
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "app" {
                    enumerator.skipDescendants()
                    include(url)
                }
            }
        }
        (additionalURLs + running.map(\.url)).forEach(include)
        return found.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

public enum ApplicationGPUPreference: String, Codable {
    case automatic, highPerformance
    public var title: String { self == .automatic ? "默认（不附加参数）" : "优先高性能 GPU" }
}

public enum ApplicationGPUError: LocalizedError {
    case settingsUnavailable, unsupportedSettings, applicationChanged, alreadyRunning
    case unsupportedApplication, unavailableHardware, experimentalConsentRequired

    public var errorDescription: String? {
        switch self {
        case .settingsUnavailable: return "偏好文件无法读取或格式损坏。为避免覆盖原数据，已暂停保存；请在 Finder 中检查偏好文件。"
        case .unsupportedSettings: return "偏好文件版本不受支持，未覆盖原文件。"
        case .applicationChanged: return "应用已移动、删除或类型已变化，请刷新列表后重试。"
        case .alreadyRunning: return "该应用（或相同标识的另一个副本）已运行。请先手动完全退出，再从此窗口启动；ClamOpen 不会结束你的应用。"
        case .unsupportedApplication: return "该应用没有已适配的选卡接口，只能默认启动，不能附加高性能显卡偏好。"
        case .unavailableHardware: return "当前没有检测到可用于此选项的 Intel／AMD 双显卡组合。"
        case .experimentalConsentRequired: return "此 Electron 应用尚未验证选卡效果，需要先确认实验性启动说明。"
        }
    }
}

/// Bounded reads avoid loading entire diagnostic/configuration files into memory.
func readApplicationGPUFile(_ url: URL, limit: Int) throws -> Data {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw ApplicationGPUError.settingsUnavailable }
    return data
}

public struct ApplicationGPUSettings: Codable, Equatable {
    public var version = 1
    public var preferences: [String: ApplicationGPUPreference] = [:]
    public var experimentalConsent: Set<String> = []
    public var additionalPaths: [String] = []
    public init() {}
    public func preference(for app: ApplicationGPUApp) -> ApplicationGPUPreference { preferences[app.id] ?? .automatic }
}

public final class ApplicationGPUSettingsStore {
    public let url: URL
    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClamOpen/application-gpu.json")) { self.url = url }
    public func load() throws -> ApplicationGPUSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return ApplicationGPUSettings() }
        do {
            let data = try readApplicationGPUFile(url, limit: 1_048_576)
            let settings = try JSONDecoder().decode(ApplicationGPUSettings.self, from: data)
            try validate(settings)
            return settings
        } catch let error as ApplicationGPUError { throw error }
        catch { throw ApplicationGPUError.settingsUnavailable }
    }

    public func save(_ settings: ApplicationGPUSettings) throws {
        _ = try load() // Never overwrite a corrupt or future-version document.
        try validate(settings)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        guard data.count <= 1_048_576 else { throw ApplicationGPUError.settingsUnavailable }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validate(_ settings: ApplicationGPUSettings) throws {
        guard settings.version == 1 else { throw ApplicationGPUError.unsupportedSettings }
        let paths = Array(settings.preferences.keys) + settings.additionalPaths + Array(settings.experimentalConsent)
        guard paths.count <= 12_288, paths.allSatisfy({
            $0.hasPrefix("/") && $0.count <= 4096 && $0.lowercased().hasSuffix(".app")
                && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else { throw ApplicationGPUError.settingsUnavailable }
    }
}

public struct ApplicationGPULaunchPlan {
    public let url: URL
    public let arguments: [String]
    public static func make(app: ApplicationGPUApp, preference: ApplicationGPUPreference,
        running: [RunningGPUApplication], supportsHighPerformance: Bool, experimentalConfirmed: Bool) throws -> Self {
        guard !running.contains(where: { $0.url.path == app.id || $0.bundleIdentifier == app.bundleIdentifier }) else {
            throw ApplicationGPUError.alreadyRunning
        }
        try validatePreference(app: app, preference: preference, supportsHighPerformance: supportsHighPerformance,
                               experimentalConfirmed: experimentalConfirmed)
        return Self(url: app.url, arguments: preference == .highPerformance ? ["--force-high-performance-gpu"] : [])
    }

    public static func validatePreference(app: ApplicationGPUApp, preference: ApplicationGPUPreference,
        supportsHighPerformance: Bool, experimentalConfirmed: Bool) throws {
        guard preference == .highPerformance else { return }
        guard app.support.allowsHighPerformanceRequest else { throw ApplicationGPUError.unsupportedApplication }
        guard supportsHighPerformance else { throw ApplicationGPUError.unavailableHardware }
        guard app.support != .experimentalElectron || experimentalConfirmed else {
            throw ApplicationGPUError.experimentalConsentRequired
        }
    }

    public static func validateIdentity(original: ApplicationGPUApp, current: ApplicationGPUApp?) throws {
        guard let current, original.id == current.id, original.bundleIdentifier == current.bundleIdentifier,
              original.support == current.support else { throw ApplicationGPUError.applicationChanged }
    }
}

public enum ApplicationGPUProcessArguments {
    /// KERN_PROCARGS2: argc, executable path, padding, argc NUL-terminated argv entries,
    /// then environment. Inspect only exact argv entries, not environment or substrings.
    public static func highPerformanceRequested(in data: Data) -> Bool? {
        guard data.count >= 5, data.count <= 1_048_576 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 65_536 else { return nil }
        let bytes = [UInt8](data)
        guard let executableEnd = bytes[4...].firstIndex(of: 0) else { return nil }
        var offset = executableEnd + 1
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        let flag = Array("--force-high-performance-gpu".utf8)
        var requested = false
        for _ in 0..<Int(argc) {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            if bytes[offset..<end].elementsEqual(flag) { requested = true }
            offset = end + 1
        }
        return requested
    }
}

public enum ApplicationGPURendererReport {
    /// A user-provided GL_RENDERER is scoped to that report, never a live per-app measurement.
    public static func renderer(from text: String) -> String? {
        guard text.utf8.count <= 2_097_152 else { return nil }
        var values: Set<String> = []
        for line in text.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(of: ":"),
                  line[..<separator].trimmingCharacters(in: .whitespaces) == "GL_RENDERER" else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.count <= 1024,
                  value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            values.insert(value)
        }
        return values.count == 1 ? values.first : nil
    }
}
