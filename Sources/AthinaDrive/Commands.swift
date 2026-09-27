import AppKit
import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation

// The command line of athina-drive, parsed and checked before anything on the
// screen is touched: every scenario reaches the accessibility tree, the
// pointer, and the journal through this one tool, so a mistyped drive step
// fails with a usage message and exit 64 rather than click somewhere
// unintended.

/// `athina-drive`: every command a scenario runs, one subcommand each.
struct AthinaDrive: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "athina-drive",
    abstract: "Drive a pid's windows, menu bar extra, and journal for an end-to-end scenario.",
    subcommands: [
      Permissions.self,
      Ready.self,
      Windows.self,
      Toast.self,
      BarReport.self,
      Front.self,
      Activate.self,
      AX.self,
      Click.self,
      Raise.self,
      Close.self,
      MenuPick.self,
      Tap.self,
      Announce.self,
      Flip.self,
      Journal.self,
      Key.self,
      Shot.self,
      API.self,
    ]
  )

  /// Every command that runs, as opposed to one that only groups others,
  /// such as `click`, in the order `--help` lists them.
  static var leaves: [ParsableCommand.Type] {
    func leaves(of command: ParsableCommand.Type) -> [ParsableCommand.Type] {
      let children = command.configuration.subcommands
      return children.isEmpty ? [command] : children.flatMap(leaves(of:))
    }
    return leaves(of: self)
  }
}

/// A process id on the command line: a positive integer.
struct ProcessID: ExpressibleByArgument, Equatable {
  /// The pid.
  let value: Int32

  init?(argument: String) {
    guard let value = Int32(argument), value > 0 else { return nil }
    self.value = value
  }
}

/// Arguments that may begin with a dash, read from one list.
///
/// swift-argument-parser takes any argument beginning with a dash for an
/// option, but a coordinate on a display left of the main one is negative,
/// and a title or value can be `-1`. A command that takes these takes them
/// as one `.allUnrecognized` list, with its usage written out, and reads
/// them here; a word beginning with `--` is still refused as an unknown
/// option.
enum Words {
  /// `words` checked against `names`, of which the last `optional` may be
  /// left out.
  static func text(_ words: [String], _ names: [String], optional: Int = 0) throws -> [String] {
    if let option = words.first(where: { $0.hasPrefix("--") }) {
      throw ValidationError("Unknown option '\(option)'")
    }
    let fewest = names.count - optional
    guard words.count >= fewest else {
      throw ValidationError("Missing expected argument '<\(names[words.count])>'")
    }
    guard words.count <= names.count else {
      throw ValidationError("Unexpected argument '\(words[names.count])'")
    }
    return words
  }

  /// `words` checked against `names`, every one a number.
  static func numbers(_ words: [String], _ names: [String]) throws -> [Double] {
    try zip(text(words, names), names).map { word, name in
      guard let number = Double(word) else {
        throw ValidationError("The value '\(word)' is invalid for '<\(name)>'")
      }
      return number
    }
  }
}

struct Permissions: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Whether this shell has Accessibility and Screen Recording."
  )

  func run() {
    // Neither grant can be given from a shell; a run that is missing one has
    // to say so rather than fail later with an empty window list.
    say("accessibility=\(AXIsProcessTrusted() ? "yes" : "no")")
    say("screenRecording=\(CGPreflightScreenCaptureAccess() ? "yes" : "no")")
  }
}

struct Ready: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Print READY once the app's menu bar extra exists; exit 2 until then."
  )

  @Argument var pid: ProcessID

  func run() {
    let ready = statusItem(of: pid.value) != nil
    say(ready ? "READY" : "NOT READY")
    Darwin.exit(ready ? 0 : 2)
  }
}

struct Windows: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The on-screen windows of a pid, with ids and frames."
  )

  @Argument var pid: ProcessID

  func run() {
    for window in onScreenWindows() where window.pid == pid.value {
      say(window.description)
    }
  }
}

struct Toast: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The window id of the suggestion toast, or nothing and exit 2."
  )

  @Argument var pid: ProcessID

  func run() {
    guard let toast = toastWindow(of: pid.value) else { Darwin.exit(2) }
    say("\(toast.id)")
  }
}

struct BarReport: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bar",
    abstract: "Menu bar extras and menu titles with frames, gaps, and empty space."
  )

  @Argument var pid: ProcessID?

  func run() { Bar.report(pid: pid?.value) }
}

struct Front: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "The frontmost app and its pid.")

  func run() {
    let front = NSWorkspace.shared.frontmostApplication
    say("frontmost app=\"\(front?.localizedName ?? "?")\" pid=\(front?.processIdentifier ?? -1)")
  }
}

struct Activate: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Bring a pid to the front.")

  @Argument var pid: ProcessID

  func run() {
    guard let app = NSRunningApplication(processIdentifier: pid.value) else {
      fail("activate: no pid \(pid.value)", code: 2)
    }
    let activated = app.activate()
    usleep(400_000)
    let front = NSWorkspace.shared.frontmostApplication
    say(
      """
      activate -> \(activated); frontmost now \"\(front?.localizedName ?? "?")\" \
      pid=\(front?.processIdentifier ?? -1)
      """
    )
  }
}

struct AX: ParsableCommand {
  /// What `ax` does to the pid's accessibility tree.
  enum Action: String, CaseIterable, ExpressibleByArgument {
    case dump, texts, menuitems, menu, pressextra, cancelmenu, get, press, pressx, focus, set
  }

  static let configuration = CommandConfiguration(
    commandName: "ax",
    abstract: "Read or press elements through accessibility, with no pointer.",
    usage: """
      athina-drive ax <pid> <\(Action.allCases.map(\.rawValue).joined(separator: "|"))> \
      [<role>] [<match>] [<value>] [--scope <scope>]
      """,
    discussion: """
      get, press, pressx (an exact match), focus and set find the first element of <role> \
      (any when empty) whose name contains <match>; set gives it <value>.
      """
  )

  @Argument var pid: ProcessID
  @Argument var action: Action
  @Argument(parsing: .allUnrecognized, help: .hidden) var words: [String] = []
  @Option(help: "Only windows whose title contains this, or extras for the status menu.")
  var scope: String?

  /// The role, match and value, as many as `action` takes.
  func terms() throws -> [String] {
    switch action {
    case .get, .press, .pressx, .focus:
      try Words.text(words, ["role", "match"], optional: 1)
    case .set:
      try Words.text(words, ["role", "match", "value"])
    default:
      try Words.text(words, [])
    }
  }

  mutating func validate() throws { _ = try terms() }

  func run() throws {
    Accessibility.run(pid: pid.value, action: action, terms: try terms(), scope: scope)
  }
}

struct Click: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Post a real HID click, aborting if the pointer is moved.",
    subcommands: [Item.self, At.self, Window.self]
  )

  struct Item: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Click a pid's menu bar extra.")

    @Argument var pid: ProcessID
    @Option(help: ArgumentHelp("Capture the result.", valueName: "out.png")) var shot: String?

    func run() { Clicker.perform(.statusItem(pid: pid.value), shot: shot) }
  }

  struct At: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Click a point on the menu bar that is on no item.",
      usage: "athina-drive click at <x> <y> [--shot <out.png>]"
    )

    @Argument(parsing: .allUnrecognized, help: .hidden) var words: [String] = []
    @Option(help: ArgumentHelp("Capture the result.", valueName: "out.png")) var shot: String?

    mutating func validate() throws { _ = try Words.numbers(words, ["x", "y"]) }

    func run() throws {
      let point = try Words.numbers(words, ["x", "y"])
      Clicker.perform(.emptyBar(point: CGPoint(x: point[0], y: point[1])), shot: shot)
    }
  }

  struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Click a point, in screen coordinates, on one of a pid's windows.",
      usage: "athina-drive click window <pid> <x> <y> [--shot <out.png>]"
    )

    @Argument var pid: ProcessID
    @Argument(parsing: .allUnrecognized, help: .hidden) var words: [String] = []
    @Option(help: ArgumentHelp("Capture the result.", valueName: "out.png")) var shot: String?

    mutating func validate() throws { _ = try Words.numbers(words, ["x", "y"]) }

    func run() throws {
      let point = try Words.numbers(words, ["x", "y"])
      Clicker.perform(
        .window(pid: pid.value, point: CGPoint(x: point[0], y: point[1])),
        shot: shot
      )
    }
  }
}

struct Raise: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Bring one of a pid's windows to the front, which journals a window switch.",
    usage: "athina-drive raise <pid> [<title>]"
  )

  @Argument var pid: ProcessID
  @Argument(parsing: .allUnrecognized, help: .hidden) var words: [String] = []

  mutating func validate() throws { _ = try Words.text(words, ["title"], optional: 1) }

  func run() throws {
    // By pid and window title, never by app name: another lane's app, or
    // the owner's own, must never be brought forward by a scenario.
    let wanted = try Words.text(words, ["title"], optional: 1).first ?? ""
    let app = AXUIElementCreateApplication(pid.value)
    let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    guard
      let window = windows.first(where: {
        wanted.isEmpty || title($0).localizedCaseInsensitiveContains(wanted)
      })
    else {
      fail("raise: pid \(pid.value) has no window matching \"\(wanted)\"", code: 2)
    }
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    say("raised \"\(title(window))\" of pid \(pid.value) -> \(raised.rawValue)")
  }
}

struct Close: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Close one of a pid's windows through its close button.",
    usage: "athina-drive close <pid> <title>"
  )

  @Argument var pid: ProcessID
  @Argument(parsing: .allUnrecognized, help: .hidden) var words: [String] = []

  mutating func validate() throws { _ = try Words.text(words, ["title"]) }

  func run() throws {
    let wanted = try Words.text(words, ["title"])[0]
    let app = AXUIElementCreateApplication(pid.value)
    let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    guard let window = windows.first(where: { title($0).localizedCaseInsensitiveContains(wanted) })
    else {
      say("close: pid \(pid.value) has no window matching \"\(wanted)\"")
      Darwin.exit(2)
    }
    guard let button = attr(window, kAXCloseButtonAttribute) else {
      fail("close: \"\(title(window))\" has no close button", code: 2)
    }
    let closed = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    say("closed \"\(title(window))\" of pid \(pid.value) -> \(closed.rawValue)")
  }
}

struct MenuPick: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "menupick",
    abstract: "Hover a submenu row and click one of its items with the pointer.",
    usage: "athina-drive menupick <pid> <row> <item>"
  )

  @Argument var pid: ProcessID
  @Argument(parsing: .allUnrecognized, help: .hidden) var words: [String] = []

  mutating func validate() throws { _ = try Words.text(words, ["row", "item"]) }

  func run() throws {
    let titles = try Words.text(words, ["row", "item"])
    Clicker.menuPick(pid: pid.value, row: titles[0], item: titles[1])
  }
}

struct Tap: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "A listen-only event tap logging mouse-downs and what is under them.",
    subcommands: [Session.self, Pid.self]
  )

  struct Session: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Log every mouse-down.")

    func run() { Watchers.tap(pid: nil) }
  }

  struct Pid: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Log one app's mouse-downs.")

    @Argument var pid: ProcessID

    func run() { Watchers.tap(pid: pid.value) }
  }
}

struct Announce: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Log every AXAnnouncementRequested the app posts."
  )

  @Argument var pid: ProcessID

  func run() { Watchers.announcements(pid: pid.value) }
}

struct Flip: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "A click-through helper window that changes text and colour on SIGUSR1.",
    usage: "athina-drive flip <x> <y> <w> <h>"
  )

  @Argument(parsing: .allUnrecognized, help: .hidden) var words: [String] = []

  mutating func validate() throws { _ = try Words.numbers(words, ["x", "y", "w", "h"]) }

  func run() throws {
    let frame = try Words.numbers(words, ["x", "y", "w", "h"])
    MainActor.assumeIsolated {
      FlipWindow.run(frame: CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]))
    }
  }
}

struct Journal: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "A named read-only query over a journal; `journal - queries` lists them."
  )

  @Argument var db: String
  @Argument var query: String

  func run() { JournalReader.run(database: db, query: query) }
}

struct Key: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Post a key press.")

  @Argument var keycode: CGKeyCode
  @Flag(help: "Hold Command.") var cmd = false
  @Flag(help: "Hold Shift.") var shift = false

  func run() { Pointer.key(keycode, command: cmd, shift: shift) }
}

struct Shot: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Capture a window by id or a screen region.",
    subcommands: [Window.self, Region.self]
  )

  struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Capture a window by id.")

    @Argument var id: CGWindowID
    @Argument(help: ArgumentHelp(valueName: "out.png")) var out: String

    func run() {
      screencapture(["-x", "-o", "-l", "\(id)", out])
      say("window \(id) -> \(out)")
    }
  }

  struct Region: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Capture a region of the screen.",
      usage: "athina-drive shot region <x> <y> <w> <h> <out.png>"
    )

    @Argument(parsing: .allUnrecognized, help: .hidden) var words: [String] = []

    mutating func validate() throws { _ = try region() }

    /// The region as `screencapture -R` takes it, and the file to write.
    func region() throws -> (region: String, out: String) {
      let names = ["x", "y", "w", "h"]
      let words = try Words.text(words, names + ["out.png"])
      let numbers = try Words.numbers(Array(words.prefix(4)), names)
      return (numbers.map { "\(Int($0))" }.joined(separator: ","), words[4])
    }

    func run() throws {
      let (region, out) = try region()
      screencapture(["-x", "-o", "-R", region, out])
      say("region \(region) -> \(out)")
    }
  }
}

struct API: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "api",
    abstract: """
      One request to a replay's control API, in ATHINA_CONTROL_DIR; prints the answer, or one \
      field of it with --field.
      """,
    usage: "athina-drive api <command> [<key=value> ...] [--field <path>]",
    discussion: "Exit 0 when the answer is ok, 1 when it is not, 2 when no app answered."
  )

  @Argument var command: String
  @Argument var arguments: [String] = []
  @Option(help: "Print only this field of the answer, such as elements.0.enabled.")
  var field: String?

  mutating func validate() throws { _ = try ControlClient.request(command, arguments) }

  func run() throws {
    try ControlClient.run(ControlClient.request(command, arguments), field: field)
  }
}
