import Foundation
import os

public enum RecoveryDiagnostics {
    private static let logger = Logger(subsystem: "com.clamopen.app", category: "DisplayRecovery")
    public static func record(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}

extension DisplaySnapshot: CustomStringConvertible {
    public var description: String {
        "reliable=\(isReliable) displays=[" + displays.map {
            "id=\($0.id) builtin=\($0.builtin) online=\($0.online) active=\($0.active) asleep=\($0.asleep)"
        }.joined(separator: "; ") + "]"
    }
}
