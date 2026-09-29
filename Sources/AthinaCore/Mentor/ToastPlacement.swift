import CoreGraphics
import Foundation

/// Where the toast's panel goes on a screen, and how long a note stays.
///
/// The toast opens under the menu bar at the top right of the screen. A
/// person may drag it off what it covers; from then until the next suggestion
/// it keeps the top edge and the horizontal place they gave it, growing and
/// shrinking downward from there as its content changes, rather than jumping
/// back over what they moved it off. Pure, so the rules are proven on
/// rectangles in AppKit's screen space (origin at the bottom left).
public enum ToastPlacement {
  /// The shortest time a note stays up.
  public static let minimumNoteDuration: TimeInterval = 4
  /// Words a person reads in a second, the pace a note's time on screen is set by.
  public static let wordsPerSecond: Double = 3

  /// The panel's frame for content of `size` on a screen whose visible frame
  /// is `visible`.
  ///
  /// - Parameters:
  ///   - size: The panel's size.
  ///   - visible: The screen's frame less the menu bar and the Dock.
  ///   - margin: The space kept from the visible frame's top and right edges
  ///     where the toast opens.
  ///   - movedTopLeft: The top-left corner the person dragged the panel to,
  ///     or nil when it has not been moved since the suggestion came.
  /// - Returns: The frame, in the visible frame's coordinates.
  public static func frame(
    size: CGSize,
    visible: CGRect,
    margin: CGFloat,
    movedTopLeft: CGPoint?
  ) -> CGRect {
    guard let moved = movedTopLeft else {
      return CGRect(
        x: visible.maxX - size.width - margin,
        y: visible.maxY - size.height - margin,
        width: size.width,
        height: size.height
      )
    }
    // Kept whole on the screen: a toast grown past the bottom edge moves up
    // rather than hiding its buttons.
    let x = min(max(moved.x, visible.minX), visible.maxX - size.width)
    let top = min(max(moved.y, visible.minY + size.height), visible.maxY)
    return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
  }

  /// How long a note stays up: long enough to read it at `wordsPerSecond`,
  /// and never less than `minimumNoteDuration`.
  public static func noteDuration(for text: String) -> TimeInterval {
    let words = text.split(whereSeparator: \.isWhitespace).count
    return max(minimumNoteDuration, (Double(words) / wordsPerSecond).rounded(.up))
  }
}
