import AppKit
import QuartzCore

/// The display's frames as one window sees them, for a picture of it taken from the window server.
///
/// The window server composites a window on the display's refresh, so a
/// capture waits for a frame rather than for a guessed length of time.
@MainActor
final class DisplayFrames: NSObject {
  private var link: CADisplayLink?
  private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
  private var nextToken = 0

  init(_ window: NSWindow) {
    super.init()
    let link = window.displayLink(target: self, selector: #selector(frame(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
    let pending = waiting.values
    waiting = [:]
    for continuation in pending { continuation.resume() }
  }

  /// Returns at the display's next frame, or after 50 ms when none comes,
  /// as for a window on no display, so no wait here can hang.
  func next() async {
    nextToken += 1
    let token = nextToken
    await withCheckedContinuation { continuation in
      waiting[token] = continuation
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(50))
        self?.waiting.removeValue(forKey: token)?.resume()
      }
    }
  }

  @objc private func frame(_ link: CADisplayLink) {
    let pending = waiting.values
    waiting = [:]
    for continuation in pending { continuation.resume() }
  }

  /// Waits until the window has had three frames in a row in which nothing changed.
  ///
  /// Nothing changed means no view waiting for layout or to be drawn, and no
  /// Core Animation animation running in it. Whatever a view does on its own
  /// once it appears, such as a task that loads what it shows or an image
  /// fading in, keeps a frame from counting, so the wait lasts as long as
  /// that and no longer. It gives up after 90 frames, about a second and a
  /// half, since something that repeats, such as a spinner, never stops.
  func settle(_ window: NSWindow) async {
    var quiet = 0
    for _ in 0..<90 {
      await next()
      let root = window.contentView?.superview ?? window.contentView
      let busy =
        window.viewsNeedDisplay || root.map(Self.needsLayout) == true
        || root?.layer.map(Self.isAnimating) == true
      root?.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      quiet = busy ? 0 : quiet + 1
      if quiet == 3 { return }
    }
  }

  private static func needsLayout(_ view: NSView) -> Bool {
    view.needsLayout || view.subviews.contains(where: needsLayout)
  }

  private static func isAnimating(_ layer: CALayer) -> Bool {
    layer.animationKeys()?.isEmpty == false || (layer.sublayers ?? []).contains(where: isAnimating)
  }
}
