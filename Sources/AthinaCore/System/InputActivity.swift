import CoreGraphics
import Foundation

/// Seconds since the last keyboard, mouse, or trackpad event in this login
/// session.
///
/// Needs no permission: it reads a system-wide counter, never events.
public enum InputActivity {
  // `kCGAnyInputEventType`, which Swift does not import. `CGEventType` has an
  // initializer for every raw value, so this never fails.
  private static let anyEventType = CGEventType(rawValue: ~0)!

  /// Returns the real seconds since the last input event of any kind.
  public static func secondsSinceLastInput() -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEventType)
  }
}
