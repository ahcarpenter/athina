import Foundation

// What travels over the control API's socket (docs/e2e.md "The control API"): one
// JSON request per line from athina-drive, one JSON answer per line from the
// app. Both sides use these types, so neither can drift from the other.

/// The names and limits both ends of the control API share.
public enum ControlProtocol {
  /// Names this protocol in every `ping` answer, and marks a binary that
  /// carries the control API: `scripts/check-no-control-api.sh` refuses a
  /// release whose binary contains it.
  public static let name = "com.ahcarpenter.athina.control-api/1"
  /// The longest request line the app reads, so a stray writer cannot make
  /// it buffer without end.
  public static let maximumLineLength = 1 << 20
  /// The socket and the secret inside a run's control directory.
  ///
  /// AthinaCore's `ControlMode` names the same two, and a test holds them
  /// equal: the app's release build links AthinaCore but never this module.
  public static let socketName = "control.sock"
  /// The file inside a run's control directory that holds its secret.
  public static let secretName = "secret"

  /// What a parameter takes, for those that take something other than text.
  public enum Kind: Sendable {
    case bool
    case number
    /// Any JSON value, such as the setting `wait-setting` waits for.
    case json
  }

  /// The parameters that take something other than text, and what each
  /// takes; every other one is text.
  public static let kinds: [String: Kind] = [
    "force": .bool,
    "present": .bool,
    "timeout": .number,
    "equals": .json,
    "x": .number,
    "y": .number,
    "after": .number, "seconds": .number, "idle": .bool,
  ]
}

/// A JSON value, for requests and answers whose fields vary by command.
public enum ControlValue: Equatable, Sendable, Codable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case array([ControlValue])
  case object([String: ControlValue])

  /// Decodes whatever JSON value there is: null, true or false, a number,
  /// text, an array, or else an object.
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([ControlValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: ControlValue].self))
    }
  }

  /// Encodes the plain JSON value, with no case name around it.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  /// The text, or nil when the value is not a string.
  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  /// The value when it is true or false, or nil when it is anything else.
  public var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  /// The number, or nil when the value is not one.
  public var number: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  /// The value at a dotted path such as `elements.0.enabled`: a key into an
  /// object, or an index into an array.
  ///
  /// Nil when the path leads nowhere.
  public subscript(path path: String) -> ControlValue? {
    var current: ControlValue? = self
    for part in path.split(separator: ".", omittingEmptySubsequences: true) {
      switch current {
      case .object(let object): current = object[String(part)]
      case .array(let array):
        guard let index = Int(part), array.indices.contains(index) else { return nil }
        current = array[index]
      default: return nil
      }
    }
    return current
  }

  /// How a shell script reads it: a string as it is, anything else as JSON.
  public var text: String {
    switch self {
    case .string(let value): return value
    case .number(let value):
      return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    case .bool(let value): return value ? "true" : "false"
    case .null: return "null"
    case .array, .object:
      return (try? ControlValue.encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        ?? ""
    }
  }

  /// `key=value` from a command line, typed as the parameter takes it
  /// (`ControlProtocol.kinds`): `true` or `false`, a number, or JSON for the
  /// parameters that take one, and the text as written for every other.
  ///
  /// A value that does not read as what its parameter takes goes as text, which
  /// the app refuses by the parameter's name.
  public static func argument(_ text: String) -> (key: String, value: ControlValue)? {
    guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { return nil }
    let key = String(text[..<equals])
    let raw = String(text[text.index(after: equals)...])
    guard let kind = ControlProtocol.kinds[key],
      let data = raw.data(using: .utf8),
      let value = try? JSONDecoder().decode(ControlValue.self, from: data)
    else {
      return (key, .string(raw))
    }
    switch (kind, value) {
    case (.json, _), (.bool, .bool), (.number, .number): return (key, value)
    default: return (key, .string(raw))
    }
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()
}

/// One request: which command, with what arguments, carrying the run's secret.
public struct ControlRequest: Equatable, Sendable, Codable {
  /// The request's number, which its answer carries back as `id`; athina-drive
  /// sends its own pid.
  public var id: Int
  /// The run's secret, as the control directory's `secret` file holds it.
  ///
  /// A request whose secret does not match gets an error and nothing else.
  public var secret: String
  /// The command's name, such as `click` or `wait-setting` (docs/e2e.md "The
  /// control API").
  public var command: String
  /// The command's parameters by name, such as `window=` or `timeout=`.
  public var arguments: [String: ControlValue]

  /// Creates a request for `command`, carrying the run's secret.
  public init(id: Int, secret: String, command: String, arguments: [String: ControlValue] = [:]) {
    self.id = id
    self.secret = secret
    self.command = command
    self.arguments = arguments
  }

  /// Returns the request as it goes over the socket: one line of JSON ending
  /// in a newline.
  public func line() throws -> Data {
    var data = try ControlValue.encoder.encode(self)
    data.append(0x0A)
    return data
  }

  /// Reads a request from one line the app received, without its newline;
  /// throws when the line is not one.
  public static func decode(line: Data) throws -> ControlRequest {
    try JSONDecoder().decode(ControlRequest.self, from: line)
  }

  /// Returns the parameter named `key` as it was sent, whatever its type, or
  /// nil when the request leaves it out.
  public func argument(_ key: String) -> ControlValue? { arguments[key] }

  /// A parameter as the type its command takes: nil when the request leaves
  /// it out, and thrown, by name, when it holds another type, so a command
  /// never carries on as if it had not been given.
  public func string(_ key: String) throws -> String? { try read(key, "text") { $0.string } }
  /// Returns the parameter named `key` as true or false, nil when the request
  /// leaves it out; throws when it holds anything else.
  public func bool(_ key: String) throws -> Bool? { try read(key, "true or false") { $0.bool } }
  /// Returns the parameter named `key` as a number, nil when the request
  /// leaves it out; throws when it holds anything else.
  public func number(_ key: String) throws -> Double? { try read(key, "a number") { $0.number } }

  private func read<T>(
    _ key: String,
    _ expected: String,
    _ typed: (ControlValue) -> T?
  ) throws -> T? {
    guard let given = arguments[key] else { return nil }
    guard let value = typed(given) else {
      throw ControlArgumentError(key: key, expected: expected, given: given)
    }
    return value
  }
}

/// A parameter holding another type than the one its command takes.
public struct ControlArgumentError: Error, Equatable, CustomStringConvertible {
  /// The name of the parameter, such as `timeout`.
  public let key: String
  /// What the parameter takes, as the message words it, such as `a number`.
  public let expected: String
  /// The value the request held instead.
  public let given: ControlValue

  /// Reads like `timeout= takes a number, not soon`.
  public var description: String { "\(key)= takes \(expected), not \(given.text)" }
}

/// One answer: `ok`, and when it is not, `refused` (the app would not do it,
/// for a reason a check can name, such as `disabled`) or `error`; the rest is
/// the command's own.
///
/// It never repeats the request, so the secret never comes back out.
public struct ControlReply: Equatable, Sendable {
  /// Every field of the answer by name, `ok`, `refused` and `error` among
  /// them.
  public var fields: [String: ControlValue]

  /// Creates an answer holding exactly these fields.
  public init(_ fields: [String: ControlValue] = [:]) {
    self.fields = fields
  }

  /// Returns an answer that succeeded, with the command's own fields.
  public static func ok(_ fields: [String: ControlValue] = [:]) -> ControlReply {
    ControlReply(fields.merging(["ok": .bool(true)]) { _, new in new })
  }

  /// Returns an answer the app would not carry out, for a reason a check can
  /// name.
  ///
  /// - Parameters:
  ///   - reason: The reason a check names, such as `disabled` or `missing`,
  ///     which goes in `refused`.
  ///   - message: What went wrong, for a person to read, which goes in `error`.
  ///   - fields: The command's own fields, such as the control it judged.
  /// - Returns: The answer, with `ok` false and the command's fields beside it.
  public static func refused(
    _ reason: String,
    _ message: String,
    _ fields: [String: ControlValue] = [:]
  ) -> ControlReply {
    ControlReply(
      fields.merging(["ok": .bool(false), "refused": .string(reason), "error": .string(message)]) {
        _,
        new in new
      }
    )
  }

  /// Returns an answer that failed with `message` in `error`, for a reason no
  /// check names.
  public static func error(
    _ message: String,
    _ fields: [String: ControlValue] = [:]
  ) -> ControlReply {
    ControlReply(fields.merging(["ok": .bool(false), "error": .string(message)]) { _, new in new })
  }

  /// Whether the command succeeded: the answer's `ok` is true.
  public var ok: Bool { fields["ok"]?.bool == true }
  /// The reason the app would not carry the command out, or nil when it was
  /// not refused.
  public var refused: String? { fields["refused"]?.string }

  /// The field named `key`, or nil when the answer has none.
  public subscript(key: String) -> ControlValue? {
    get { fields[key] }
    set { fields[key] = newValue }
  }

  /// The whole answer as one JSON object, from which athina-drive reads a
  /// dotted path such as `elements.0.enabled`.
  public var json: ControlValue { .object(fields) }

  /// Returns the answer as it goes over the socket: one line of JSON ending in
  /// a newline.
  ///
  /// An answer that cannot be encoded goes as an error saying so.
  public func line() -> Data {
    var data =
      (try? ControlValue.encoder.encode(json))
      ?? Data(#"{"ok":false,"error":"unencodable answer"}"#.utf8)
    data.append(0x0A)
    return data
  }

  /// Reads an answer from one line the app sent; throws unless the line is a
  /// JSON object.
  public static func decode(line: Data) throws -> ControlReply {
    guard case .object(let fields) = try JSONDecoder().decode(ControlValue.self, from: line) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "an answer is a JSON object")
      )
    }
    return ControlReply(fields)
  }
}

/// The check of a request's secret against the run's.
public enum ControlSecret {
  /// Whether `given` is the run's secret, in time that depends only on the
  /// secret's length and never on where the two first differ.
  public static func matches(_ given: String, _ expected: String) -> Bool {
    let a = Array(given.utf8)
    let b = Array(expected.utf8)
    var difference = UInt8(a.count == b.count ? 0 : 1)
    for index in b.indices {
      difference |= (index < a.count ? a[index] : 0) ^ b[index]
    }
    return difference == 0 && !b.isEmpty
  }
}
