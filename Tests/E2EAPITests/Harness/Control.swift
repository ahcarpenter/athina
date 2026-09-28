#if E2EAPI
  import AthinaControlProtocol
  import Darwin
  import Foundation

  extension ControlValue {
    /// The elements, or nil when the value is not an array.
    var array: [ControlValue]? {
      if case .array(let value) = self { return value }
      return nil
    }
  }

  /// A control a request names, as `find`, `click` and the other commands take it (docs/e2e.md "The
  /// control API"): in the window titled `window`, or any window when that is nil, by its
  /// accessibility identifier, or by role, subrole and label.
  struct Target: Sendable, CustomStringConvertible {
    var window: String?
    var identifier: String?
    var role: String?
    var subrole: String?
    var label: String?

    /// The control carrying `identifier` in the window titled `window`.
    static func identifier(_ identifier: String, in window: String) -> Target {
      Target(window: window, identifier: identifier)
    }

    /// The control whose description or title is `label`, whole, in the window titled `window`:
    /// how the system-drawn Settings toolbar tabs are found, which carry no identifier.
    static func label(_ label: String, in window: String) -> Target {
      Target(window: window, label: label)
    }

    /// The first control of `role`, with `label` when that is given.
    static func role(_ role: String, label: String? = nil, in window: String? = nil) -> Target {
      Target(window: window, role: role, label: label)
    }

    /// The control of `subrole`, such as a title bar's `AXCloseButton`.
    static func subrole(_ subrole: String, in window: String) -> Target {
      Target(window: window, subrole: subrole)
    }

    /// Every control of the window titled `window`, or of every window.
    static func everything(in window: String? = nil) -> Target {
      Target(window: window)
    }

    var arguments: [String: ControlValue] {
      var arguments: [String: ControlValue] = [:]
      for (key, value) in [
        ("window", window), ("identifier", identifier), ("role", role), ("subrole", subrole),
        ("label", label),
      ] {
        if let value { arguments[key] = .string(value) }
      }
      return arguments
    }

    var description: String {
      arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.text)" }
        .joined(separator: " ")
    }
  }

  /// A control as `find` reads it from Athina's own accessibility tree.
  struct Element: Decodable, Sendable {
    let role: String
    let subrole: String
    let label: String
    let title: String
    let identifier: String
    let value: String
    let enabled: Bool
    /// x, y, width and height, in points from the top left of the main display.
    let frame: [Double]
    let window: String

    /// The texts it shows, its label, title and value, leaving out the empty ones.
    var texts: [String] { [label, title, value].filter { !$0.isEmpty } }
  }

  /// One of Athina's open windows, as `windows` lists it.
  struct AppWindow: Decodable, Sendable {
    let title: String
    let number: Int
    /// Its window level, which a hermetic run keeps below the desktop picture.
    let level: Int
  }

  /// A row of the menu bar extra's menu as the app builds it, as `menu` reads it.
  struct MenuItem: Decodable, Sendable {
    let title: String
    let enabled: Bool
    let separator: Bool
    /// A submenu's own rows.
    let items: [MenuItem]?
  }

  /// An event the app has handled, as `wait-event` answers with it.
  struct AppEvent: Decodable, Sendable {
    let sequence: Int
    let name: String
    /// The event's fields, each as text.
    let event: [String: String]
  }

  /// What `observe` did with a scripted moment.
  struct Observed: Decodable, Sendable {
    /// The newest event's sequence before this moment was sensed, for a `wait-event` on what it
    /// brings.
    let after: Int
    /// Whether the capture was journaled.
    let kept: Bool?
    /// Why it was not.
    let why: String?
  }

  /// The replay's control API, typed (docs/e2e.md "The control API"): one request per call over the
  /// run's socket, each written to `api.log` with its answer.
  ///
  /// An answer that says no (`ok` false) comes back for the scenario to check; only a request
  /// that gets no answer at all, such as one to an app that has exited, throws.
  struct Control: Sendable {
    /// The run's control directory, which holds its socket and its secret.
    let directory: URL
    let secret: String
    let transcript: LogFile

    // MARK: - Any command

    /// Sends `command` with `arguments` and returns the answer, whatever it says.
    func send(
      _ command: String,
      _ arguments: [String: ControlValue] = [:]
    ) async throws -> ControlReply {
      let request = ControlRequest(
        id: Int(getpid()),
        secret: secret,
        command: command,
        arguments: arguments
      )
      let directory = directory
      // A blocking read that a wait holds open for seconds, so on a thread of its own rather
      // than one of the few the tests' tasks share.
      let line = try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
          continuation.resume(
            with: Result { try ControlConnection.exchange(request, in: directory) }
          )
        }
      }
      let asked = arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.text)" }
      transcript.append(
        "\(LogFile.stamp()) \(([command] + asked).joined(separator: " "))\n"
          + "    \(String(decoding: line, as: UTF8.self))"
      )
      return try ControlReply.decode(line: line)
    }

    /// The field at `path` of `reply`, as `T`.
    private func decode<T: Decodable>(
      _ type: T.Type,
      _ reply: ControlReply,
      _ path: String
    ) throws -> T {
      let value = reply.json[path: path] ?? .null
      return try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
    }

    // MARK: - The app and its windows

    func ping() async throws -> ControlReply { try await send("ping") }

    func windows() async throws -> [AppWindow] {
      try decode([AppWindow].self, try await send("windows"), "windows")
    }

    /// Waits until a window titled `window` is open, or gone when `present` is false; whether it
    /// came to be so in `timeout` seconds.
    func waitWindow(
      _ window: String,
      present: Bool = true,
      timeout: Double = 10
    ) async throws
      -> Bool
    {
      try await send(
        "wait-window",
        ["window": .string(window), "present": .bool(present), "timeout": .number(timeout)]
      ).ok
    }

    /// A PNG of the window titled `window` at `path`, drawn in `appearance` when that is given.
    func snapshot(
      window: String,
      path: URL,
      appearance: String? = nil
    ) async throws
      -> ControlReply
    {
      var arguments: [String: ControlValue] = [
        "window": .string(window), "path": .string(path.path),
      ]
      if let appearance { arguments["appearance"] = .string(appearance) }
      return try await send("snapshot", arguments)
    }

    // MARK: - Controls

    func find(_ target: Target) async throws -> [Element] {
      let reply = try await send("find", target.arguments)
      guard reply.ok else { return [] }
      return try decode([Element].self, reply, "elements")
    }

    /// The first control `target` names, or nil when there is none.
    func first(_ target: Target) async throws -> Element? { try await find(target).first }

    /// A click on the control through AppKit's own event path; `force` clicks one the app
    /// would refuse, to prove the refusal.
    func click(_ target: Target, force: Bool = false) async throws -> ControlReply {
      var arguments = target.arguments
      if force { arguments["force"] = .bool(true) }
      return try await send("click", arguments)
    }

    /// An accessibility press, as VoiceOver presses a control.
    func press(_ target: Target) async throws -> ControlReply {
      try await send("press", target.arguments)
    }

    func scroll(_ target: Target) async throws -> ControlReply {
      try await send("scroll", target.arguments)
    }

    func openLink(_ target: Target) async throws -> ControlReply {
      try await send("open-link", target.arguments)
    }

    /// Chooses the item titled `item` in a pop-up button, as choosing it from the button's menu
    /// does, without opening the menu.
    func choose(_ target: Target, item: String) async throws -> ControlReply {
      try await send("choose", target.arguments.merging(["item": .string(item)]) { _, new in new })
    }

    /// `text` as key presses to the first responder of the window titled `window`, each held
    /// with `modifiers`: `type("a", holding: [.command], in: "Models")` is Command-A.
    func type(
      _ text: String,
      holding modifiers: [ControlProtocol.Modifier] = [],
      in window: String
    ) async throws -> ControlReply {
      var arguments: [String: ControlValue] = ["window": .string(window), "text": .string(text)]
      if !modifiers.isEmpty {
        arguments["modifiers"] = .string(modifiers.map(\.rawValue).joined(separator: ","))
      }
      return try await send("type", arguments)
    }

    /// One key press, virtual key code `code` held with `modifiers`, posted to the app's event
    /// queue for the window titled `window`, where an event monitor in the app, such as a
    /// shortcut recorder's, takes it as it takes a person's.
    func key(
      _ code: Int,
      holding modifiers: [ControlProtocol.Modifier] = [],
      in window: String
    ) async throws -> ControlReply {
      var arguments: [String: ControlValue] = [
        "window": .string(window), "code": .number(Double(code)),
      ]
      if !modifiers.isEmpty {
        arguments["modifiers"] = .string(modifiers.map(\.rawValue).joined(separator: ","))
      }
      return try await send("key", arguments)
    }

    // MARK: - The menu

    func menu() async throws -> [MenuItem] {
      try decode([MenuItem].self, try await send("menu"), "items")
    }

    /// Chooses the item titled `title`, or `"<submenu> > <title>"`, through the handler the menu
    /// runs.
    func menu(press title: String) async throws -> ControlReply {
      try await send("menu", ["press": .string(title)])
    }

    // MARK: - Settings

    /// The live setting at `key`, a dotted path such as `mentor.snoozes`.
    func setting(_ key: String) async throws -> ControlValue {
      try await send("settings", ["key": .string(key)])["value"] ?? .null
    }

    func waitSetting(_ key: String, equals value: ControlValue) async throws -> ControlReply {
      try await send("wait-setting", ["key": .string(key), "equals": value])
    }

    // MARK: - Input from outside the app

    /// A click outside Athina's windows at `x`, `y`, handed to the suggestion toast.
    func outsideClick(x: Double, y: Double) async throws -> ControlReply {
      try await send("outside-click", ["x": .number(x), "y": .number(y)])
    }

    /// A press of the global shortcut `key`, `pause` or `talk-back`, as the system reports one;
    /// refused as `disabled` when it is not registered.
    func hotKey(_ key: String) async throws -> ControlReply {
      try await send("hotkey", ["key": .string(key)])
    }

    // MARK: - Sensing, events, the journal and the clock

    /// Scripts what the run senses next: `app` in front, in `window`, showing `text`.
    func observe(
      app: String,
      bundle: String,
      window: String,
      text: String
    ) async throws
      -> Observed?
    {
      let reply = try await send(
        "observe",
        [
          "app": .string(app), "bundle": .string(bundle), "window": .string(window),
          "text": .string(text),
        ]
      )
      guard reply.ok else { return nil }
      return try decode(Observed.self, reply, "")
    }

    /// Waits for the first event named `name` after the sequence `after` whose fields hold
    /// every one of `matching`; nil when none came in `timeout` seconds.
    func waitEvent(
      _ name: String,
      after: Int? = nil,
      matching: [String: String] = [:],
      timeout: Double = 10
    ) async throws -> AppEvent? {
      var arguments: [String: ControlValue] = [
        "name": .string(name), "timeout": .number(timeout),
      ]
      if let after { arguments["after"] = .number(Double(after)) }
      for (key, value) in matching { arguments[key] = .string(value) }
      let reply = try await send("wait-event", arguments)
      guard reply.ok else { return nil }
      return try decode(AppEvent.self, reply, "")
    }

    /// The rows of the named journal query `query`, each keyed by column, from the app's own
    /// journal.
    func journal(_ query: String) async throws -> [[String: String]] {
      try decode(
        [[String: String]].self,
        try await send("journal", ["query": .string(query)]),
        "rows"
      )
    }

    /// Moves the replay's clock `seconds` ahead.
    func advance(seconds: Double) async throws -> ControlReply {
      try await send("advance", ["seconds": .number(seconds)])
    }
  }
#endif
