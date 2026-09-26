import Foundation

/// How long a replayed call takes to answer, chosen once at launch from the
/// command line.
///
/// A replay waits out each call's recorded latency by default, so its
/// in-flight states look the way they do live and `make run` still
/// looks like a live session:
///
/// - `--replay-latency immediate`: every replayed call is answered at once,
///   for a scripted check that waits on what the calls produce, such as the
///   end-to-end harness waiting for a toast
/// - `--replay-latency recorded`: the default, named
///
/// The flag on a live or recording launch is refused, like the clock flags:
/// nothing there is replayed, so the launch says why rather than ignore it. A
/// command line that asked for a replay it could not start is offline too, and
/// is treated as a replay. A value that is neither is refused and said the
/// same way, and the replay keeps the recorded latency.
public struct ReplayLatencyMode: Equatable, Sendable {
  /// What the replay client waits out on each call.
  public var latency: ReplayClaudeClient.Latency
  /// Why the flag was not accepted, or nil when it was or was not given.
  public var refusal: String?

  /// The command-line flag that chooses the latency.
  public static let flag = "--replay-latency"

  /// Creates a mode with this latency and refusal; the defaults are the
  /// recorded latency and no refusal.
  public init(latency: ReplayClaudeClient.Latency = .recorded, refusal: String? = nil) {
    self.latency = latency
    self.refusal = refusal
  }

  /// Reads the latency flag from the launch's command-line arguments.
  ///
  /// - Parameters:
  ///   - arguments: The launch's command-line arguments.
  ///   - clientMode: The launch's model client mode; the flag is honored only
  ///     in a replay, including one that could not start.
  public init(arguments: [String], clientMode: ModelClientMode) {
    guard let index = arguments.firstIndex(of: ReplayLatencyMode.flag) else {
      self.init()
      return
    }
    guard clientMode.isOffline else {
      self.init(refusal: "\(ReplayLatencyMode.flag) applies only to \(ModelClientMode.replayFlag)")
      return
    }
    let value = index + 1 < arguments.count ? arguments[index + 1] : ""
    guard let latency = ReplayClaudeClient.Latency(rawValue: value) else {
      let choices = ReplayClaudeClient.Latency.allCases.map(\.rawValue).joined(separator: " or ")
      self.init(refusal: "\(ReplayLatencyMode.flag) needs \(choices)")
      return
    }
    self.init(latency: latency)
  }
}
