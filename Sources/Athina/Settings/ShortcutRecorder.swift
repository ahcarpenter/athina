import AppKit
import AthinaCore
import KeyboardShortcuts
import SwiftUI

/// Records a keyboard shortcut: KeyboardShortcuts' own recorder, bound to a
/// stored `HotKey`.
///
/// Click it and press the new combination, or press Escape to cancel. The
/// global shortcuts are held off while it records, so pressing one records
/// it. Delete or its clear button removes the shortcut, except one that must
/// stay set, which keeps its combination. A combination in `conflicts`, one
/// the system or the app's menu uses, or one without Control, Option, or
/// Command that is not a function key, is refused.
struct ShortcutRecorder: NSViewRepresentable {
  /// What the shortcut is for, which VoiceOver reads as the control's label.
  let title: String
  /// The control's accessibility identifier, which end-to-end scenarios find
  /// it by.
  let identifier: String
  @Binding var hotKey: HotKey?
  /// Whether the shortcut must stay set, so clearing it keeps the combination.
  var isRequired = false
  var conflicts: [HotKey] = []
  /// Why a combination in `conflicts` is refused, the title of the alert that
  /// says so.
  var conflictNote = "This keyboard shortcut is already in use."

  init(
    title: String,
    identifier: String,
    hotKey: Binding<HotKey?>,
    conflicts: [HotKey] = [],
    conflictNote: String = "This keyboard shortcut is already in use."
  ) {
    self.title = title
    self.identifier = identifier
    _hotKey = hotKey
    self.conflicts = conflicts
    self.conflictNote = conflictNote
  }

  /// A recorder for a shortcut that is always set.
  init(
    title: String,
    identifier: String,
    hotKey: Binding<HotKey>,
    conflicts: [HotKey] = [],
    conflictNote: String = "This keyboard shortcut is already in use."
  ) {
    self.init(
      title: title,
      identifier: identifier,
      hotKey: Binding<HotKey?>(
        get: { hotKey.wrappedValue },
        set: { if let key = $0 { hotKey.wrappedValue = key } }
      ),
      conflicts: conflicts,
      conflictNote: conflictNote
    )
    isRequired = true
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
    let coordinator = context.coordinator
    let recorder = KeyboardShortcuts.RecorderCocoa(shortcut: hotKey?.shortcut) { shortcut in
      coordinator.recorded(shortcut)
    }
    recorder.validateShortcut = { coordinator.validate($0) }
    recorder.setAccessibilityLabel(title)
    recorder.setAccessibilityIdentifier(identifier)
    coordinator.recorder = recorder
    return recorder
  }

  func updateNSView(_ recorder: KeyboardShortcuts.RecorderCocoa, context: Context) {
    context.coordinator.parent = self
    recorder.setAccessibilityLabel(title)
    let shortcut = hotKey?.shortcut
    if recorder.shortcut != shortcut {
      recorder.shortcut = shortcut
    }
  }

  /// Takes what the recorder records into the binding.
  @MainActor
  final class Coordinator {
    var parent: ShortcutRecorder
    weak var recorder: KeyboardShortcuts.RecorderCocoa?

    init(_ parent: ShortcutRecorder) {
      self.parent = parent
    }

    func validate(_ shortcut: KeyboardShortcuts.Shortcut) -> KeyboardShortcuts.ValidationResult {
      guard let key = HotKey(shortcut) else {
        return .disallow(reason: "This keyboard shortcut can't be used.")
      }
      if parent.conflicts.contains(key) {
        return .disallow(reason: parent.conflictNote)
      }
      return .allow
    }

    func recorded(_ shortcut: KeyboardShortcuts.Shortcut?) {
      guard let shortcut, let key = HotKey(shortcut) else {
        if parent.isRequired {
          // The field says it was cleared before it has finished clearing
          // itself, so the combination goes back on the next turn.
          Task { [weak self] in
            self?.recorder?.shortcut = self?.parent.hotKey?.shortcut
          }
        } else {
          parent.hotKey = nil
        }
        return
      }
      parent.hotKey = key
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "\(parent.title) set to \(shortcut)",
          .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ]
      )
    }
  }
}
