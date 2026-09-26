import Foundation
import Testing

@testable import AthinaCore

/// Every output schema a tier sends against the type `MentorLoop` decodes its
/// reply with.
///
/// The schemas are hand-written literals beside the types, so nothing but
/// this keeps them in step: a reply shaped exactly as a schema asks must
/// decode, and the keys the type asks its decoder about while decoding it,
/// present or not, must be the schema's keys at every level. A key the type
/// ignores, or one the type reads that the schema never
/// asks for, fails here rather than as a field the model is asked for and the
/// app drops, or one the app waits for and never gets.
@Suite struct PromptSchemaTests {
  private struct UnreadableSchema: Error, CustomStringConvertible {
    var description: String
  }

  /// A reply exactly as `schema` describes it: every property present, a
  /// string, number or boolean for each scalar, an enum's first value, the
  /// branch of an `anyOf` that is not null, and one item in an array.
  private func sample(of schema: JSONValue) throws -> JSONValue {
    guard case .object(let node) = schema else {
      throw UnreadableSchema(description: "not a schema: \(schema)")
    }
    if case .array(let options)? = node["anyOf"] {
      guard let option = options.first(where: { $0 != ["type": "null"] }) else {
        throw UnreadableSchema(description: "an anyOf with only null: \(schema)")
      }
      return try sample(of: option)
    }
    if case .array(let values)? = node["enum"], let first = values.first { return first }
    switch node["type"] {
    case "object":
      guard case .object(let properties)? = node["properties"] else {
        throw UnreadableSchema(description: "an object without properties: \(schema)")
      }
      return .object(try properties.mapValues { try sample(of: $0) })
    case "array":
      return .array([try sample(of: node["items"] ?? .null)])
    case "string": return "text"
    case "number": return 0.5
    case "boolean": return true
    default: throw UnreadableSchema(description: "a type this test cannot fill: \(schema)")
    }
  }

  /// Every key at every level, as a dotted path; an array's items are `[]`.
  private func keyPaths(of value: JSONValue, under prefix: String = "") -> Set<String> {
    switch value {
    case .object(let fields):
      return fields.reduce(into: Set<String>()) { paths, field in
        paths.insert(prefix + field.key)
        paths.formUnion(keyPaths(of: field.value, under: prefix + field.key + "."))
      }
    case .array(let items):
      return items.reduce(into: Set<String>()) { paths, item in
        paths.formUnion(keyPaths(of: item, under: prefix + "[]."))
      }
    default:
      return []
    }
  }

  /// Every object in `schema` whose required keys are not exactly its
  /// properties, by path: each tier asks for every field it describes.
  private func partlyRequired(_ schema: JSONValue, at path: String = "") -> [String] {
    guard case .object(let node) = schema else { return [] }
    var found: [String] = []
    if case .object(let properties)? = node["properties"] {
      let required: Set<String>
      if case .array(let names)? = node["required"] {
        required = Set(names.compactMap { if case .string(let name) = $0 { name } else { nil } })
      } else {
        required = []
      }
      if required != Set(properties.keys) { found.append(path.isEmpty ? "(top)" : path) }
      for (key, property) in properties {
        found += partlyRequired(property, at: path.isEmpty ? key : path + "." + key)
      }
    }
    if case .array(let options)? = node["anyOf"] {
      for option in options { found += partlyRequired(option, at: path) }
    }
    if let items = node["items"] { found += partlyRequired(items, at: path + "[]") }
    return found
  }

  private func expectSchema<T: Decodable>(
    _ schema: JSONValue,
    matches type: T.Type,
    readingAlso unasked: Set<String> = [],
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let reply = try sample(of: schema)
    let log = KeyLog()
    _ = try T(from: KeyRecordingDecoder(value: reply, prefix: "", codingPath: [], log: log))
    let asked = keyPaths(of: reply)
    let read = log.paths
    #expect(
      asked.subtracting(read).isEmpty,
      "\(T.self) drops what the schema asks for: \(asked.subtracting(read).sorted())",
      sourceLocation: sourceLocation
    )
    #expect(
      read.subtracting(asked) == unasked,
      "\(T.self) reads what the schema never asks for: \(read.subtracting(asked).sorted())",
      sourceLocation: sourceLocation
    )
    #expect(
      partlyRequired(schema).isEmpty,
      "the schema leaves some of its properties unrequired: \(partlyRequired(schema))",
      sourceLocation: sourceLocation
    )
  }

  /// Without contexts the schema leaves out the context field, which the
  /// verdict reads as none.
  @Test func theTriageSchemaMatchesTheTriageVerdict() throws {
    try expectSchema(
      MentorPrompts.triageSchema(contexts: []),
      matches: TriageVerdict.self,
      readingAlso: ["context"]
    )
  }

  @Test func theTriageSchemaWithContextsMatchesTheTriageVerdict() throws {
    let contexts = [MentorshipContext(name: "writing Swift"), MentorshipContext(name: "email")]
    try expectSchema(MentorPrompts.triageSchema(contexts: contexts), matches: TriageVerdict.self)
  }

  @Test func theMentorSchemaMatchesTheMentorVerdict() throws {
    try expectSchema(MentorPrompts.mentorSchema, matches: MentorVerdict.self)
  }

  @Test func theRefreshSchemaMatchesTheUnderstandingVerdict() throws {
    try expectSchema(MentorPrompts.understandingRefreshSchema, matches: UnderstandingVerdict.self)
  }

  @Test func theFollowUpSchemaMatchesTheFollowUpReply() throws {
    try expectSchema(MentorPrompts.followUpSchema, matches: FollowUpReply.self)
  }
}

/// The key paths a type asked about while decoding, written as `keyPaths` writes them.
private final class KeyLog {
  var paths: Set<String> = []
}

/// A decoder over a `JSONValue` that notes every key a keyed container is
/// asked about, whether decoded, checked for, tested for null or opened, so a
/// key the type reads is seen even when the value holds none for it.
private struct KeyRecordingDecoder: Decoder {
  var value: JSONValue
  var prefix: String
  var codingPath: [any CodingKey]
  var log: KeyLog
  var userInfo: [CodingUserInfoKey: Any] { [:] }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    guard case .object(let fields) = value else {
      throw DecodingError.typeMismatch(
        [String: JSONValue].self,
        .init(codingPath: codingPath, debugDescription: "not an object: \(value)")
      )
    }
    return KeyedDecodingContainer(
      KeyedContainer<Key>(fields: fields, prefix: prefix, codingPath: codingPath, log: log)
    )
  }

  func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
    guard case .array(let items) = value else {
      throw DecodingError.typeMismatch(
        [JSONValue].self,
        .init(codingPath: codingPath, debugDescription: "not an array: \(value)")
      )
    }
    return UnkeyedContainer(items: items, prefix: prefix + "[].", codingPath: codingPath, log: log)
  }

  func singleValueContainer() throws -> any SingleValueDecodingContainer {
    SingleValueContainer(decoder: self)
  }
}

private struct IndexKey: CodingKey {
  var intValue: Int?
  var stringValue: String { "\(intValue ?? 0)" }
  init(intValue: Int) { self.intValue = intValue }
  init?(stringValue: String) { nil }
}

private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
  var fields: [String: JSONValue]
  var prefix: String
  var codingPath: [any CodingKey]
  var log: KeyLog
  var allKeys: [Key] { fields.keys.compactMap { Key(stringValue: $0) } }

  private func child(_ key: Key) throws -> KeyRecordingDecoder {
    log.paths.insert(prefix + key.stringValue)
    guard let value = fields[key.stringValue] else {
      throw DecodingError.keyNotFound(
        key,
        .init(codingPath: codingPath, debugDescription: "no \(key.stringValue)")
      )
    }
    return KeyRecordingDecoder(
      value: value,
      prefix: prefix + key.stringValue + ".",
      codingPath: codingPath + [key],
      log: log
    )
  }

  func contains(_ key: Key) -> Bool {
    log.paths.insert(prefix + key.stringValue)
    return fields[key.stringValue] != nil
  }

  func decodeNil(forKey key: Key) throws -> Bool { try child(key).value == .null }

  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
    try T(from: child(key))
  }

  func nestedContainer<NestedKey: CodingKey>(
    keyedBy type: NestedKey.Type,
    forKey key: Key
  ) throws -> KeyedDecodingContainer<NestedKey> {
    try child(key).container(keyedBy: type)
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
    try child(key).unkeyedContainer()
  }

  func superDecoder() throws -> any Decoder {
    KeyRecordingDecoder(value: .object(fields), prefix: prefix, codingPath: codingPath, log: log)
  }

  func superDecoder(forKey key: Key) throws -> any Decoder { try child(key) }
}

private struct UnkeyedContainer: UnkeyedDecodingContainer {
  var items: [JSONValue]
  var prefix: String
  var codingPath: [any CodingKey]
  var log: KeyLog
  var currentIndex = 0
  var count: Int? { items.count }
  var isAtEnd: Bool { currentIndex >= items.count }

  init(items: [JSONValue], prefix: String, codingPath: [any CodingKey], log: KeyLog) {
    self.items = items
    self.prefix = prefix
    self.codingPath = codingPath
    self.log = log
  }

  private mutating func next() throws -> KeyRecordingDecoder {
    guard !isAtEnd else {
      throw DecodingError.valueNotFound(
        JSONValue.self,
        .init(codingPath: codingPath, debugDescription: "past the end")
      )
    }
    defer { currentIndex += 1 }
    return KeyRecordingDecoder(
      value: items[currentIndex],
      prefix: prefix,
      codingPath: codingPath + [IndexKey(intValue: currentIndex)],
      log: log
    )
  }

  mutating func decodeNil() throws -> Bool {
    guard !isAtEnd, items[currentIndex] == .null else { return false }
    currentIndex += 1
    return true
  }

  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try T(from: next()) }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy type: NestedKey.Type
  ) throws -> KeyedDecodingContainer<NestedKey> {
    try next().container(keyedBy: type)
  }

  mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
    try next().unkeyedContainer()
  }

  mutating func superDecoder() throws -> any Decoder { try next() }
}

private struct SingleValueContainer: SingleValueDecodingContainer {
  var decoder: KeyRecordingDecoder
  var codingPath: [any CodingKey] { decoder.codingPath }

  private func mismatch<T>(_ type: T.Type) -> DecodingError {
    .typeMismatch(
      type,
      .init(codingPath: codingPath, debugDescription: "not a \(T.self): \(decoder.value)")
    )
  }

  private func number<T: BinaryInteger>(_ type: T.Type) throws -> T {
    guard case .number(let number) = decoder.value, let exact = T(exactly: number) else {
      throw mismatch(type)
    }
    return exact
  }

  func decodeNil() -> Bool { decoder.value == .null }

  func decode(_ type: Bool.Type) throws -> Bool {
    guard case .bool(let bool) = decoder.value else { throw mismatch(type) }
    return bool
  }

  func decode(_ type: String.Type) throws -> String {
    guard case .string(let string) = decoder.value else { throw mismatch(type) }
    return string
  }

  func decode(_ type: Double.Type) throws -> Double {
    guard case .number(let number) = decoder.value else { throw mismatch(type) }
    return number
  }

  func decode(_ type: Float.Type) throws -> Float { Float(try decode(Double.self)) }
  func decode(_ type: Int.Type) throws -> Int { try number(type) }
  func decode(_ type: Int8.Type) throws -> Int8 { try number(type) }
  func decode(_ type: Int16.Type) throws -> Int16 { try number(type) }
  func decode(_ type: Int32.Type) throws -> Int32 { try number(type) }
  func decode(_ type: Int64.Type) throws -> Int64 { try number(type) }
  func decode(_ type: UInt.Type) throws -> UInt { try number(type) }
  func decode(_ type: UInt8.Type) throws -> UInt8 { try number(type) }
  func decode(_ type: UInt16.Type) throws -> UInt16 { try number(type) }
  func decode(_ type: UInt32.Type) throws -> UInt32 { try number(type) }
  func decode(_ type: UInt64.Type) throws -> UInt64 { try number(type) }
  func decode<T: Decodable>(_ type: T.Type) throws -> T { try T(from: decoder) }
}
