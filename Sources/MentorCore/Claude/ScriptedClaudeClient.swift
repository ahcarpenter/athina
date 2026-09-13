import Foundation

/// A `ClaudeClient` that answers from a queue and records every request, so
/// the loop can be exercised without the network.
public actor ScriptedClaudeClient: ClaudeClient {
    public struct Sent: Sendable {
        public var request: MessagesRequest
        public var apiKey: String
        public var timeout: TimeInterval
    }

    private var queue: [Result<MessagesResponse, ClaudeClientError>]
    public private(set) var sent: [Sent] = []
    /// Optional delay per call, to test in-flight behavior.
    public var delay: Duration = .zero

    public init(responses: [Result<MessagesResponse, ClaudeClientError>] = []) {
        queue = responses
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

    public func send(_ request: MessagesRequest, apiKey: String, timeout: TimeInterval) async throws -> MessagesResponse {
        sent.append(Sent(request: request, apiKey: apiKey, timeout: timeout))
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        guard !queue.isEmpty else {
            throw ClaudeClientError.transport("scripted client has no response queued")
        }
        return try queue.removeFirst().get()
    }
}
