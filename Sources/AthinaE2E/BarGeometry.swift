import CoreGraphics
import Foundation

/// One menu bar element read through accessibility: a status item ("extra") on
/// the right of the bar, or a menu title ("File", "Edit") on the left.
public struct BarItem: Equatable, Sendable {
  /// The localized name of the app that owns the item.
  public let app: String
  /// The process id of the app that owns the item.
  public let pid: Int32
  /// The item's accessibility title, or for a status item without one its
  /// description.
  public let title: String
  /// The item's frame in global screen points, origin at the top left of the
  /// main display, as accessibility reports it.
  public let frame: CGRect

  /// Creates an item owned by `app` (process `pid`) with `title` at `frame`.
  public init(app: String, pid: Int32, title: String, frame: CGRect) {
    self.app = app
    self.pid = pid
    self.title = title
    self.frame = frame
  }
}

/// The menu bar maths a scenario needs: where to click an item, how far its
/// neighbours sit from it, and where the bar is empty.
///
/// Status items are anchored at the right of the bar, so an item that changes
/// width moves every item to its left. `gaps` is what a check of that reads.
public enum BarGeometry {
  /// Left to right, which is the order a person sees.
  public static func sorted(_ items: [BarItem]) -> [BarItem] {
    items.sorted { ($0.frame.minX, $0.app) < ($1.frame.minX, $1.app) }
  }

  /// The click target of an item: its centre, on whole pixels, because a
  /// posted HID event lands on a point and half-pixels round unpredictably.
  public static func centre(of frame: CGRect) -> CGPoint {
    CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded())
  }

  /// The horizontal gap between each pair of neighbouring items, left to right.
  ///
  /// A negative gap means they overlap.
  public static func gaps(_ items: [BarItem]) -> [(left: BarItem, right: BarItem, gap: Double)] {
    let ordered = sorted(items)
    guard ordered.count > 1 else { return [] }
    return (1..<ordered.count).map { i in
      (ordered[i - 1], ordered[i], ordered[i].frame.minX - ordered[i - 1].frame.maxX)
    }
  }

  /// The leftmost item whose frame contains `point`, or nil when the point
  /// is on no item.
  public static func item(at point: CGPoint, in items: [BarItem]) -> BarItem? {
    sorted(items).first { $0.frame.contains(point) }
  }

  /// A point on the menu bar that is on no item at all: the middle of the span
  /// between the frontmost app's last menu title and the leftmost status item.
  ///
  /// A click there reaches the same global monitor an item click does, which is
  /// what makes it the control case for a dismissal.
  ///
  /// Returns nil when the span is narrower than `minWidth`, rather than
  /// guessing: a scenario that cannot find empty bar space must say so.
  public static func emptyPoint(
    menuTitles: [BarItem],
    extras: [BarItem],
    minWidth: Double = 24
  ) -> CGPoint? {
    guard let lastTitle = sorted(menuTitles).last, let firstExtra = sorted(extras).first else {
      return nil
    }
    let span = firstExtra.frame.minX - lastTitle.frame.maxX
    guard span >= minWidth else { return nil }
    let y = firstExtra.frame.midY.rounded()
    return CGPoint(x: (lastTitle.frame.maxX + span / 2).rounded(), y: y)
  }
}
