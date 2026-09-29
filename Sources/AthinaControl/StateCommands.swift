import AppKit
import AthinaControlProtocol
import AthinaCore
import AthinaE2E
import Foundation

// The control API's commands over the app's state rather than its windows:
// scripted sensing, the events the app has handled, its journal, its clock,
// the links in its own text, and the items of its pop-up buttons (docs/e2e.md
// "The control API").
extension ControlCommands {
  /// The names `wait-event` waits for (`ControlEventLog.Entry.name`).
  static let eventNames = [
    "observation", "focus", "mode", "event", "status", "suggestion", "feedback", "followUp", "call",
    "announcement",
  ]

  // MARK: - Scripted sensing

  /// Scripts what a hermetic run senses next.
  ///
  /// `app=` and `bundle=` in front, in `window=`, showing `text=`
  /// (`ScriptedObservation`), captured at once; or with `idle=true` or
  /// `idle=false` alone, input going idle or coming back. The answer's `after`
  /// is the newest event's sequence before this one was sensed, for a
  /// `wait-event` on what it brings. Refused as `unscripted` in a run that
  /// senses the real Mac.
  func observe(_ request: ControlRequest) async throws -> ControlReply {
    let after = ControlValue.number(Double(host.controlEvents.sequence))
    let refusal = ControlReply.refused(
      "unscripted",
      "this run senses the real Mac; observe scripts only a hermetic run's sensing"
    )
    if let idle = try request.bool("idle") {
      guard ["app", "bundle", "window", "text"].allSatisfy({ request.argument($0) == nil }) else {
        return .error("idle= goes alone, with no app=, bundle=, window= or text=")
      }
      return await host.controlSetIdle(idle) ? .ok(["after": after]) : refusal
    }
    guard let app = try request.string("app"), let bundle = try request.string("bundle") else {
      return .error(
        "observe needs app=<name> and bundle=<identifier>, with window=<title> and text=<what it shows>,"
          + " or idle=true or idle=false alone"
      )
    }
    let scripted = ScriptedObservation(
      appName: app,
      bundleID: bundle,
      windowTitle: try request.string("window"),
      text: try request.string("text") ?? ""
    )
    switch await host.controlObserve(scripted) {
    case .kept(let observation):
      return .ok([
        "after": after, "kept": .bool(true), "observation": .number(Double(observation.id)),
        "reason": .string(observation.reason.rawValue),
      ])
    case .notKept(let why):
      return .ok(["after": after, "kept": .bool(false), "why": .string(why)])
    case .notScripted:
      return refusal
    }
  }

  // MARK: - Events

  /// Waits for the first event named `name=` after the sequence `after=` (0,
  /// every event since launch, unless given), whose fields hold every other
  /// argument given: `wait-event name=event kind=understanding`.
  func waitEvent(_ request: ControlRequest) async throws -> ControlReply {
    guard let name = try request.string("name"), Self.eventNames.contains(name) else {
      return .error("wait-event needs name=, one of \(Self.eventNames.joined(separator: ", "))")
    }
    let after = Int(try request.number("after") ?? 0)
    var matching: [String: String] = [:]
    for (key, value) in request.arguments where !["name", "after", "timeout"].contains(key) {
      matching[key] = value.text
    }
    var found: ControlEventLog.Entry?
    let host = host
    let reached = try await poll(request) {
      found = host.controlEvents.first(named: name, after: after, matching: matching)
      return found != nil
    }
    guard reached, let found else {
      let wanted = ([name] + matching.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        .joined(separator: " ")
      return .error(
        "no event \(wanted) after \(after) came in time",
        ["latest": .number(Double(host.controlEvents.sequence))]
      )
    }
    return .ok([
      "sequence": .number(Double(found.sequence)), "name": .string(found.name),
      "event": .object(found.fields.mapValues { .string($0) }),
    ])
  }

  // MARK: - The journal

  /// One of the harness's named journal queries (`JournalQueries`),
  /// `query=<name>`, answered from the app's own journal: its `columns`, and
  /// its `rows` as objects keyed by column.
  func journal(_ request: ControlRequest) async throws -> ControlReply {
    let names = JournalQueries.all.map(\.name).joined(separator: ", ")
    guard let name = try request.string("query"), let query = JournalQueries.named(name) else {
      return .error("journal needs query=, one of \(names)")
    }
    let rows = try await host.controlJournalRows(query.sql)
    return .ok([
      "columns": .array(query.columns.map { .string($0) }),
      "rows": .array(
        rows.map { row in
          .object(
            Dictionary(
              uniqueKeysWithValues: zip(query.columns, row.map { ControlValue.string($0) })
            )
          )
        }
      ),
    ])
  }

  // MARK: - The clock

  /// Moves the replay's clock `seconds=` ahead, or `interval=` as the debug
  /// panel's Advance field takes it (`15m`, `2h`, `1d12h`), as that field
  /// does, and answers with its time (`now`, ISO 8601) and how far it has
  /// been moved ahead in all.
  func advance(_ request: ControlRequest) throws -> ControlReply {
    let seconds: TimeInterval
    switch (try request.number("seconds"), try request.string("interval")) {
    case (let given?, nil):
      seconds = given
    case (nil, let interval?):
      guard let parsed = ClockInterval.seconds(from: interval) else {
        return .error("\"\(interval)\" is not an interval such as 15m, 2h, or 1d")
      }
      seconds = parsed
    case (.some, .some):
      return .error("advance takes seconds= or interval=, not both")
    case (nil, nil):
      return .error("advance needs seconds=<how far> or interval=<such as 15m, 2h, or 1d>")
    }
    if let refusal = host.controlAdvanceClock(by: seconds) { return .error(refusal) }
    let clock = host.controlClock
    return .ok([
      "now": .string(ISO8601DateFormatter().string(from: clock.now)),
      "movedAhead": .number(clock.movedAhead),
    ])
  }

  // MARK: - Links

  /// Follows a link in the app's own text through the handler a click on it runs.
  ///
  /// The link is found as `click` finds a control, and its URL is the one
  /// SwiftUI carries as its identifier. It proves where the link goes and that
  /// the app handles it, not that a click reaches it: a click the app
  /// simulates does not follow a link inside a Text. Refused as `missing` when
  /// the control is not a link, and `unhandled` when the app has no handler
  /// for its URL.
  func openLink(_ request: ControlRequest) async throws -> ControlReply {
    let node: AppAccessibility.Node
    switch try control(request) {
    case .found(let found): node = found
    case .answer(let answer): return answer
    }
    guard node.role == "AXLink" else {
      return .refused(
        "missing",
        "that control is a \(node.role), not a link",
        ["target": node.summary]
      )
    }
    guard let url = URL(string: node.identifier), url.scheme != nil else {
      return .error("the link carries no URL as its identifier", ["target": node.summary])
    }
    guard host.controlOpenLink(url) else {
      return .refused("unhandled", "the app has no handler for \(url.absoluteString)")
    }
    return .ok(["url": .string(url.absoluteString), "dispatched": .bool(await EventFlush.flush())])
  }

  // MARK: - Pop-up buttons

  /// Chooses the item titled `item=` in a pop-up button, as VoiceOver does:
  /// the button is pressed, which opens its menu, and the menu's item is
  /// pressed.
  ///
  /// The button is found as `click` finds a control. A SwiftUI pop-up button
  /// offers its items to no assistive app until its menu is open, and the
  /// menu runs its own tracking loop until an item is chosen. So the press
  /// that opens it is made from a run-loop block rather than from this
  /// command, leaving the main queue free inside that loop, and this command
  /// goes on there to find the item among the app's open menus and press it,
  /// which closes the menu. Refused as `missing` when the control is not a
  /// pop-up button or its menu has no such item (the menu is then closed
  /// again), and `disabled` when it is dimmed.
  func choose(_ request: ControlRequest) async throws -> ControlReply {
    let node: AppAccessibility.Node
    switch try control(request) {
    case .found(let found): node = found
    case .answer(let answer): return answer
    }
    guard node.role == "AXPopUpButton" else {
      return .refused(
        "missing",
        "that control is a \(node.role), not a pop-up button",
        ["target": node.summary]
      )
    }
    guard let title = try request.string("item") else {
      return .error("choose needs item=<the title of the item to choose>")
    }
    guard node.enabled else {
      return .refused("disabled", "the control is dimmed", ["target": node.summary])
    }
    let button = UncheckedElement(node.element)
    RunLoop.main.perform(inModes: [.common]) {
      _ = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
    }
    let app = AXUIElementCreateApplication(getpid())
    var shown: [String] = []
    for _ in 0..<50 {
      try await Task.sleep(for: .milliseconds(100))
      let items = Self.elements(under: app, role: kAXMenuItemRole as String)
      guard !items.isEmpty else { continue }
      shown = items.compactMap { Self.string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
      if let item = items.first(where: { Self.string($0, kAXTitleAttribute) == title }) {
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        return .ok([
          "target": node.summary,
          "chosen": .string(title),
          "dispatched": .bool(await EventFlush.flush()),
        ])
      }
      break
    }
    // Close the menu again, so nothing is left open over the window.
    for menu in Self.elements(under: app, role: kAXMenuRole as String) {
      AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }
    return .refused(
      "missing",
      shown.isEmpty
        ? "the pop-up button's menu never opened"
        : "the menu has no item titled \(title); it has \(shown.joined(separator: ", "))",
      ["target": node.summary]
    )
  }

  /// Every element under `root` with `role`, breadth first, a few levels deep.
  private static func elements(under root: AXUIElement, role: String) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var level = [root]
    for _ in 0..<8 where !level.isEmpty {
      var next: [AXUIElement] = []
      for element in level {
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] {
          if string(child, kAXRoleAttribute) == role { found.append(child) }
          next.append(child)
        }
      }
      level = next
    }
    return found
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return value as? String
  }
}

/// An accessibility element carried into a run-loop block on the main thread
/// it was read on.
private struct UncheckedElement: @unchecked Sendable {
  let element: AXUIElement
  init(_ element: AXUIElement) { self.element = element }
}
