import AppKit
import MentorCore
import SwiftUI

/// Click, then press the new combination. Escape cancels. An optional
/// binding shows a placeholder while unset and offers Clear; a combination
/// listed in `conflicts` is refused with a note instead of being taken.
struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey?
    var placeholder = "Not set"
    var allowsClear = true
    var conflicts: [HotKey] = []
    var conflictNote = "That combination is already in use."

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var refusal: String?

    init(
        hotKey: Binding<HotKey?>,
        placeholder: String = "Not set",
        allowsClear: Bool = true,
        conflicts: [HotKey] = [],
        conflictNote: String = "That combination is already in use."
    ) {
        _hotKey = hotKey
        self.placeholder = placeholder
        self.allowsClear = allowsClear
        self.conflicts = conflicts
        self.conflictNote = conflictNote
    }

    /// A recorder for a hotkey that is always set.
    init(hotKey: Binding<HotKey>, conflicts: [HotKey] = [], conflictNote: String = "That combination is already in use.") {
        self.init(
            hotKey: Binding(get: { hotKey.wrappedValue }, set: { if let key = $0 { hotKey.wrappedValue = key } }),
            allowsClear: false, conflicts: conflicts, conflictNote: conflictNote
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press keys…" : (hotKey?.displayString ?? placeholder))
                    .font(.body.weight(.medium))
                    .foregroundStyle(hotKey == nil && !isRecording ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            if allowsClear, hotKey != nil, !isRecording {
                Button("Clear") { hotKey = nil }
                    .controlSize(.small)
            }
            if isRecording {
                Text("Include ⌃, ⌥, or ⌘. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.orange)
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
