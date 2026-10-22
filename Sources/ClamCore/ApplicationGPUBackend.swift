import AppKit
import Darwin

public enum ApplicationGPUBackend {
    /// Call on the main thread; snapshot NSWorkspace state before background filesystem work.
    public static func runningApplications() -> [RunningGPUApplication] {
        precondition(Thread.isMainThread)
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let url = app.bundleURL, !app.isTerminated else { return nil }
            return RunningGPUApplication(url: url, bundleIdentifier: app.bundleIdentifier, pid: app.processIdentifier)
        }
    }

    /// This passive enumeration does not use MTLCreateSystemDefaultDevice or write pmset.
    public static func supportsHighPerformanceLaunch() -> Bool {
        let hardware = GPUSystemBackend().hardwareSnapshot()
        return hardware.supportsLegacySwitching && hardware.devices.contains(where: { $0.isLowPower })
            && hardware.devices.contains(where: { !$0.isLowPower && $0.name.localizedCaseInsensitiveContains("AMD") })
    }

    /// Read only a selected application's main PID. Do not retain or log raw argv/environment.
    public static func highPerformanceRequest(pid: Int32) -> Bool? {
        guard pid > 0 else { return nil }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > 0, size <= 1_048_576 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard status == 0, size <= data.count else { return nil }
        data.count = size
        return ApplicationGPUProcessArguments.highPerformanceRequested(in: data)
    }

    public static func readRendererReport(at url: URL) throws -> String? {
        let data = try readApplicationGPUFile(url, limit: 2_097_152)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return ApplicationGPURendererReport.renderer(from: text)
    }

    /// Explicit user action only. No shell, no profile/debug flags, no auto-termination.
    public static func open(_ plan: ApplicationGPULaunchPlan, completion: @escaping (Error?) -> Void) {
        precondition(Thread.isMainThread)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = plan.arguments
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: plan.url, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
