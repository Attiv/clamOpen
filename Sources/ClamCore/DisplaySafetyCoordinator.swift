import Foundation

public struct DisplayState: Equatable {
    public let id: UInt32
    public let builtin: Bool
    public let online: Bool
    public let active: Bool
    public let asleep: Bool

    public init(id: UInt32, builtin: Bool, online: Bool, active: Bool, asleep: Bool) {
        self.id = id
        self.builtin = builtin
        self.online = online
        self.active = active
        self.asleep = asleep
    }
}

public struct DisplaySnapshot: Equatable {
    public let displays: [DisplayState]
    public let isReliable: Bool
    public init(displays: [DisplayState], isReliable: Bool = true) {
        self.displays = displays
        self.isReliable = isReliable
    }
    public var builtinActive: Bool { displays.contains { $0.builtin && $0.online && $0.active && !$0.asleep } }
    public var hasUsableExternal: Bool { isReliable && displays.contains { !$0.builtin && $0.online && $0.active && !$0.asleep } }
    public var hasAwakeDisplay: Bool { displays.contains { $0.online && $0.active && !$0.asleep } }
    public var screensAppearAsleep: Bool {
        // A disabled built-in screen may remain online and NOT marked asleep.
        // Do not require that inactive screen to report sleep as well.
        !hasAwakeDisplay && displays.contains { $0.online && $0.asleep }
    }
}

public enum DisplayResult: Equatable {
    case ok
    case failed(String)
    public var message: String {
        switch self { case .ok: return "成功"; case .failed(let message): return message }
    }
}

public protocol DisplayBackend {
    func snapshot() -> DisplaySnapshot
    func setBuiltinEnabled(_ enabled: Bool) -> DisplayResult
}

public enum RecoveryLatchState { case clear, requested, unavailable }
public protocol RecoveryLatch {
    var state: RecoveryLatchState { get }
    func request() throws
    var requestID: String? { get }
    func clear(acknowledging requestID: String?) throws
}

public enum RecoveryStatus: Equatable { case idle, recovering, verified, failed }

/// Main-thread confined; all time values use a monotonic clock supplied by the caller.
public final class DisplaySafetyCoordinator {
    public var autoMode = false
    public private(set) var intentDisabled = false
    public private(set) var isRecoveryHeld = false
    public private(set) var isSleeping = false
    public private(set) var recoveryStatus: RecoveryStatus = .idle
    public private(set) var lastError: String?
    private let backend: DisplayBackend
    private let latch: RecoveryLatch
    private let log: (String) -> Void
    private var systemSleeping = false
    private var screenWakeObserved = false
    private var explicitRecovery = false
    private var observedRequestID: String?
    private var attempts = 0
    private var nextAttemptAt: TimeInterval = 0
    private let retryDelays: [TimeInterval] = [1, 2, 4, 2]

    public init(backend: DisplayBackend, latch: RecoveryLatch,
                log: @escaping (String) -> Void = { _ in }) {
        self.backend = backend
        self.latch = latch
        self.log = log
        isRecoveryHeld = latch.state != .clear
        observedRequestID = latch.requestID
    }

    /// Explicit menu action, distinct from passively loading the Auto preference.
    @discardableResult
    public func setAutoModeByUser(_ enabled: Bool, now: TimeInterval) -> DisplayResult {
        autoMode = enabled
        // No external display: arm Auto without changing displays or consuming
        // a recovery hold. Passive startup preference loading never calls here.
        guard enabled, backend.snapshot().hasUsableExternal else { return .ok }
        // Reuse all manual guards, including sleep, unverified recovery and
        // generation-aware emergency request checks around the transaction.
        return disableByUser(now: now)
    }

    public func disableByUser(now: TimeInterval) -> DisplayResult {
        guard !isSleeping, !systemSleeping, recoveryStatus != .recovering else {
            return .failed("正在休眠或恢复中，请等待内置屏恢复后再关闭")
        }
        guard backend.snapshot().hasUsableExternal else {
            return .failed("外接显示器未处于可用、唤醒状态，已拒绝关闭内置屏")
        }
        guard latch.state != .unavailable else {
            return .failed("无法读取急救恢复标记，已拒绝关闭内置屏")
        }
        if latch.state == .requested && (!isRecoveryHeld || latch.requestID != observedRequestID) {
            requestRecovery(now: now)
            return .failed("刚收到独立急救请求，已优先恢复；请确认画面后再关闭")
        }
        do { try latch.clear(acknowledging: observedRequestID) }
        catch { return .failed("无法解除安全恢复状态：\(error)") }
        isRecoveryHeld = false
        explicitRecovery = false
        recoveryStatus = .idle
        lastError = nil
        return disable(now: now)
    }

    private func disable(now: TimeInterval) -> DisplayResult {
        // Recheck immediately before and after the transaction: the independent
        // rescue process may issue its request while CoreGraphics is configuring.
        guard latch.state == .clear, backend.snapshot().hasUsableExternal else {
            requestRecovery(now: now, forceAwake: false)
            return .failed("恢复请求或显示状态变化，已取消关闭")
        }
        let result = backend.setBuiltinEnabled(false)
        intentDisabled = result == .ok
        log("disable: \(result.message); \(backend.snapshot())")
        if latch.state != .clear || !backend.snapshot().hasUsableExternal {
            requestRecovery(now: now, forceAwake: false)
            return .failed("关闭期间收到恢复请求或外接屏不可用，已转入安全恢复")
        }
        if result != .ok {
            // A failed transaction may have partially changed display state.
            requestRecovery(now: now, forceAwake: false)
        }
        return result
    }

    public func tick(now: TimeInterval) {
        let snapshot = backend.snapshot()
        if latch.state != .clear && (!isRecoveryHeld || latch.requestID != observedRequestID) {
            holdSafety(reason: "persistent recovery request")
            recoveryStatus = .idle
        }
        guard !systemSleeping else { return }
        // Immediately after a screen-wake event CoreGraphics may still report
        // stale asleep flags. Do not cancel/reset that bounded recovery cycle.
        // A real sleep notification always suspends it via screensDidSleep().
        if !isSleeping && snapshot.screensAppearAsleep && !explicitRecovery
            && (recoveryStatus == .idle || recoveryStatus == .verified) {
            screensDidSleep()
            return
        }
        if isSleeping {
            // Backup for a missed screensDidWake notification. Online alone is
            // deliberately insufficient evidence of user-visible wake.
            guard snapshot.isReliable && snapshot.hasAwakeDisplay else { return }
            screensDidWake(now: now)
            return
        }
        if intentDisabled && snapshot.builtinActive {
            holdSafety(reason: "built-in display reactivated; do not fight recovery")
            recoveryStatus = .idle
        }
        if !snapshot.hasUsableExternal && !snapshot.builtinActive && !isRecoveryHeld {
            holdSafety(reason: "no usable external display")
            recoveryStatus = .idle
        }
        if isRecoveryHeld {
            if recoveryStatus == .idle || (recoveryStatus == .verified && !snapshot.builtinActive) {
                startRecovery(now: now)
            }
            advanceRecovery(now: now, snapshot: snapshot)
            return
        }
        if autoMode && snapshot.builtinActive && snapshot.hasUsableExternal {
            _ = disable(now: now)
        }
    }

    public func screensDidSleep() {
        screenWakeObserved = false
        explicitRecovery = false
        isSleeping = true
        holdSafety(reason: "screens sleeping; suspend configuration")
        recoveryStatus = .idle
    }

    public func systemWillSleep() {
        systemSleeping = true
        screensDidSleep()
    }

    public func systemDidWake(now: TimeInterval) {
        systemSleeping = false
        log("system wake; waiting for awake displays if necessary")
        let snapshot = backend.snapshot()
        if !screenWakeObserved && (!snapshot.isReliable || !snapshot.hasAwakeDisplay) {
            isSleeping = true
        }
        screenWakeObserved = false // consume evidence for this system-wake event
        // Do not blindly reset isSleeping: screensDidWake can arrive before didWake.
        // Always latch recovery, including wake events whose sleep event was missed.
        holdSafety(reason: "system wake")
        tick(now: now)
    }

    public func screensDidWake(now: TimeInterval) {
        screenWakeObserved = true
        let newWake = isSleeping || systemSleeping || recoveryStatus == .idle
        systemSleeping = false
        isSleeping = false
        if newWake {
            requestRecovery(now: now, forceAwake: false)
        } else {
            holdSafety(reason: "screen wake notification")
            advanceRecovery(now: now, snapshot: backend.snapshot())
        }
    }

    public func requestRecovery(now: TimeInterval, forceAwake: Bool = true) {
        holdSafety(reason: "recovery requested")
        if forceAwake {
            systemSleeping = false
            isSleeping = false
        }
        explicitRecovery = forceAwake
        startRecovery(now: now)
        if !isSleeping && !systemSleeping {
            advanceRecovery(now: now, snapshot: backend.snapshot())
        }
    }

    private func holdSafety(reason: String) {
        let changed = !isRecoveryHeld || intentDisabled
        isRecoveryHeld = true
        intentDisabled = false
        if latch.state != .requested {
            do { try latch.request() }
            catch { log("cannot persist recovery hold: \(error)") }
        }
        observedRequestID = latch.requestID
        if changed { log("safe mode: \(reason); \(backend.snapshot())") }
    }

    private func startRecovery(now: TimeInterval) {
        recoveryStatus = .recovering
        attempts = 0
        nextAttemptAt = now
        lastError = nil
    }

    private func advanceRecovery(now: TimeInterval, snapshot: DisplaySnapshot) {
        guard recoveryStatus == .recovering || recoveryStatus == .failed else { return }
        if snapshot.isReliable && snapshot.builtinActive {
            explicitRecovery = false
            recoveryStatus = .verified
            lastError = nil
            log("recovery verified after \(attempts) attempts; \(snapshot)")
            return
        }
        guard recoveryStatus == .recovering else { return }
        guard now >= nextAttemptAt else { return }
        guard attempts < retryDelays.count else {
            recoveryStatus = .failed
            lastError = lastError ?? "配置已提交，但仍未确认内置屏处于活动状态"
            log("recovery exhausted: \(lastError!); \(snapshot)")
            return
        }
        let result = backend.setBuiltinEnabled(true)
        nextAttemptAt = now + retryDelays[attempts]
        attempts += 1
        if case .failed(let error) = result { lastError = error }
        log("restore attempt \(attempts): \(result.message); before=\(snapshot)")
        // Only a fresh subsequent snapshot can verify this attempt.
    }
}
