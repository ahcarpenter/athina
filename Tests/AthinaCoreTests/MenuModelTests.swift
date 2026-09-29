import Foundation
import Testing

@testable import AthinaCore

/// The menu bar item's menu as the app builds it: what it holds in each
/// state, and the command a path of titles names, with a refusal naming the
/// step when one is not there or is dimmed, as the control API's `menu press=`
/// reports it.
@Suite struct MenuModelTests {
  static let pause = HotKey(keyCode: 35, modifiers: [.command, .shift])

  func state(
    mentor: MenuModel.State.Either = .line("Mentor: replay mode, nothing billed"),
    answerLine: String? = nil,
    talkBack: MenuModel.State.Either = .line("Talk back: no shortcut set"),
    isPaused: Bool = false,
    pauseShortcut: HotKey? = MenuModelTests.pause,
    capturesFrames: Bool = true,
    hasLastSuggestion: Bool = false,
    hasActiveSuggestion: Bool = false,
    showsDebugPanel: Bool = false
  ) -> MenuModel.State {
    MenuModel.State(
      statusLines: ["Watching", "Replaying 7 recorded calls"],
      mentor: mentor,
      answerLine: answerLine,
      mentorContextLine: nil,
      understandingLine: "Goal: not worked out yet",
      talkBack: talkBack,
      isPaused: isPaused,
      pauseShortcut: pauseShortcut,
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
        "Watching",
        "Replaying 7 recorded calls",
        "Mentor: replay mode, nothing billed",
        "Goal: not worked out yet",
        "Talk back: no shortcut set",
        "-",
        "Pause Watching",
        "Capture Now",
        "-",
        "Show Last Suggestion",
        "Answer Suggestion",
        "-",
        "Suggestions",
        "Permissions…",
        "Settings…",
        "-",
        "About Athina",
        "Quit Athina",
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
      model.items.contains(.command("Resume Watching", .togglePause, shortcut: .hotKey(Self.pause)))
    )
  }

  @Test func aClearedPauseShortcutLeavesTheCommandWithNone() {
    let model = MenuModel(state(pauseShortcut: nil))
    #expect(model.items.contains(.command("Pause Watching", .togglePause, shortcut: nil)))
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

  func call(
    _ tier: ModelTier,
    _ model: String,
    at timestamp: Date,
    outcome: ModelCallOutcome = .quiet,
    replayed: Bool = false,
    provider: ModelProvider = .anthropic
  ) -> ModelCallRecord {
    ModelCallRecord(
      timestamp: timestamp,
      tier: tier,
      model: model,
      promptVersion: 1,
      promptCharacters: 100,
      imageBytes: 0,
      usage: Usage(inputTokens: 10, outputTokens: 5),
      cost: 0.001,
      latency: 1,
      outcome: outcome,
      detail: nil,
      replayed: replayed,
      provider: provider
    )
  }

  @Test func whichModelAnsweredSitsUnderTheMentorsSpend() {
    let lines = titles(
      MenuModel(state(answerLine: "Last answer: Claude Haiku 4.5 via replay (Triage), 15:23:06"))
    )
    let index = lines.firstIndex(of: "Mentor: replay mode, nothing billed")!
    #expect(lines[index + 1] == "Last answer: Claude Haiku 4.5 via replay (Triage), 15:23:06")
    #expect(
      MenuModel(state(answerLine: "Last answer: Claude Haiku 4.5 via replay (Triage), 15:23:06"))
        .items[index + 1] == .status("Last answer: Claude Haiku 4.5 via replay (Triage), 15:23:06")
    )
  }

  @Test func theLatestCallNamesTheModelThatAnsweredAndTheTierThatAsked() {
    let now = Calendar.current.date(bySettingHour: 15, minute: 30, second: 0, of: Date())!
    let triage = call(.triage, "claude-haiku-4-5-20251001", at: now.addingTimeInterval(-60))
    let mentor = call(
      .mentor,
      "claude-opus-5-5",
      at: now.addingTimeInterval(-30),
      outcome: .suggested
    )
    // The log is newest first, but the line reads the times, not the order.
    #expect(
      MenuModel.answerLine(calls: [triage, mentor], now: now)
        == "Last answer: Claude Opus 5.5 via Anthropic (Mentor), \(ClockFormat.time(mentor.timestamp))"
    )
  }

  @Test func aFailedCallAnsweredNothingSoTheLineNamesTheOneBefore() {
    let now = Calendar.current.date(bySettingHour: 15, minute: 30, second: 0, of: Date())!
    let triage = call(.triage, "claude-haiku-4-5-20251001", at: now.addingTimeInterval(-60))
    let failed = call(.mentor, "claude-opus-5-5", at: now.addingTimeInterval(-30), outcome: .error)
    #expect(
      MenuModel.answerLine(calls: [failed, triage], now: now)
        == "Last answer: Claude Haiku 4.5 via Anthropic (Triage), \(ClockFormat.time(triage.timestamp))"
    )
    #expect(MenuModel.answerLine(calls: [failed], now: now) == nil)
    #expect(MenuModel.answerLine(calls: [], now: now) == nil)
  }

  @Test func anAnswerFromAnEarlierDaySaysWhichDay() {
    let now = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
    let old = call(.followUp, "claude-sonnet-5", at: yesterday, outcome: .answered)
    #expect(
      MenuModel.answerLine(calls: [old], now: now)
        == "Last answer: Claude Sonnet 5 via Anthropic (Follow-up), \(ClockFormat.dayAndTime(yesterday))"
    )
  }

  @Test func aModelTheCatalogDoesNotKnowIsNamedByItsID() {
    let now = Date()
    let retired = call(.triage, "claude-retired-1", at: now)
    #expect(
      MenuModel.answerLine(calls: [retired], now: now)
        == "Last answer: claude-retired-1 via Anthropic (Triage), \(ClockFormat.time(now))"
    )
  }

  @Test func theLineSaysWhichProviderAnswered() {
    let now = Date()
    let openAI = call(.mentor, "gpt-6-sol", at: now, outcome: .suggested, provider: .openAI)
    #expect(
      MenuModel.answerLine(calls: [openAI], now: now)
        == "Last answer: GPT-6 Sol via OpenAI (Mentor), \(ClockFormat.time(now))"
    )
    let zen = call(.triage, "claude-haiku-4-5", at: now, provider: .openCode)
    #expect(
      MenuModel.answerLine(calls: [zen], now: now)
        == "Last answer: Claude Haiku 4.5 via OpenCode (Triage), \(ClockFormat.time(now))"
    )
  }

  @Test func aReplayedAnswerSaysItWasReplayedWhateverTheProvider() {
    let now = Date()
    let replayed = call(
      .triage,
      "claude-haiku-4-5-20251001",
      at: now,
      replayed: true,
      provider: .openAI
    )
    #expect(
      MenuModel.answerLine(calls: [replayed], now: now)
        == "Last answer: Claude Haiku 4.5 via replay (Triage), \(ClockFormat.time(now))"
    )
  }
}
