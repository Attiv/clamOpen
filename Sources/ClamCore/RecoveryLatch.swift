import Foundation

public final class FileRecoveryLatch: RecoveryLatch {
    public static let notificationName = Notification.Name("com.clamopen.recoveryRequested")
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClamOpen", isDirectory: true)) {
        self.directory = directory
    }
    private var marker: URL { directory.appendingPathComponent("recovery-request") }
    private var acknowledgement: URL { directory.appendingPathComponent("recovery-acknowledged") }

    public var state: RecoveryLatchState {
        do {
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else { return .unavailable }
            let requested = try readToken(marker)
            let acknowledged = try readToken(acknowledgement)
            return requested == nil || requested == acknowledged ? .clear : .requested
        } catch {
            return isMissing(error) ? .clear : .unavailable
        }
    }

    public func request() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(UUID().uuidString.utf8).write(to: marker, options: .atomic)
    }

    public var requestID: String? {
        try? readToken(marker)
    }

    public func clear(acknowledging requestID: String?) throws {
        guard state != .unavailable else { throw CocoaError(.fileReadNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Never delete the request file. If a new request races this write, its
        // UUID differs from the consumed UUID and remains pending.
        try Data((requestID ?? "").utf8).write(to: acknowledgement, options: .atomic)
    }

    private func readToken(_ url: URL) throws -> String? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? 1024 < 128 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard let value = String(data: try Data(contentsOf: url), encoding: .utf8),
                  value.isEmpty || UUID(uuidString: value) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return value.isEmpty ? nil : value
        } catch {
            if isMissing(error) { return nil }
            throw error
        }
    }

    private func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }
}
