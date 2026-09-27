#if E2EAPI
  import AppKit
  import ApplicationServices
  import CoreGraphics
  import Foundation
  import Synchronization

  /// What says a hermetic run showed nothing (README "Hermetic runs").
  ///
  /// From the moment the app starts to the moment it stops, its windows above the desktop
  /// picture are counted five times a second, and its items in the menu bar as often as
  /// reading the bar allows, about once every two seconds. Both counts must stay at 0. Each look is logged, to
  /// `hermetic-windows.log` and `hermetic-bar.log`, with the windows seen, if any, and every
  /// app's items seen in the bar beside Athina's, since a reader macOS does not trust for
  /// Accessibility reads a bar with nothing in it.
  ///
  /// Each watcher runs on a thread of its own: a look blocks, for seconds when an app is slow to
  /// answer about its items, which the tasks the scenarios share must never wait on.
  final class HermeticWatch: Sendable {
    struct Tally: Sendable {
      var looks = 0
      var failed = 0
      /// Looks that found Athina there.
      var found = 0
      /// Looks that saw any app's item in the menu bar.
      var sawAnyItem = 0
    }

    private let pid: pid_t
    private let windowsLog: LogFile
    private let barLog: LogFile
    private let windows = Mutex(Tally())
    private let bar = Mutex(Tally())
    private let stopped = Atomic<Bool>(false)

    init(pid: pid_t, evidence: URL) {
      self.pid = pid
      windowsLog = LogFile(evidence.appendingPathComponent("hermetic-windows.log"))
      barLog = LogFile(evidence.appendingPathComponent("hermetic-bar.log"))
    }

    func start() {
      Thread.detachNewThread { [self] in
        while !stopped.load(ordering: .relaxed), kill(pid, 0) == 0 {
          lookAtWindows()
          Thread.sleep(forTimeInterval: 0.2)
        }
      }
      Thread.detachNewThread { [self] in
        while !stopped.load(ordering: .relaxed), kill(pid, 0) == 0 {
          lookAtBar()
          Thread.sleep(forTimeInterval: 0.2)
        }
      }
    }

    func stop() {
      stopped.store(true, ordering: .relaxed)
      windowsLog.close()
      barLog.close()
    }

    var windowTally: Tally { windows.withLock { $0 } }
    var barTally: Tally { bar.withLock { $0 } }

    /// The app's windows on screen above the desktop picture, where a parked window is not.
    private func lookAtWindows() {
      let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
      guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
      else {
        windows.withLock {
          $0.looks += 1
          $0.failed += 1
        }
        windowsLog.append("\(LogFile.stamp()) failed")
        return
      }
      let seen = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }.map {
        "\"\($0[kCGWindowName as String] as? String ?? "")\""
      }
      windows.withLock {
        $0.looks += 1
        if !seen.isEmpty { $0.found += 1 }
      }
      windowsLog.append("\(LogFile.stamp()) \(seen.count) \(seen.joined(separator: " "))")
    }

    /// The app's items in the menu bar, and every other app's, read through accessibility.
    private func lookAtBar() {
      let ours = extras(of: pid)
      var others = 0
      for app in NSWorkspace.shared.runningApplications where app.processIdentifier != pid {
        others += extras(of: app.processIdentifier)
      }
      bar.withLock {
        $0.looks += 1
        if ours > 0 { $0.found += 1 }
        if ours + others > 0 { $0.sawAnyItem += 1 }
      }
      barLog.append("\(LogFile.stamp()) \(ours) \(ours + others)")
    }

    private func extras(of pid: pid_t) -> Int {
      let app = AXUIElementCreateApplication(pid)
      // A hung app must not hold the watcher; the bar is read often.
      AXUIElementSetMessagingTimeout(app, 0.3)
      var bar: CFTypeRef?
      guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
        let bar, CFGetTypeID(bar) == AXUIElementGetTypeID()
      else { return 0 }
      var count: CFIndex = 0
      AXUIElementGetAttributeValueCount(
        bar as! AXUIElement,
        kAXChildrenAttribute as CFString,
        &count
      )
      return count
    }
  }
#endif
