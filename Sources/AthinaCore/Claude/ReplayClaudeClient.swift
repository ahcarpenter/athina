import Foundation

/// Answers calls from recorded fixtures with no network at all. Behind
/// `Athina --replay <dir>` and the loop tests that run against the committed
/// fixture set.
///
/// A call is matched on its kind, never on its bytes, because the screen text
/// in a request differs on every run. The fixtures of a kind are served in
/// order and then from the start again, so a long session keeps working and
/// the same calls always get the same answers. A fixture recorded with a
/// different prompt version than the call's is stale: it is refused, naming
/// the fixture and both versions, unless stale fixtures were allowed.
public actor ReplayClaudeClient: ClaudeClient {
    /// One fixture and the name it is reported under.
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var fixture: CallFixture

        public init(name: String, fixture: CallFixture) {
            self.name = name
            self.fixture = fixture
        }
    }

    /// Whether a replayed call takes as long as the recorded one did. The raw
    /// values are what `--replay-latency` takes (`ReplayLatencyMode`).
    public enum Latency: String, CaseIterable, Equatable, Sendable {
        /// Answer at once, for tests and scripted checks.
        case immediate
        /// Wait the recorded latency (never past the call's timeout), so the
        /// app's in-flight states look the way they do live.
        case recorded
    }

    /// One call that was answered or refused, for tests and the log.
    public struct Served: Equatable, Sendable {
        public var call: CallIdentity
        public var request: MessagesRequest
        /// The fixture that answered or was refused; nil when none of the kind exists.
        public var fixtureName: String?
    }

    public nonisolated let entries: [Entry]
    public nonisolated let allowStale: Bool
    public nonisolated let latency: Latency
    /// Set when the fixtures could not be loaded: every call is refused with it.
    public nonisolated let unavailableReason: String?
    /// What a recorded latency is waited out on, so a replay on a faster
    /// clock answers faster too.
    private let clock: any AthinaClock
    private var nextIndex: [String: Int] = [:]
    public private(set) var served: [Served] = []

    public init(entries: [Entry], allowStale: Bool = false, latency: Latency = .immediate, clock: any AthinaClock = SystemClock()) {
        self.entries = entries
        self.allowStale = allowStale
        self.latency = latency
        self.clock = clock
        unavailableReason = nil
    }

    private init(unavailable reason: String) {
        entries = []
        allowStale = false
        latency = .immediate
        clock = SystemClock()
        unavailableReason = reason
    }

    /// A client that refuses every call with `reason`, for a replay that
    /// could not start. It still never touches the network.
    public static func unavailable(_ reason: String) -> ReplayClaudeClient {
        ReplayClaudeClient(unavailable: reason)
    }

    /// Loads every fixture in `directory`. Throws when the directory or a
    /// fixture cannot be read, or when there is nothing to replay.
    public static func load(
        from directory: URL, allowStale: Bool = false, latency: Latency = .immediate, clock: any AthinaClock = SystemClock()
    ) throws -> ReplayClaudeClient {
        let loaded = try CallFixtureFiles.load(from: directory)
        guard !loaded.isEmpty else { throw ReplayLoadError.empty(directory.path) }
        return ReplayClaudeClient(
            entries: loaded.map { Entry(name: $0.name, fixture: $0.fixture) },
            allowStale: allowStale, latency: latency, clock: clock
        )
    }

    public nonisolated var isReplay: Bool { true }

    public func send(_ request: MessagesRequest, call: CallIdentity, apiKey: String, timeout: TimeInterval) async throws -> MessagesResponse {
        if let unavailableReason {
            served.append(Served(call: call, request: request, fixtureName: nil))
            throw ClaudeClientError.replay(unavailableReason)
        }
        let candidates = entries.filter { $0.fixture.identity.kind == call.kind }
        guard !candidates.isEmpty else {
            served.append(Served(call: call, request: request, fixtureName: nil))
            throw ClaudeClientError.replay("no recorded \(call.kind) call to replay")
        }
        let index = nextIndex[call.kind, default: 0] % candidates.count
        nextIndex[call.kind] = index + 1
        let entry = candidates[index]
        served.append(Served(call: call, request: request, fixtureName: entry.name))
        let recordedVersion = entry.fixture.identity.promptVersion
        if recordedVersion != call.promptVersion, !allowStale {
            throw ClaudeClientError.replay(ReplayClaudeClient.staleMessage(
                fixture: entry.name, recorded: recordedVersion, current: call.promptVersion
            ))
        }
        if latency == .recorded, entry.fixture.latency > 0 {
            try await clock.sleep(for: .seconds(min(entry.fixture.latency, timeout)))
        }
        return try entry.fixture.result.get()
    }

    public static func staleMessage(fixture: String, recorded: Int, current: Int) -> String {
        "fixture \(fixture) is stale: recorded with prompt version \(recorded), the current prompt version is \(current). Record it again live with make record, for the committed fixtures in the same change that bumped the version. To replay it anyway while iterating on prompts locally, use \(ModelClientMode.allowStaleFlag) (make run-replay ALLOW_STALE=1)."
    }

    /// What the loaded set holds, for the menu and the debug panel.
    public nonisolated func summary(directory: URL, promptVersion: Int) -> ReplaySummary {
        var counts: [String: Int] = [:]
        var staleVersions = Set<Int>()
        var staleCount = 0
        for entry in entries {
            counts[entry.fixture.identity.kind, default: 0] += 1
            if entry.fixture.identity.promptVersion != promptVersion {
                staleCount += 1
                staleVersions.insert(entry.fixture.identity.promptVersion)
            }
        }
        return ReplaySummary(
            directory: directory,
            countsByKind: counts,
            staleCount: staleCount,
            staleVersions: staleVersions.sorted(),
            promptVersion: promptVersion,
            allowStale: allowStale,
            unavailableReason: unavailableReason
        )
    }
}

/// What a replay is serving from, as the app shows it.
public struct ReplaySummary: Equatable, Sendable {
    public var directory: URL
    public var countsByKind: [String: Int]
    public var staleCount: Int
    public var staleVersions: [Int]
    public var promptVersion: Int
    public var allowStale: Bool
    /// Why nothing can be replayed, when that is the case.
    public var unavailableReason: String?

    public init(
        directory: URL,
        countsByKind: [String: Int],
        staleCount: Int = 0,
        staleVersions: [Int] = [],
        promptVersion: Int,
        allowStale: Bool = false,
        unavailableReason: String? = nil
    ) {
        self.directory = directory
        self.countsByKind = countsByKind
        self.staleCount = staleCount
        self.staleVersions = staleVersions
        self.promptVersion = promptVersion
        self.allowStale = allowStale
        self.unavailableReason = unavailableReason
    }

    public var total: Int { countsByKind.values.reduce(0, +) }

    /// Kinds in the loop's tier order, then any others by name, with counts:
    /// "4 triage, 3 mentor, 1 test".
    public var kindsDescription: String {
        let known = ModelTier.allCases.map(\.rawValue)
        let ordered = countsByKind.keys.sorted { lhs, rhs in
            switch (known.firstIndex(of: lhs), known.firstIndex(of: rhs)) {
            case let (l?, r?): l < r
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs < rhs
            }
        }
        return ordered.map { "\(countsByKind[$0] ?? 0) \($0)" }.joined(separator: ", ")
    }
}
