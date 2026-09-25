import Foundation

/// Where the app's model calls go, chosen once at launch from the command line.
///
/// - no flag: live, to api.anthropic.com
/// - `--record [<dir>]`: live, and every call is also written to `<dir>`
///   (default `CallFixtureFiles.defaultRecordingDirectory()`). A relative
///   `<dir>` is taken inside that directory, never against the working
///   directory, which is `/` for an app started with `open`. When the
///   directory cannot be created or written, every call is refused with the
///   reason and nothing goes live.
/// - `--replay <dir>`: answered from the fixtures in `<dir>`, with no network,
///   no key, and no spend; `--allow-stale-fixtures` also serves fixtures
///   recorded with another prompt version
///
/// A command line that asks for something contradictory or incomplete is
/// `invalid`: the app then refuses every call with the reason rather than
/// guessing, and never falls back to live calls. So is one that names a
/// directory a sandboxed process cannot reach (`RuntimeEnvironment`): the
/// fixtures to replay must be inside its container or its own bundle, and a
/// recording inside its container.
public enum ModelClientMode: Equatable, Sendable {
  case live
  case record(directory: URL)
  case replay(directory: URL, allowStale: Bool)
  case invalid(String)

  public static let recordFlag = "--record"
  public static let replayFlag = "--replay"
  public static let allowStaleFlag = "--allow-stale-fixtures"

  public init(
    arguments: [String],
    defaultRecordingDirectory: URL = CallFixtureFiles.defaultRecordingDirectory(),
    environment: RuntimeEnvironment = .current
  ) {
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
      self = .invalid(
        "\(ModelClientMode.recordFlag) and \(ModelClientMode.replayFlag) cannot be combined"
      )
    case (nil, let replay?):
      guard let path = value(after: replay) else {
        self = .invalid("\(ModelClientMode.replayFlag) needs the directory of fixtures to replay")
        return
      }
      let directory = ModelClientMode.url(forPath: path)
      if let refusal = environment.refusal(reading: directory, for: ModelClientMode.replayFlag) {
        self = .invalid(refusal)
        return
      }
      self = .replay(directory: directory, allowStale: allowStale)
    case (let record?, nil):
      guard !allowStale else {
        self = .invalid(
          "\(ModelClientMode.allowStaleFlag) applies only to \(ModelClientMode.replayFlag)"
        )
        return
      }
      let directory =
        value(after: record).map {
          ModelClientMode.url(forPath: $0, relativeTo: defaultRecordingDirectory)
        }
        ?? defaultRecordingDirectory
      if let refusal = environment.refusal(writing: directory, for: ModelClientMode.recordFlag) {
        self = .invalid(refusal)
        return
      }
      self = .record(directory: directory)
    case (nil, nil):
      self =
        allowStale
        ? .invalid(
          "\(ModelClientMode.allowStaleFlag) applies only to \(ModelClientMode.replayFlag)"
        )
        : .live
    }
  }

  /// Tilde-expanded and made absolute: a relative path is taken inside
  /// `base`, or against the current directory when there is none.
  static func url(forPath path: String, relativeTo base: URL? = nil) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    guard let base, !expanded.hasPrefix("/") else {
      return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
    return base.appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
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
    /// Why a recording cannot be written, when that is the case.
    public var recordingUnavailableReason: String?
  }

  /// Builds the client.
  ///
  /// A replay whose fixtures cannot be loaded and an invalid command line get a
  /// replay client that refuses every call with the reason; a recording whose
  /// directory cannot be written gets a `RefusingClaudeClient`, which is not a
  /// replay. Either way the problem shows up in the call log and nothing goes
  /// live. `clock` is what a replayed latency is waited out on and a recording
  /// is stamped with.
  public func makeClient(
    prices: PriceTable,
    clock: any AthinaClock = SystemClock(),
    latency: ReplayClaudeClient.Latency = .recorded,
    promptVersion: Int = MentorPrompts.version,
    live: @Sendable () -> any ClaudeClient = { AnthropicClient() }
  ) -> Setup {
    switch self {
    case .live:
      return Setup(client: live(), replay: nil)
    case .record(let directory):
      do {
        try CallFixtureFiles.checkWritable(directory)
      } catch {
        let reason = "cannot record to \(directory.path): \(error.localizedDescription)"
        return Setup(
          client: RefusingClaudeClient(reason: reason),
          replay: nil,
          recordingUnavailableReason: reason
        )
      }
      return Setup(
        client: RecordingClaudeClient(
          wrapping: live(),
          directory: directory,
          prices: prices,
          clock: clock
        ),
        replay: nil
      )
    case .replay(let directory, let allowStale):
      let client: ReplayClaudeClient
      do {
        client = try ReplayClaudeClient.load(
          from: directory,
          allowStale: allowStale,
          latency: latency,
          clock: clock
        )
      } catch {
        client = .unavailable(String(describing: error))
      }
      return Setup(
        client: client,
        replay: client.summary(directory: directory, promptVersion: promptVersion)
      )
    case .invalid(let reason):
      return Setup(client: ReplayClaudeClient.unavailable(reason), replay: nil)
    }
  }
}
