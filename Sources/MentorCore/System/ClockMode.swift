import Foundation

/// Which clock the app runs on, chosen once at launch from the command line.
///
/// Every launch runs on real time (`SystemClock`) except a replay, which runs
/// on an `AdjustableClock` over real time so a scripted check can compress the
/// waits the product is built around:
///
/// - `--time-scale <n>`: the replay's clock runs n times faster than real
///   time, from 1 to `scaleRange.upperBound`
/// - `--advance-clock <interval>`: the replay's clock starts that far ahead,
///   for example `90s`, `15m`, `2h`, or `1d12h`
///
/// and the debug panel moves it ahead on demand. A command line that asked for
/// a replay it could not start keeps the replay's journal, so it gets the
/// replay's clock too. Either flag on a live or recording launch, or with a
/// value that cannot be used, is refused: the app runs on real time and says
/// why, so a live or recording run can never use a controlled clock.
public enum ClockMode: Equatable, Sendable {
    /// Real time.
    case system
    /// A replay's clock, `scale` times real time and started `ahead` seconds ahead.
    case replay(scale: Double, ahead: TimeInterval)
    /// A clock flag that was not accepted; the app runs on real time.
    case refused(String)

    public static let scaleFlag = "--time-scale"
    public static let advanceFlag = "--advance-clock"
    /// A replay's clock runs at most this many times real time: past it the
    /// sensing loop's polls come faster than a capture can finish.
    public static let scaleRange: ClosedRange<Double> = 1...100
    /// The furthest one step moves a replay's clock ahead.
    public static let maxAdvance: TimeInterval = 30 * 86400

    public init(arguments: [String], clientMode: ModelClientMode) {
        func value(after flag: String) -> String?? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            guard index + 1 < arguments.count else { return .some(nil) }
            let next = arguments[index + 1]
            return next.hasPrefix("--") || next.isEmpty ? .some(nil) : .some(next)
        }
        let scaleValue = value(after: ClockMode.scaleFlag)
        let advanceValue = value(after: ClockMode.advanceFlag)
        guard clientMode.isOffline else {
            let given = [scaleValue.map { _ in ClockMode.scaleFlag }, advanceValue.map { _ in ClockMode.advanceFlag }].compactMap { $0 }
            self = given.isEmpty
                ? .system
                : .refused("\(given.joined(separator: " and ")) \(given.count == 1 ? "applies" : "apply") only to \(ModelClientMode.replayFlag)")
            return
        }
        var scale = 1.0
        if let scaleValue {
            guard let text = scaleValue, let parsed = Double(text), ClockMode.scaleRange.contains(parsed) else {
                self = .refused("\(ClockMode.scaleFlag) needs a number from \(Int(ClockMode.scaleRange.lowerBound)) to \(Int(ClockMode.scaleRange.upperBound))")
                return
            }
            scale = parsed
        }
        var ahead: TimeInterval = 0
        if let advanceValue {
            guard let text = advanceValue, let parsed = ClockInterval.seconds(from: text), ClockMode.accepts(advance: parsed) else {
                self = .refused("\(ClockMode.advanceFlag) needs an interval such as 15m, 2h, or 1d, up to \(ClockInterval.description(of: ClockMode.maxAdvance))")
                return
            }
            ahead = parsed
        }
        self = .replay(scale: scale, ahead: ahead)
    }

    /// Whether one step may move a replay's clock ahead by `seconds`.
    public static func accepts(advance seconds: TimeInterval) -> Bool {
        seconds > 0 && seconds <= maxAdvance
    }

    /// The clock for this mode, and the handle that moves it, which only a
    /// replay has. A replay's clock starts at real time; `startReplay` moves
    /// it to where the replay carries on from.
    public func makeClock(base: some MentorClock = SystemClock()) -> (clock: any MentorClock, control: AdjustableClock?) {
        switch self {
        case .system, .refused:
            return (base, nil)
        case .replay(let scale, _):
            let clock = AdjustableClock(running: base, scale: scale)
            return (clock, clock)
        }
    }

    /// Moves a replay's clock to where the replay starts, before anything
    /// runs on it: never behind the newest time in the replay's own journal,
    /// which a faster or advanced session leaves stamped ahead of real time,
    /// so a relaunch carries on where the last one stopped instead of going
    /// back in time; then `--advance-clock` further.
    public func startReplay(_ clock: AdjustableClock, journalNewest: Date?) {
        guard case .replay(_, let ahead) = self else { return }
        if let journalNewest {
            clock.advance(toDate: journalNewest)
        }
        if ahead > 0 {
            clock.advance(by: .seconds(ahead))
        }
    }
}

/// Intervals as a person types them for the clock: a number and a unit, `s`,
/// `m`, `h`, or `d`, as many as needed (`1h30m`), or a bare number of seconds.
public enum ClockInterval {
    private static let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]

    /// The interval in seconds, or nil when the text is not one.
    public static func seconds(from text: String) -> TimeInterval? {
        let compact = text.lowercased().filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }
        if let plain = TimeInterval(compact) { return plain.isFinite ? plain : nil }
        var total: TimeInterval = 0
        var number = ""
        for character in compact {
            if character.isNumber || character == "." {
                number.append(character)
            } else if let unit = units[character], let value = TimeInterval(number) {
                total += value * unit
                number = ""
            } else {
                return nil
            }
        }
        return number.isEmpty && total.isFinite ? total : nil
    }

    /// Whole days, hours, minutes, and seconds, largest first, leaving out
    /// the ones that are zero: "1d 2h", "15m", and 3630 seconds as "1h 30s".
    public static func description(of seconds: TimeInterval) -> String {
        var remaining = Int(seconds.rounded())
        guard remaining > 0 else { return "0s" }
        var parts: [String] = []
        for (unit, size) in [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)] where remaining >= size {
            parts.append("\(remaining / size)\(unit)")
            remaining %= size
        }
        return parts.joined(separator: " ")
    }
}
