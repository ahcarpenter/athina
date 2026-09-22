import Foundation
import Testing
@testable import AthinaCore

/// The fixture file format: what a recorded call keeps, how it is named and
/// stored, and that no key ever reaches the file.
@Suite struct CallFixtureTests {
    static let realisticKey = "sk-ant-api03-Zq8xV2mN4pL7rT1yW9bC3dF6hJ0kS5uE8gA2iO4-AbCdEf"

    static func request(text: String = "App: TextEdit", image: Bool = false) -> MessagesRequest {
        var content: [ContentBlock] = []
        if image { content.append(.image(mediaType: "image/jpeg", base64: "/9j/4AAQSkZJRg==")) }
        content.append(.text(text))
        return MessagesRequest(
            model: "claude-sonnet-5",
            maxTokens: 6000,
            system: [SystemBlock(text: "You are Athina.")],
            messages: [Message(role: .user, content: content)],
            outputConfig: OutputConfig(format: OutputFormat(schema: ["type": "object", "additionalProperties": false]), effort: .low)
        )
    }

    static func fixture(
        kind: String = "mentor",
        promptVersion: Int = MentorPrompts.version,
        at time: Date = Date(timeIntervalSince1970: 1_789_000_000),
        request: MessagesRequest = request(image: true),
        result: Result<MessagesResponse, ClaudeClientError> = .success(MessagesResponse(
            id: "msg_1", model: "claude-sonnet-5", stopReason: "end_turn",
            content: [ResponseBlock(type: "thinking"), ResponseBlock(type: "text", text: #"{"reason": "r", "suggestion": null}"#)],
            usage: Usage(inputTokens: 2400, outputTokens: 310, cacheCreationInputTokens: 1100, cacheReadInputTokens: 0)
        ))
    ) -> CallFixture {
        CallFixture(
            identity: CallIdentity(kind: kind, promptVersion: promptVersion),
            recordedAt: time, request: request, result: result, latency: 4.25, cost: 0.0123
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("athina-fixtures-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aSuccessWithAnImageRoundTrips() throws {
        let fixture = Self.fixture()
        let data = try CallFixtureFiles.encode(fixture, redacting: Self.realisticKey)
        let decoded = try CallFixtureFiles.decoder.decode(CallFixture.self, from: data)
        #expect(decoded == fixture)
        #expect(decoded.request.imageByteCount == fixture.request.imageByteCount)

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["format"] as? Int == CallFixture.format)
        #expect(object["kind"] as? String == "mentor")
        #expect(object["promptVersion"] as? Int == MentorPrompts.version)
        #expect(object["model"] as? String == "claude-sonnet-5")
        #expect(object["cost"] as? Double == 0.0123)
        #expect(object["latency"] as? Double == 4.25)
        #expect((object["usage"] as? [String: Any])?["cache_creation_input_tokens"] as? Int == 1100)
        #expect(object["error"] == nil)
        // The request is stored in the API's own shape.
        let request = try #require(object["request"] as? [String: Any])
        #expect(request["max_tokens"] as? Int == 6000)
        #expect((request["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test(arguments: [
        ClaudeClientError.api(status: 529, type: "overloaded_error", message: "Overloaded"),
        .transport("The request timed out."),
        .badResponse("not json"),
        .replay("no recorded mentor call to replay"),
        .notSent("cannot record to /recordings: permission denied"),
    ])
    func everyErrorRoundTrips(error: ClaudeClientError) throws {
        let fixture = Self.fixture(kind: "triage", result: .failure(error))
        let data = try CallFixtureFiles.encode(fixture, redacting: "")
        let decoded = try CallFixtureFiles.decoder.decode(CallFixture.self, from: data)
        #expect(decoded == fixture)
        #expect(decoded.usage == Usage())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["response"] == nil)
    }

    @Test func anUnknownFormatOrAMissingAnswerIsRejected() throws {
        let data = try CallFixtureFiles.encode(Self.fixture(), redacting: "")
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["format"] = CallFixture.format + 1
        #expect(throws: DecodingError.self) {
            try CallFixtureFiles.decoder.decode(CallFixture.self, from: JSONSerialization.data(withJSONObject: object))
        }
        object["format"] = CallFixture.format
        object["response"] = nil
        #expect(throws: DecodingError.self) {
            try CallFixtureFiles.decoder.decode(CallFixture.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func theKeyIsRedactedWhereverItAppears() throws {
        let other = "sk-ant-admin01-QwErTyUiOpAsDfGhJkLzXcVbNm123456"
        let fixture = Self.fixture(
            request: Self.request(text: "Terminal shows export ANTHROPIC_API_KEY=\(Self.realisticKey) and \(other)"),
            result: .success(MessagesResponse(
                id: "msg_2", model: "claude-sonnet-5", stopReason: "end_turn",
                content: [ResponseBlock(type: "text", text: "Rotate \(Self.realisticKey) now")], usage: Usage()
            ))
        )
        let text = String(decoding: try CallFixtureFiles.encode(fixture, redacting: Self.realisticKey), as: UTF8.self)
        #expect(!text.contains(Self.realisticKey))
        #expect(!text.contains(other))
        #expect(!text.contains("sk-ant-api03"))
        #expect(text.contains("export ANTHROPIC_API_KEY=\(CallFixtureFiles.redactionMarker)"))
        #expect(text.contains("Rotate \(CallFixtureFiles.redactionMarker) now"))

        // A short stand-in is never matched literally, so it cannot blank out ordinary text.
        let untouched = String(decoding: try CallFixtureFiles.encode(Self.fixture(), redacting: "e"), as: UTF8.self)
        #expect(untouched.contains("You are Athina."))
        #expect(!untouched.contains(CallFixtureFiles.redactionMarker))
    }

    @Test func anEmDashIsWrittenAsItsEscapeAndReadBackAsItself() throws {
        let fixture = Self.fixture(request: Self.request(text: "Window: photo-renames.txt \u{2014} Edited"))
        let data = try CallFixtureFiles.encode(fixture, redacting: "")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\u{2014}"))
        #expect(text.contains(#"photo-renames.txt \u2014 Edited"#))
        #expect(try CallFixtureFiles.decoder.decode(CallFixture.self, from: data) == fixture)
    }

    @Test func fileNamesSortByRecordingTimeAndNameTheKind() {
        let early = Self.fixture(kind: "triage", at: Date(timeIntervalSince1970: 1_789_000_000.25))
        let late = Self.fixture(kind: "follow up", at: Date(timeIntervalSince1970: 1_789_000_000.5))
        let earlyName = CallFixtureFiles.fileName(for: early, suffix: "aaaa")
        let lateName = CallFixtureFiles.fileName(for: late, suffix: "0000")
        #expect(earlyName == "20260910T002640.250Z-triage-aaaa.json")
        #expect(lateName == "20260910T002640.500Z-follow_up-0000.json")
        #expect(earlyName < lateName)
    }

    /// A name shows only the millisecond, so each recording is stamped in a
    /// later millisecond than the one before, whatever the clock read: the
    /// same millisecond, the same instant, or earlier after the wall clock
    /// stepped back. Otherwise these names would tie on the time and sort by
    /// their ids, backwards.
    @Test func eachRecordingIsStampedInALaterMillisecond() {
        let readings = [
            Date(timeIntervalSince1970: 1_789_000_000.2501),
            Date(timeIntervalSince1970: 1_789_000_000.2504),
            Date(timeIntervalSince1970: 1_789_000_000.2504),
            Date(timeIntervalSince1970: 1_788_999_999),
            Date(timeIntervalSince1970: 1_789_000_001.5),
        ]
        let stamps = readings.reduce(into: [Date]()) { stamps, now in
            stamps.append(CallFixtureFiles.recordingStamp(at: now, after: stamps.last))
        }
        let names = zip(stamps, ["4", "3", "2", "1", "0"]).map { stamp, suffix in
            CallFixtureFiles.fileName(for: Self.fixture(kind: "triage", at: stamp), suffix: suffix)
        }
        #expect(names == [
            "20260910T002640.250Z-triage-4.json",
            "20260910T002640.251Z-triage-3.json",
            "20260910T002640.252Z-triage-2.json",
            "20260910T002640.253Z-triage-1.json",
            "20260910T002641.500Z-triage-0.json",
        ])
        #expect(names == names.sorted())
        // A reading already in a later millisecond is kept exactly.
        #expect(stamps.first == readings.first)
        #expect(stamps.last == readings.last)
    }

    @Test func writtenFixturesArePrivateAndLoadInNameOrder() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = try CallFixtureFiles.write(Self.fixture(kind: "mentor", at: Date(timeIntervalSince1970: 1_789_000_002)), to: directory, redacting: Self.realisticKey)
        let first = try CallFixtureFiles.write(Self.fixture(kind: "triage", at: Date(timeIntervalSince1970: 1_789_000_001)), to: directory, redacting: Self.realisticKey)
        try Data("notes".utf8).write(to: directory.appendingPathComponent("README.txt"))

        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int
        #expect(directoryMode == 0o700)
        #expect(fileMode == 0o600)

        let loaded = try CallFixtureFiles.load(from: directory)
        #expect(loaded.map(\.name) == [first.lastPathComponent, second.lastPathComponent])
        #expect(loaded.map(\.fixture.identity.kind) == ["triage", "mentor"])
    }

    @Test func anUnreadableFixtureIsNamed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try CallFixtureFiles.write(Self.fixture(), to: directory, redacting: "")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: directory.appendingPathComponent("zz-broken.json"))
        #expect {
            try CallFixtureFiles.load(from: directory)
        } throws: { error in
            guard case ReplayLoadError.unreadableFixture(let name, _) = error else { return false }
            return name == "zz-broken.json"
        }
        #expect(throws: ReplayLoadError.self) {
            try CallFixtureFiles.load(from: directory.appendingPathComponent("missing"))
        }
    }
}
