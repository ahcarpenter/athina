import AppKit
import AthinaCore
import SwiftUI

/// Click, then press the new combination. Escape cancels. An optional
/// binding shows a placeholder while unset and offers Clear; a combination
/// listed in `conflicts` is refused with a note instead of being taken.
struct HotKeyRecorder: View {
    /// What the hotkey is for, which VoiceOver reads as the button's label.
    let title: String
    @Binding var hotKey: HotKey?
    var placeholder = "Not Set"
    var allowsClear = true
    var conflicts: [HotKey] = []
    var conflictNote = "That combination is already in use."

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var refusal: String?

    init(
        title: String,
        hotKey: Binding<HotKey?>,
        placeholder: String = "Not Set",
        allowsClear: Bool = true,
        conflicts: [HotKey] = [],
        conflictNote: String = "That combination is already in use.",
        previewRecording: Bool = false,
        previewRefusal: String? = nil
    ) {
        self.title = title
        _isRecording = State(initialValue: previewRecording)
        _refusal = State(initialValue: previewRefusal)
        _hotKey = hotKey
        self.placeholder = placeholder
        self.allowsClear = allowsClear
        self.conflicts = conflicts
        self.conflictNote = conflictNote
    }

    /// A recorder for a hotkey that is always set.
    init(title: String, hotKey: Binding<HotKey>, conflicts: [HotKey] = [], conflictNote: String = "That combination is already in use.") {
        self.init(
            title: title,
            hotKey: Binding(get: { hotKey.wrappedValue }, set: { if let key = $0 { hotKey.wrappedValue = key } }),
            allowsClear: false, conflicts: conflicts, conflictNote: conflictNote
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                if allowsClear, hotKey != nil, !isRecording {
                    Button("Clear") { hotKey = nil }
                        .accessibilityLabel("Clear \(title.lowercased())")
                }
                Button {
                    isRecording ? stop() : start()
                } label: {
                    Text(isRecording ? "Type Shortcut" : (hotKey?.displayString ?? placeholder))
                        .foregroundStyle(hotKey == nil && !isRecording ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .frame(minWidth: 96)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)
                .accessibilityLabel(title)
                .accessibilityValue(isRecording ? "Recording" : (hotKey?.accessibilityName ?? placeholder))
                .accessibilityHint(isRecording ? "Type the new combination, or press Escape to cancel." : "Records a new combination.")
            }
            if isRecording {
                Text("Include Control, Option, or Command. Press Escape to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let refusal {
                StatusLabel(refusal, kind: .warning)
                    .font(.caption)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        refusal = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stop()
                return nil
            }
            var modifiers: HotKey.Modifiers = []
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            let candidate = HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            guard candidate.isUsable else {
                NSSound.beep()
                return nil
            }
            if conflicts.contains(candidate) {
                NSSound.beep()
                stop()
                refusal = conflictNote
                return nil
            }
            hotKey = candidate
            stop()
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: "\(title) set to \(candidate.accessibilityName)", .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
