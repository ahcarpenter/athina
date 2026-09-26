import AppKit
import KeyboardShortcuts

/// A global keyboard shortcut as settings.json stores it: a virtual key code
/// plus modifier bits of Athina's own.
///
/// Every build has written this form, so a saved shortcut keeps working and an
/// older build still reads the file. `shortcut` is the same combination as the
/// KeyboardShortcuts package has it, which registers, names and records it
/// (README "Keyboard shortcuts").
public struct HotKey: Codable, Equatable, Hashable, Sendable {
  /// The modifier keys held with the key, in bits of Athina's own, which is
  /// what settings.json stores.
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

  /// The combination a recorder took, in the stored form; nil for one this
  /// form cannot hold, which no recorder makes: a modifier other than Control,
  /// Option, Shift and Command (the recorder drops Fn), or a key code out of
  /// range.
  public init?(_ shortcut: KeyboardShortcuts.Shortcut) {
    guard let keyCode = UInt32(exactly: shortcut.carbonKeyCode) else { return nil }
    var flags = shortcut.modifiers
    var modifiers: Modifiers = []
    for (flag, modifier) in HotKey.modifierFlags where flags.contains(flag) {
      modifiers.insert(modifier)
      flags.remove(flag)
    }
    guard flags.isEmpty else { return nil }
    self.init(keyCode: keyCode, modifiers: modifiers)
  }

  /// Control-Option-Command-P.
  public static let defaultPause = HotKey(keyCode: 35, modifiers: [.control, .option, .command])

  /// The same combination as KeyboardShortcuts has it: what the app
  /// registers with the system, shows by the current keyboard layout, and
  /// hands its recorder.
  public var shortcut: KeyboardShortcuts.Shortcut {
    var flags: NSEvent.ModifierFlags = []
    for (flag, modifier) in HotKey.modifierFlags where modifiers.contains(modifier) {
      flags.insert(flag)
    }
    let key = KeyboardShortcuts.Key(rawValue: Int(keyCode))
    return KeyboardShortcuts.Shortcut(key, modifiers: flags)
  }

  /// The combination as macOS writes it, the key named by the current keyboard
  /// layout: "⌃⌥⌘P".
  @MainActor public var displayString: String {
    shortcut.description
  }

  /// Whether the combination can be a global shortcut without taking a key
  /// people type: it holds Control, Option, or Command, or its key is a
  /// function key, the rule KeyboardShortcuts' recorder applies.
  public var isUsable: Bool {
    !modifiers.isDisjoint(with: [.control, .option, .command])
      || HotKey.functionKeys.contains(keyCode)
  }

  /// Each of the stored modifiers with AppKit's flag for it.
  private static let modifierFlags: [(NSEvent.ModifierFlags, Modifiers)] = [
    (.control, .control),
    (.option, .option),
    (.shift, .shift),
    (.command, .command),
  ]

  /// F1 to F20, the function keys a Mac keyboard can have.
  private static let functionKeys: Set<UInt32> = Set(
    [
      KeyboardShortcuts.Key.f1,
      .f2,
      .f3,
      .f4,
      .f5,
      .f6,
      .f7,
      .f8,
      .f9,
      .f10,
      .f11,
      .f12,
      .f13,
      .f14,
      .f15,
      .f16,
      .f17,
      .f18,
      .f19,
      .f20,
    ]
    .map { UInt32($0.rawValue) }
  )
}
