import Foundation

/// Checks a reply against the JSON schema its call sent, before anything
/// reads it.
///
/// Every provider is asked for structured output, but a reply is still text
/// from the network, so the loop checks it here whoever answered. It covers
/// the parts of JSON Schema Athina's own schemas use (`MentorPrompts`): `type`,
/// `properties`, `required`, `additionalProperties: false`, `items`, `enum`
/// and `anyOf`. Anything else in a schema is not checked.
public enum JSONSchemaCheck {
  /// Why `value` does not match `schema`, as a path and a reason such as
  /// `$.suggestion.category: not one of the allowed values`, or nil when it
  /// matches.
  public static func problem(with value: JSONValue, against schema: JSONValue) -> String? {
    problem(value, schema, at: "$")
  }

  /// Why the text of a reply is not JSON matching `schema`, or nil when it
  /// is.
  public static func problem(withReply text: String, against schema: JSONValue) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
      return "$: not JSON"
    }
    return problem(with: value, against: schema)
  }

  private static func problem(_ value: JSONValue, _ schema: JSONValue, at path: String) -> String? {
    guard case .object(let rules) = schema else { return nil }
    if case .array(let options)? = rules["anyOf"] {
      guard options.contains(where: { problem(value, $0, at: path) == nil }) else {
        return "\(path): matches none of the allowed shapes"
      }
    }
    if case .array(let allowed)? = rules["enum"], !allowed.contains(value) {
      return "\(path): not one of the allowed values"
    }
    if let type = rules["type"] {
      let types: [String] =
        switch type {
        case .string(let one): [one]
        case .array(let many): many.compactMap { if case .string(let t) = $0 { t } else { nil } }
        default: []
        }
      if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
        return "\(path): expected \(types.joined(separator: " or "))"
      }
    }
    switch value {
    case .object(let fields):
      let properties: [String: JSONValue] =
        if case .object(let properties)? = rules["properties"] { properties } else { [:] }
      if case .array(let required)? = rules["required"] {
        for case .string(let key) in required where fields[key] == nil {
          return "\(path): missing \(key)"
        }
      }
      if rules["additionalProperties"] == .bool(false),
        let extra = fields.keys.sorted().first(where: { properties[$0] == nil })
      {
        return "\(path): unexpected \(extra)"
      }
      for key in fields.keys.sorted() {
        guard let field = fields[key], let rule = properties[key] else { continue }
        if let problem = problem(field, rule, at: "\(path).\(key)") { return problem }
      }
    case .array(let elements):
      if let items = rules["items"] {
        for (index, element) in elements.enumerated() {
          if let problem = problem(element, items, at: "\(path)[\(index)]") { return problem }
        }
      }
    default:
      break
    }
    return nil
  }

  private static func matches(_ value: JSONValue, type: String) -> Bool {
    switch (type, value) {
    case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool),
      ("null", .null), ("number", .number):
      true
    case ("integer", .number(let number)): number == number.rounded()
    default: false
    }
  }
}
