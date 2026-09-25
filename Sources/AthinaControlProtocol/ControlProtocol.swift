import Foundation

// What travels over the control API's socket (README "The control API"): one
// JSON request per line from athina-drive, one JSON answer per line from the
// app. Both sides use these types, so neither can drift from the other.

public enum ControlProtocol {
    /// Names this protocol in every `ping` answer, and marks a binary that
    /// carries the control API: `scripts/check-no-control-api.sh` refuses a
    /// release whose binary contains it.
    public static let name = "com.ahcarpenter.athina.control-api/1"
    /// The longest request line the app reads, so a stray writer cannot make
    /// it buffer without end.
    public static let maximumLineLength = 1 << 20
    /// The socket and the secret inside a run's control directory. AthinaCore's
    /// `ControlMode` names the same two, and a test holds them equal: the app's
    /// release build links AthinaCore but never this module.
    public static let socketName = "control.sock"
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
        "force": .bool, "present": .bool, "timeout": .number, "equals": .json, "x": .number, "y": .number,
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

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The value at a dotted path such as `elements.0.enabled`: a key into an
    /// object, or an index into an array. Nil when the path leads nowhere.
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
            return (try? ControlValue.encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    /// `key=value` from a command line, typed as the parameter takes it
    /// (`ControlProtocol.kinds`): `true` or `false`, a number, or JSON for
    /// the parameters that take one, and the text as written for every other.
    /// A value that does not read as what its parameter takes goes as text,
    /// which the app refuses by the parameter's name.
    public static func argument(_ text: String) -> (key: String, value: ControlValue)? {
        guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { return nil }
        let key = String(text[..<equals])
        let raw = String(text[text.index(after: equals)...])
        guard let kind = ControlProtocol.kinds[key],
              let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(ControlValue.self, from: data) else {
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
    public var id: Int
    public var secret: String
    public var command: String
    public var arguments: [String: ControlValue]

    public init(id: Int, secret: String, command: String, arguments: [String: ControlValue] = [:]) {
        self.id = id
        self.secret = secret
        self.command = command
        self.arguments = arguments
    }

    public func line() throws -> Data {
        var data = try ControlValue.encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(line: Data) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: line)
    }

    public func argument(_ key: String) -> ControlValue? { arguments[key] }

    /// A parameter as the type its command takes: nil when the request leaves
    /// it out, and thrown, by name, when it holds another type, so a command
    /// never carries on as if it had not been given.
    public func string(_ key: String) throws -> String? { try read(key, "text") { $0.string } }
    public func bool(_ key: String) throws -> Bool? { try read(key, "true or false") { $0.bool } }
    public func number(_ key: String) throws -> Double? { try read(key, "a number") { $0.number } }

    private func read<T>(_ key: String, _ expected: String, _ typed: (ControlValue) -> T?) throws -> T? {
        guard let given = arguments[key] else { return nil }
        guard let value = typed(given) else { throw ControlArgumentError(key: key, expected: expected, given: given) }
        return value
    }
}

/// A parameter holding another type than the one its command takes.
public struct ControlArgumentError: Error, Equatable, CustomStringConvertible {
    public let key: String
    public let expected: String
    public let given: ControlValue

    public var description: String { "\(key)= takes \(expected), not \(given.text)" }
}

/// One answer: `ok`, and when it is not, `refused` (the app would not do it,
/// for a reason a check can name, such as `disabled`) or `error`; the rest is
/// the command's own. It never repeats the request, so the secret never comes
/// back out.
public struct ControlReply: Equatable, Sendable {
    public var fields: [String: ControlValue]

    public init(_ fields: [String: ControlValue] = [:]) {
        self.fields = fields
    }

    public static func ok(_ fields: [String: ControlValue] = [:]) -> ControlReply {
        ControlReply(fields.merging(["ok": .bool(true)]) { _, new in new })
    }

    public static func refused(_ reason: String, _ message: String, _ fields: [String: ControlValue] = [:]) -> ControlReply {
        ControlReply(fields.merging(["ok": .bool(false), "refused": .string(reason), "error": .string(message)]) { _, new in new })
    }

    public static func error(_ message: String, _ fields: [String: ControlValue] = [:]) -> ControlReply {
        ControlReply(fields.merging(["ok": .bool(false), "error": .string(message)]) { _, new in new })
    }

    public var ok: Bool { fields["ok"]?.bool == true }
    public var refused: String? { fields["refused"]?.string }

    public subscript(key: String) -> ControlValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    public var json: ControlValue { .object(fields) }

    public func line() -> Data {
        var data = (try? ControlValue.encoder.encode(json)) ?? Data(#"{"ok":false,"error":"unencodable answer"}"#.utf8)
        data.append(0x0A)
        return data
    }

    public static func decode(line: Data) throws -> ControlReply {
        guard case .object(let fields) = try JSONDecoder().decode(ControlValue.self, from: line) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "an answer is a JSON object"))
        }
        return ControlReply(fields)
    }
}

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
