import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Long-running watchers a scenario starts in the background and reads
// afterwards: what the app announces, where clicks really went, and a window
// that keeps changing so sensing has something to see.

enum Watchers {
  /// Every VoiceOver announcement the app posts, with a timestamp.
  ///
  /// This is how a check proves a suggestion was announced without VoiceOver
  /// running.
  static func announcements(pid: Int32) -> Never {
    let app = AXUIElementCreateApplication(pid)
    var observer: AXObserver?
    let callback: AXObserverCallbackWithInfo = { _, _, notification, info, _ in
      let dictionary = info as NSDictionary? as? [String: Any] ?? [:]
      let announcement = dictionary["AXAnnouncementKey"] as? String ?? "\(dictionary)"
      let priority = dictionary["AXPriorityKey"] ?? "-"
      print("\(stamp()) \(notification as String) priority=\(priority) \"\(announcement)\"")
      fflush(stdout)
    }
    guard AXObserverCreateWithInfoCallback(pid, callback, &observer) == .success, let observer
    else {
      fail("announce: could not observe pid \(pid)")
    }
    let added = AXObserverAddNotification(observer, app, "AXAnnouncementRequested" as CFString, nil)
    say("\(stamp()) observing pid \(pid) announcements (add -> \(added.rawValue))")
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    CFRunLoopRun()
    exit(0)
  }

  /// A listen-only tap. `session` sees every mouse-down in the session, which
  /// is what attributes a dismissal to a real click rather than a timeout;
  /// `pid` sees the copies delivered to one app.
  static func tap(pid: Int32?) -> Never {
    let mask: CGEventMask =
      (1 << CGEventType.leftMouseDown.rawValue)
      | (1 << CGEventType.leftMouseUp.rawValue)
      | (1 << CGEventType.rightMouseDown.rawValue)
      | (1 << CGEventType.otherMouseDown.rawValue)

    let callback: CGEventTapCallBack = { _, type, event, _ in
      let under = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
      let sourcePid = event.getIntegerValueField(.eventSourceUnixProcessID)
      print(
        """
        \(stamp()) type=\(type.rawValue) at=\(event.location) sourcePid=\(sourcePid) \
        under=\(under) [\(windowOwner(of: under))]
        """
      )
      fflush(stdout)
      return Unmanaged.passUnretained(event)
    }

    let tap: CFMachPort?
    if let pid {
      tap = CGEvent.tapCreateForPid(
        pid: pid,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: nil
      )
    } else {
      tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: nil
      )
    }
    guard let tap else { fail("tap: could not create the event tap (needs Accessibility)") }
    CFRunLoopAddSource(
      CFRunLoopGetCurrent(),
      CFMachPortCreateRunLoopSource(nil, tap, 0),
      .commonModes
    )
    CGEvent.tapEnable(tap: tap, enable: true)
    say(
      "\(stamp()) tapping \(pid.map { "events delivered to pid \($0)" } ?? "session mouse-downs")"
    )
    CFRunLoopRun()
    exit(0)
  }

}

/// The app a window id belongs to, so a logged click names what it landed on.
///
/// File scope, not a member: the tap callback is a C function pointer and can
/// capture nothing at all.
private func windowOwner(of windowID: Int64) -> String {
  guard windowID > 0,
    let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID))
      as? [[String: Any]],
    let window = info.first
  else { return "not in the window list" }
  return "owner=\(window[kCGWindowOwnerName as String] ?? "?") "
    + "pid=\(window[kCGWindowOwnerPID as String] ?? -1) "
    + "layer=\(window[kCGWindowLayer as String] ?? 0)"
}

/// A click-through window that changes its text and colour on SIGUSR1.
///
/// Sensing drops a frame whose perceptual hash matches the last one, so a
/// static screen journals nothing. This is the cheapest way to give a scenario
/// a screen that keeps changing in both pixels and OCR text, and it never
/// takes focus, so it cannot disturb whoever is at the Mac.
@MainActor
enum FlipWindow {
  private static let sentences = [
    "Quarterly budget review\nMarketing spend up 12 percent\nHeadcount plan for October",
    "Recipe for lentil soup\nTwo cups red lentils\nSimmer for twenty minutes",
    "Train timetable\nDeparts 08:15 platform 4\nArrives 10:42 platform 9",
    "Garden notes\nPrune the roses in March\nMulch the beds before frost",
    "Chess opening study\nSicilian Najdorf main line\nCastle before move ten",
    "Piano practice log\nScales at 90 bpm\nNocturne bars 1 to 16",
  ]
  private static let colors: [NSColor] = [
    .white, .black, .systemYellow, .systemBlue, .systemGreen, .systemPink,
  ]
  private static var shown = 0

  static func run(frame rect: CGRect) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let window = NSWindow(
      contentRect: rect,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.level = .floating
    window.ignoresMouseEvents = true
    window.isOpaque = true
    window.hasShadow = false

    let label = NSTextField(labelWithString: "")
    label.font = NSFont.systemFont(ofSize: 34, weight: .bold)
    label.alignment = .center
    label.maximumNumberOfLines = 0
    label.frame = CGRect(x: 20, y: 20, width: rect.width - 40, height: rect.height - 40)
    window.contentView?.addSubview(label)

    func flip() {
      let index = shown % sentences.count
      label.stringValue = sentences[index]
      label.textColor = index == 0 || index == 2 ? .black : .white
      window.backgroundColor = colors[index]
      window.orderFrontRegardless()
      say("\(stamp()) flip \(shown): \(sentences[index].split(separator: "\n")[0])")
      shown += 1
    }

    signal(SIGUSR1, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    source.setEventHandler { flip() }
    source.resume()
    flip()
    app.run()
    exit(0)
  }
}
