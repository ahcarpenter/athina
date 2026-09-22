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
/// a replay it could not start keeps the replay's files, so it gets the
/// replay's clock too. Either flag on a live or recording launch is refused:
/// the app runs on real time and says why, so a live or recording run can
/// never use a controlled clock. A replay's flag with a value that cannot be
/// used is refused and said the same way, but the replay keeps its own clock
/// at real time with nothing added ahead, so the debug panel and
/// `ClockRemote` still move it.
public enum ClockMode: Equatable, Sendable {
    /// Real time.
    case system
    /// A replay's clock, `scale` times real time and started `ahead` seconds
    /// ahead, and why a clock flag was not accepted when one was not.
    case replay(scale: Double, ahead: TimeInterval, refusal: String? = nil)
    /// A clock flag outside a replay, which was not accepted; the app runs on real time.
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
                self = .replay(
                    scale: 1, ahead: 0,
                    refusal: "\(ClockMode.scaleFlag) needs a number from \(Int(ClockMode.scaleRange.lowerBound)) to \(Int(ClockMode.scaleRange.upperBound))"
                )
                return
            }
            scale = parsed
        }
        var ahead: TimeInterval = 0
        if let advanceValue {
            guard let text = advanceValue, let parsed = ClockInterval.seconds(from: text), ClockMode.accepts(advance: parsed) else {
                self = .replay(
                    scale: 1, ahead: 0,
                    refusal: "\(ClockMode.advanceFlag) needs an interval such as 15m, 2h, or 1d, up to \(ClockInterval.description(of: ClockMode.maxAdvance))"
                )
                return
            }
            ahead = parsed
        }
        self = .replay(scale: scale, ahead: ahead)
    }

    /// Why a clock flag was not accepted, or nil when none was refused.
    public var refusal: String? {
        switch self {
        case .system: nil
        case .replay(_, _, let refusal): refusal
        case .refused(let reason): reason
        }
    }

    /// Whether one step may move a replay's clock ahead by `seconds`.
    public static func accepts(advance seconds: TimeInterval) -> Bool {
        seconds > 0 && seconds <= maxAdvance
    }

    /// The clock for this mode, and the handle that moves it, which only a
    /// replay has. A replay's clock starts at real time; `startReplay` moves
    /// it to where the replay starts.
    public func makeClock(base: some AthinaClock = SystemClock()) -> (clock: any AthinaClock, control: AdjustableClock?) {
        switch self {
        case .system, .refused:
            return (base, nil)
        case .replay(let scale, _, _):
            let clock = AdjustableClock(running: base, scale: scale)
            return (clock, clock)
        }
    }

    /// Moves a replay's clock to where the replay starts, which is `--advance-clock`
    /// ahead of real time. Every replay makes a directory of its own and so
    /// opens an empty journal, so there is never anything to carry on from.
    public func startReplay(_ clock: AdjustableClock) {
        guard case .replay(_, let ahead, _) = self, ahead > 0 else { return }
        clock.advance(by: .seconds(ahead))
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

/// Moves a replay's clock from another process, with no accessibility: a
/// distributed notification named `name`, whose object is the replay's
/// process id as text and whose user info holds `intervalKey` with an interval
/// as the debug panel's Advance field takes it (`15m`, `2h`, `1d`), and
/// `replyKey` with a file path to answer at.
///
/// A distributed notification reaches only the observers registered when it is
/// posted, and posting says nothing about whether anyone heard it, so a
/// replay that is still starting, a pid that is not Athina, or a live launch
/// that never listens would all look like success. The reply file is what
/// makes a request provable: the replay writes `Reply` there, and
/// `scripts/advance-clock.sh` waits for that file and fails naming the pid
/// when it never appears. Only a replay listens, and only for its own pid, so
/// a request can never reach a live or recording launch or another replay.
public enum ClockRemote {
    public static let name = "com.ahcarpenter.athina.advance-clock"
    public static let intervalKey = "interval"
    public static let replyKey = "replyTo"

    /// Whether a launch in `mode` listens at all.
    public static func listens(in mode: ClockMode) -> Bool {
        if case .replay = mode { return true }
        return false
    }

    /// The object a replay with process id `pid` listens for.
    public static func object(for pid: Int32) -> String {
        String(pid)
    }

    /// The seconds a request asks for, or why it is refused.
    public static func seconds(from userInfo: [AnyHashable: Any]?) -> Result<TimeInterval, Refusal> {
        guard let text = userInfo?[intervalKey] as? String else {
            return .failure(Refusal(reason: "no \(intervalKey) in the request"))
        }
        guard let seconds = ClockInterval.seconds(from: text), ClockMode.accepts(advance: seconds) else {
            return .failure(Refusal(reason: "\"\(text)\" is not an interval such as 15m, 2h, or 1d, up to \(ClockInterval.description(of: ClockMode.maxAdvance))"))
        }
        return .success(seconds)
    }

    /// Where the request asks for its answer, or nil when it asked for none.
    /// A relative path is refused rather than resolved, because the app's
    /// working directory is `/` when it was started with `open`.
    public static func replyURL(from userInfo: [AnyHashable: Any]?) -> URL? {
        guard let path = userInfo?[replyKey] as? String, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// What a replay answers a request with.
    public struct Reply: Codable, Equatable, Sendable {
        /// Whether the clock moved.
        public var moved: Bool
        /// Why it did not, when it did not.
        public var reason: String?
        /// How far the clock has been moved ahead in all, in seconds.
        public var movedAhead: TimeInterval
        /// What the clock reads now.
        public var now: Date
        /// The replay that answered.
        public var pid: Int32

        public init(moved: Bool, reason: String? = nil, movedAhead: TimeInterval, now: Date, pid: Int32 = getpid()) {
            self.moved = moved
            self.reason = reason
            self.movedAhead = movedAhead
            self.now = now
            self.pid = pid
        }

        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
        }

        public static func decode(_ data: Data) throws -> Reply {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Reply.self, from: data)
        }
    }

    /// Answers the request at the path it named, and only where a request may
    /// make a replay write: a file that does not exist yet, inside the system
    /// temporary directory, never inside the live data folder. Does nothing
    /// when the request named none, and throws rather than writing otherwise,
    /// which the caller logs.
    ///
    /// Nothing authenticates this channel. The notification name is a
    /// constant and a replay's pid is in `ps`, so any process in the login
    /// session can ask a running replay to answer somewhere; an unconstrained
    /// path would make that a way to create or replace any file the user can
    /// write, the live settings among them. Refusing to replace a file closes
    /// the rest: the exclusive create fails on a symlink too. It costs
    /// `scripts/advance-clock.sh` nothing, which names a fresh `mktemp` path
    /// that it has already removed, in the per-user temporary directory
    /// (`getconf DARWIN_USER_TEMP_DIR`) that `NSTemporaryDirectory` names.
    ///
    /// The path is resolved once and that one path is both checked and written
    /// to. Checking what was asked for and writing to it are not the same
    /// thing: `..` after a symlink means one path to `AppPaths.resolvedPath`,
    /// which folds `..` away before resolving links, and another to the
    /// kernel, which follows the link first. A request could name
    /// `<temp>/link-into-the-live-folder/../file` and pass a check that read
    /// `<temp>/file` while the write landed in the live data folder.
    public static func answer(
        _ reply: Reply,
        at url: URL?,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        supportDirectory: URL = AppPaths.supportDirectory()
    ) throws {
        guard let url else { return }
        let target = URL(fileURLWithPath: AppPaths.resolvedPath(url))
        guard AppPaths.isAt(target, orInside: temporaryDirectory),
              !AppPaths.isAt(target, orInside: supportDirectory) else {
            throw Refusal(reason: "\(target.path) is not somewhere a clock request may be answered: it must be inside \(temporaryDirectory.path) and outside \(supportDirectory.path)")
        }
        do {
            try reply.encoded().write(to: target, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw Refusal(reason: "\(target.path) already exists, and a clock request never replaces a file")
        }
    }

    public struct Refusal: Error, Equatable {
        public var reason: String
    }
}
