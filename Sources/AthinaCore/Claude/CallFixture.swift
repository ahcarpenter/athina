import Foundation

/// One recorded model call, as one JSON file: the request exactly as it was
/// built (system blocks, messages with any image, output format, model), the
/// response as Athina decodes it or the error, and the call's identity, usage,
/// latency, and cost.
///
/// The API key is never part of it, and any key that shows up in the text is
/// redacted before the file is written.
///
/// `ReplayClaudeClient` serves these without the network; see README,
/// "Iterating without the network".
public struct CallFixture: Equatable, Sendable {
  /// The file format this code reads and writes.
  public static let format = 1

  /// Which kind of call this was and the prompt version that built it.
  ///
  /// A replay serves a fixture to calls of the same kind and refuses it as
  /// stale when the versions differ.
  public var identity: CallIdentity
  /// When the call started, stamped so file names sort in the order the calls
  /// were made (`CallFixtureFiles.recordingStamp(at:after:)`).
  public var recordedAt: Date
  /// The request exactly as the loop built it.
  public var request: MessagesRequest
  /// The response as Athina decoded it, or the error the call ended in.
  public var result: Result<MessagesResponse, ClaudeClientError>
  /// Seconds the call took when it was recorded.
  public var latency: TimeInterval
  /// Estimated dollars when it was recorded.
  public var cost: Double

  /// Creates a fixture from a call's parts.
  public init(
    identity: CallIdentity,
    recordedAt: Date,
    request: MessagesRequest,
    result: Result<MessagesResponse, ClaudeClientError>,
    latency: TimeInterval,
    cost: Double
  ) {
    self.identity = identity
    self.recordedAt = recordedAt
    self.request = request
    self.result = result
    self.latency = latency
    self.cost = cost
  }

  /// The model the request asked for.
  public var model: String { request.model }

  /// The response's usage, or zero for an error.
  public var usage: Usage { (try? result.get().usage) ?? Usage() }
}

extension CallFixture: Codable {
  private enum CodingKeys: String, CodingKey {
    case format, kind, promptVersion, recordedAt, model, usage, latency, cost, request, response,
      error
  }

  /// Decodes a fixture file.
  ///
  /// Throws for any format but `format`, and for a file with neither a response
  /// nor an error.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let format = try container.decode(Int.self, forKey: .format)
    guard format == CallFixture.format else {
      throw DecodingError.dataCorruptedError(
        forKey: .format,
        in: container,
        debugDescription:
          "fixture format \(format) is not the supported format \(CallFixture.format)"
      )
    }
    identity = CallIdentity(
      kind: try container.decode(String.self, forKey: .kind),
      promptVersion: try container.decode(Int.self, forKey: .promptVersion)
    )
    recordedAt = try container.decode(Date.self, forKey: .recordedAt)
    request = try container.decode(MessagesRequest.self, forKey: .request)
    if let response = try container.decodeIfPresent(MessagesResponse.self, forKey: .response) {
      result = .success(response)
    } else if let error = try container.decodeIfPresent(ClaudeClientError.self, forKey: .error) {
      result = .failure(error)
    } else {
      throw DecodingError.dataCorruptedError(
        forKey: .response,
        in: container,
        debugDescription: "a fixture needs a response or an error"
      )
    }
    latency = try container.decode(TimeInterval.self, forKey: .latency)
    cost = try container.decode(Double.self, forKey: .cost)
  }

  /// `model` and `usage` are written for whoever reads the file; the request
  /// and the response are what a replay uses.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(CallFixture.format, forKey: .format)
    try container.encode(identity.kind, forKey: .kind)
    try container.encode(identity.promptVersion, forKey: .promptVersion)
    try container.encode(recordedAt, forKey: .recordedAt)
    try container.encode(model, forKey: .model)
    try container.encode(usage, forKey: .usage)
    try container.encode(latency, forKey: .latency)
    try container.encode(cost, forKey: .cost)
    try container.encode(request, forKey: .request)
    switch result {
    case .success(let response): try container.encode(response, forKey: .response)
    case .failure(let error): try container.encode(error, forKey: .error)
    }
  }
}

// MARK: - Files

/// Reading and writing fixture files, and the app's own recordings directory.
public enum CallFixtureFiles {
  /// Stands in for a key wherever one appeared in a recorded call.
  public static let redactionMarker = "[redacted API key]"

  /// Anthropic keys, whatever window they were on screen in.
  private static let keyPattern = try! NSRegularExpression(pattern: "sk-ant-[A-Za-z0-9_-]{16,}")

  /// The shortest string treated as a key worth redacting by exact match, so
  /// a placeholder or a test key can never blank out ordinary text.
  public static let minimumExactKeyLength = 16

  /// Where `Athina --record` writes when no directory is given:
  /// `~/Library/Application Support/athina/recordings`, outside any
  /// repository, created with mode 0700.
  public static func defaultRecordingDirectory() -> URL {
    AppPaths.supportDirectory().appendingPathComponent("recordings", isDirectory: true)
  }

  /// Pretty and key-sorted, so a fixture reads well and diffs cleanly.
  public static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  /// Reads fixture files, with the ISO 8601 dates `encoder` writes.
  public static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  /// The fixture as JSON with `apiKey`, and anything shaped like an Anthropic
  /// key, replaced by the redaction marker.
  ///
  /// An em dash, which window titles and model text can carry, is written as
  /// its JSON escape: it decodes to the same text, and the file never holds the
  /// character this repository does not use.
  public static func encode(_ fixture: CallFixture, redacting apiKey: String) throws -> Data {
    var text = String(decoding: try encoder.encode(fixture), as: UTF8.self)
    text = redact(text, apiKey: apiKey)
    text = text.replacingOccurrences(of: "\u{2014}", with: "\\u2014")
    return Data(text.utf8)
  }

  static func redact(_ text: String, apiKey: String) -> String {
    var redacted = text
    if apiKey.count >= minimumExactKeyLength {
      redacted = redacted.replacingOccurrences(of: apiKey, with: redactionMarker)
      // The same key as it would appear inside a JSON string.
      if let data = try? JSONEncoder().encode(apiKey) {
        let escaped = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        if escaped != apiKey {
          redacted = redacted.replacingOccurrences(of: String(escaped), with: redactionMarker)
        }
      }
    }
    let range = NSRange(redacted.startIndex..., in: redacted)
    return keyPattern.stringByReplacingMatches(
      in: redacted,
      range: range,
      withTemplate: redactionMarker
    )
  }

  /// A name that sorts by recording time, to the millisecond, then says what
  /// the call was: `20260914T203102.123Z-triage-1a2b3c4d.json`.
  ///
  /// Recorded calls never share a millisecond (`recordingStamp(at:after:)`), so
  /// their names sort in the order the calls were made.
  public static func fileName(
    for fixture: CallFixture,
    suffix: String = String(UUID().uuidString.prefix(8)).lowercased()
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss"
    let millisecond = Self.millisecond(of: fixture.recordedAt)
    let second = (Double(millisecond) / 1000).rounded(.down)
    let fraction = String(format: "%03ld", millisecond - Int(second) * 1000)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let kind = String(
      fixture.identity.kind.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    )
    return
      "\(formatter.string(from: Date(timeIntervalSince1970: second))).\(fraction)Z-\(kind)-\(suffix).json"
  }

  /// The stamp for a call made at `now` after a call stamped `previous`.
  ///
  /// It is `now` when its name shows a later millisecond than the name of
  /// `previous` does, and otherwise the next millisecond. A name shows only the
  /// millisecond, so without this two calls inside one millisecond, or either
  /// side of the wall clock stepping back, would sort by kind and id instead of
  /// in the order they were made.
  public static func recordingStamp(at now: Date, after previous: Date?) -> Date {
    guard let previous, millisecond(of: now) <= millisecond(of: previous) else { return now }
    return Date(timeIntervalSince1970: Double(millisecond(of: previous) + 1) / 1000)
  }

  /// The millisecond a name shows for `date`, the nearest one, counted from 1970.
  static func millisecond(of date: Date) -> Int {
    Int((date.timeIntervalSince1970 * 1000).rounded())
  }

  /// Creates `directory` (mode 0700 when missing) and proves a fixture can be
  /// written there by writing and removing a probe file.
  ///
  /// Throws when either fails.
  public static func checkWritable(_ directory: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let probe = directory.appendingPathComponent(".write-probe-\(UUID().uuidString)")
    try Data().write(to: probe)
    try manager.removeItem(at: probe)
  }

  /// Writes one fixture into `directory` (created with mode 0700 when missing)
  /// as a file only the user can read.
  ///
  /// Returns its URL.
  @discardableResult
  public static func write(
    _ fixture: CallFixture,
    to directory: URL,
    redacting apiKey: String
  ) throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let url = directory.appendingPathComponent(fileName(for: fixture))
    try encode(fixture, redacting: apiKey).write(to: url, options: [.atomic])
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  /// Every `.json` fixture in `directory`, ordered by file name, which is
  /// recording order for recorded files and whatever order a curated set was
  /// named in.
  ///
  /// Throws, naming the file, when one cannot be read.
  public static func load(from directory: URL) throws -> [(name: String, fixture: CallFixture)] {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw ReplayLoadError.unreadableDirectory(directory.path, error.localizedDescription)
    }
    return try names.filter { $0.hasSuffix(".json") }.sorted().map { name in
      let url = directory.appendingPathComponent(name)
      do {
        return (name, try decoder.decode(CallFixture.self, from: Data(contentsOf: url)))
      } catch {
        throw ReplayLoadError.unreadableFixture(name, String(describing: error))
      }
    }
  }

}

/// Why a directory of fixtures could not be replayed.
public enum ReplayLoadError: Error, Equatable, CustomStringConvertible, Sendable {
  case unreadableDirectory(String, String)
  case unreadableFixture(String, String)
  case empty(String)

  /// The reason as one line naming the directory or file, which the menu, the
  /// Mentor card, and the call log show.
  public var description: String {
    switch self {
    case .unreadableDirectory(let path, let reason):
      "cannot read the fixture directory \(path): \(reason)"
    case .unreadableFixture(let name, let reason): "cannot read fixture \(name): \(reason)"
    case .empty(let path): "no recorded calls in \(path)"
    }
  }
}
