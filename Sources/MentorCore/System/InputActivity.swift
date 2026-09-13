import CoreGraphics
import Foundation

/// Seconds since the last keyboard, mouse, or trackpad event in this login
/// session. Needs no permission: it reads a system-wide counter, never events.
public enum InputActivity {
    private static let anyEventType = CGEventType(rawValue: ~0)!

    public static func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEventType)
    }
}
