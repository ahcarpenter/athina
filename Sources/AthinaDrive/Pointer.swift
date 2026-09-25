import AppKit
import ApplicationServices
import Foundation
import AthinaE2E

// Real pointer input. Every click here is a HID event, the same kind a hand
// makes, because what Athina does with a click depends on which NSEvent
// monitor sees it, and a synthetic AXPress never reaches one.
//
// The Mac is shared, so a click is posted only when the pointer is still where
// the drive put it and the thing under it is the thing that was aimed at.

enum Pointer {
    /// A fresh source per event: `CGEventSource` is not Sendable, and making
    /// one costs nothing next to the waits around a click.
    static var source: CGEventSource? { CGEventSource(stateID: .hidSystemState) }

    static func location() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func move(to point: CGPoint) {
        CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    static func glide(to point: CGPoint, steps: Int = 12, stepMicroseconds: UInt32 = 30_000) {
        let start = location()
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            move(to: CGPoint(
                x: start.x + (point.x - start.x) * fraction,
                y: start.y + (point.y - start.y) * fraction
            ))
            usleep(stepMicroseconds)
        }
    }

    static func isAt(_ point: CGPoint, tolerance: Double = 1.5) -> Bool {
        let now = location()
        return abs(now.x - point.x) < tolerance && abs(now.y - point.y) < tolerance
    }

    static func click(at point: CGPoint) {
        CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        )?.post(tap: .cghidEventTap)
        usleep(80_000)
        CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    static func key(_ code: CGKeyCode, command: Bool = false, shift: Bool = false) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        var flags = CGEventFlags()
        if command { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(40_000)
        up?.post(tap: .cghidEventTap)
    }
}

/// Exit codes a scenario reads: 3 means the drive refused to click because the
/// target was not what was asked for, 4 means someone else moved the pointer.
enum ClickExit: Int32 {
    case wrongTarget = 3
    case pointerMoved = 4
}

enum ClickTarget {
    /// The centre of a pid's menu bar extra.
    case statusItem(pid: Int32)
    /// A screen point that must be on no menu bar item at all.
    case emptyBar(point: CGPoint)
    /// A screen point whose topmost window, or the accessibility element a
    /// click there reaches, must belong to a pid.
    case window(pid: Int32, point: CGPoint)
}

enum Clicker {
    static func perform(_ target: ClickTarget, shot: String?) {
        let point: CGPoint
        let region: String
        switch target {
        case let .statusItem(pid):
            guard let item = statusItem(of: pid), let itemFrame = frame(of: item) else {
                fail("click item: pid \(pid) has no menu bar extra", code: ClickExit.wrongTarget.rawValue)
            }
            point = BarGeometry.centre(of: itemFrame)
            say("item \"\(title(item))\" frame \(itemFrame)")
            region = "\(Int(itemFrame.minX) - 150),0,\(Int(itemFrame.width) + 300),34"
        case let .emptyBar(target):
            point = target
            region = "\(Int(target.x) - 200),0,500,34"
        case let .window(_, target):
            point = target
            region = "\(Int(target.x) - 200),\(Int(target.y) - 100),400,200"
        }

        Pointer.glide(to: point)
        for _ in 0..<4 {
            Pointer.move(to: point)
            usleep(80_000)
        }
        guard Pointer.isAt(point) else {
            fail("ABORT: pointer is at \(Pointer.location()), not \(point)", code: ClickExit.pointerMoved.rawValue)
        }

        // What is under the point, from both the accessibility tree and the
        // window list: a transcript has to show what was really clicked.
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        var hitRole = ""
        var hitPid: pid_t = 0
        if let hit {
            AXUIElementGetPid(hit, &hitPid)
            hitRole = role(hit)
            let app = NSRunningApplication(processIdentifier: hitPid)?.localizedName ?? "?"
            say("AX under point: role=\(hitRole) title=\"\(title(hit))\" pid=\(hitPid) app=\(app)")
        } else {
            say("AX under point: nothing")
        }
        let top = topmostWindow(at: point)
        say("topmost window at \(point): \(top?.description ?? "none")")

        switch target {
        case .emptyBar:
            guard !["AXMenuBarItem", "AXMenuItem", "AXButton"].contains(hitRole) else {
                fail("NOT CLICKING: \(point) is on a \(hitRole), not empty menu bar space", code: ClickExit.wrongTarget.rawValue)
            }
        case let .window(pid, _):
            // The window list cannot tell a window that lets clicks through
            // from one that takes them, and a utility such as Magnet keeps a
            // full-screen one above every app. The accessibility hit test
            // skips such a window the way a click does, and names another
            // app's window that would take the click, so either one naming
            // the pid is enough.
            guard top?.pid == pid || hitPid == pid else {
                fail("NOT CLICKING: topmost window at \(point) is not pid \(pid)", code: ClickExit.wrongTarget.rawValue)
            }
        case .statusItem:
            break
        }

        if let shot { screencapture(["-x", "-o", "-R", region, shot]) }
        guard Pointer.isAt(point) else {
            fail("ABORT: pointer moved to \(Pointer.location()) before the click", code: ClickExit.pointerMoved.rawValue)
        }
        say("mouse-down at \(stamp()) at \(point)")
        Pointer.click(at: point)
        usleep(600_000)
        say("pointer now \(Pointer.location())")
    }

    /// Hover a row of the open status menu, wait for its submenu, and click one
    /// of its items with the pointer, so the click takes the same path a
    /// person's does rather than an AXPress.
    static func menuPick(pid: Int32, row rowTitle: String, item itemTitle: String) {
        func menuItemFrame(_ wanted: String) -> CGRect? {
            let app = AXUIElementCreateApplication(pid)
            guard let extras = attr(app, "AXExtrasMenuBar") else { return nil }
            var items: [AXUIElement] = []
            findAll(extras as! AXUIElement, { role($0) == "AXMenuItem" }, into: &items)
            guard let element = items.first(where: { title($0) == wanted }), let rect = frame(of: element),
                  rect.width > 0 else { return nil }
            return rect
        }

        guard let row = menuItemFrame(rowTitle) else {
            fail("menupick: row \"\(rowTitle)\" is not on screen", code: ClickExit.wrongTarget.rawValue)
        }
        say("row \"\(rowTitle)\" frame \(row)")

        // Accessibility can report the submenu's frame before macOS draws it
        // there, or after it has closed again, so the click waits until the
        // hit test at the target names the item. When it never does, the
        // pointer goes back into the row to open the submenu afresh.
        let attempts = 3
        var target = CGPoint.zero
        var miss = ""
        for attempt in 1...attempts {
            Pointer.glide(to: CGPoint(x: row.midX, y: row.midY), steps: 10, stepMicroseconds: 25_000)

            // A submenu opens after a hover delay macOS decides, not after a
            // fixed wait, so poll for it while keeping the pointer moving
            // inside the row: a still pointer can leave the hover unrenewed.
            var opened: CGRect?
            for poll in 0..<20 {
                usleep(200_000)
                Pointer.move(to: CGPoint(x: row.midX + (poll.isMultiple(of: 2) ? 1 : -1), y: row.midY))
                if let frame = menuItemFrame(itemTitle) {
                    opened = frame
                    say("submenu opened after \(Double(poll + 1) * 0.2)s")
                    break
                }
            }
            guard let item = opened else {
                fail("menupick: item \"\(itemTitle)\" did not open under \"\(rowTitle)\" within 4s", code: ClickExit.wrongTarget.rawValue)
            }
            say("item \"\(itemTitle)\" frame \(item)")
            // Cross into the submenu along the row before dropping onto the
            // item, or the submenu closes as the pointer leaves the parent.
            Pointer.glide(to: CGPoint(x: item.minX + 12, y: row.midY), steps: 8, stepMicroseconds: 25_000)
            target = CGPoint(x: (item.minX + 40).rounded(), y: item.midY.rounded())
            Pointer.glide(to: target, steps: 8, stepMicroseconds: 25_000)

            // What is under the point decides, and for a menu that is the
            // accessibility tree, not the window list: macOS draws menus and
            // the menu bar into Window Server's own surfaces, so the topmost
            // window there is often not the app's at all. It is still worth
            // logging.
            for _ in 0..<5 {
                usleep(200_000)
                guard Pointer.isAt(target) else {
                    fail("ABORT: pointer is at \(Pointer.location()), not \(target)", code: ClickExit.pointerMoved.rawValue)
                }
                var hit: AXUIElement?
                AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(target.x), Float(target.y), &hit)
                guard let hit else {
                    miss = "nothing"
                    continue
                }
                var hitPid: pid_t = 0
                AXUIElementGetPid(hit, &hitPid)
                if hitPid == pid, role(hit) == "AXMenuItem", title(hit) == itemTitle {
                    say("AX under point: role=\(role(hit)) title=\"\(title(hit))\" pid=\(hitPid)")
                    miss = ""
                    break
                }
                miss = "\(role(hit)) \"\(title(hit))\" of pid \(hitPid)"
            }
            if miss.isEmpty { break }
            say("topmost window at \(target): \(topmostWindow(at: target)?.description ?? "none")")
            say("attempt \(attempt) of \(attempts): \(target) is \(miss), not \(pid)'s \"\(itemTitle)\"")
        }
        guard miss.isEmpty else {
            fail(
                "NOT CLICKING: \(target) is \(miss), not \(pid)'s \"\(itemTitle)\", after \(attempts) attempts",
                code: ClickExit.wrongTarget.rawValue
            )
        }
        say("clicking \"\(itemTitle)\" at \(target) at \(stamp())")
        Pointer.click(at: target)
    }
}
