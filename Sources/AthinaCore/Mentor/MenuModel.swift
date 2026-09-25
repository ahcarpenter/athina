import Foundation

/// The menu bar item's menu, as Athina builds it.
///
/// It lists what Athina is doing, then its commands, then its windows, then
/// Quit. Status rows are dimmed text; a status that needs something from the
/// person is a command that goes there.
///
/// One model serves every reader. The app's menu bar extra draws it, and the
/// control API reads it and runs its commands (`target`) in a hermetic run,
/// which puts no item in the menu bar at all. So both run the same command
/// through the same handler, and only a real-screen check is left to prove
/// that the menu macOS draws is this one.
public struct MenuModel: Equatable, Sendable {
  /// What choosing a command does.
  public enum Command: Equatable, Sendable {
    case togglePause
    case captureNow
    case showLastSuggestion
    /// Answers the suggestion that is up.
    case answer(SuggestionFeedback)
    case openSuggestions
    case openPermissions
    /// Opens Settings on the pane with this identifier, or on the one it
    /// last showed when nil.
    case openSettings(pane: String?)
    case openDebugPanel
    case about
    case quit
  }

  /// A command's key equivalent.
  public enum Shortcut: Equatable, Sendable {
    /// A hot key of the person's choosing, shown beside its command.
    case hotKey(HotKey)
    /// Command and this character.
    case command(Character)
  }

  /// One row of the menu.
  public indirect enum Item: Equatable, Sendable {
    /// A dimmed line saying what Athina is doing.
    case status(String)
    /// A command, dimmed while it cannot run.
    case command(String, Command, enabled: Bool = true, shortcut: Shortcut? = nil)
    case separator
    /// A submenu, which a person cannot open while it is dimmed.
    case submenu(String, [Item], enabled: Bool = true)

    /// The row's title as the menu shows it; empty for a separator.
    public var title: String {
      switch self {
      case .status(let title), .command(let title, _, _, _), .submenu(let title, _, _): title
      case .separator: ""
      }
    }

    /// Whether a person can choose the row: a status row never can.
    public var isEnabled: Bool {
      switch self {
      case .status, .separator: false
      case .command(_, _, let enabled, _), .submenu(_, _, let enabled): enabled
      }
    }
  }

  /// A status row that asks for something, shown as the command that does it.
  public struct StatusAction: Equatable, Sendable {
    /// What the menu shows, such as "Add API Key…".
    public var title: String
    /// What choosing it does.
    public var command: Command

    /// A status row that runs `command` when chosen.
    public init(title: String, command: Command) {
      self.title = title
      self.command = command
    }
  }

  /// Everything the menu is built from.
  public struct State: Equatable, Sendable {
    /// What Athina is doing, then where calls go, the clock, refused launch
    /// flags, and the control API: every line there is something to say.
    public var statusLines: [String]
    /// The mentor's status: the command that fixes what holds it, when one
    /// does, and otherwise its line.
    public var mentor: Either
    /// The mentorship context in force, when one is.
    public var mentorContextLine: String?
    /// What Athina understands the person to be working toward, when it does.
    public var understandingLine: String?
    /// Talking back: the command that sets it up, or its line.
    public var talkBack: Either
    /// Whether the person paused watching.
    public var isPaused: Bool
    /// The pause hot key, shown beside the command that does the same.
    public var pauseShortcut: HotKey?
    /// Whether sensing is in a mode that captures, so Capture Now can.
    public var capturesFrames: Bool
    /// Whether a suggestion was shown this launch, for Show Last Suggestion.
    public var hasLastSuggestion: Bool
    /// Whether a suggestion is up to be answered.
    public var hasActiveSuggestion: Bool
    /// Whether Settings > Advanced turns the debug panel on.
    public var showsDebugPanel: Bool

    /// A status line, or the command that stands in for it.
    public enum Either: Equatable, Sendable {
      case line(String)
      case action(StatusAction)
    }

    /// Everything the menu is built from, with the quiet defaults of a menu
    /// that has nothing to offer beyond its standing commands.
    public init(
      statusLines: [String],
      mentor: Either,
      mentorContextLine: String? = nil,
      understandingLine: String? = nil,
      talkBack: Either,
      isPaused: Bool = false,
      pauseShortcut: HotKey? = nil,
      capturesFrames: Bool = true,
      hasLastSuggestion: Bool = false,
      hasActiveSuggestion: Bool = false,
      showsDebugPanel: Bool = false
    ) {
      self.statusLines = statusLines
      self.mentor = mentor
      self.mentorContextLine = mentorContextLine
      self.understandingLine = understandingLine
      self.talkBack = talkBack
      self.isPaused = isPaused
      self.pauseShortcut = pauseShortcut
      self.capturesFrames = capturesFrames
      self.hasLastSuggestion = hasLastSuggestion
      self.hasActiveSuggestion = hasActiveSuggestion
      self.showsDebugPanel = showsDebugPanel
    }
  }

  /// The menu's rows, from the top.
  public var items: [Item]

  /// A menu of exactly these rows.
  public init(items: [Item]) {
    self.items = items
  }

  /// The menu the app shows in `state`.
  public init(_ state: State) {
    var items: [Item] = state.statusLines.map(Item.status)
    items.append(Self.row(state.mentor))
    items += [state.mentorContextLine, state.understandingLine].compactMap { $0.map(Item.status) }
    items.append(Self.row(state.talkBack))
    items += [
      .separator,
      .command(
        state.isPaused ? "Resume Watching" : "Pause Watching",
        .togglePause,
        shortcut: state.pauseShortcut.map(Shortcut.hotKey)
      ),
      .command("Capture Now", .captureNow, enabled: state.capturesFrames),
      .separator,
      .command("Show Last Suggestion", .showLastSuggestion, enabled: state.hasLastSuggestion),
      // The suggestion never takes keyboard focus, so its answers are here
      // too, where the keyboard and VoiceOver reach them. The submenu stays
      // in the menu, its items dimmed, while no suggestion is up.
      .submenu(
        "Answer Suggestion",
        [
          .command("Tell Me More", .answer(.tellMeMore), enabled: state.hasActiveSuggestion),
          .command("Not Now", .answer(.notNow), enabled: state.hasActiveSuggestion),
          .command("Never for This", .answer(.never), enabled: state.hasActiveSuggestion),
          .separator,
          .command("Close Suggestion", .answer(.dismissed), enabled: state.hasActiveSuggestion),
        ]
      ),
      .separator,
      .command("Suggestions", .openSuggestions),
      .command("Permissions…", .openPermissions),
      .command("Settings…", .openSettings(pane: nil), shortcut: .command(",")),
    ]
    // A builder's tool, in a group of its own after the everyday windows,
    // as Safari's Develop menu follows its everyday menus, and only while
    // Settings > Advanced turns it on, in every mode.
    if state.showsDebugPanel {
      items += [.separator, .command("Debug Panel", .openDebugPanel)]
    }
    // Athina has no app menu, so its menu carries the app menu's About and Quit.
    items += [
      .separator,
      .command("About Athina", .about),
      .command("Quit Athina", .quit, shortcut: .command("q")),
    ]
    self.items = items
  }

  private static func row(_ either: State.Either) -> Item {
    switch either {
    case .line(let line): .status(line)
    case .action(let action): .command(action.title, action.command)
    }
  }

  /// What a path of titles names, or why it names nothing a person could
  /// choose.
  public enum Target: Equatable, Sendable {
    case command(Command)
    case refused(reason: String, message: String)
  }

  /// The command a path of titles from the top of the menu names.
  ///
  /// The titles are joined by " > " (`Answer Suggestion > Tell Me More`). A
  /// path is refused by the step's name when that step is not there or is
  /// dimmed, since a person could neither choose it nor open the submenu it
  /// heads.
  public func target(_ path: String) -> Target {
    var steps = path.components(separatedBy: " > ")
    let last = steps.removeLast()
    var current = items
    var place = "the menu"
    for step in steps {
      switch Self.lookUp(step, in: current, place) {
      case .refused(let refusal): return refusal
      case .found(.submenu(_, let children, _)):
        current = children
        place = "\"\(step)\""
      case .found:
        return .refused(reason: "missing", message: "\"\(step)\" has no submenu")
      }
    }
    switch Self.lookUp(last, in: current, place) {
    case .refused(let refusal): return refusal
    case .found(.command(_, let command, _, _)): return .command(command)
    case .found: return .refused(reason: "missing", message: "\"\(last)\" is not a command")
    }
  }

  private enum Lookup {
    case found(Item)
    case refused(Target)
  }

  private static func lookUp(_ title: String, in items: [Item], _ place: String) -> Lookup {
    guard let item = items.first(where: { $0.title == title && $0 != .separator }) else {
      return .refused(.refused(reason: "missing", message: "\(place) has no item \"\(title)\""))
    }
    guard item.isEnabled else {
      return .refused(.refused(reason: "disabled", message: "\"\(title)\" is dimmed"))
    }
    return .found(item)
  }
}
