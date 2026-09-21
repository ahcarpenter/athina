import Foundation

/// A `ClaudeClient` that answers from a queue of hand-written responses and
/// records every request, so a test can drive one exact branch of the loop:
/// an error, a refusal, a reply that does not parse, a slow call. Responses are
/// served in the order they were queued, whatever kind of call asks. Recorded
/// responses are served by `ReplayClaudeClient` instead.
public actor ScriptedClaudeClient: ClaudeClient {
    public struct Sent: Sendable {
        public var request: MessagesRequest
        public var call: CallIdentity
        public var apiKey: String
        public var timeout: TimeInterval
    }

    private var queue: [Result<MessagesResponse, ClaudeClientError>]
    public private(set) var sent: [Sent] = []
    /// Optional delay per call, to test in-flight behavior.
    public var delay: Duration = .zero
    /// What the delay is waited out on: a test clock holds a call in flight
    /// until the test advances it.
    private let clock: any AthinaClock

    public init(responses: [Result<MessagesResponse, ClaudeClientError>] = [], clock: any AthinaClock = SystemClock()) {
        queue = responses
        self.clock = clock
    }

    public func enqueue(_ response: Result<MessagesResponse, ClaudeClientError>) {
        queue.append(response)
    }

    public func enqueue(json: String, model: String = "scripted", usage: Usage = Usage(inputTokens: 100, outputTokens: 20)) {
        queue.append(.success(MessagesResponse(
            id: "msg_\(queue.count)", model: model, stopReason: "end_turn",
            content: [ResponseBlock(type: "text", text: json)], usage: usage
        )))
    }

    public func setDelay(_ delay: Duration) {
        self.delay = delay
    }

    public func send(_ request: MessagesRequest, call: CallIdentity, apiKey: String, timeout: TimeInterval) async throws -> MessagesResponse {
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
