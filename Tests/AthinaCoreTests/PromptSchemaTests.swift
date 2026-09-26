import Foundation
import Testing

@testable import AthinaCore

/// Every output schema a tier sends against the type `MentorLoop` decodes its
/// reply with.
///
/// The schemas are hand-written literals beside the types, so nothing but
/// this keeps them in step: a reply shaped exactly as a schema asks must
/// decode, and encoding what it decoded must give back the same keys at every
/// level. A key the type ignores, or one the type reads that the schema never
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

  private func expectSchema<T: Codable>(
    _ schema: JSONValue,
    matches type: T.Type,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let reply = try sample(of: schema)
    let decoded = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(reply))
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))
    let asked = keyPaths(of: reply)
    let read = keyPaths(of: encoded)
    #expect(
      asked.subtracting(read).isEmpty,
      "\(T.self) drops what the schema asks for: \(asked.subtracting(read).sorted())",
      sourceLocation: sourceLocation
    )
    #expect(
      read.subtracting(asked).isEmpty,
      "\(T.self) reads what the schema never asks for: \(read.subtracting(asked).sorted())",
      sourceLocation: sourceLocation
    )
    #expect(
      partlyRequired(schema).isEmpty,
      "the schema leaves some of its properties unrequired: \(partlyRequired(schema))",
      sourceLocation: sourceLocation
    )
  }

  @Test func theTriageSchemaMatchesTheTriageVerdict() throws {
    try expectSchema(MentorPrompts.triageSchema(contexts: []), matches: TriageVerdict.self)
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
