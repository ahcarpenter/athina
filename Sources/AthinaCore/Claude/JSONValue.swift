import Foundation

/// A plain JSON value, used for JSON schemas sent to the API.
///
/// Literal conformances let a schema be written as a Swift literal, and the
/// encoder emits integral numbers without a fractional part so `1` stays `1`.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case array([JSONValue])
  case object([String: JSONValue])

  /// Decodes a JSON null, bool, number, string, array, or object.
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([JSONValue].self) {
      self = .array(array)
    } else if let object = try? container.decode([String: JSONValue].self) {
      self = .object(object)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "unsupported JSON value"
      )
    }
  }

  /// Encodes the value, writing a whole number below 1e15 in magnitude as an
  /// integer.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let string): try container.encode(string)
    case .number(let number):
      if number == number.rounded(), abs(number) < 1e15 {
        try container.encode(Int64(number))
      } else {
        try container.encode(number)
      }
    case .bool(let bool): try container.encode(bool)
    case .null: try container.encodeNil()
    case .array(let array): try container.encode(array)
    case .object(let object): try container.encode(object)
    }
  }
}

extension JSONValue:
  ExpressibleByStringLiteral,
  ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral,
  ExpressibleByNilLiteral,
  ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  /// Creates a string value.
  public init(stringLiteral value: String) { self = .string(value) }
  /// Creates a number value from an integer literal.
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  /// Creates a number value from a float literal.
  public init(floatLiteral value: Double) { self = .number(value) }
  /// Creates a bool value.
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  /// Creates the null value from `nil`.
  public init(nilLiteral: ()) { self = .null }
  /// Creates an array value.
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  /// Creates an object value; a key written twice keeps its last value.
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
