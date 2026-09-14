import Foundation

/// Where the app's model calls go, chosen once at launch from the command line.
///
/// - no flag: live, to api.anthropic.com
/// - `--record [<dir>]`: live, and every call is also written to `<dir>`
///   (default `CallFixtureFiles.defaultRecordingDirectory()`)
/// - `--replay <dir>`: answered from the fixtures in `<dir>`, with no network,
///   no key, and no spend; `--allow-stale-fixtures` also serves fixtures
///   recorded with another prompt version
///
/// A command line that asks for something contradictory or incomplete is
/// `invalid`: the app then refuses every call with the reason rather than
/// guessing, and never falls back to live calls.
public enum ModelClientMode: Equatable, Sendable {
    case live
    case record(directory: URL)
    case replay(directory: URL, allowStale: Bool)
    case invalid(String)

    public static let recordFlag = "--record"
    public static let replayFlag = "--replay"
    public static let allowStaleFlag = "--allow-stale-fixtures"

    public init(arguments: [String], defaultRecordingDirectory: URL = CallFixtureFiles.defaultRecordingDirectory()) {
        let recordIndex = arguments.firstIndex(of: ModelClientMode.recordFlag)
        let replayIndex = arguments.firstIndex(of: ModelClientMode.replayFlag)
        let allowStale = arguments.contains(ModelClientMode.allowStaleFlag)

        func value(after index: Int) -> String? {
            guard index + 1 < arguments.count else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("--") || next.isEmpty ? nil : next
        }

        switch (recordIndex, replayIndex) {
        case (.some, .some):
            self = .invalid("\(ModelClientMode.recordFlag) and \(ModelClientMode.replayFlag) cannot be combined")
        case (nil, let replay?):
            guard let path = value(after: replay) else {
                self = .invalid("\(ModelClientMode.replayFlag) needs the directory of fixtures to replay")
                return
            }
            self = .replay(directory: ModelClientMode.url(forPath: path), allowStale: allowStale)
        case (let record?, nil):
            guard !allowStale else {
                self = .invalid("\(ModelClientMode.allowStaleFlag) applies only to \(ModelClientMode.replayFlag)")
                return
            }
            self = .record(directory: value(after: record).map(ModelClientMode.url(forPath:)) ?? defaultRecordingDirectory)
        case (nil, nil):
            self = allowStale
                ? .invalid("\(ModelClientMode.allowStaleFlag) applies only to \(ModelClientMode.replayFlag)")
                : .live
        }
    }

    /// Tilde-expanded and made absolute against the current directory.
    static func url(forPath path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// True when no call made in this mode can reach the network or bill.
    public var isOffline: Bool {
        switch self {
        case .live, .record: false
        case .replay, .invalid: true
        }
    }

    /// The client for this mode, plus what a replay is serving from.
    public struct Setup: Sendable {
        public var client: any ClaudeClient
        public var replay: ReplaySummary?
    }

    /// Builds the client. A replay whose fixtures cannot be loaded, and an
    /// invalid command line, get a client that refuses every call with the
    /// reason, so the problem shows up in the call log and nothing goes live.
    public func makeClient(
        prices: PriceTable,
        latency: ReplayClaudeClient.Latency = .recorded,
        promptVersion: Int = MentorPrompts.version,
        live: @Sendable () -> any ClaudeClient = { AnthropicClient() }
    ) -> Setup {
        switch self {
        case .live:
            return Setup(client: live(), replay: nil)
        case .record(let directory):
            return Setup(client: RecordingClaudeClient(wrapping: live(), directory: directory, prices: prices), replay: nil)
        case .replay(let directory, let allowStale):
            let client: ReplayClaudeClient
            do {
                client = try ReplayClaudeClient.load(from: directory, allowStale: allowStale, latency: latency)
            } catch {
                client = .unavailable(String(describing: error))
            }
            return Setup(client: client, replay: client.summary(directory: directory, promptVersion: promptVersion))
        case .invalid(let reason):
            return Setup(client: ReplayClaudeClient.unavailable(reason), replay: nil)
        }
    }
}
