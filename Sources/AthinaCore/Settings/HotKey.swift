import Foundation

/// A global keyboard shortcut, stored as a virtual key code plus modifiers.
public struct HotKey: Codable, Equatable, Hashable, Sendable {
  /// The modifier keys held with the key, in bits of Athina's own that
  /// `HotKeyCenter` turns into Carbon's flags when it registers the shortcut.
  public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    /// The modifier bits, which are what settings.json stores.
    public let rawValue: UInt32
    /// Creates the set whose bits are `rawValue`.
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// The Control key.
    public static let control = Modifiers(rawValue: 1 << 0)
    /// The Option key.
    public static let option = Modifiers(rawValue: 1 << 1)
    /// The Shift key.
    public static let shift = Modifiers(rawValue: 1 << 2)
    /// The Command key.
    public static let command = Modifiers(rawValue: 1 << 3)
  }

  /// The macOS virtual key code of the key, a position on the keyboard
  /// rather than a character (35 is P on a US layout).
  public var keyCode: UInt32
  /// The modifier keys held with it.
  public var modifiers: Modifiers

  /// Creates the shortcut that presses `keyCode` with `modifiers` held.
  public init(keyCode: UInt32, modifiers: Modifiers) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  /// Control-Option-Command-P.
  public static let defaultPause = HotKey(keyCode: 35, modifiers: [.control, .option, .command])

  /// Human-readable form, for example "⌃⌥⌘P".
  public var displayString: String {
    var s = ""
    if modifiers.contains(.control) { s += "⌃" }
    if modifiers.contains(.option) { s += "⌥" }
    if modifiers.contains(.shift) { s += "⇧" }
    if modifiers.contains(.command) { s += "⌘" }
    return s + HotKey.keyName(for: keyCode)
  }

  /// The combination spelled out the way the Human Interface Guidelines write
  /// shortcuts, for VoiceOver: "Control-Option-Command-P".
  ///
  /// Modifiers keep the standard order, and a key shown as a symbol gets its
  /// name.
  public var accessibilityName: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("Control") }
    if modifiers.contains(.option) { parts.append("Option") }
    if modifiers.contains(.shift) { parts.append("Shift") }
    if modifiers.contains(.command) { parts.append("Command") }
    let key = HotKey.keyName(for: keyCode)
    parts.append(HotKey.spokenKeyNames[key] ?? key)
    return parts.joined(separator: "-")
  }

  /// Whether the combination is usable as a global hotkey: it needs at
  /// least one non-shift modifier so ordinary typing cannot trigger it.
  public var isUsable: Bool {
    !modifiers.isDisjoint(with: [.control, .option, .command])
  }

  /// Names for ANSI virtual key codes (US layout positions).
  public static func keyName(for keyCode: UInt32) -> String {
    if let name = keyNames[keyCode] { return name }
    return "Key \(keyCode)"
  }

  private static let keyNames: [UInt32: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
    20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
    29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
    39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
    50: "`", 36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
    96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
    109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
    123: "←", 124: "→", 125: "↓", 126: "↑",
  ]

  /// Names for the keys `keyName` shows as a symbol or punctuation mark.
  private static let spokenKeyNames: [String: String] = [
    "↩": "Return", "⇥": "Tab", "⌫": "Delete", "⎋": "Escape",
    "←": "Left Arrow", "→": "Right Arrow", "↓": "Down Arrow", "↑": "Up Arrow",
    "=": "Equal Sign", "-": "Hyphen", "[": "Left Bracket", "]": "Right Bracket",
    "'": "Apostrophe", ";": "Semicolon", "\\": "Backslash", ",": "Comma",
    "/": "Slash", ".": "Period", "`": "Grave Accent",
  ]
}
