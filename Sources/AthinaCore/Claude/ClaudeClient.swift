import Foundation

// MARK: - Request

/// Reasoning depth for models that accept `output_config.effort`. Sent as-is;
/// `xhigh` is accepted by every effort-capable model in the catalog.
public enum Effort: String, Codable, CaseIterable, Sendable, Identifiable {
    case low
    case medium
    case high
    case xhigh

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        }
    }
}

public struct CacheControl: Codable, Equatable, Sendable {
    public var type: String

    public static let ephemeral = CacheControl(type: "ephemeral")

    public init(type: String) {
        self.type = type
    }
}

/// One block of the system prompt. Every Athina system prompt carries a
/// cache marker so repeated calls read it from the prompt cache; a block that
/// changes on every call passes nil.
public struct SystemBlock: Codable, Equatable, Sendable {
    public var type: String
    public var text: String
    public var cacheControl: CacheControl?

    public init(text: String, cacheControl: CacheControl? = .ephemeral) {
        type = "text"
        self.text = text
        self.cacheControl = cacheControl
    }

    private enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }
}

public enum Role: String, Codable, Sendable {
    case user
    case assistant
}

/// A user or assistant content block. Images are base64 JPEGs.
public enum ContentBlock: Codable, Equatable, Sendable {
    case text(String)
    case image(mediaType: String, base64: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, source
    }

    private enum SourceKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            let source = try container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            self = .image(
                mediaType: try source.decode(String.self, forKey: .mediaType),
                base64: try source.decode(String.self, forKey: .data)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unsupported block type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mediaType, let base64):
            try container.encode("image", forKey: .type)
            var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try source.encode("base64", forKey: .type)
            try source.encode(mediaType, forKey: .mediaType)
            try source.encode(base64, forKey: .data)
        }
    }
}

public struct Message: Codable, Equatable, Sendable {
    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }
}

/// Structured output: the response text is JSON matching `schema`.
public struct OutputFormat: Codable, Equatable, Sendable {
    public var type: String
    public var schema: JSONValue

    public init(schema: JSONValue) {
        type = "json_schema"
        self.schema = schema
    }
}

public struct OutputConfig: Codable, Equatable, Sendable {
    public var format: OutputFormat?
    public var effort: Effort?

    public init(format: OutputFormat? = nil, effort: Effort? = nil) {
        self.format = format
        self.effort = effort
    }
}

/// A Messages API request body. Field names follow the API's snake_case.
public struct MessagesRequest: Codable, Equatable, Sendable {
    public var model: String
    public var maxTokens: Int
    public var system: [SystemBlock]
    public var messages: [Message]
    public var outputConfig: OutputConfig?

    public init(model: String, maxTokens: Int, system: [SystemBlock], messages: [Message], outputConfig: OutputConfig? = nil) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.outputConfig = outputConfig
    }

    private enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }

    /// Characters of prompt text (system plus text blocks), for the call log.
    public var promptCharacterCount: Int {
        var count = system.reduce(0) { $0 + $1.text.count }
        for message in messages {
            for block in message.content {
                if case .text(let text) = block { count += text.count }
            }
        }
        return count
    }

    /// Bytes of image data across all messages, decoded from base64.
    public var imageByteCount: Int {
        var count = 0
        for message in messages {
            for block in message.content {
                guard case .image(_, let base64) = block else { continue }
                let padding = base64.hasSuffix("==") ? 2 : (base64.hasSuffix("=") ? 1 : 0)
                count += base64.utf8.count * 3 / 4 - padding
            }
        }
        return count
    }
}

// MARK: - Response

/// Token counts the API reports for one response.
public struct Usage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int = 0, cacheReadInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
    }

    /// Everything the model read, cached or not.
    public var totalInputTokens: Int {
        inputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }
}

/// A response content block. Only text blocks matter to Athina; thinking
/// blocks and any future kinds decode to their type and are ignored. Encodable
/// so a recorded call can store the response it replays.
public struct ResponseBlock: Codable, Equatable, Sendable {
    public var type: String
    public var text: String?

    public init(type: String, text: String? = nil) {
        self.type = type
        self.text = text
    }
}

public struct MessagesResponse: Codable, Equatable, Sendable {
    public var id: String
    public var model: String
    public var stopReason: String?
    public var content: [ResponseBlock]
    public var usage: Usage

    public init(id: String, model: String, stopReason: String?, content: [ResponseBlock], usage: Usage) {
        self.id = id
        self.model = model
        self.stopReason = stopReason
        self.content = content
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case id, model, content, usage
        case stopReason = "stop_reason"
    }

    /// The text blocks joined, which for structured output is the JSON document.
    public var text: String {
        content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }

    public var isRefusal: Bool { stopReason == "refusal" }
    public var isTruncated: Bool { stopReason == "max_tokens" }
}

/// The API's error envelope.
public struct APIErrorBody: Decodable, Equatable, Sendable {
    public struct Detail: Decodable, Equatable, Sendable {
        public var type: String
        public var message: String
    }

    public var error: Detail
}

public enum ClaudeClientError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The API answered with an error status and, when it sent one, its own message.
    case api(status: Int, type: String, message: String)
    /// The request never completed: no network, timeout, TLS failure.
    case transport(String)
    /// A 200 whose body could not be decoded.
    case badResponse(String)
    /// A replay client had no recorded answer it may serve, and why. Nothing
    /// was sent anywhere.
    case replay(String)
    /// A live client would not send the call, and why. Nothing was sent.
    case notSent(String)

    public var description: String {
        switch self {
        case .api(let status, let type, let message): "\(type) (HTTP \(status)): \(message)"
        case .transport(let message): "network: \(message)"
        case .badResponse(let message): "bad response: \(message)"
        case .replay(let message): "replay: \(message)"
        case .notSent(let message): "not sent: \(message)"
        }
    }
}

/// Recorded errors are stored as `{"kind": ..., "message": ...}`, with the
/// status and type too for an API error.
extension ClaudeClientError: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, status, type, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decode(String.self, forKey: .message)
        switch try container.decode(String.self, forKey: .kind) {
        case "api":
            self = .api(
                status: try container.decode(Int.self, forKey: .status),
                type: try container.decode(String.self, forKey: .type),
                message: message
            )
        case "transport": self = .transport(message)
        case "badResponse": self = .badResponse(message)
        case "replay": self = .replay(message)
        case "notSent": self = .notSent(message)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown error kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .api(let status, let type, let message):
            try container.encode("api", forKey: .kind)
            try container.encode(status, forKey: .status)
            try container.encode(type, forKey: .type)
            try container.encode(message, forKey: .message)
        case .transport(let message):
            try container.encode("transport", forKey: .kind)
            try container.encode(message, forKey: .message)
        case .badResponse(let message):
            try container.encode("badResponse", forKey: .kind)
            try container.encode(message, forKey: .message)
        case .replay(let message):
            try container.encode("replay", forKey: .kind)
            try container.encode(message, forKey: .message)
        case .notSent(let message):
            try container.encode("notSent", forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

// MARK: - Client

/// Which kind of call a request is and which prompt version built it. The loop
/// passes it with every request, so recording and replay can file and find a
/// call without reading its bytes, which differ on every run. It is opaque to
/// them: a new kind of call needs no change in either.
public struct CallIdentity: Codable, Hashable, Sendable {
    /// The kind of call: the raw value of the tier that made it, such as
    /// `triage` or `mentor`.
    public var kind: String
    /// The prompt version the request was built with.
    public var promptVersion: Int

    public init(kind: String, promptVersion: Int) {
        self.kind = kind
        self.promptVersion = promptVersion
    }
}

/// Sends one Messages API request. The API key is passed per call and never stored.
public protocol ClaudeClient: Sendable {
    /// True when calls are answered from recordings: nothing reaches the
    /// network, nothing is billed, and no key is needed.
    var isReplay: Bool { get }

    func send(_ request: MessagesRequest, call: CallIdentity, apiKey: String, timeout: TimeInterval) async throws -> MessagesResponse
}

extension ClaudeClient {
    public var isReplay: Bool { false }
}

/// The Anthropic Messages API over URLSession. The only host Athina ever talks to.
public struct AnthropicClient: ClaudeClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"

    private let session: URLSession

    public init(session: URLSession = AnthropicClient.makeSession()) {
        self.session = session
    }

    /// The most a whole call may take, whatever its own timeout says.
    public static let resourceTimeout: TimeInterval = 600

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpAdditionalHeaders = nil
        return URLSession(configuration: configuration)
    }

    /// Deterministic encoding: sorted keys keep the cached prefix byte-identical between calls.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public func send(_ request: MessagesRequest, call: CallIdentity, apiKey: String, timeout: TimeInterval) async throws -> MessagesResponse {
        var urlRequest = URLRequest(url: AnthropicClient.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(AnthropicClient.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.httpBody = try AnthropicClient.encoder.encode(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ClaudeClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeClientError.badResponse("not an HTTP response")
        }
        return try AnthropicClient.decode(status: http.statusCode, body: data)
    }

    /// Maps a status and body to a response or a typed error. Shared with tests.
    public static func decode(status: Int, body: Data) throws -> MessagesResponse {
        let decoder = JSONDecoder()
        guard status == 200 else {
            if let envelope = try? decoder.decode(APIErrorBody.self, from: body) {
                throw ClaudeClientError.api(status: status, type: envelope.error.type, message: envelope.error.message)
            }
            let text = String(decoding: body.prefix(200), as: UTF8.self)
            throw ClaudeClientError.api(status: status, type: "http_error", message: text.isEmpty ? "empty body" : text)
        }
        do {
            return try decoder.decode(MessagesResponse.self, from: body)
        } catch {
            throw ClaudeClientError.badResponse(String(describing: error))
        }
    }
}
