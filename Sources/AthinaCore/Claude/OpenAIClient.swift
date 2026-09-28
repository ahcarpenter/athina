import Foundation

/// The OpenAI Responses API over URLSession: the Codex models, with the
/// person's OpenAI key.
///
/// Every call is mapped onto the Responses API's own request shape with its
/// words unchanged: the system blocks become one developer message, one text
/// part per block; the screenshot a base64 JPEG data URL; the schema a strict
/// `json_schema` format. The reply is mapped back onto `MessagesResponse`, so
/// the loop reads every provider's answer the same way. Nothing is stored at
/// OpenAI (`store: false`). OpenCode's Zen gateway serves its GPT models behind the same
/// shape at its own endpoint (`OpenCodeClient`).
public struct OpenAIClient: ClaudeClient {
  /// OpenAI's Responses API URL.
  public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

  private let session: URLSession
  private let endpoint: URL

  /// Creates a client that posts to `endpoint` over `session`.
  public init(
    endpoint: URL = OpenAIClient.endpoint,
    session: URLSession = AnthropicClient.makeSession()
  ) {
    self.endpoint = endpoint
    self.session = session
  }

  /// Posts `request`, mapped to the Responses API, with the route's key as a
  /// bearer token, and returns the reply mapped back.
  ///
  /// - Throws: `ClaudeClientError.transport` when the request does not
  ///   complete, `.api` for any status but 200, and `.badResponse` for a body
  ///   that does not decode or a response that failed.
  public func send(
    _ request: MessagesRequest,
    call: CallIdentity,
    route: CallRoute,
    timeout: TimeInterval
  ) async throws -> MessagesResponse {
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = timeout
    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
    urlRequest.setValue("Bearer \(route.key)", forHTTPHeaderField: "authorization")
    urlRequest.httpBody = try OpenAIClient.body(for: request, call: call)

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
    return try OpenAIClient.decode(status: http.statusCode, body: data)
  }

  // MARK: Request

  /// The Responses API body for `request`, with sorted keys so the same call
  /// always sends the same bytes.
  ///
  /// The schema is named after the call's kind, which the API requires of a
  /// strict format.
  public static func body(for request: MessagesRequest, call: CallIdentity) throws -> Data {
    var input: [JSONValue] = []
    if !request.system.isEmpty {
      input.append(
        [
          "role": "developer",
          "content": .array(
            request.system.map { ["type": "input_text", "text": .string($0.text)] }
          ),
        ]
      )
    }
    for message in request.messages {
      let textType: JSONValue = message.role == .assistant ? "output_text" : "input_text"
      let parts: [JSONValue] = message.content.map { block in
        switch block {
        case .text(let text):
          return ["type": textType, "text": .string(text)]
        case .image(let mediaType, let base64):
          return [
            "type": "input_image",
            "image_url": .string("data:\(mediaType);base64,\(base64)"),
            "detail": "auto",
          ]
        }
      }
      input.append(["role": .string(message.role.rawValue), "content": .array(parts)])
    }
    var body: [String: JSONValue] = [
      "model": .string(request.model),
      "input": .array(input),
      "max_output_tokens": .number(Double(request.maxTokens)),
      "store": false,
    ]
    // Reasoning counts against max_output_tokens, so it gets room of its own
    // rather than spending a short reply's budget.
    if let effort = request.outputConfig?.effort {
      body["reasoning"] = ["effort": .string(effort.rawValue)]
      body["max_output_tokens"] = .number(
        Double(request.maxTokens + MentorLoop.thinkingAllowance)
      )
    }
    if let format = request.outputConfig?.format {
      body["text"] = [
        "format": [
          "type": "json_schema",
          "name": .string("athina_\(call.kind)"),
          "strict": true,
          "schema": format.schema,
        ]
      ]
    }
    return try AnthropicClient.encoder.encode(JSONValue.object(body))
  }

  // MARK: Response

  /// A Responses API reply, as far as Athina reads it.
  struct Reply: Decodable {
    struct Item: Decodable {
      struct Part: Decodable {
        var type: String
        var text: String?
        var refusal: String?
      }
      var type: String
      var content: [Part]?
    }
    struct Incomplete: Decodable {
      var reason: String?
    }
    struct Failure: Decodable {
      var code: String?
      var message: String?
    }
    struct Tokens: Decodable {
      struct InputDetails: Decodable {
        var cachedTokens: Int?
        var cacheWriteTokens: Int?
        private enum CodingKeys: String, CodingKey {
          case cachedTokens = "cached_tokens"
          case cacheWriteTokens = "cache_write_tokens"
        }
      }
      var inputTokens: Int
      var outputTokens: Int
      var inputTokensDetails: InputDetails?
      private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case inputTokensDetails = "input_tokens_details"
      }
    }
    var id: String
    var model: String
    var status: String?
    var incompleteDetails: Incomplete?
    var error: Failure?
    var output: [Item]
    var usage: Tokens?
    private enum CodingKeys: String, CodingKey {
      case id, model, status, error, output, usage
      case incompleteDetails = "incomplete_details"
    }
  }

  /// OpenAI's error envelope; its type can be null, and its code says more.
  struct ErrorBody: Decodable {
    struct Detail: Decodable {
      var type: String?
      var code: String?
      var message: String
    }
    var error: Detail
  }

  /// Maps a status and body to a response in the Messages API's terms, or a
  /// typed error.
  ///
  /// A refusal part stops with `refusal`; a reply cut off at
  /// `max_output_tokens` stops with `max_tokens`, and one stopped by the
  /// content filter counts as a refusal; the output text parts are the text.
  /// Cached input tokens count as cache reads and cache writes as cache
  /// writes, so every provider's usage is priced the same way. Shared with
  /// tests.
  public static func decode(status: Int, body: Data) throws -> MessagesResponse {
    let decoder = JSONDecoder()
    guard status == 200 else {
      if let envelope = try? decoder.decode(ErrorBody.self, from: body) {
        throw ClaudeClientError.api(
          status: status,
          type: envelope.error.type ?? envelope.error.code ?? "http_error",
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
    let reply: Reply
    do {
      reply = try decoder.decode(Reply.self, from: body)
    } catch {
      throw ClaudeClientError.badResponse(String(describing: error))
    }
    if reply.status == "failed" {
      throw ClaudeClientError.badResponse(
        "the response failed: \(reply.error?.message ?? reply.error?.code ?? "no reason given")"
      )
    }
    let parts = reply.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
    let blocks = parts.compactMap { part in
      part.type == "output_text" ? ResponseBlock(type: "text", text: part.text ?? "") : nil
    }
    let stopReason: String
    if parts.contains(where: { $0.type == "refusal" }) {
      stopReason = "refusal"
    } else if reply.status == "incomplete" {
      stopReason =
        reply.incompleteDetails?.reason == "content_filter" ? "refusal" : "max_tokens"
    } else {
      stopReason = "end_turn"
    }
    let cached = reply.usage?.inputTokensDetails?.cachedTokens ?? 0
    let written = reply.usage?.inputTokensDetails?.cacheWriteTokens ?? 0
    let usage = Usage(
      inputTokens: max(0, (reply.usage?.inputTokens ?? 0) - cached - written),
      outputTokens: reply.usage?.outputTokens ?? 0,
      cacheCreationInputTokens: written,
      cacheReadInputTokens: cached
    )
    return MessagesResponse(
      id: reply.id,
      model: reply.model,
      stopReason: stopReason,
      content: blocks,
      usage: usage
    )
  }
}

/// OpenCode, through its Zen API gateway, with the person's OpenCode key.
///
/// Zen serves each model family behind its own maker's request shape: Claude
/// models at its Messages endpoint and GPT models at its Responses endpoint
/// (opencode.ai/docs/zen, "Endpoints"). Each call goes to the one its model
/// uses, which the catalog records (`ClaudeModel.api`).
public struct OpenCodeClient: ClaudeClient {
  /// Zen's Anthropic-shaped endpoint, for its Claude models.
  public static let messagesEndpoint = URL(string: "https://opencode.ai/zen/v1/messages")!
  /// Zen's OpenAI-shaped endpoint, for its GPT models.
  public static let responsesEndpoint = URL(string: "https://opencode.ai/zen/v1/responses")!

  private let messages: any ClaudeClient
  private let responses: any ClaudeClient

  /// Creates a client that sends each family to its endpoint.
  public init(
    messages: any ClaudeClient = AnthropicClient(endpoint: OpenCodeClient.messagesEndpoint),
    responses: any ClaudeClient = OpenAIClient(endpoint: OpenCodeClient.responsesEndpoint)
  ) {
    self.messages = messages
    self.responses = responses
  }

  /// Sends the call to the endpoint its model's family uses.
  ///
  /// - Throws: `ClaudeClientError.notSent` for a model the catalog does not
  ///   list for OpenCode, sending nothing.
  public func send(
    _ request: MessagesRequest,
    call: CallIdentity,
    route: CallRoute,
    timeout: TimeInterval
  ) async throws -> MessagesResponse {
    guard let model = ModelCatalog.model(id: request.model, provider: .openCode) else {
      throw ClaudeClientError.notSent("OpenCode has no model \(request.model) in Athina's list")
    }
    let client = model.api == .messages ? messages : responses
    return try await client.send(request, call: call, route: route, timeout: timeout)
  }
}
