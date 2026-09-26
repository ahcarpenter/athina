#if E2EAPI
  import Foundation
  import Testing

  extension Scenarios {
    /// The understanding a mentor call writes reaches the menu, the card, and Settings, and
    /// Reset Understanding asks first.
    ///
    /// The mentor call that raises the first suggestion also writes the first understanding, so
    /// this follows that record out to the menu, the debug panel's card, and Settings > Models,
    /// and then through Reset Understanding, which asks before it forgets every revision. The
    /// suggestion comes from scripted sensing (README "Scripted sensing"), every control is
    /// clicked or typed into through Athina's own event path, and the journal is read through the
    /// app. The footer's link to the Journal pane is followed through the handler a click on it
    /// runs (`open-link`); that a real click on it reaches that handler is the real-screen tier's
    /// to prove.
    @Test func `understanding-surfaces`() async {
      await Run.scenario("understanding-surfaces", arguments: ["--open", "debug"]) { run in
        let control = run.control
        let panel = "Debug Panel"
        let reset = Target.identifier("understanding.reset", in: panel)
        let refresh = Target.identifier("understanding.refreshInterval", in: "Models")
        let revisions = { try await control.journal("understanding") }
        let resetEvents = {
          try await control.journal("events").filter {
            $0["kind"] == "understanding" && ($0["detail"] ?? "").hasPrefix("reset")
          }.count
        }
        // The menu's rows, one title each, kept with the evidence.
        let menuTitles = { (name: String) -> String in
          let titles = try await control.menu().filter { !$0.separator }.map(\.title)
            .joined(separator: "\n")
          try (titles + "\n").write(
            to: run.evidence.appendingPathComponent("\(name)-menu.txt"),
            atomically: true,
            encoding: .utf8
          )
          return titles
        }
        // Everything a window shows, one line per element, kept with the evidence.
        let windowTexts = { (window: String, name: String) -> String in
          let texts = try await control.find(.everything(in: window)).flatMap(\.texts)
            .joined(separator: "\n")
          try (texts + "\n").write(
            to: run.evidence.appendingPathComponent("\(name)-texts.txt"),
            atomically: true,
            encoding: .utf8
          )
          return texts
        }
        let refreshInterval = { try await control.setting("mentor.understandingRefreshInterval") }
        let fieldValue = { (field: Target) in try await control.first(field)?.value ?? "" }
        // Types an amount into a duration row and ends the edit with Tab, the way a person moves
        // on to the next field. The field is emptied first, backwards and then forwards from
        // wherever the click put the insertion point, which in a field that lines its text up on
        // the right is often before the text. The amount the row is left showing is what it
        // committed, which it can take a moment to show once the edit ends on a busy Mac, so it
        // is read until it is the amount expected, `want`, or that moment has passed.
        let typeDuration = { (field: Target, typed: String, want: String) -> String in
          guard try await control.scroll(field).ok, try await control.click(field).ok,
            try await control.type(
              String(repeating: "\u{7f}", count: 6) + String(repeating: "\u{F728}", count: 6)
                + typed + "\t",
              in: "Models"
            ).ok
          else { return "" }
          return try await run.settled(want) { try await fieldValue(field) }
        }

        guard try await control.waitWindow(panel, timeout: 20) else {
          throw AppProcess.Failure("the debug panel never opened")
        }
        _ = try await run.scriptedToast()
        // The mentor call carries the understanding in its reply, so the record is written just
        // after the suggestion it came with.
        guard try await control.waitEvent("status", matching: ["understanding": "1"]) != nil else {
          throw AppProcess.Failure("no understanding was written")
        }
        let goal = try await revisions().last?["goal"] ?? ""
        // Every goal check below compares against this text, and an empty one would match any
        // text, so a record with no goal to follow stops the scenario.
        guard !goal.isEmpty, goal != "-" else {
          throw AppProcess.Failure("the understanding names no goal to follow")
        }
        run.log("the understanding names \"\(goal)\"")
        run.check("the mentor call wrote an understanding", 1, try await revisions().count)

        // The menu shows the goal, clipped to fit a menu item, so only its start can be compared
        // with the record.
        run.check(
          "the menu shows the goal it worked out",
          true,
          try await menuTitles("with-goal").contains("Goal: \(goal.prefix(40))")
        )

        // The card sits under the Mentor loop card in the Now pane, below the fold.
        if try await !control.scroll(reset).ok { run.log("the card could not be scrolled to") }
        let card = try await windowTexts(panel, "card")
        try await run.picture(panel, "card")
        run.check("the card shows the goal", true, card.contains(goal))
        run.check("the card names the refresh interval", true, card.contains("of active use"))
        run.check(
          "the card offers Reset Understanding",
          true,
          card.contains("Reset Understanding…")
        )

        run.check(
          "the menu's Settings… command is chosen",
          true,
          try await control.menu(press: "Settings…").ok
        )
        guard try await control.waitWindow("General", timeout: 10) else {
          throw AppProcess.Failure("Settings never opened")
        }
        run.check(
          "a click on the Models toolbar item lands",
          true,
          try await control.click(.label("Models", in: "General")).ok
        )
        guard try await control.waitWindow("Models", timeout: 5) else {
          throw AppProcess.Failure("the Models pane never showed")
        }
        let settings = try await windowTexts("Models", "settings")
        try await run.picture("Models", "models")
        run.check("Settings shows the current goal", true, settings.contains(goal))

        // The section's two duration rows show different unit words, minutes beside hours with
        // the shipped defaults, and a unit pop-up sizes to the word it is showing, so this is
        // where a row that reserves only its own word pushes its field and stepper off the other
        // row's x.
        let refreshX = try await control.first(refresh)?.frame.first
        let idleX = try await control.first(.identifier("understanding.idleGap", in: "Models"))?
          .frame
          .first
        // Two empty readings would match each other, so nothing to measure is a scenario failure
        // rather than a check that passes by saying nothing.
        guard let refreshX, let idleX else {
          throw AppProcess.Failure("the Models pane showed no duration fields to measure")
        }
        run.check("the duration rows start their fields on one x", refreshX, idleX)

        // The row is held to the seconds the setting itself accepts, 5 minutes to 12 hours, and it
        // commits when the edit ends, so typing an amount outside that and moving on leaves the
        // nearest one it allows rather than a figure validated() would quietly clamp behind the
        // person.
        run.check(
          "a refresh below the range settles at the shortest allowed",
          "5",
          try await typeDuration(refresh, "1", "5")
        )
        run.check(
          "the setting holds the shortest refresh",
          .number(300),
          try await run.settled(.number(300), refreshInterval)
        )
        run.check(
          "a refresh above the range settles at the longest allowed",
          "720",
          try await typeDuration(refresh, "1000", "720")
        )
        run.check(
          "the setting holds the longest refresh",
          .number(43200),
          try await run.settled(.number(43200), refreshInterval)
        )
        run.check(
          "an allowed refresh is left as typed",
          "20",
          try await typeDuration(refresh, "20", "20")
        )
        run.check(
          "the setting holds the refresh typed",
          .number(1200),
          try await run.settled(.number(1200), refreshInterval)
        )

        // The footer names the Journal pane by linking to it, and the link opens it here rather
        // than in a browser, so the Settings window itself changes pane.
        run.check(
          "the footer's link to Journal is followed",
          "athina-settings:journal",
          try await control.openLink(.identifier("athina-settings:journal", in: "Models"))["url"]?
            .string
        )
        run.check(
          "the footer link opens the Journal pane in place",
          true,
          try await control.waitWindow("Journal", timeout: 5)
        )
        try await run.picture("Journal", "journal-pane")
        _ = try await control.click(.subrole("AXCloseButton", in: "Journal"))
        if try await !control.waitWindow("Journal", present: false, timeout: 5) {
          run.log("Settings would not close")
        }

        // Asking first, and Cancel keeping every revision.
        let kept = try await revisions().count
        _ = try await control.scroll(reset)
        // A destructive button takes no click into a window that is not forward, and a hermetic
        // run's never are, so it is pressed as VoiceOver presses it.
        run.check("Reset Understanding… is pressed", true, try await control.press(reset).ok)
        let cancel = Target.role("AXButton", label: "Cancel", in: panel)
        run.check(
          "the confirmation comes up",
          "Cancel",
          try await run.settled("Cancel") { try await control.first(cancel)?.label ?? "" }
        )
        let confirmation = try await windowTexts(panel, "confirmation")
        try await run.picture(panel, "confirmation")
        run.check(
          "the confirmation asks before resetting",
          true,
          confirmation.contains("Reset the understanding?")
        )
        run.check(
          "the confirmation says it cannot be undone",
          true,
          confirmation.contains("You can't undo this action.")
        )
        run.check("a click on Cancel lands", true, try await control.click(cancel).ok)
        run.check("Cancel keeps every revision", kept, try await revisions().count)
        run.check("Cancel journals no reset", 0, try await resetEvents())

        run.check("Reset Understanding… is pressed again", true, try await control.press(reset).ok)
        run.check(
          "a click on the confirmation's Reset Understanding lands",
          true,
          try await control.click(.role("AXButton", label: "Reset Understanding", in: panel)).ok
        )
        run.check(
          "the reset is journaled",
          "understanding",
          try await control.waitEvent("event", matching: ["kind": "understanding"])?.event["kind"]
        )
        run.check("Reset Understanding forgets every revision", 0, try await revisions().count)
        run.check("the reset is journaled once", 1, try await resetEvents())
        let after = try await windowTexts(panel, "card-after-reset")
        try await run.picture(panel, "card-after-reset")
        run.check(
          "the card says there is no understanding yet",
          true,
          after.contains("No understanding yet.")
        )
        run.check(
          "the menu says the goal is not worked out yet",
          true,
          try await menuTitles("after-reset").contains("Goal: not worked out yet")
        )
      }
    }
  }
#endif
