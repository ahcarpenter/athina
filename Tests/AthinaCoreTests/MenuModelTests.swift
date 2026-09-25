import Testing

@testable import AthinaCore

/// The menu bar item's menu as the app builds it: what it holds in each
/// state, and the command a path of titles names, with a refusal naming the
/// step when one is not there or is dimmed, as the control API's `menu press=`
/// reports it.
@Suite struct MenuModelTests {
  let pause = HotKey(keyCode: 35, modifiers: [.command, .shift])

  func state(
    mentor: MenuModel.State.Either = .line("Mentor: replay mode, nothing billed"),
    talkBack: MenuModel.State.Either = .line("Talk back: no shortcut set"),
    isPaused: Bool = false,
    capturesFrames: Bool = true,
    hasLastSuggestion: Bool = false,
    hasActiveSuggestion: Bool = false,
    showsDebugPanel: Bool = false
  ) -> MenuModel.State {
    MenuModel.State(
      statusLines: ["Watching", "Replaying 7 recorded calls"],
      mentor: mentor,
      mentorContextLine: nil,
      understandingLine: "Goal: not worked out yet",
      talkBack: talkBack,
      isPaused: isPaused,
      pauseShortcut: pause,
      capturesFrames: capturesFrames,
      hasLastSuggestion: hasLastSuggestion,
      hasActiveSuggestion: hasActiveSuggestion,
      showsDebugPanel: showsDebugPanel
    )
  }

  func titles(_ model: MenuModel) -> [String] {
    model.items.map { $0 == .separator ? "-" : $0.title }
  }

  @Test func theMenuReadsStatusThenCommandsThenWindowsThenQuit() {
    #expect(
      titles(MenuModel(state())) == [
        "Watching", "Replaying 7 recorded calls", "Mentor: replay mode, nothing billed",
        "Goal: not worked out yet", "Talk back: no shortcut set", "-",
        "Pause Watching", "Capture Now", "-",
        "Show Last Suggestion", "Answer Suggestion", "-",
        "Suggestions", "Permissions…", "Settings…", "-",
        "About Athina", "Quit Athina",
      ]
    )
  }

  @Test func statusRowsAreDimmedText() {
    let model = MenuModel(state())
    #expect(model.items.first == .status("Watching"))
    #expect(!model.items[0].isEnabled)
  }

  @Test func aStatusThatAsksForSomethingIsTheCommandThatDoesIt() {
    let action = MenuModel.StatusAction(
      title: "Add API Key…",
      command: .openSettings(pane: "models")
    )
    let model = MenuModel(state(mentor: .action(action)))
    #expect(model.target("Add API Key…") == .command(.openSettings(pane: "models")))
  }

  @Test func pausingTurnsTheCommandRoundAndKeepsItsShortcut() {
    let model = MenuModel(state(isPaused: true))
    #expect(
      model.items.contains(.command("Resume Watching", .togglePause, shortcut: .hotKey(pause)))
    )
  }

  @Test func theDebugPanelIsAGroupOfItsOwnAfterSettingsOnlyWhileTurnedOn() {
    #expect(!titles(MenuModel(state())).contains("Debug Panel"))
    let on = titles(MenuModel(state(showsDebugPanel: true)))
    let index = on.firstIndex(of: "Debug Panel")!
    #expect(Array(on[(index - 2)...(index + 1)]) == ["Settings…", "-", "Debug Panel", "-"])
  }

  @Test func theAnswersAreDimmedWhileNoSuggestionIsUp() {
    let idle = MenuModel(state())
    #expect(
      idle.target("Answer Suggestion > Tell Me More")
        == .refused(reason: "disabled", message: #""Tell Me More" is dimmed"#)
    )
    let up = MenuModel(state(hasActiveSuggestion: true))
    #expect(up.target("Answer Suggestion > Tell Me More") == .command(.answer(.tellMeMore)))
    #expect(up.target("Answer Suggestion > Close Suggestion") == .command(.answer(.dismissed)))
  }

  @Test func anItemOfTheMenuIsFound() {
    let model = MenuModel(state())
    #expect(model.target("Settings…") == .command(.openSettings(pane: nil)))
    #expect(model.target("Quit Athina") == .command(.quit))
  }

  @Test func aMissingStepIsRefusedByName() {
    let model = MenuModel(state())
    #expect(
      model.target("Debug Panel")
        == .refused(reason: "missing", message: #"the menu has no item "Debug Panel""#)
    )
    #expect(
      model.target("Answer Suggestion > Tell Me Less")
        == .refused(
          reason: "missing",
          message: #""Answer Suggestion" has no item "Tell Me Less""#
        )
    )
    #expect(
      model.target("Answer > Tell Me More")
        == .refused(reason: "missing", message: #"the menu has no item "Answer""#)
    )
    #expect(
      model.target("Settings… > General")
        == .refused(reason: "missing", message: #""Settings…" has no submenu"#)
    )
    #expect(
      model.target("Answer Suggestion")
        == .refused(reason: "missing", message: #""Answer Suggestion" is not a command"#)
    )
  }

  @Test func aDimmedStepIsRefusedByName() {
    let model = MenuModel(state(capturesFrames: false))
    #expect(
      model.target("Capture Now")
        == .refused(reason: "disabled", message: #""Capture Now" is dimmed"#)
    )
    // A status row is never a command a person can choose.
    #expect(
      model.target("Watching") == .refused(reason: "disabled", message: #""Watching" is dimmed"#)
    )
    // A dimmed submenu cannot be opened, so nothing in it can be chosen.
    let dimmed = MenuModel(items: [
      .submenu("Pause", [.command("For an Hour", .togglePause)], enabled: false)
    ])
    #expect(
      dimmed.target("Pause > For an Hour")
        == .refused(reason: "disabled", message: #""Pause" is dimmed"#)
    )
  }
}
