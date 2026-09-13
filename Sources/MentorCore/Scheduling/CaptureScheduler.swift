import Foundation

/// Pure decision logic for when to capture.
///
/// Feed it what happened (`noteFocusChange`, `noteInput`, `noteCaptureFinished`,
/// `setActive`) and ask `evaluate(now:)` what to do. It never touches a clock
/// itself, so it is fully testable.
public struct CaptureScheduler: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Capture right now for this reason.
        case capture(CaptureReason)
        /// Nothing due. `until` is when the next capture would fall due, or nil when inactive.
        case wait(until: Date?)
    }

    public var settings: SensingSettings
    public private(set) var isActive = false
    public private(set) var activatedAt: Date?
    public private(set) var lastCaptureAt: Date?
    public private(set) var lastInputAt: Date?
    public private(set) var pendingFocusChangeAt: Date?
    public private(set) var inputSinceLastCapture = false
    public private(set) var manualRequested = false

    public init(settings: SensingSettings) {
        self.settings = settings
    }

    /// Activation queues a prompt capture (as if focus changed) so resuming
    /// or regaining permissions shows something soon. Deactivation clears
    /// every pending trigger.
    public mutating func setActive(_ active: Bool, at now: Date) {
        guard active != isActive else { return }
        isActive = active
        if active {
            activatedAt = now
            pendingFocusChangeAt = now
        } else {
            pendingFocusChangeAt = nil
            inputSinceLastCapture = false
            manualRequested = false
        }
    }

    public mutating func noteFocusChange(at now: Date) {
        pendingFocusChangeAt = now
    }

    public mutating func noteInput(at time: Date) {
        if let lastInputAt, lastInputAt >= time { return }
        lastInputAt = time
        inputSinceLastCapture = true
    }

    public mutating func requestManualCapture() {
        manualRequested = true
    }

    public mutating func noteCaptureFinished(at now: Date) {
        lastCaptureAt = now
        pendingFocusChangeAt = nil
        inputSinceLastCapture = false
        manualRequested = false
    }

    /// The next capture that would fall due and why, ignoring whether it is already due.
    public func nextDue(now: Date) -> (at: Date, reason: CaptureReason)? {
        guard isActive else { return nil }
        let s = settings
        let earliest = lastCaptureAt.map { $0.addingTimeInterval(s.minCaptureInterval) } ?? .distantPast

        var candidates: [(at: Date, reason: CaptureReason, priority: Int)] = []
        if manualRequested {
            candidates.append((now, .manual, 0))
        }
        if let pendingFocusChangeAt {
            let at = max(pendingFocusChangeAt.addingTimeInterval(s.focusSettleDelay), earliest)
            candidates.append((at, .focusChange, 1))
        }
        if inputSinceLastCapture, let lastInputAt {
            let at = max(lastInputAt.addingTimeInterval(s.inputSettleDelay), earliest)
            candidates.append((at, .inputSettled, 2))
        }
        let floorBase = lastCaptureAt ?? activatedAt ?? now
        let floorAt = max(floorBase.addingTimeInterval(s.floorInterval), earliest)
        candidates.append((floorAt, .floor, 3))

        let best = candidates.min { a, b in
            a.at != b.at ? a.at < b.at : a.priority < b.priority
        }
        return best.map { ($0.at, $0.reason) }
    }

    public func evaluate(now: Date) -> Decision {
        guard let due = nextDue(now: now) else { return .wait(until: nil) }
        return due.at <= now ? .capture(due.reason) : .wait(until: due.at)
    }
}
