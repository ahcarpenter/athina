import AthinaCore
import Carbon
import KeyboardShortcuts

/// Registers Athina's global keyboard shortcuts through KeyboardShortcuts,
/// which needs no permission and reports both the press and the release of a
/// combination.
///
/// The release is what makes push-to-talk possible without Input Monitoring:
/// the package hears the key go up without watching keyboard events at all.
/// It also keeps the shortcuts working while a menu is open, when the system
/// holds them back, and holds them off while one of its recorders records, so
/// pressing a shortcut there records it instead of running it.
@MainActor
final class HotKeyCenter {
  /// One registration each.
  enum Slot: CaseIterable {
    case pause
    case pushToTalk
  }

  var onPress: ((Slot) -> Void)?
  var onRelease: ((Slot) -> Void)?

  /// Each slot's listener; ending it unregisters the combination.
  private var listeners: [Slot: Task<Void, Never>] = [:]

  /// Registers the combination for the slot, replacing any previous one; nil
  /// unregisters it.
  ///
  /// Returns false when the combination is unset or unusable, or another app
  /// holds it for itself, so pressing it never reaches Athina.
  @discardableResult
  func register(_ hotKey: HotKey?, for slot: Slot) -> Bool {
    unregister(slot)
    guard let hotKey, hotKey.isUsable else { return false }
    let shortcut = hotKey.shortcut
    let heldElsewhere = HotKeyCenter.isHeldExclusively(shortcut)
    // Made here rather than in the task, so the combination is registered now.
    let events = KeyboardShortcuts.events(for: shortcut)
    listeners[slot] = Task { [weak self] in
      for await event in events {
        switch event {
        case .keyDown: self?.onPress?(slot)
        case .keyUp: self?.onRelease?(slot)
        }
      }
    }
    return !heldElsewhere
  }

  func unregister(_ slot: Slot) {
    listeners.removeValue(forKey: slot)?.cancel()
  }

  func unregisterAll() {
    for slot in Slot.allCases { unregister(slot) }
  }

  /// Whether another app registered the combination for itself alone, which
  /// takes every press of it from the rest.
  ///
  /// Any number of apps can register a combination the way KeyboardShortcuts
  /// does, and all of them hear it, so its registration never fails and it
  /// reports none. Only an exclusive registration takes a combination from
  /// the others, and a trial exclusive one is refused exactly when another
  /// app holds it that way.
  ///
  /// The system also refuses it when this app already holds the combination,
  /// as it may for a moment after a slot lets go of one (the package lets go
  /// on its next turn), so the package's own registrations are held off while
  /// the trial runs.
  private static func isHeldExclusively(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
    let wasEnabled = KeyboardShortcuts.isEnabled
    KeyboardShortcuts.isEnabled = false
    defer { KeyboardShortcuts.isEnabled = wasEnabled }
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(shortcut.carbonKeyCode),
      UInt32(shortcut.carbonModifiers),
      EventHotKeyID(signature: 0x4154_4850, id: 1),  // "ATHP"
      GetEventDispatcherTarget(),
      OptionBits(kEventHotKeyExclusive),
      &ref
    )
    if let ref { UnregisterEventHotKey(ref) }
    return status == eventHotKeyExistsErr
  }
}
