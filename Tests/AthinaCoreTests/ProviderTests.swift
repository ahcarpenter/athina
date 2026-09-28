import Foundation
import Testing

@testable import AthinaCore

/// Answers a URLSession's requests from a test, and keeps each request as it
/// would have gone out, so a client can be checked without the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Captured: Sendable {
    var url: URL?
    var headers: [String: String]
    var body: Data
  }

  nonisolated(unsafe) private static var answer: (Int, Data) = (200, Data())
  nonisolated(unsafe) private static var captured: [Captured] = []
  private static let lock = NSLock()

  /// A session whose every request this protocol answers with `status` and
  /// `body`.
  static func session(answering status: Int, body: Data) -> URLSession {
    lock.withLock {
      answer = (status, body)
      captured = []
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  /// Every request answered since the last `session(answering:body:)`.
  static var requests: [Captured] { lock.withLock { captured } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 65536)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        body.append(contentsOf: buffer[0..<count])
      }
      stream.close()
    }
    let (status, reply) = StubURLProtocol.lock.withLock {
      StubURLProtocol.captured.append(
        Captured(url: request.url, headers: request.allHTTPHeaderFields ?? [:], body: body)
      )
      return StubURLProtocol.answer
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: ["content-type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// OpenAI and OpenCode answer beside Anthropic.
///
/// Each provider has its own key and its own Allow, each call is mapped onto the provider's own request
/// shape with its words unchanged, every reply is checked against its schema,
/// and spend is priced per provider. Nothing here reaches the network.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ProviderTests {
  private typealias Harness = MentorLoopTests.Harness
  private static let no = #"{"worth_a_look": false, "reason": "Reading docs"}"#
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
  private let call = CallIdentity(kind: "mentor", promptVersion: MentorPrompts.version)

  /// A mentor-shaped request: two system blocks, a screenshot and text, a
  /// schema and an effort.
  private var mentorRequest: MessagesRequest {
    MessagesRequest(
      model: "gpt-6-sol",
      maxTokens: 8000,
      system: [
        SystemBlock(text: "You are a mentor."),
        SystemBlock(text: "The understanding so far.", cacheControl: nil),
      ],
      messages: [
        Message(
          role: .user,
          content: [.image(mediaType: "image/jpeg", base64: "AAEC"), .text("The screen says hi.")]
        )
      ],
      outputConfig: OutputConfig(
        format: OutputFormat(schema: MentorPrompts.followUpSchema),
        effort: .medium
      )
    )
  }

  // MARK: Consent by recipient

  @Test func eachProviderNeedsItsOwnAllow() {
    var settings = SensingSettings()
    settings.consent = Consent(answer: .allowed, at: t0)
    #expect(settings.hasConsent)
    // Another company receives what is sent, so Anthropic's Allow does not
    // carry over.
    settings.mentor.provider = .openAI
    #expect(!settings.hasConsent)
    settings.mentor.provider = .openCode
    #expect(!settings.hasConsent)
    settings.setConsent(Consent(answer: .allowed, at: t0 + 60), for: .openCode)
    #expect(settings.hasConsent)
    #expect(settings.consent(for: .openAI) == nil)
    // Switching back finds Anthropic's answer where every earlier build keeps it.
    settings.mentor.provider = .anthropic
    #expect(settings.hasConsent)
    #expect(settings.consent == Consent(answer: .allowed, at: t0))
  }

  @Test func anotherProvidersAllowIsNeverWhereAnEarlierBuildWouldReadIt() throws {
    var settings = SensingSettings()
    settings.mentor.provider = .openAI
    settings.setConsent(Consent(answer: .allowed, at: t0), for: .openAI)
    #expect(settings.consent == nil)
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(settings))
    guard case .object(let fields) = json else {
      Issue.record("settings did not encode as an object")
      return
    }
    #expect(fields["consent"] == nil)
  }

  @Test func withdrawingDeclinesEveryProvider() {
    var settings = SensingSettings()
    for provider in ModelProvider.allCases {
      settings.setConsent(Consent(answer: .allowed, at: t0), for: provider)
    }
    settings.withdrawConsent(at: t0 + 60)
    for provider in ModelProvider.allCases {
      settings.mentor.provider = provider
      #expect(!settings.hasConsent)
      #expect(settings.consent(for: provider)?.answer == .declined)
    }
  }

  @Test func eachDisclosureNamesItsRecipientAndHost() {
    for provider in ModelProvider.allCases {
      let disclosure = ConsentDisclosure(for: provider)
      #expect(disclosure.destination.contains(provider.host))
      #expect(disclosure.sentHeading == "What is sent to \(provider.name)")
    }
    #expect(ConsentDisclosure(for: .openAI).summary.contains("OpenAI"))
    #expect(ConsentDisclosure(for: .openCode).summary.contains("Anomaly"))
  }

  @Test func aProviderFromALaterBuildReadsAsAnthropic() throws {
    let json = #"{"mentor": {"provider": "someLaterProvider", "hourlySpendCap": 3}}"#
    let settings = try SensingSettings(json: Data(json.utf8))
    #expect(settings.mentor.provider == .anthropic)
    #expect(settings.mentor.hourlySpendCap == 3)
  }

  // MARK: Settings and catalog

  @Test func eachProviderKeepsItsOwnModelsAndEfforts() {
    var settings = MentorSettings()
    #expect(settings.triageModelInfo == ModelCatalog.haiku45)
    settings.provider = .openAI
    #expect(settings.triageModelInfo == ModelCatalog.gpt6Luna)
    #expect(settings.mentorModelInfo == ModelCatalog.gpt6Sol)
    #expect(settings.effort(for: .triage) == .low)
    settings.tierModels.mentorEffort = .xhigh
    #expect(settings.openAIModels.mentorEffort == .xhigh)
    #expect(settings.mentorEffort == .medium)
    settings.provider = .openCode
    #expect(settings.triageModelInfo.id == "claude-haiku-4-5")
    #expect(settings.effort(for: .triage) == nil)
    #expect(settings.mentorModelInfo.api == .messages)
  }

  @Test func aModelTheProviderDoesNotOfferFallsBackToItsDefault() {
    var settings = MentorSettings()
    settings.openAIModels.mentor = "claude-opus-5"
    settings.openCodeModels.triage = "gpt-4"
    let validated = settings.validated()
    #expect(validated.openAIModels.mentor == ModelCatalog.gpt6Sol.id)
    #expect(validated.openCodeModels.triage == "claude-haiku-4-5")
  }

  @Test func everyOfferedModelHasAPriceAndTheCheapestNeverMentors() {
    for provider in ModelProvider.allCases {
      for model in ModelCatalog.models(for: provider) {
        #expect(PriceTable.defaults.price(for: model.priceKey) != nil, "\(model.priceKey)")
        #expect(model.provider == provider)
      }
      let mentors = ModelCatalog.choices(for: .mentor, provider: provider)
      #expect(!mentors.isEmpty)
      #expect(!mentors.contains { $0.id == "gpt-6-luna" || !$0.supportsEffort })
    }
    // Anthropic's rows keep their bare ids, as earlier builds saved them.
    #expect(ModelCatalog.opus5.priceKey == "claude-opus-5")
    #expect(ModelCatalog.gpt6Sol.priceKey == "openai/gpt-6-sol")
    let usage = Usage(inputTokens: 1_000_000, outputTokens: 1_000_000)
    #expect(PriceTable.defaults.cost(of: usage, model: "gpt-6-sol", provider: .openAI) == 12)
    #expect(PriceTable.defaults.cost(of: usage, model: "claude-opus-5", provider: .openCode) == 30)
  }

  @Test func anOlderPriceTableGainsTheNewProvidersRows() throws {
    let json = #"{"mentor": {"prices": {"checkedOn": "2026-09-26", "prices": {}}}}"#
    let settings = try SensingSettings(json: Data(json.utf8))
    #expect(settings.mentor.prices.price(for: "openai/gpt-6-luna") != nil)
    #expect(settings.mentor.prices.price(for: "opencode/claude-haiku-4-5") != nil)
  }

  // MARK: The OpenAI request shape

  @Test func aCallMapsOntoTheResponsesAPIWithItsWordsUnchanged() throws {
    let body = try OpenAIClient.body(for: mentorRequest, call: call)
    let json = try JSONDecoder().decode(JSONValue.self, from: body)
    let expected: JSONValue = [
      "model": "gpt-6-sol",
      "store": false,
      "max_output_tokens": 8000,
      "reasoning": ["effort": "medium"],
      "input": [
        [
          "role": "developer",
          "content": [
            ["type": "input_text", "text": "You are a mentor."],
            ["type": "input_text", "text": "The understanding so far."],
          ],
        ],
        [
          "role": "user",
          "content": [
            ["type": "input_image", "image_url": "data:image/jpeg;base64,AAEC", "detail": "auto"],
            ["type": "input_text", "text": "The screen says hi."],
          ],
        ],
      ],
      "text": [
        "format": [
          "type": "json_schema",
          "name": "athina_mentor",
          "strict": true,
          "schema": MentorPrompts.followUpSchema,
        ]
      ],
    ]
    #expect(json == expected)
    // The same call always sends the same bytes.
    #expect(try OpenAIClient.body(for: mentorRequest, call: call) == body)
  }

  @Test func aCallWithNoEffortOrSchemaSendsNeither() throws {
    let request = MessagesRequest(
      model: "gpt-6-luna",
      maxTokens: 16,
      system: [],
      messages: [Message(role: .user, content: [.text("Reply with the single word OK.")])]
    )
    let json = try JSONDecoder().decode(
      JSONValue.self,
      from: OpenAIClient.body(for: request, call: call)
    )
    guard case .object(let fields) = json else {
      Issue.record("not an object")
      return
    }
    #expect(fields["reasoning"] == nil)
    #expect(fields["text"] == nil)
    #expect(fields["max_output_tokens"] == .number(Double(16 + MentorLoop.thinkingAllowance)))
    #expect(
      fields["input"] == [
        [
          "role": "user",
          "content": [["type": "input_text", "text": "Reply with the single word OK."]],
        ]
      ]
    )
  }

  @Test func aTriageSizedCallKeepsItsReplyBudgetBesideItsReasoning() throws {
    let request = MessagesRequest(
      model: "gpt-6-luna",
      maxTokens: MentorLoop.triageMaxTokens,
      system: [SystemBlock(text: "Triage.")],
      messages: [Message(role: .user, content: [.text("The screen says hi.")])],
      outputConfig: OutputConfig(effort: .low)
    )
    let json = try JSONDecoder().decode(
      JSONValue.self,
      from: OpenAIClient.body(for: request, call: call)
    )
    guard case .object(let fields) = json else {
      Issue.record("not an object")
      return
    }
    #expect(fields["reasoning"] == ["effort": "low"])
    #expect(
      fields["max_output_tokens"]
        == .number(Double(MentorLoop.triageMaxTokens + MentorLoop.thinkingAllowance))
    )
  }

  // MARK: The OpenAI reply

  private func reply(
    status: String = "completed",
    content: String = #"[{"type": "output_text", "text": "{\"answer\": \"Yes\"}"}]"#,
    incomplete: String = "null",
    usage: String =
      #"{"input_tokens": 1000, "output_tokens": 200, "input_tokens_details": {"cached_tokens": 600, "cache_write_tokens": 100}}"#
  ) -> Data {
    Data(
      """
      {"id": "resp_1", "object": "response", "model": "gpt-6-sol-2026-08-01", "status": "\(status)",
       "incomplete_details": \(incomplete), "error": null,
       "output": [{"type": "reasoning", "summary": []},
                  {"type": "message", "role": "assistant", "content": \(content)}],
       "usage": \(usage)}
      """.utf8
    )
  }

  @Test func aReplyMapsBackWithItsTextAndUsage() throws {
    let response = try OpenAIClient.decode(status: 200, body: reply())
    #expect(response.text == #"{"answer": "Yes"}"#)
    #expect(response.stopReason == "end_turn")
    #expect(response.model == "gpt-6-sol-2026-08-01")
    #expect(
      response.usage
        == Usage(
          inputTokens: 300,
          outputTokens: 200,
          cacheCreationInputTokens: 100,
          cacheReadInputTokens: 600
        )
    )
  }

  @Test func aRefusalACutOffAndAFilteredReplyAreRecognized() throws {
    let refused = try OpenAIClient.decode(
      status: 200,
      body: reply(content: #"[{"type": "refusal", "refusal": "I can't help with that."}]"#)
    )
    #expect(refused.isRefusal)
    let cut = try OpenAIClient.decode(
      status: 200,
      body: reply(status: "incomplete", incomplete: #"{"reason": "max_output_tokens"}"#)
    )
    #expect(cut.isTruncated)
    let filtered = try OpenAIClient.decode(
      status: 200,
      body: reply(status: "incomplete", incomplete: #"{"reason": "content_filter"}"#)
    )
    #expect(filtered.isRefusal)
  }

  @Test func errorsCarryTheServersMessage() {
    let body = Data(
      #"{"error": {"message": "Incorrect API key provided.", "type": null, "code": "invalid_api_key"}}"#
        .utf8
    )
    #expect(
      throws: ClaudeClientError.api(
        status: 401,
        type: "invalid_api_key",
        message: "Incorrect API key provided."
      )
    ) {
      try OpenAIClient.decode(status: 401, body: body)
    }
    #expect(throws: ClaudeClientError.self) {
      try OpenAIClient.decode(status: 200, body: reply(status: "failed"))
    }
  }

  // MARK: What goes out

  @Test func anOpenAICallGoesOnlyToItsEndpointWithABearerKey() async throws {
    let session = StubURLProtocol.session(answering: 200, body: reply())
    let client = OpenAIClient(session: session)
    _ = try await client.send(
      mentorRequest,
      call: call,
      route: CallRoute(.openAI, key: "sk-o"),
      timeout: 5
    )
    let sent = try #require(StubURLProtocol.requests.first)
    #expect(sent.url == URL(string: "https://api.openai.com/v1/responses"))
    #expect(sent.headers["Authorization"] == "Bearer sk-o")
    #expect(sent.headers["x-api-key"] == nil)
    #expect(sent.body == (try OpenAIClient.body(for: mentorRequest, call: call)))
  }

  @Test func openCodeSendsEachFamilyToItsOwnEndpoint() async throws {
    let gpt = StubURLProtocol.session(answering: 200, body: reply())
    let zen = OpenCodeClient(
      messages: AnthropicClient(endpoint: OpenCodeClient.messagesEndpoint, session: gpt),
      responses: OpenAIClient(endpoint: OpenCodeClient.responsesEndpoint, session: gpt)
    )
    _ = try await zen.send(
      mentorRequest,
      call: call,
      route: CallRoute(.openCode, key: "zk"),
      timeout: 5
    )
    #expect(
      StubURLProtocol.requests.first?.url == URL(string: "https://opencode.ai/zen/v1/responses")
    )
    #expect(StubURLProtocol.requests.first?.headers["Authorization"] == "Bearer zk")

    let messageReply = Data(
      #"{"id": "msg_1", "model": "claude-opus-5", "stop_reason": "end_turn", "content": [{"type": "text", "text": "{}"}], "usage": {"input_tokens": 5, "output_tokens": 1}}"#
        .utf8
    )
    let claude = StubURLProtocol.session(answering: 200, body: messageReply)
    let zenClaude = OpenCodeClient(
      messages: AnthropicClient(endpoint: OpenCodeClient.messagesEndpoint, session: claude),
      responses: OpenAIClient(endpoint: OpenCodeClient.responsesEndpoint, session: claude)
    )
    var request = mentorRequest
    request.model = "claude-opus-5"
    _ = try await zenClaude.send(
      request,
      call: call,
      route: CallRoute(.openCode, key: "zk"),
      timeout: 5
    )
    let sent = try #require(StubURLProtocol.requests.first)
    #expect(sent.url == URL(string: "https://opencode.ai/zen/v1/messages"))
    #expect(sent.headers["x-api-key"] == "zk")
    #expect(sent.body == (try AnthropicClient.encoder.encode(request)))

    request.model = "gemini-3.8-flash"
    await #expect(throws: ClaudeClientError.self) {
      try await zenClaude.send(
        request,
        call: call,
        route: CallRoute(.openCode, key: "zk"),
        timeout: 5
      )
    }
  }

  @Test func theLiveClientSendsEachCallToItsProvider() async throws {
    let anthropic = ScriptedClaudeClient()
    let openAI = ScriptedClaudeClient()
    let openCode = ScriptedClaudeClient()
    await anthropic.enqueue(json: "{}", model: "a")
    await openAI.enqueue(json: "{}", model: "o")
    await openCode.enqueue(json: "{}", model: "z")
    let client = LiveModelClient(anthropic: anthropic, openAI: openAI, openCode: openCode)
    let request = MessagesRequest(model: "m", maxTokens: 1, system: [], messages: [])
    #expect(
      try await client.send(request, call: call, route: CallRoute(.anthropic, key: "k"), timeout: 1)
        .model == "a"
    )
    #expect(
      try await client.send(request, call: call, route: CallRoute(.openAI, key: "k"), timeout: 1)
        .model == "o"
    )
    #expect(
      try await client.send(request, call: call, route: CallRoute(.openCode, key: "k"), timeout: 1)
        .model == "z"
    )
  }

  // MARK: Schema check

  @Test func aReplyIsCheckedAgainstItsSchema() {
    let schema = MentorPrompts.mentorSchema
    let empty =
      #"{"reason": "fine", "suggestion": null, "updated_understanding": {"goals": [], "timeline": [], "mentor_history": [], "open_concerns": []}}"#
    #expect(JSONSchemaCheck.problem(withReply: empty, against: schema) == nil)
    let extra = empty.replacingOccurrences(
      of: #""reason": "fine","#,
      with: #""reason": "fine", "mood": 1,"#
    )
    #expect(JSONSchemaCheck.problem(withReply: extra, against: schema) == "$: unexpected mood")
    let missing = #"{"reason": "fine", "suggestion": null}"#
    #expect(
      JSONSchemaCheck.problem(withReply: missing, against: schema)
        == "$: missing updated_understanding"
    )
    let badCategory = empty.replacingOccurrences(
      of: #""suggestion": null"#,
      with:
        #""suggestion": {"title": "t", "body": "b", "explanation": "e", "category": "gossip", "confidence": 0.9, "judged_goal": null, "region": null}"#
    )
    #expect(
      JSONSchemaCheck.problem(withReply: badCategory, against: schema)
        == "$.suggestion: matches none of the allowed shapes"
    )
    #expect(JSONSchemaCheck.problem(withReply: "not json", against: schema) == "$: not JSON")
    #expect(
      JSONSchemaCheck.problem(withReply: #"{"answer": 3}"#, against: MentorPrompts.followUpSchema)
        == "$.answer: expected string"
    )
  }

  // MARK: The loop on another provider

  @Test func theLoopCallsTheProviderInForceWithItsKeyAndPricesIt() async throws {
    var settings = MentorSettings()
    settings.provider = .openAI
    let h = try await Harness(settings: settings, key: "sk-ant-unused")
    // Anthropic's key is no key for OpenAI.
    #expect(await h.loop.currentStatus().availability == .noAPIKey)
    try h.keyStore.save("sk-openai", for: .openAI)
    await h.loop.apiKeyChanged()
    #expect(await h.loop.currentStatus().availability == .ready)
    await h.client.enqueue(
      json: Self.no,
      model: "gpt-6-luna",
      usage: Usage(inputTokens: 1_000_000, outputTokens: 0)
    )
    await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 1)
    let sent = try #require(await h.client.sent.first)
    #expect(sent.route == CallRoute(.openAI, key: "sk-openai"))
    #expect(sent.request.model == "gpt-6-luna")
    let record = try #require(try await h.journal.recentModelCalls(limit: 1).first)
    #expect(record.provider == .openAI)
    // A million input tokens at GPT-6 Luna's $0.10.
    #expect(abs(record.cost - 0.10) < 1e-9)
  }

  @Test func switchingProviderReadsThatProvidersKey() async throws {
    let h = try await Harness(key: "sk-ant-test")
    try h.keyStore.save("zen-key", for: .openCode)
    var settings = MentorSettings()
    settings.provider = .openCode
    await h.loop.updateSettings(settings)
    await h.waitUntil { $0.availability == .ready }
    await h.client.enqueue(json: Self.no)
    await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 1)
    let sent = try #require(await h.client.sent.first)
    #expect(sent.route == CallRoute(.openCode, key: "zen-key"))
    #expect(sent.request.model == "claude-haiku-4-5")
  }

  /// A key store that holds each read of one provider's key until the test
  /// lets it go, as a keychain prompt the captain has not answered yet does.
  private final class SlowKeyStore: KeyStore, @unchecked Sendable {
    let keys: InMemoryKeyStore
    let slow: ModelProvider
    let reading = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    init(keys: [ModelProvider: String], slow: ModelProvider) {
      self.keys = InMemoryKeyStore(keys: keys)
      self.slow = slow
    }

    func load(for provider: ModelProvider) throws -> String? {
      if provider == slow {
        reading.signal()
        release.wait()
      }
      return try keys.load(for: provider)
    }
    func save(_ key: String, for provider: ModelProvider) throws {
      try keys.save(key, for: provider)
    }
    func delete(for provider: ModelProvider) throws { try keys.delete(for: provider) }

    /// Returns once a read of the slow provider's key has begun.
    func readBegun() async {
      await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          self.reading.wait()
          continuation.resume()
        }
      }
    }
  }

  @Test func noCallCarriesTheOldProvidersKeyWhileTheNewOneIsRead() async throws {
    let clock = AdjustableClock(startingAt: Harness.start)
    let client = ScriptedClaudeClient(clock: clock)
    let store = SlowKeyStore(
      keys: [.anthropic: "sk-ant-test", .openCode: "zen-key"],
      slow: .openCode
    )
    let (stream, input) = AsyncStream<SensingEvent>.makeStream()
    let loop = MentorLoop(
      settings: MentorSettings(),
      journal: try Journal.inMemory(),
      client: client,
      keyStore: store,
      events: stream,
      consented: true,
      clock: clock,
      calendar: MentorLoopTests.calendar
    )
    let updates = await loop.events()
    var events = updates.makeAsyncIterator()
    func waitUntil(calls: Int = 0, _ condition: (MentorStatus) -> Bool) async {
      while true {
        let sentCount = await client.sent.count
        if condition(await loop.currentStatus()), sentCount >= calls { return }
        guard await events.next() != nil else { return }
      }
    }
    await loop.start()
    input.yield(.modeChanged(.watching))
    await waitUntil { $0.mode == .watching }

    var settings = MentorSettings()
    settings.provider = .openCode
    // Returns while OpenCode's key is still being read.
    await loop.updateSettings(settings)
    await store.readBegun()
    // The loop is waiting on OpenCode's key and takes the next snapshot meanwhile.
    clock.advance(by: .milliseconds(1))
    input.yield(.observation(Fixtures.observation(id: 1, at: clock.date)))
    await waitUntil { $0.lastGate?.observationID == 1 && $0.inFlight == nil }
    #expect(await client.sent.isEmpty)
    #expect(await loop.currentStatus().availability == .noAPIKey)

    store.release.signal()
    await waitUntil { $0.availability == .ready }
    await client.enqueue(json: Self.no)
    clock.advance(by: .milliseconds(1))
    input.yield(.observation(Fixtures.observation(id: 2, at: clock.date)))
    await waitUntil(calls: 1) { $0.lastGate?.observationID == 2 && $0.inFlight == nil }
    let sent = await client.sent
    #expect(sent.map(\.route) == [CallRoute(.openCode, key: "zen-key")])
    await loop.stop()
  }

  @Test func aReplyThatBreaksItsSchemaIsAnErrorThatStillCounts() async throws {
    var settings = MentorSettings()
    settings.provider = .openAI
    let h = try await Harness(settings: settings, key: nil)
    try h.keyStore.save("sk-openai", for: .openAI)
    await h.loop.apiKeyChanged()
    await h.client.enqueue(
      json: #"{"worth_a_look": "yes", "reason": "x"}"#,
      model: "gpt-6-luna",
      usage: Usage(inputTokens: 10_000_000, outputTokens: 0)
    )
    await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 1)
    let status = await h.loop.currentStatus()
    #expect(status.lastTriage?.outcome == .error)
    #expect(status.lastTriage?.detail?.contains("does not match its schema") == true)
    // What the provider billed still counts toward the hour: ten million
    // input tokens at GPT-6 Luna's $0.10.
    #expect(abs((status.lastTriage?.cost ?? 0) - 1.0) < 1e-9)
    #expect(status.spendThisHour > 0.99)
  }

  @Test func anthropicRepliesAreReadAsTheyAlwaysWere() async throws {
    let h = try await Harness()
    // A triage reply with a field the schema does not name still parses.
    await h.client.enqueue(json: #"{"worth_a_look": false, "reason": "x", "extra": 1}"#)
    await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 1)
    #expect(await h.loop.currentStatus().lastTriage?.outcome == .quiet)
  }
}
