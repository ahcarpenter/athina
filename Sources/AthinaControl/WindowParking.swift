import AppKit
import Foundation
import ObjectiveC

/// Keeps a hermetic run's windows off the screen.
///
/// Every window goes below the desktop picture, the level `--snapshot`
/// renders at, as it is ordered onto the screen, before the window server
/// draws it at all: moved any later, even at the end of the event loop pass
/// that opened it, it showed for a frame, and for the length of its opening
/// animation. There the window server still composites it, so it takes every
/// click the control API simulates and its checkpoints are the ones a visible
/// window gives, and nobody at the Mac sees it.
///
/// Ordering in is where every window passes: SwiftUI's, AppKit's About panel,
/// and the app's own panels alike, so each is caught by exchanging
/// `NSWindow`'s two ordering primitives for ones that park it first. After
/// every pass through the event loop, any window on screen that is still not
/// parked is parked too, should one ever reach the screen another way. This is
/// in the control API's target, so only a development build carries it.
@MainActor
public enum WindowParking {
  /// Below the desktop picture.
  public static let level = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1
  )

  private static var observer: (any NSObjectProtocol)?

  /// Parks every window from now on.
  ///
  /// Call it before the first window opens.
  public static func start() {
    guard observer == nil else { return }
    for (original, parking) in [
      (#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.parkedOrder(_:relativeTo:))),
      (#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.parkedOrderFrontRegardless)),
    ] {
      if let original = class_getInstanceMethod(NSWindow.self, original),
        let parking = class_getInstanceMethod(NSWindow.self, parking)
      {
        method_exchangeImplementations(original, parking)
      }
    }
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didUpdateNotification,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        for window in NSApp.windows where window.isVisible { park(window) }
      }
    }
  }

  static func park(_ window: NSWindow) {
    if window.level != level { window.level = level }
  }
}

extension NSWindow {
  /// `order(_:relativeTo:)` once `WindowParking` exchanged the two: this
  /// name then calls the original.
  @objc fileprivate func parkedOrder(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
    if place != .out { MainActor.assumeIsolated { WindowParking.park(self) } }
    parkedOrder(place, relativeTo: other)
  }

  /// `orderFrontRegardless()`, as `parkedOrder` is `order(_:relativeTo:)`.
  @objc fileprivate func parkedOrderFrontRegardless() {
    MainActor.assumeIsolated { WindowParking.park(self) }
    parkedOrderFrontRegardless()
  }
}
