import Foundation

/// Decides whether a freshly captured frame is worth keeping.
public enum FrameKeepPolicy {
  public struct Verdict: Equatable, Sendable {
    public var keep: Bool
    public var distance: Int?
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
