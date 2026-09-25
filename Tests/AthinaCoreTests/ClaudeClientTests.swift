import Foundation
import Testing

@testable import AthinaCore

@Suite struct ClaudeClientTests {
  @Test func requestEncodesToTheDocumentedShape() throws {
    let request = MessagesRequest(
      model: "claude-fable-5-1",
      maxTokens: 200,
      system: [SystemBlock(text: "You are a test.")],
      messages: [
        Message(
          role: .user,
          content: [
            .image(mediaType: "image/jpeg", base64: "/9j/4AAQ"),
            .text("Time: 10:00:00"),
          ]
        )
      ],
      outputConfig: OutputConfig(
        format: OutputFormat(schema: [
          "type": "object",
          "properties": ["ok": ["type": "boolean"]],
          "required": ["ok"],
          "additionalProperties": false,
        ]),
        effort: .medium
      )
    )
    let encoded = try AnthropicClient.encoder.encode(request)
    let expected = try Fixtures.data("messages-request")
    let lhs = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
    let rhs = try JSONSerialization.jsonObject(with: expected) as? NSDictionary
    #expect(lhs == rhs)
    // Sorted keys keep the bytes stable between calls, which prompt caching needs.
    #expect(try AnthropicClient.encoder.encode(request) == encoded)
    #expect(request.promptCharacterCount == "You are a test.".count + "Time: 10:00:00".count)
    #expect(request.imageByteCount == 6)
  }

  @Test func effortIsOmittedWhenNil() throws {
    let request = MessagesRequest(
      model: "claude-haiku-4-5-20251001",
      maxTokens: 10,
      system: [],
      messages: [Message(role: .user, content: [.text("hi")])],
      outputConfig: OutputConfig(
        format: OutputFormat(schema: ["type": "object", "additionalProperties": false]),
        effort: nil
      )
    )
    let json = String(decoding: try AnthropicClient.encoder.encode(request), as: UTF8.self)
    #expect(!json.contains("effort"))
    #expect(json.contains("\"cache_control\"") == false)
    #expect(json.contains("\"system\":[]"))
  }

  @Test func responseDecodesUsageAndText() throws {
    let response = try AnthropicClient.decode(
      status: 200,
      body: try Fixtures.data("messages-response")
    )
    #expect(response.model == "claude-haiku-4-5-20251001")
    #expect(response.stopReason == "end_turn")
    #expect(
      response.usage
        == Usage(
          inputTokens: 412,
          outputTokens: 29,
          cacheCreationInputTokens: 0,
          cacheReadInputTokens: 1187
        )
    )
    #expect(response.usage.totalInputTokens == 1599)
    let verdict = try JSONDecoder().decode(TriageVerdict.self, from: Data(response.text.utf8))
    #expect(
      verdict
        == TriageVerdict(worthALook: true, reason: "Repeated manual test runs in the terminal")
    )
  }

  @Test func thinkingBlocksAreSkippedWhenReadingText() throws {
    let response = try AnthropicClient.decode(
      status: 200,
      body: try Fixtures.data("messages-response-thinking")
    )
    #expect(response.content.count == 2)
    let verdict = try JSONDecoder().decode(MentorVerdict.self, from: Data(response.text.utf8))
    #expect(verdict.suggestion == nil)
    #expect(verdict.reason == "The user is reading documentation")
    #expect(response.usage.cacheCreationInputTokens == 760)
  }

  @Test func refusalIsRecognized() throws {
    let response = try AnthropicClient.decode(
      status: 200,
      body: try Fixtures.data("messages-refusal")
    )
    #expect(response.isRefusal)
    #expect(response.text.isEmpty)
  }

  @Test func apiErrorsCarryTheServersMessage() throws {
    #expect(
      throws: ClaudeClientError.api(
        status: 401,
        type: "authentication_error",
        message: "invalid x-api-key"
      )
    ) {
      try AnthropicClient.decode(status: 401, body: try Fixtures.data("messages-error"))
    }
    #expect(
      throws: ClaudeClientError.api(
        status: 502,
        type: "http_error",
        message: "<html>bad gateway</html>"
      )
    ) {
      try AnthropicClient.decode(status: 502, body: Data("<html>bad gateway</html>".utf8))
    }
    #expect(throws: ClaudeClientError.self) {
      try AnthropicClient.decode(status: 200, body: Data("not json".utf8))
    }
  }

  @Test func mentorVerdictDecodesASuggestion() throws {
    let json = """
      {"reason": "Manual copy between windows", "suggestion": {"title": "Use a snippet", \
      "body": "b", "explanation": "e", "category": "shortcut", "confidence": 0.8}}
      """
    let verdict = try JSONDecoder().decode(MentorVerdict.self, from: Data(json.utf8))
    #expect(verdict.suggestion?.category == .shortcut)
    #expect(verdict.suggestion?.confidence == 0.8)
  }

  @Test func schemasAreValidForStructuredOutput() throws {
    for schema in [MentorPrompts.triageSchema(contexts: []), MentorPrompts.mentorSchema] {
      let data = try AnthropicClient.encoder.encode(schema)
      let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(object["additionalProperties"] as? Bool == false)
      #expect(object["type"] as? String == "object")
    }
    let mentor =
      try JSONSerialization.jsonObject(
        with: try AnthropicClient.encoder.encode(MentorPrompts.mentorSchema)
      ) as? [String: Any]
    let properties = mentor?["properties"] as? [String: Any]
    let suggestion = properties?["suggestion"] as? [String: Any]
    let variants = try #require(suggestion?["anyOf"] as? [[String: Any]])
    #expect(variants.count == 2)
    let payload = try #require(variants.first { $0["type"] as? String == "object" })
    let category = (payload["properties"] as? [String: Any])?["category"] as? [String: Any]
    #expect(category?["enum"] as? [String] == SuggestionCategory.allCases.map(\.rawValue))
  }

  @Test func triageVerdictDecodesWithAndWithoutTheContextField() throws {
    let placed = try JSONDecoder().decode(
      TriageVerdict.self,
      from: Data(
        #"{"worth_a_look": true, "reason": "r", "context": "writing Swift"}"#.utf8
      )
    )
    #expect(placed.context == "writing Swift")

    let none = try JSONDecoder().decode(
      TriageVerdict.self,
      from: Data(
        #"{"worth_a_look": false, "reason": "r", "context": null}"#.utf8
      )
    )
    #expect(none.context == nil)

    // A reply from before the question was asked still decodes.
    let old = try JSONDecoder().decode(
      TriageVerdict.self,
      from: Data(#"{"worth_a_look": true, "reason": "r"}"#.utf8)
    )
    #expect(old.context == nil)
  }

  @Test func theTriageSchemaAsksForTheContextOnlyWhenOneIsDeclared() throws {
    let bare = try #require(
      try JSONSerialization.jsonObject(
        with: AnthropicClient.encoder.encode(MentorPrompts.triageSchema(contexts: []))
      ) as? [String: Any]
    )
    #expect((bare["properties"] as? [String: Any])?["context"] == nil)
    #expect(bare["required"] as? [String] == ["worth_a_look", "reason"])

    let contexts = [
      MentorshipContext(name: "writing Swift"), MentorshipContext(name: "drafting documents"),
    ]
    let asked = try #require(
      try JSONSerialization.jsonObject(
        with: AnthropicClient.encoder.encode(MentorPrompts.triageSchema(contexts: contexts))
      ) as? [String: Any]
    )
    #expect(asked["additionalProperties"] as? Bool == false)
    #expect(asked["required"] as? [String] == ["worth_a_look", "reason", "context"])
    let context = try #require(
      (asked["properties"] as? [String: Any])?["context"] as? [String: Any]
    )
    let variants = try #require(context["anyOf"] as? [[String: Any]])
    #expect(variants.first?["type"] as? String == "null")
    // The enum of declared names means the model cannot invent a context.
    #expect(variants.last?["enum"] as? [String] == ["writing Swift", "drafting documents"])
  }

  @Test func theTriageSystemPromptCarriesTheDeclaredContextsUnchangedOtherwise() {
    let bare = MentorPrompts.triageSystem(contexts: [])
    #expect(bare == MentorPrompts.triageBase)
    #expect(!bare.contains("Set context to"))

    let contexts = [
      MentorshipContext(name: "writing Swift", detail: "the Athina app itself"),
      MentorshipContext(name: "drafting documents"),
    ]
    let withContexts = MentorPrompts.triageSystem(contexts: contexts)
    // Same prefix, so only the appended section is a new cache write.
    #expect(withContexts.hasPrefix(bare))
    #expect(withContexts.contains("- \"writing Swift\": the Athina app itself"))
    #expect(withContexts.contains("- \"drafting documents\""))
    #expect(withContexts.contains("answer null whenever you are unsure"))
    #expect(!withContexts.contains("\u{2014}"))
  }

  /// The declared block is a bullet list the model reads as the whole set of
  /// contexts, so a detail the editor let the user wrap must not add a line.
  @Test func aMultiLineDetailStillRendersAsOneBulletPerContext() {
    var settings = MentorSettings()
    settings.contexts = [
      MentorshipContext(
        name: "writing Swift",
        detail: "Building Athina itself.\nSwift, SwiftUI,\n\nand the tests."
      ),
      MentorshipContext(name: "reading API documentation"),
    ]
    let contexts = settings.validated().contexts
    #expect(contexts.first?.detail == "Building Athina itself. Swift, SwiftUI, and the tests.")

    let section = MentorPrompts.triageSystem(contexts: contexts)
      .dropFirst(MentorPrompts.triageBase.count)
    let bullets = section.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("- ") }
    #expect(
      bullets == [
        "- \"writing Swift\": Building Athina itself. Swift, SwiftUI, and the tests.",
        "- \"reading API documentation\"",
      ]
    )
  }

  @Test func modelTextLosesItsDashes() {
    #expect("prompt vanished \u{2014} press up".withPlainDashes == "prompt vanished - press up")
    #expect("a\u{2014}b and 3\u{2013}4".withPlainDashes == "a - b and 3-4")
    #expect("plain - text".withPlainDashes == "plain - text")
  }

  @Test func jsonValueRoundTripsAndEncodesIntegersPlainly() throws {
    let value: JSONValue = ["a": 1, "b": 2.5, "c": [true, nil, "x"]]
    let data = try AnthropicClient.encoder.encode(value)
    #expect(String(decoding: data, as: UTF8.self) == #"{"a":1,"b":2.5,"c":[true,null,"x"]}"#)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
  }

  @Test func scriptedClientRecordsRequestsAndAnswersInOrder() async throws {
    let client = ScriptedClaudeClient()
    await client.enqueue(json: "{\"a\":1}", model: "m1")
    await client.enqueue(.failure(.transport("offline")))
    let request = MessagesRequest(model: "m", maxTokens: 1, system: [], messages: [])
    let call = CallIdentity(kind: "triage", promptVersion: 1)
    let first = try await client.send(request, call: call, apiKey: "k", timeout: 1)
    #expect(first.model == "m1")
    await #expect(throws: ClaudeClientError.transport("offline")) {
      try await client.send(request, call: call, apiKey: "k", timeout: 1)
    }
    await #expect(throws: ClaudeClientError.self) {
      try await client.send(request, call: call, apiKey: "k", timeout: 1)
    }
    #expect(await client.sent.count == 3)
    #expect(await client.sent.first?.apiKey == "k")
    #expect(await client.sent.first?.call == call)
    #expect(!client.isReplay)
  }
}
