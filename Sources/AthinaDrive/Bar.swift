import AppKit
import ApplicationServices
import Foundation
import AthinaE2E

/// Reads the menu bar: every app's status items with their frames, the
/// frontmost app's menu titles, the gaps between neighbours, and a point on
/// the bar that is on no item.
///
/// Status items are anchored at the right, so an item that changes width with
/// its state pushes its neighbours sideways; the gaps are how a check sees it.
enum Bar {
    static func report(pid: Int32?) {
        var extras: [BarItem] = []
        for app in NSWorkspace.shared.runningApplications {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            // A hung app must not hang the drive; the bar is read often.
            AXUIElementSetMessagingTimeout(element, 0.3)
            guard let menuBar = attr(element, "AXExtrasMenuBar") else { continue }
            for item in children(menuBar as! AXUIElement) {
                guard let rect = frame(of: item) else { continue }
                extras.append(BarItem(
                    app: app.localizedName ?? "?",
                    pid: app.processIdentifier,
                    title: title(item).isEmpty ? describe(item) : title(item),
                    frame: rect
                ))
            }
        }

        say("# menu bar extras, left to right")
        for item in BarGeometry.sorted(extras) {
            let target = BarGeometry.centre(of: item.frame)
            say("extra app=\"\(item.app)\" pid=\(item.pid) title=\"\(item.title)\" "
                + "x=\(item.frame.minX) y=\(item.frame.minY) w=\(item.frame.width) h=\(item.frame.height) "
                + "centre=\(Int(target.x)),\(Int(target.y))")
        }
        say("# gaps between neighbouring extras")
        for gap in BarGeometry.gaps(extras) {
            say("gap left=\"\(gap.left.app)\" right=\"\(gap.right.app)\" gap=\(gap.gap)")
        }

        let owner = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? NSWorkspace.shared.frontmostApplication
        var titles: [BarItem] = []
        if let owner {
            let element = AXUIElementCreateApplication(owner.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            if let menuBar = attr(element, kAXMenuBarAttribute) {
                for item in children(menuBar as! AXUIElement) {
                    guard let rect = frame(of: item), rect.width > 0 else { continue }
                    titles.append(BarItem(
                        app: owner.localizedName ?? "?",
                        pid: owner.processIdentifier,
                        title: title(item),
                        frame: rect
                    ))
                }
            }
            say("# menu titles of \(owner.localizedName ?? "?") (pid \(owner.processIdentifier))")
            for item in BarGeometry.sorted(titles) {
                say("title app=\"\(item.app)\" title=\"\(item.title)\" x=\(item.frame.minX) w=\(item.frame.width)")
            }
        }

        if let point = BarGeometry.emptyPoint(menuTitles: titles, extras: extras) {
            say("empty=\(Int(point.x)),\(Int(point.y))")
        } else {
            say("empty=none")
        }
        if let screen = NSScreen.main {
            say("screen w=\(screen.frame.width) h=\(screen.frame.height) "
                + "menuBarThickness=\(NSStatusBar.system.thickness) scale=\(screen.backingScaleFactor)")
        }
    }
}
