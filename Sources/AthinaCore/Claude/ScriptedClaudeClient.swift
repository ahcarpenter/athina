import Foundation

/// A `ClaudeClient` that answers from a queue of hand-written responses and
/// records every request, so a test can drive one exact branch of the loop:
/// an error, a refusal, a reply that does not parse, a slow call. Responses are
/// served in the order they were queued, whatever kind of call asks. Recorded
/// responses are served by `ReplayClaudeClient` instead.
public actor ScriptedClaudeClient: ClaudeClient {
  /// One call the client received, with everything it was given.
  public struct Sent: Sendable {
    /// The request as the loop built it.
    public var request: MessagesRequest
    /// The identity the call was made with.
    public var call: CallIdentity
    /// The key the call was made with.
    public var apiKey: String
    /// The call's timeout, in seconds.
    public var timeout: TimeInterval
  }

  private var queue: [Result<MessagesResponse, ClaudeClientError>]
  /// Every call received so far, oldest first.
  public private(set) var sent: [Sent] = []
  /// Optional delay per call, to test in-flight behavior.
  public var delay: Duration = .zero
  /// What the delay is waited out on: a test clock holds a call in flight
  /// until the test advances it.
  private let clock: any AthinaClock

  /// Creates a client that serves `responses` in order.
  ///
  /// `clock` is what a delay is waited out on.
  public init(
    responses: [Result<MessagesResponse, ClaudeClientError>] = [],
    clock: any AthinaClock = SystemClock()
  ) {
    queue = responses
    self.clock = clock
  }

  /// Queues a response or an error to serve after those already queued.
  public func enqueue(_ response: Result<MessagesResponse, ClaudeClientError>) {
    queue.append(response)
  }

  /// Queues a successful response whose text is `json`, as a reply that ended
  /// normally.
  ///
  /// - Parameters:
  ///   - json: The response text.
  ///   - model: The model id the response names.
  ///   - usage: The token counts it reports.
  public func enqueue(
    json: String,
    model: String = "scripted",
    usage: Usage = Usage(inputTokens: 100, outputTokens: 20)
  ) {
    queue.append(
      .success(
        MessagesResponse(
          id: "msg_\(queue.count)",
          model: model,
          stopReason: "end_turn",
          content: [ResponseBlock(type: "text", text: json)],
          usage: usage
        )
      )
    )
  }

  /// Sets how long each later call waits before it is answered.
  public func setDelay(_ delay: Duration) {
    self.delay = delay
  }

  /// Records the call, waits out `delay`, and serves the next queued response.
  ///
  /// - Throws: The queued error, or a transport error when nothing is queued.
  public func send(
    _ request: MessagesRequest,
    call: CallIdentity,
    apiKey: String,
    timeout: TimeInterval
  ) async throws -> MessagesResponse {
    sent.append(Sent(request: request, call: call, apiKey: apiKey, timeout: timeout))
    if delay > .zero {
      try? await clock.sleep(for: delay)
    }
    guard !queue.isEmpty else {
      throw ClaudeClientError.transport("scripted client has no response queued")
    }
    return try queue.removeFirst().get()
  }
}
