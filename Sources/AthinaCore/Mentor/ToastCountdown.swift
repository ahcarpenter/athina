import Foundation

/// A toast's countdown to expiring on its own: running toward a deadline,
/// held with what it had left, or off.
///
/// It runs for `toastTimeout` when a suggestion is shown, is held while the
/// pointer is over the toast or the user talks back to it, runs again with
/// what it had left, and is off for a toast that stays until it is closed.
/// Pure, so the rules are proven on dates; the app only waits on its clock
/// for the deadline this names.
public struct ToastCountdown: Equatable, Sendable {
  /// A held countdown never keeps less than this, so a toast does not
  /// vanish the moment the pointer leaves it.
  public static let minimumRemaining: TimeInterval = 2

  /// When the toast expires, while the countdown runs.
  public private(set) var deadline: Date?
  /// What the countdown had left when it was held, while it is held.
  public private(set) var held: TimeInterval?

  public init() {}

  /// Runs the countdown for `duration` from `now`, whatever it was doing.
  public mutating func run(for duration: TimeInterval, from now: Date) {
    deadline = now.addingTimeInterval(duration)
    held = nil
  }

  /// Holds a running countdown with what it had left, never less than
  /// `minimumRemaining`. A held or off countdown stays as it is.
  public mutating func hold(at now: Date) {
    guard let deadline else { return }
    held = max(ToastCountdown.minimumRemaining, deadline.timeIntervalSince(now))
    self.deadline = nil
  }

  /// Turns the countdown off: the toast stays until it is closed.
  public mutating func cancel() {
    deadline = nil
    held = nil
  }
}
