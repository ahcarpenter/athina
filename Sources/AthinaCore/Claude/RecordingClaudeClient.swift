import Foundation
import OSLog

/// Wraps any `ClaudeClient` and writes every call it passes through as one
/// fixture file, success or error, then hands back exactly what the wrapped
/// client returned or threw. Behind `Athina --record`.
///
/// The key is used only to redact itself from the file. A fixture that cannot
/// be written is logged and the call goes on: recording never changes what the
/// loop sees.
public actor RecordingClaudeClient: ClaudeClient {
  private static let log = Logger(subsystem: "com.ahcarpenter.athina", category: "recording")

  /// Where each call's fixture file is written.
  public nonisolated let directory: URL
  private let inner: any ClaudeClient
  private let prices: PriceTable
  /// Stamps each recording and times its call; a recording always runs on real time.
  private let clock: any AthinaClock
  /// The last call's stamp.
  ///
  /// Each call is stamped when it starts, in a later millisecond than this, so
  /// the files sort in the order the calls were made.
  private var lastStamp: Date?
  /// The files written so far this run, oldest first.
  public private(set) var written: [URL] = []

  /// Creates a recorder around `inner`.
  ///
  /// - Parameters:
  ///   - inner: The client that makes the call, the live one behind `--record`.
  ///   - directory: Where the fixture files go.
  ///   - prices: What each fixture's estimated cost is priced from.
  ///   - clock: What each recording is stamped and timed with.
  public init(
    wrapping inner: any ClaudeClient,
    directory: URL,
    prices: PriceTable,
    clock: any AthinaClock = SystemClock()
  ) {
    self.inner = inner
    self.directory = directory
    self.prices = prices
    self.clock = clock
  }

  /// Sends the call through the wrapped client, writes it as a fixture, and
  /// returns or throws what the wrapped client did.
  ///
  /// A fixture that cannot be written is logged and changes nothing about the
  /// call. An error other than a `ClaudeClientError` is recorded as a transport
  /// error but rethrown as it was.
  public func send(
    _ request: MessagesRequest,
    call: CallIdentity,
    apiKey: String,
    timeout: TimeInterval
  ) async throws -> MessagesResponse {
    let started = CallFixtureFiles.recordingStamp(at: clock.date, after: lastStamp)
    lastStamp = started
    var thrown: (any Error)?
    var result: Result<MessagesResponse, ClaudeClientError> = .failure(
      .transport("the call did not run")
    )
    let elapsed = await clock.measure {
      do {
        result = .success(
          try await inner.send(request, call: call, apiKey: apiKey, timeout: timeout)
        )
      } catch let error as ClaudeClientError {
        thrown = error
        result = .failure(error)
      } catch {
        thrown = error
        result = .failure(.transport(error.localizedDescription))
      }
    }
    let usage = (try? result.get().usage) ?? Usage()
    let fixture = CallFixture(
      identity: call,
      recordedAt: started,
      request: request,
      result: result,
      latency: elapsed.timeInterval,
      cost: prices.cost(of: usage, model: request.model) ?? 0
    )
    do {
      let url = try CallFixtureFiles.write(fixture, to: directory, redacting: apiKey)
      written.append(url)
      RecordingClaudeClient.log.notice(
        "recorded \(call.kind, privacy: .public) call to \(url.lastPathComponent, privacy: .public)"
      )
    } catch {
      RecordingClaudeClient.log.error(
        "recording not written: \(String(describing: error), privacy: .public)"
      )
    }
    if let thrown { throw thrown }
    return try result.get()
  }
}

/// Sends nothing and refuses every call with one reason, for a recording whose
/// directory cannot be written.
///
/// It is not a replay: the loop reads the key as for any live launch, and each
/// refused call is journaled as a live error that cost nothing.
public struct RefusingClaudeClient: ClaudeClient {
  /// Why nothing can be recorded, which every refused call carries.
  public let reason: String

  /// Creates a client that refuses every call with `reason`.
  public init(reason: String) {
    self.reason = reason
  }

  /// Throws `ClaudeClientError.notSent` with the reason, sending nothing.
  public func send(
    _ request: MessagesRequest,
    call: CallIdentity,
    apiKey: String,
    timeout: TimeInterval
  ) async throws -> MessagesResponse {
    throw ClaudeClientError.notSent(reason)
  }
}
