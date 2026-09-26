import AppKit
import ApplicationServices
import AthinaControlProtocol
import AthinaCore
import CoreGraphics
import Foundation

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
/// polling does, never the replay's clock (docs/replay.md "A faster clock").
@MainActor
final class ControlCommands {
  let host: ControlHost

  init(host: ControlHost) {
    self.host = host
  }

  static let commands = [
    "ping",
    "windows",
    "find",
    "click",
    "press",
    "type",
    "scroll",
    "menu",
    "settings",
    "wait-setting",
    "wait-window",
    "snapshot",
    "outside-click",
    "hotkey",
    "observe",
    "wait-event",
    "journal",
    "advance",
    "open-link",
  ]

  /// Answers a request; a parameter of the wrong type is answered with an
  /// error naming it (`ControlArgumentError`).
  func handle(_ request: ControlRequest) async -> ControlReply {
    do {
      switch request.command {
      case "ping": return ping()
      case "windows": return windows()
      case "find": return try find(request)
      case "click": return try await click(request)
      case "press": return try await press(request)
      case "type": return try type(request)
      case "scroll": return try scroll(request)
      case "menu": return try await menu(request)
      case "settings": return try settings(request)
      case "wait-setting": return try await waitSetting(request)
      case "wait-window": return try await waitWindow(request)
      case "snapshot": return try await snapshot(request)
      case "outside-click": return try await outsideClick(request)
      case "hotkey": return try await hotKey(request)
      case "observe": return try await observe(request)
      case "wait-event": return try await waitEvent(request)
      case "journal": return try await journal(request)
      case "advance": return try advance(request)
      case "open-link": return try await openLink(request)
      default:
        return .error(
          """
          no command \"\(request.command)\"; the commands are \
          \(Self.commands.joined(separator: ", "))
          """
        )
      }
    } catch {
      return .error(String(describing: error))
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
    .ok([
      "windows": .array(
        AppAccessibility.windows(titled: nil).map { window in
          let frame = AppAccessibility.globalFrame(of: window.frame)
          return .object([
            "title": .string(window.title),
            "number": .number(Double(window.windowNumber)),
            "key": .bool(window.isKeyWindow),
            "main": .bool(window.isMainWindow),
            "level": .number(Double(window.level.rawValue)),
            "frame": .array(
              [frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) }
            ),
          ])
        }
      )
    ])
  }

  private func waitWindow(_ request: ControlRequest) async throws -> ControlReply {
    guard let title = try request.string("window") else {
      return .error("wait-window needs window=<title>")
    }
    let present = try request.bool("present") ?? true
    let reached = try await poll(request) {
      !AppAccessibility.windows(titled: title).isEmpty == present
    }
    return reached
      ? .ok()
      : .error("no window titled \"\(title)\" \(present ? "appeared" : "went away") in time")
  }

  // MARK: - Controls

  private func find(_ request: ControlRequest) throws -> ControlReply {
    let nodes = AppAccessibility.nodes(try AppAccessibility.Query(request))
    return .ok(["elements": .array(nodes.map { $0.summary })])
  }

  enum Lookup {
    case found(AppAccessibility.Node)
    case answer(ControlReply)
  }

  /// The first control, in tree order, a request names, or the answer
  /// saying why there is none.
  func control(_ request: ControlRequest) throws -> Lookup {
    let query = try AppAccessibility.Query(request)
    guard query.namesAControl else {
      return .answer(
        .error("\(request.command) needs identifier=, role=, subrole=, or label= naming a control")
      )
    }
    guard let node = AppAccessibility.nodes(query).first else {
      let place = query.window.map { "a window titled " + $0 } ?? "any window"
      return .answer(.refused("missing", "no such control in \(place)"))
    }
    return .found(node)
  }

  private func click(_ request: ControlRequest) async throws -> ControlReply {
    let node: AppAccessibility.Node
    switch try control(request) {
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
      role: node.role,
      enabled: node.enabled,
      frame: frame,
      inChrome: node.inChrome,
      clips: node.clips.map { AppAccessibility.windowRect(of: $0, in: window) },
      windowBounds: CGRect(origin: .zero, size: window.frame.size),
      contentRect: window.contentLayoutRect,
      hasSheet: window.attachedSheet != nil,
      hit: hit
    )
    let details: [String: ControlValue] = [
      "target": node.summary,
      "hitView": .string(hitView.map { String(describing: Swift.type(of: $0)) } ?? "none"),
    ]
    if try request.bool("force") != true, let refusal = rule.refusal {
      return .refused(refusal.rawValue, message(for: refusal), details)
    }
    let number = post(clickAt: centre, in: window)
    let dispatched = await PostedClicks.handled(number, in: window)
    return .ok(details.merging(["dispatched": .bool(dispatched)]) { _, new in new })
  }

  /// Presses the first control a request names through accessibility.
  ///
  /// It is the press VoiceOver or Full Keyboard Access makes: the control's
  /// own action, with no pointer. It is for a control a click the app
  /// simulates cannot drive: AppKit does not let a destructive button act on
  /// the click that first brings its window forward, and a hermetic run's
  /// windows never come forward. Refused as `disabled` when the control is
  /// dimmed, and as `unsupported` when it offers no press.
  private func press(_ request: ControlRequest) async throws -> ControlReply {
    let node: AppAccessibility.Node
    switch try control(request) {
    case .found(let found): node = found
    case .answer(let answer): return answer
    }
    guard node.enabled else {
      return .refused("disabled", "the control is dimmed", ["target": node.summary])
    }
    let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
    guard result == .success else {
      return .refused(
        "unsupported",
        "the control offers no press (\(result.rawValue))",
        ["target": node.summary]
      )
    }
    return .ok(["target": node.summary, "dispatched": .bool(await EventFlush.flush())])
  }

  private func message(for refusal: ClickRule.Refusal) -> String {
    switch refusal {
    case .disabled: "the control is dimmed"
    case .offscreen: "the control is out of sight: scrolled away, or outside its part of the window"
    case .covered: "a click at the control's centre would land on something else"
    }
  }

  private var eventNumber = 0

  /// Posts a mouse-down and a mouse-up at `point` and returns the event
  /// number they carry, which `PostedClicks` knows them by.
  private func post(clickAt point: CGPoint, in window: NSWindow) -> Int {
    PostedClicks.watch()
    eventNumber += 1
    let now = ProcessInfo.processInfo.systemUptime
    for (type, time, pressure) in [
      (NSEvent.EventType.leftMouseDown, now, 1.0), (.leftMouseUp, now + 0.05, 0.0),
    ] {
      if let event = NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: time,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: eventNumber,
        clickCount: 1,
        pressure: Float(pressure)
      ) {
        NSApp.postEvent(event, atStart: false)
      }
    }
    return eventNumber
  }

  /// Keys for the window's first responder, such as a text field a click
  /// just focused.
  private func type(_ request: ControlRequest) throws -> ControlReply {
    guard let title = try request.string("window"),
      var window = AppAccessibility.windows(titled: title).first
    else {
      return .error("type needs window=<title> of an open window")
    }
    guard let text = try request.string("text") else {
      return .error("type needs text=<what to type>")
    }
    // Keys go where a person's would: to the sheet up over the window.
    while let sheet = window.attachedSheet { window = sheet }
    let codes: [Character: UInt16] = ["\r": 36, "\n": 36, "\t": 48, "\u{7f}": 51, "\u{1b}": 53]
    let now = ProcessInfo.processInfo.systemUptime
    for character in text {
      let string = String(character)
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        if let event = NSEvent.keyEvent(
          with: type,
          location: .zero,
          modifierFlags: [],
          timestamp: now,
          windowNumber: window.windowNumber,
          context: nil,
          characters: string,
          charactersIgnoringModifiers: string,
          isARepeat: false,
          keyCode: codes[character] ?? 0
        ) {
          window.sendEvent(event)
        }
      }
    }
    return .ok([
      "firstResponder": .string(
        window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none"
      )
    ])
  }

  /// Scrolls a control into view in the scroll view that holds it, as a
  /// person scrolling to it would.
  private func scroll(_ request: ControlRequest) throws -> ControlReply {
    let node: AppAccessibility.Node
    switch try control(request) {
    case .found(let found): node = found
    case .answer(let answer): return answer
    }
    let rect = AppAccessibility.windowRect(of: node.frame, in: node.window)
    let holders = scrollViews(in: node.window).filter { scrollView in
      guard let document = scrollView.documentView else { return false }
      return document.convert(document.bounds, to: nil).contains(
        CGPoint(x: rect.midX, y: rect.midY)
      )
    }
    // The innermost one, the smallest that holds it.
    guard
      let scrollView = holders.min(by: {
        $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
      }),
      let document = scrollView.documentView
    else {
      return .error("no scroll view holds that control")
    }
    document.scrollToVisible(document.convert(rect, from: nil).insetBy(dx: 0, dy: -16))
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

  /// The status item's menu as the app builds it (`MenuModel`), read without
  /// showing it; `press=<title>`, or `press="<submenu> > <title>"`, runs an
  /// item's command through the handler choosing it from the open menu runs
  /// (`MenuModel.target`).
  ///
  /// Only the real menu bar can show that macOS draws and opens the menu; that
  /// stays a real-screen check.
  private func menu(_ request: ControlRequest) async throws -> ControlReply {
    let menu = host.controlMenu
    var fields: [String: ControlValue] = ["items": Self.items(menu.items)]
    guard let press = try request.string("press") else { return .ok(fields) }
    switch menu.target(press) {
    case .refused(let reason, let message):
      return .refused(reason, message, fields)
    case .command(let command):
      host.controlPerform(command)
      fields["dispatched"] = .bool(await EventFlush.flush())
      return .ok(fields)
    }
  }

  /// The rows as the menu shows them: a status row is a dimmed item.
  static func items(_ items: [MenuModel.Item]) -> ControlValue {
    .array(
      items.map { item in
        var fields: [String: ControlValue] = [
          "title": .string(item.title),
          "enabled": .bool(item.isEnabled),
          "separator": .bool(item == .separator),
        ]
        if case .submenu(_, let children, _) = item {
          fields["items"] = Self.items(children)
        }
        return .object(fields)
      }
    )
  }

  // MARK: - Input from outside the app

  /// A click outside Athina's windows at `x`, `y` (top-left global
  /// coordinates, as `windows` and `find` give frames), handed to the
  /// suggestion toast as its global monitor would hand it one: a hermetic
  /// run has no such monitor, so the owner's own clicks never reach it.
  private func outsideClick(_ request: ControlRequest) async throws -> ControlReply {
    guard let x = try request.number("x"), let y = try request.number("y") else {
      return .error(
        "outside-click needs x=<points> and y=<points> from the top left of the main display"
      )
    }
    let location = AppAccessibility.screenRect(of: CGRect(x: x, y: y, width: 0, height: 0)).origin
    let heard = host.controlOutsideClick(at: location)
    return .ok(["heard": .bool(heard), "dispatched": .bool(await EventFlush.flush())])
  }

  /// One of the hot keys set in Settings > General, through the handler Carbon
  /// calls: `key=pause` or `key=talk-back`, pressed and let go, or only
  /// `phase=down` or `phase=up`.
  ///
  /// `heard=<words>` is what talking back hears while its key is down, since a
  /// hermetic run opens no microphone. Refused as `disabled` when the key is
  /// not registered, since Carbon never reports a key it does not hold.
  private func hotKey(_ request: ControlRequest) async throws -> ControlReply {
    let names = ControlHotKey.allCases.map(\.rawValue).joined(separator: " or ")
    guard let name = try request.string("key"), let key = ControlHotKey(rawValue: name) else {
      return .error("hotkey needs key=\(names)")
    }
    let phase = try request.string("phase") ?? "press"
    guard ["press", "down", "up"].contains(phase) else {
      return .error("hotkey phase= is press, down, or up, not \(phase)")
    }
    let words = try request.string("heard")
    if words != nil, key != .talkBack {
      return .error("heard= goes with key=talk-back")
    }
    guard host.controlHotKeyRegistered(key) else {
      return .refused("disabled", "the \(name) hot key is not registered")
    }
    var fields: [String: ControlValue] = [:]
    if phase != "up" { host.controlHotKey(key, isDown: true) }
    if let words { fields["heard"] = .bool(host.controlHear(words)) }
    if phase != "down" { host.controlHotKey(key, isDown: false) }
    fields["dispatched"] = .bool(await EventFlush.flush())
    return .ok(fields)
  }

  // MARK: - Settings

  private func settings(_ request: ControlRequest) throws -> ControlReply {
    let settings = host.controlSettings
    guard let key = try request.string("key") else { return .ok(["settings": settings]) }
    return .ok(["value": settings[path: key] ?? .null])
  }

  private func waitSetting(_ request: ControlRequest) async throws -> ControlReply {
    guard let key = try request.string("key"), let expected = request.argument("equals") else {
      return .error("wait-setting needs key=<path> and equals=<value>")
    }
    let reached = try await poll(request) { self.host.controlSettings[path: key] == expected }
    let value = host.controlSettings[path: key] ?? .null
    return reached
      ? .ok(["value": value])
      : .error("\(key) is \(value.text), not \(expected.text)", ["value": value])
  }

  /// Checks `condition` every 20 ms until it holds or `timeout` seconds
  /// (10 unless the request says) have passed.
  func poll(_ request: ControlRequest, until condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(Int((try request.number("timeout") ?? 10) * 1000))
    while true {
      if condition() { return true }
      if clock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  // MARK: - Checkpoints

  /// A PNG of one of the app's windows at `path`.
  ///
  /// The path is absolute, ends in .png, and is new, since a checkpoint never
  /// replaces a file. With `appearance=light` or `dark`, the app is drawn in
  /// that appearance for the picture and given its own back after it, so a
  /// scenario can take a state in both.
  private func snapshot(_ request: ControlRequest) async throws -> ControlReply {
    guard let title = try request.string("window"),
      let window = AppAccessibility.windows(titled: title).first
    else {
      return .error("snapshot needs window=<title> of an open window")
    }
    guard let path = try request.string("path"), path.hasPrefix("/"), path.hasSuffix(".png") else {
      return .error("snapshot needs path=<an absolute path ending in .png>")
    }
    let appearances: [String: NSAppearance.Name] = ["light": .aqua, "dark": .darkAqua]
    let appearance = try request.string("appearance")
    if let appearance, appearances[appearance] == nil {
      return .error("snapshot appearance= is light or dark, not \(appearance)")
    }
    let previous = NSApp.appearance
    if let name = appearance.flatMap({ appearances[$0] }) {
      NSApp.appearance = NSAppearance(named: name)
    }
    defer { NSApp.appearance = previous }
    do {
      await drawnIn(window)
      let capture = try await host.controlCapture(window)
      let image = capture.image
      guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
      else {
        return .error("the capture could not be written as a PNG")
      }
      try png.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
      return .ok([
        "path": .string(path),
        "width": .number(Double(image.width)),
        "height": .number(Double(image.height)),
        "settled": .bool(capture.settled),
      ])
    } catch {
      return .error("snapshot failed: \(error.localizedDescription)")
    }
  }

  /// Waits, for up to two seconds, until the window server has finished drawing
  /// `window` in. macOS opens a window with an animation that scales and fades
  /// it in over a few hundred milliseconds, and a capture taken meanwhile is a
  /// smaller, washed-out picture of it.
  ///
  /// It is drawn in once the window server's bounds for it match its frame and
  /// hold for 100 ms.
  private func drawnIn(_ window: NSWindow) async {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    var steadySince: ContinuousClock.Instant?
    while clock.now < deadline {
      let expected = AppAccessibility.globalFrame(of: window.frame)
      if let drawn = Self.drawnBounds(of: window),
        abs(drawn.minX - expected.minX) < 1,
        abs(drawn.minY - expected.minY) < 1,
        abs(drawn.width - expected.width) < 1,
        abs(drawn.height - expected.height) < 1
      {
        let since = steadySince ?? clock.now
        steadySince = since
        if clock.now - since >= .milliseconds(100) { return }
      } else {
        steadySince = nil
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  /// Where the window server draws `window` now, in top-left global
  /// coordinates, or nil while it is not on screen.
  private static func drawnBounds(of window: NSWindow) -> CGRect? {
    guard
      let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber))
        as? [[String: Any]],
      let info = list.first,
      (info[kCGWindowIsOnscreen as String] as? Bool) == true,
      let bounds = info[kCGWindowBounds as String] as? NSDictionary
    else { return nil }
    return CGRect(dictionaryRepresentation: bounds)
  }
}

/// Knows when AppKit has handled a click the API posted.
///
/// The mouse-down always reaches the app's `sendEvent`, where a local monitor sees it; the
/// mouse-up does too, unless the control's own tracking loop takes it off the
/// queue, as a switch or a window's close button does. So a click has been
/// handled once its mouse-down was seen, the run loop is back in its default
/// mode, which it leaves for as long as a control tracks the mouse, and its
/// mouse-up was seen or is no longer waiting in the queue. An event of the
/// API's own queued after the click, as `EventFlush` queues one, is no proof:
/// a tracking loop can take that off the queue too, and did on the CI runner.
@MainActor
enum PostedClicks {
  private struct Seen: Hashable {
    let window: Int
    let number: Int
    let type: UInt
  }

  private static var monitor: Any?
  private static var seen: Set<Seen> = []

  /// Starts watching, before the first click is posted.
  static func watch() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
      let key = Seen(
        window: event.windowNumber,
        number: event.eventNumber,
        type: event.type.rawValue
      )
      MainActor.assumeIsolated { _ = PostedClicks.seen.insert(key) }
      return event
    }
  }

  /// Whether the click numbered `number` in `window` was handled within
  /// `timeout`, checked every few milliseconds.
  static func handled(
    _ number: Int,
    in window: NSWindow,
    within timeout: Duration = .seconds(5)
  ) async -> Bool {
    let down = Seen(
      window: window.windowNumber,
      number: number,
      type: NSEvent.EventType.leftMouseDown.rawValue
    )
    let up = Seen(
      window: window.windowNumber,
      number: number,
      type: NSEvent.EventType.leftMouseUp.rawValue
    )
    defer {
      seen.remove(down)
      seen.remove(up)
    }
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if RunLoop.main.currentMode == .default, seen.contains(down),
        seen.contains(up) || !queued(up)
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  /// Whether the mouse-up is still in the app's event queue, looked at
  /// without taking anything off it.
  private static func queued(_ up: Seen) -> Bool {
    guard
      let next = NSApp.nextEvent(
        matching: .leftMouseUp,
        until: .distantPast,
        inMode: .default,
        dequeue: false
      )
    else { return false }
    return next.windowNumber == up.window && next.eventNumber == up.number
  }
}

/// Waits until every event queued before it has been dispatched, by queuing
/// one more of its own and waiting for it to come round, so a command's answer
/// comes back only once AppKit has handled the events it set going.
///
/// A click waits on `PostedClicks` instead, since a control's tracking loop
/// can take this event off the queue.
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
    guard
      let marker = NSEvent.otherEvent(
        with: .applicationDefined,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: subtype,
        data1: token,
        data2: 0
      )
    else { return false }
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
