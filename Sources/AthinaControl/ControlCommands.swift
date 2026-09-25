import AppKit
import AthinaControlProtocol

/// The control API's commands, run on the main actor one at a time.
///
/// A click goes through AppKit's own event path: a mouse-down and a mouse-up
/// posted to the app's event queue for the control's window, dispatched by the
/// run loop the way a real click is after the window server: local event
/// monitors, the window's own hit test, the control's mouse-down and its
/// tracking loop. So a click that lands proves the control is hit-testable in
/// its window and wired to its action, and a disabled control does nothing
/// even when a click is forced onto it.
///
/// The waits here poll the app's own state at a fixed real-time pace, as UI
/// polling does, never the replay's clock (README "A faster clock").
@MainActor
final class ControlCommands {
    private let host: ControlHost

    init(host: ControlHost) {
        self.host = host
    }

    static let commands = [
        "ping", "windows", "find", "click", "type", "scroll", "menu", "settings", "wait-setting", "wait-window", "snapshot",
    ]

    func handle(_ request: ControlRequest) async -> ControlReply {
        switch request.command {
        case "ping": ping()
        case "windows": windows()
        case "find": find(request)
        case "click": await click(request)
        case "type": type(request)
        case "scroll": scroll(request)
        case "menu": await menu(request)
        case "settings": settings(request)
        case "wait-setting": await waitSetting(request)
        case "wait-window": await waitWindow(request)
        case "snapshot": await snapshot(request)
        default: .error("no command \"\(request.command)\"; the commands are \(Self.commands.joined(separator: ", "))")
        }
    }

    // MARK: - The app and its windows

    private func ping() -> ControlReply {
        .ok([
            "protocol": .string(ControlProtocol.name),
            "pid": .number(Double(getpid())),
            "active": .bool(NSApp.isActive),
        ])
    }

    private func windows() -> ControlReply {
        .ok(["windows": .array(AppAccessibility.windows(titled: nil).map { window in
            let frame = AppAccessibility.globalFrame(of: window.frame)
            return .object([
                "title": .string(window.title), "number": .number(Double(window.windowNumber)),
                "key": .bool(window.isKeyWindow), "main": .bool(window.isMainWindow),
                "level": .number(Double(window.level.rawValue)),
                "frame": .array([frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) }),
            ])
        })])
    }

    private func waitWindow(_ request: ControlRequest) async -> ControlReply {
        guard let title = request.string("window") else { return .error("wait-window needs window=<title>") }
        let present = request.bool("present") ?? true
        let reached = await poll(request) { !AppAccessibility.windows(titled: title).isEmpty == present }
        return reached ? .ok() : .error("no window titled \"\(title)\" \(present ? "appeared" : "went away") in time")
    }

    // MARK: - Controls

    private func find(_ request: ControlRequest) -> ControlReply {
        let nodes = AppAccessibility.nodes(AppAccessibility.Query(request))
        return .ok(["elements": .array(nodes.map { $0.summary })])
    }

    private enum Lookup {
        case found(AppAccessibility.Node)
        case answer(ControlReply)
    }

    /// The control a request names, or the answer saying why there is none.
    private func control(_ request: ControlRequest) -> Lookup {
        let query = AppAccessibility.Query(request)
        guard query.namesAControl else {
            return .answer(.error("\(request.command) needs identifier=, role=, subrole=, or label= naming a control"))
        }
        let nodes = AppAccessibility.nodes(query)
        guard nodes.indices.contains(query.index) else {
            let place = query.window.map { "a window titled " + $0 } ?? "any window"
            return .answer(.refused("missing", "no such control in \(place)", ["matches": .number(Double(nodes.count))]))
        }
        return .found(nodes[query.index])
    }

    private func click(_ request: ControlRequest) async -> ControlReply {
        let node: AppAccessibility.Node
        switch control(request) {
        case .found(let found): node = found
        case .answer(let answer): return answer
        }
        let window = node.window
        let frame = AppAccessibility.windowRect(of: node.frame, in: window)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        // The window's own hit test: the frame view has no superview, so it
        // takes a point in the window's coordinates.
        let root = window.contentView?.superview ?? window.contentView
        let hitView = root?.hitTest(centre)
        let hit: ClickRule.Hit
        if let hitView, let content = window.contentView {
            hit = hitView.isDescendant(of: content) ? .content : .chrome
        } else {
            hit = .nothing
        }
        let rule = ClickRule(
            role: node.role, enabled: node.enabled, frame: frame, inChrome: node.inChrome,
            clips: node.clips.map { AppAccessibility.windowRect(of: $0, in: window) },
            windowBounds: CGRect(origin: .zero, size: window.frame.size), contentRect: window.contentLayoutRect,
            hasSheet: window.attachedSheet != nil, hit: hit
        )
        let details: [String: ControlValue] = [
            "target": node.summary,
            "hitView": .string(hitView.map { String(describing: Swift.type(of: $0)) } ?? "none"),
        ]
        if request.bool("force") != true, let refusal = rule.refusal {
            return .refused(refusal.rawValue, message(for: refusal), details)
        }
        // `dry=true` answers whether the click would land, and posts nothing.
        if request.bool("dry") == true { return .ok(details) }
        post(clickAt: centre, in: window)
        let dispatched = await EventFlush.flush()
        return .ok(details.merging(["dispatched": .bool(dispatched)]) { _, new in new })
    }

    private func message(for refusal: ClickRule.Refusal) -> String {
        switch refusal {
        case .disabled: "the control is dimmed"
        case .offscreen: "the control is out of sight: scrolled away, or outside its part of the window"
        case .covered: "a click at the control's centre would land on something else"
        }
    }

    private var eventNumber = 0

    private func post(clickAt point: CGPoint, in window: NSWindow) {
        eventNumber += 1
        let now = ProcessInfo.processInfo.systemUptime
        for (type, time, pressure) in [(NSEvent.EventType.leftMouseDown, now, 1.0), (.leftMouseUp, now + 0.05, 0.0)] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                context: nil, eventNumber: eventNumber, clickCount: 1, pressure: Float(pressure)
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// Keys for the window's first responder, such as a text field a click
    /// just focused. `replace=true` selects what it holds first, through the
    /// responder chain's Select All, so the typing replaces it.
    private func type(_ request: ControlRequest) -> ControlReply {
        guard let title = request.string("window"), let window = AppAccessibility.windows(titled: title).first else {
            return .error("type needs window=<title> of an open window")
        }
        guard let text = request.string("text") else { return .error("type needs text=<what to type>") }
        if request.bool("replace") == true {
            _ = window.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
        }
        let codes: [Character: UInt16] = ["\r": 36, "\n": 36, "\t": 48, "\u{7f}": 51, "\u{1b}": 53]
        let now = ProcessInfo.processInfo.systemUptime
        for character in text {
            let string = String(character)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: now, windowNumber: window.windowNumber,
                    context: nil, characters: string, charactersIgnoringModifiers: string, isARepeat: false,
                    keyCode: codes[character] ?? 0
                ) {
                    window.sendEvent(event)
                }
            }
        }
        return .ok(["firstResponder": .string(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none")])
    }

    /// Scrolls a control into view in the scroll view that holds it, as a
    /// person scrolling to it would, or a window's scroll view to `to=top` or
    /// `to=end`.
    private func scroll(_ request: ControlRequest) -> ControlReply {
        if AppAccessibility.Query(request).namesAControl {
            let node: AppAccessibility.Node
            switch control(request) {
            case .found(let found): node = found
            case .answer(let answer): return answer
            }
            let rect = AppAccessibility.windowRect(of: node.frame, in: node.window)
            let holders = scrollViews(in: node.window).filter { scrollView in
                guard let document = scrollView.documentView else { return false }
                return document.convert(document.bounds, to: nil).contains(CGPoint(x: rect.midX, y: rect.midY))
            }
            // The innermost one, the smallest that holds it.
            guard let scrollView = holders.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
                  let document = scrollView.documentView else {
                return .error("no scroll view holds that control")
            }
            document.scrollToVisible(document.convert(rect, from: nil).insetBy(dx: 0, dy: -16))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return .ok()
        }
        guard let title = request.string("window"), let window = AppAccessibility.windows(titled: title).first else {
            return .error("scroll needs window=<title> and a control, or to=top or to=end")
        }
        guard let scrollView = scrollViews(in: window).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scrollView.documentView else {
            return .error("the window has no scroll view")
        }
        let toEnd = request.string("to") != "top"
        let height = max(0, document.frame.height - scrollView.contentView.bounds.height)
        let y = toEnd == document.isFlipped ? height : 0
        scrollView.contentView.scroll(to: CGPoint(x: scrollView.contentView.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return .ok()
    }

    private func scrollViews(in window: NSWindow) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scrollView = view as? NSScrollView { found.append(scrollView) }
            view.subviews.forEach(walk)
        }
        window.contentView.map(walk)
        return found
    }

    // MARK: - The menu bar extra's menu

    /// The status item's menu as the app builds it, read without showing it;
    /// `press=<title>`, or `press="<submenu> > <title>"`, runs an item's own
    /// action, as choosing it from the open menu does. Refused when the item
    /// is dimmed or not there. Only the real menu bar can show that macOS
    /// draws and opens the menu; that stays a real-screen check.
    private func menu(_ request: ControlRequest) async -> ControlReply {
        guard let menu = statusMenu() else {
            return .error("the status item's menu is out of reach")
        }
        refresh(menu)
        var fields: [String: ControlValue] = ["items": items(of: menu)]
        guard let press = request.string("press") else { return .ok(fields) }
        let path = press.components(separatedBy: " > ")
        var current = menu
        for step in path.dropLast() {
            guard let submenu = current.items.first(where: { $0.title == step })?.submenu else {
                return .refused("missing", "the menu has no submenu \"\(step)\"", fields)
            }
            refresh(submenu)
            current = submenu
        }
        guard let index = current.items.firstIndex(where: { $0.title == path.last }) else {
            return .refused("missing", "the menu has no item \"\(press)\"", fields)
        }
        guard current.items[index].isEnabled else {
            return .refused("disabled", "\"\(press)\" is dimmed", fields)
        }
        current.performActionForItem(at: index)
        fields["dispatched"] = .bool(await EventFlush.flush())
        return .ok(fields)
    }

    /// The menu SwiftUI's MenuBarExtra gave its status item. Nothing public
    /// leads from the app to that item, so it is reached through the status
    /// bar window that holds it; slice 3's menu model replaces this.
    private func statusMenu() -> NSMenu? {
        for window in NSApp.windows where window.responds(to: NSSelectorFromString("statusItem")) {
            if let item = window.value(forKey: "statusItem") as? NSStatusItem, let menu = item.menu { return menu }
        }
        return nil
    }

    private func refresh(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }

    private func items(of menu: NSMenu) -> ControlValue {
        .array(menu.items.map { item in
            var fields: [String: ControlValue] = [
                "title": .string(item.title), "enabled": .bool(item.isEnabled), "separator": .bool(item.isSeparatorItem),
            ]
            if let submenu = item.submenu {
                refresh(submenu)
                fields["items"] = items(of: submenu)
            }
            return .object(fields)
        })
    }

    // MARK: - Settings

    private func settings(_ request: ControlRequest) -> ControlReply {
        let settings = host.controlSettings
        guard let key = request.string("key") else { return .ok(["settings": settings]) }
        return .ok(["value": settings[path: key] ?? .null])
    }

    private func waitSetting(_ request: ControlRequest) async -> ControlReply {
        guard let key = request.string("key"), let expected = request.argument("equals") else {
            return .error("wait-setting needs key=<path> and equals=<value>")
        }
        let reached = await poll(request) { self.host.controlSettings[path: key] == expected }
        let value = host.controlSettings[path: key] ?? .null
        return reached ? .ok(["value": value]) : .error("\(key) is \(value.text), not \(expected.text)", ["value": value])
    }

    /// Checks `condition` every 20 ms until it holds or `timeout` seconds
    /// (10 unless the request says) have passed.
    private func poll(_ request: ControlRequest, until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int((request.number("timeout") ?? 10) * 1000))
        while true {
            if condition() { return true }
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Checkpoints

    /// A PNG of one of the app's windows at `path`: absolute, ending in .png,
    /// and new, since a checkpoint never replaces a file.
    private func snapshot(_ request: ControlRequest) async -> ControlReply {
        guard let title = request.string("window"), let window = AppAccessibility.windows(titled: title).first else {
            return .error("snapshot needs window=<title> of an open window")
        }
        guard let path = request.string("path"), path.hasPrefix("/"), path.hasSuffix(".png") else {
            return .error("snapshot needs path=<an absolute path ending in .png>")
        }
        do {
            let image = try await host.controlCapture(window)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return .error("the capture could not be written as a PNG")
            }
            try png.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            return .ok(["path": .string(path), "width": .number(Double(image.width)), "height": .number(Double(image.height))])
        } catch {
            return .error("snapshot failed: \(error.localizedDescription)")
        }
    }
}

/// Waits until every event queued before it has been dispatched, by queuing
/// one more of its own and waiting for it to come round, so a click's answer
/// comes back only once AppKit has handled its mouse-down and mouse-up.
@MainActor
enum EventFlush {
    private static let subtype: Int16 = 0x4154
    private static var monitor: Any?
    private static var waiting: [Int: CheckedContinuation<Bool, Never>] = [:]
    private static var next = 0

    static func flush(within timeout: Duration = .seconds(5)) async -> Bool {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
                guard event.subtype.rawValue == subtype else { return event }
                let token = event.data1
                MainActor.assumeIsolated { EventFlush.finish(token, dispatched: true) }
                return nil
            }
        }
        next += 1
        let token = next
        guard let marker = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, subtype: subtype, data1: token, data2: 0
        ) else { return false }
        return await withCheckedContinuation { continuation in
            waiting[token] = continuation
            NSApp.postEvent(marker, atStart: false)
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish(token, dispatched: false)
            }
        }
    }

    private static func finish(_ token: Int, dispatched: Bool) {
        waiting.removeValue(forKey: token)?.resume(returning: dispatched)
    }
}
