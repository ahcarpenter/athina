import AppKit
import MentorCore
import SwiftUI

/// Click, then press the new combination. Escape cancels.
struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press keys…" : hotKey.displayString)
                    .font(.body.weight(.medium))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            if isRecording {
                Text("Include ⌃, ⌥, or ⌘. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
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
