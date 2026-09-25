import Foundation

// MARK: - Request

/// Reasoning depth for models that accept `output_config.effort`.
///
/// Sent as-is; `xhigh` is accepted by every effort-capable model in the
/// catalog.
public enum Effort: String, Codable, CaseIterable, Sendable, Identifiable {
  case low
  case medium
  case high
  case xhigh

  /// The raw value, which identifies a level in the effort picker.
  public var id: String { rawValue }

  /// The level's name in Settings > Models.
  public var label: String {
    switch self {
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra high"
    }
  }
}

/// A prompt-cache marker, the API's `cache_control`.
public struct CacheControl: Codable, Equatable, Sendable {
  /// The cache type; Athina sends only `ephemeral`.
  public var type: String

  /// The API's default marker, which caches for five minutes.
  public static let ephemeral = CacheControl(type: "ephemeral")

  /// Creates a marker of the given cache type.
  public init(type: String) {
    self.type = type
  }
}

/// One block of the system prompt.
///
/// Every Athina system prompt carries a cache marker so repeated calls read it
/// from the prompt cache; a block that changes on every call passes nil.
public struct SystemBlock: Codable, Equatable, Sendable {
  /// The block type, always `text`.
  public var type: String
  /// The prompt text of this block.
  public var text: String
  /// The cache marker, or nil for a block that changes on every call.
  public var cacheControl: CacheControl?

  /// Creates a text block, marked for the cache unless `cacheControl` is nil.
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

/// Who a message is from.
public enum Role: String, Codable, Sendable {
  case user
  case assistant
}

/// A user or assistant content block.
///
/// Images are base64 JPEGs.
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

  /// Decodes a text block or a base64 image block, throwing on any other type.
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
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "unsupported block type \(other)"
      )
    }
  }

  /// Encodes the block in the API's shape, an image as a base64 `source`.
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

/// One turn of the conversation sent to the model.
public struct Message: Codable, Equatable, Sendable {
  /// Who the turn is from.
  public var role: Role
  /// The turn's text and image blocks, in order.
  public var content: [ContentBlock]

  /// Creates a message.
  public init(role: Role, content: [ContentBlock]) {
    self.role = role
    self.content = content
  }
}

/// Structured output: the response text is JSON matching `schema`.
public struct OutputFormat: Codable, Equatable, Sendable {
  /// The format type, always `json_schema`.
  public var type: String
  /// The JSON schema the response text must match.
  public var schema: JSONValue

  /// Creates a JSON schema format for `schema`.
  public init(schema: JSONValue) {
    type = "json_schema"
    self.schema = schema
  }
}

/// The request's `output_config`: structured output and reasoning effort.
public struct OutputConfig: Codable, Equatable, Sendable {
  /// The schema the response must follow, or nil for free text.
  public var format: OutputFormat?
  /// The reasoning effort, or nil to send none, as for a model that rejects it.
  public var effort: Effort?

  /// Creates an output config.
  public init(format: OutputFormat? = nil, effort: Effort? = nil) {
    self.format = format
    self.effort = effort
  }
}

/// A Messages API request body.
///
/// Field names follow the API's snake_case.
public struct MessagesRequest: Codable, Equatable, Sendable {
  /// The model id, such as `claude-opus-5`.
  public var model: String
  /// The most output tokens the response may use.
  ///
  /// A response that reaches it stops with `max_tokens` and is truncated.
  public var maxTokens: Int
  /// The system prompt, block by block.
  public var system: [SystemBlock]
  /// The conversation, oldest turn first.
  public var messages: [Message]
  /// Structured output and effort, or nil to send neither.
  public var outputConfig: OutputConfig?

  /// Creates a request.
  public init(
    model: String,
    maxTokens: Int,
    system: [SystemBlock],
    messages: [Message],
    outputConfig: OutputConfig? = nil
  ) {
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
  /// Input tokens read outside the prompt cache.
  public var inputTokens: Int
  /// Tokens the model generated.
  public var outputTokens: Int
  /// Input tokens written to the prompt cache.
  public var cacheCreationInputTokens: Int
  /// Input tokens read from the prompt cache.
  public var cacheReadInputTokens: Int

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
  }

  /// Creates usage counts, each zero unless given.
  public init(
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    cacheCreationInputTokens: Int = 0,
    cacheReadInputTokens: Int = 0
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheCreationInputTokens = cacheCreationInputTokens
    self.cacheReadInputTokens = cacheReadInputTokens
  }

  /// Decodes usage, reading a count the API leaves out as zero.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
    outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    cacheCreationInputTokens =
      try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
    cacheReadInputTokens =
      try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
  }

  /// Everything the model read, cached or not.
  public var totalInputTokens: Int {
    inputTokens + cacheCreationInputTokens + cacheReadInputTokens
  }
}

/// A response content block.
///
/// Only text blocks matter to Athina; thinking blocks and any future kinds
/// decode to their type and are ignored. Encodable so a recorded call can store
/// the response it replays.
public struct ResponseBlock: Codable, Equatable, Sendable {
  /// The block type, such as `text` or `thinking`.
  public var type: String
  /// The block's text, or nil for a block that carries none.
  public var text: String?

  /// Creates a response block.
  public init(type: String, text: String? = nil) {
    self.type = type
    self.text = text
  }
}

/// A Messages API response, as Athina decodes it.
public struct MessagesResponse: Codable, Equatable, Sendable {
  /// The id the API gave the message.
  public var id: String
  /// The id of the model that answered, which the suggestion, follow-up or
  /// understanding made from the response records.
  public var model: String
  /// Why the model stopped, such as `end_turn`, `max_tokens`, or `refusal`.
  ///
  /// Nil when the API sent none.
  public var stopReason: String?
  /// The response's content blocks, in order.
  public var content: [ResponseBlock]
  /// The call's token counts, which its cost is priced from.
  public var usage: Usage

  /// Creates a response.
  public init(
    id: String,
    model: String,
    stopReason: String?,
    content: [ResponseBlock],
    usage: Usage
  ) {
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

  /// Whether the model declined to answer (`stop_reason` is `refusal`).
  public var isRefusal: Bool { stopReason == "refusal" }
  /// Whether the response was cut off at `max_tokens`.
  public var isTruncated: Bool { stopReason == "max_tokens" }
}

/// The API's error envelope.
public struct APIErrorBody: Decodable, Equatable, Sendable {
  /// The error's type and message.
  public struct Detail: Decodable, Equatable, Sendable {
    /// The API's error type, such as `overloaded_error`.
    public var type: String
    /// The API's explanation of the error.
    public var message: String
  }

  /// The error the API reported.
  public var error: Detail
}

/// Why a model call brought back no response.
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

  /// The error as one line for the call log, such as
  /// `overloaded_error (HTTP 529): Overloaded`.
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

  /// Decodes a recorded error, throwing on an unknown `kind`.
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
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "unknown error kind \(other)"
      )
    }
  }

  /// Encodes the error as its `kind` and message, adding the status and type
  /// for an API error.
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

/// Which kind of call a request is and which prompt version built it.
///
/// The loop passes it with every request, so recording and replay can file and
/// find a call without reading its bytes, which differ on every run. It is
/// opaque to them: a new kind of call needs no change in either.
public struct CallIdentity: Codable, Hashable, Sendable {
  /// The kind of call: the raw value of the tier that made it, such as
  /// `triage` or `mentor`.
  public var kind: String
  /// The prompt version the request was built with.
  public var promptVersion: Int

  /// Creates an identity from a call kind and a prompt version.
  public init(kind: String, promptVersion: Int) {
    self.kind = kind
    self.promptVersion = promptVersion
  }
}

/// Sends one Messages API request.
///
/// The API key is passed per call and never stored.
public protocol ClaudeClient: Sendable {
  /// True when calls are answered from recordings: nothing reaches the
  /// network, nothing is billed, and no key is needed.
  var isReplay: Bool { get }

  func send(
    _ request: MessagesRequest,
    call: CallIdentity,
    apiKey: String,
    timeout: TimeInterval
  ) async throws -> MessagesResponse
}

extension ClaudeClient {
  /// False: a client is live unless it says otherwise.
  public var isReplay: Bool { false }
}

/// The Anthropic Messages API over URLSession.
///
/// The only host Athina ever talks to.
public struct AnthropicClient: ClaudeClient {
  /// The Messages API URL, the only one Athina sends to.
  public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
  /// The `anthropic-version` header every request carries.
  public static let apiVersion = "2023-06-01"

  private let session: URLSession

  /// Creates a client that sends over `session`.
  public init(session: URLSession = AnthropicClient.makeSession()) {
    self.session = session
  }

  /// The most a whole call may take, whatever its own timeout says.
  public static let resourceTimeout: TimeInterval = 600

  /// Returns the session calls go over by default.
  ///
  /// It is ephemeral, so nothing is kept on disk; it fails at once without a
  /// network rather than waiting for one; and it caps a whole call at
  /// `resourceTimeout`.
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

  /// Posts `request` with `apiKey` and returns the decoded response.
  ///
  /// `call` is not sent; only recording and replay use it.
  ///
  /// - Throws: `ClaudeClientError.transport` when the request does not
  ///   complete, `.api` for any status but 200, and `.badResponse` for a body
  ///   that does not decode.
  public func send(
    _ request: MessagesRequest,
    call: CallIdentity,
    apiKey: String,
    timeout: TimeInterval
  ) async throws -> MessagesResponse {
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

  /// Maps a status and body to a response or a typed error.
  ///
  /// Shared with tests.
  public static func decode(status: Int, body: Data) throws -> MessagesResponse {
    let decoder = JSONDecoder()
    guard status == 200 else {
      if let envelope = try? decoder.decode(APIErrorBody.self, from: body) {
        throw ClaudeClientError.api(
          status: status,
          type: envelope.error.type,
          message: envelope.error.message
        )
      }
      let text = String(decoding: body.prefix(200), as: UTF8.self)
      throw ClaudeClientError.api(
        status: status,
        type: "http_error",
        message: text.isEmpty ? "empty body" : text
      )
    }
    do {
      return try decoder.decode(MessagesResponse.self, from: body)
    } catch {
      throw ClaudeClientError.badResponse(String(describing: error))
    }
  }
}
