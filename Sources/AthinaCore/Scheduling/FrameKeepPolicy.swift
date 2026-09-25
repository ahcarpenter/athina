import Foundation

/// Decides whether a freshly captured frame is worth keeping.
public enum FrameKeepPolicy {
  /// Whether to keep a frame, and why.
  public struct Verdict: Equatable, Sendable {
    /// Whether the frame is kept; a dropped frame is never recognized or
    /// journaled.
    public var keep: Bool
    /// The Hamming distance to the previous kept frame, or nil for the first
    /// frame.
    public var distance: Int?
    /// A short human-readable reason, such as "window changed" or
    /// "near-duplicate (distance 3 <= 5)".
    public var reason: String
  }

  /// Decides whether a frame differs enough from the previous kept frame to keep.
  ///
  /// - Parameters:
  ///   - distance: Hamming distance to the previous kept frame, nil when there is none.
  ///   - threshold: Frames at or under this distance are duplicates.
  ///   - windowChanged: Whether the window signature differs from the previous kept frame.
  ///   - textChanged: Whether the focused element's text differs from the previous kept frame.
  /// - Returns: Whether to keep the frame, with its distance and the reason.
  public static func decide(
    distance: Int?,
    threshold: Int,
    windowChanged: Bool,
    textChanged: Bool
  ) -> Verdict {
    guard let distance else {
      return Verdict(keep: true, distance: nil, reason: "first frame")
    }
    if distance > threshold {
      return Verdict(
        keep: true,
        distance: distance,
        reason: "frame changed (distance \(distance) > \(threshold))"
      )
    }
    if windowChanged {
      return Verdict(keep: true, distance: distance, reason: "window changed")
    }
    if textChanged {
      return Verdict(keep: true, distance: distance, reason: "focused text changed")
    }
    return Verdict(
      keep: false,
      distance: distance,
      reason: "near-duplicate (distance \(distance) <= \(threshold))"
    )
  }
}
