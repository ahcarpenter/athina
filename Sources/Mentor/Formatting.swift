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
        ClockFormat.time(date)
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

    /// The text with its spaces made non-breaking, so a wrapping label never
    /// splits a number from its unit or a short phrase in two.
    static func unbroken(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// A path with the home directory shown as a tilde.
    static func path(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func rect(_ rect: CGRect) -> String {
        String(format: "%.0f, %.0f  %.0f × %.0f", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    static func dayAndTime(_ date: Date) -> String {
        ClockFormat.dayAndTime(date)
    }

    /// Dollars with enough precision for cents on small figures: $0.0042, $0.13, $1.00.
    static func dollars(_ amount: Double) -> String {
        if amount == 0 { return "$0.00" }
        if amount < 0.01 { return String(format: "$%.4f", amount) }
        if amount < 1 { return String(format: "$%.3f", amount) }
        return String(format: "$%.2f", amount)
    }

    static func multiplier(_ value: Double) -> String {
        value < 10 ? String(format: "%.1fx", value) : String(format: "%.0fx", value)
    }

    static func tokens(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    static func seconds(_ interval: TimeInterval) -> String {
        interval < 10 ? String(format: "%.2fs", interval) : String(format: "%.1fs", interval)
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
