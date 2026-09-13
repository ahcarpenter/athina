import Foundation
import MentorCore
import SwiftUI

enum Formatting {
    static func bytes(_ count: UInt64) -> String {
        bytes(Int64(count))
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: count)
    }

    static func clockTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    static func age(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "\(Int(max(0, seconds)))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m ago"
    }

    static func countdown(to date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        return seconds <= 0 ? "now" : "in \(Int(seconds.rounded(.up)))s"
    }

    static func duration(_ interval: TimeInterval) -> String {
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }

    static func rect(_ rect: CGRect) -> String {
        String(format: "%.0f, %.0f  %.0f × %.0f", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    /// A SwiftUI shortcut mirroring the global hotkey, so the menu shows it.
    static func keyboardShortcut(for hotKey: HotKey) -> KeyboardShortcut? {
        let name = HotKey.keyName(for: hotKey.keyCode)
        guard name.count == 1, let character = name.lowercased().first else { return nil }
        var modifiers: EventModifiers = []
        if hotKey.modifiers.contains(.command) { modifiers.insert(.command) }
        if hotKey.modifiers.contains(.option) { modifiers.insert(.option) }
        if hotKey.modifiers.contains(.control) { modifiers.insert(.control) }
        if hotKey.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}

extension View {
    /// Applies a shortcut when one is available.
    @ViewBuilder
    func optionalKeyboardShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        if let shortcut {
            self.keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
