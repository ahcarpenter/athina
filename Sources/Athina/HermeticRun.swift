import AppKit
import AthinaCore

/// Brings Athina forward for a window the person asked for.
///
/// Every such request goes through here, never `NSApp.activate()` directly,
/// so a hermetic run (`ControlMode.isHermetic`, README "Hermetic runs") never
/// takes the front from whoever is using the Mac.
@MainActor
enum AppActivation {
  static func request() {
    guard !AppState.shared.controlMode.isHermetic else { return }
    NSApp.activate()
  }
}

/// Keeps a hermetic run's windows off the screen.
///
/// Each one moves below the desktop picture as it first appears, the level
/// `--snapshot` renders at. There the window server still composites it, so
/// it takes every click the control API simulates and its checkpoints are the
/// ones a visible window gives, and nobody at the Mac sees it.
///
/// A window is parked once it is on screen, at the end of the pass through the
/// event loop that put it there, never while it is being made: a Settings
/// window moved while SwiftUI was still making it was never reachable. Every
/// window is looked at after every pass, so one any code opens, SwiftUI's,
/// AppKit's About panel, or the toast, is parked the same way.
@MainActor
enum WindowParking {
  /// Below the desktop picture.
  static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)

  private static var observer: (any NSObjectProtocol)?

  static func start() {
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didUpdateNotification,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated { NSApp.windows.forEach(park) }
    }
  }

  private static func park(_ window: NSWindow) {
    guard window.isVisible, window.level != level else { return }
    window.level = level
  }
}
