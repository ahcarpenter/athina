import Foundation

/// Settings a later build must still read from a file an older one wrote:
/// every field has a default, and a key the file lacks takes it.
///
/// A conforming type keeps its synthesized `Codable`, so a new field needs no
/// decode line or coding key to be read and saved. `init(json:)` is what
/// makes a missing key take its default, since the synthesized decoder
/// requires every key; an optional field must default to nil, because a
/// saved nil is a missing key.
public protocol SettingsSection: Codable {
  /// The defaults.
  init()
  /// Clamps every value into a range the app can operate with.
  func validated() -> Self
}

extension SettingsSection {
  /// Decodes `data`, a settings file this build or an older one wrote, and
  /// validates it.
  ///
  /// The file is laid over the encoded defaults before the synthesized
  /// decoder reads it, so a key it lacks or holds null takes its default, in
  /// this section and in every struct inside it. A dictionary, an array, an
  /// optional the defaults leave nil and every other value comes whole from
  /// the file when the file has it, so a dictionary is never merged key by
  /// key. A value of the wrong type still throws.
  public init(json data: Data) throws {
    let defaults = Self()
    let encodedDefaults = try JSONDecoder().decode(
      JSONValue.self,
      from: JSONEncoder().encode(defaults)
    )
    let file = try JSONDecoder().decode(JSONValue.self, from: data)
    let merged = SettingsMerge.laying(file, over: defaults, encoded: encodedDefaults)
    self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(merged)).validated()
  }
}

enum SettingsMerge {
  /// `file` laid over `value`, whose encoding is `encoded`: when `value` is a
  /// struct and both are objects, `encoded` with each of the file's keys
  /// laid over its field, a null skipped; otherwise `file`.
  static func laying(_ file: JSONValue, over value: Any, encoded: JSONValue) -> JSONValue {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .struct,
      case .object(var merged) = encoded,
      case .object(let fields) = file
    else { return file }
    let children = Dictionary(
      mirror.children.compactMap { child in child.label.map { ($0, child.value) } },
      uniquingKeysWith: { first, _ in first }
    )
    for (key, field) in fields where field != .null {
      if let child = children[key], let base = merged[key] {
        merged[key] = laying(field, over: child, encoded: base)
      } else {
        merged[key] = field
      }
    }
    return .object(merged)
  }
}
