#if E2EAPI
  import Foundation
  import Testing

  extension Scenarios {
    /// Right after Clear Journal, the debug panel's Latest frame pane says the journal was cleared
    /// and the next capture appears there, not that Screen Recording is missing; the Mentor loop
    /// card names no observation, model call or callout Clear Journal deleted; and the next capture
    /// fills the pane again.
    ///
    /// Clearing deletes every observation, so the pane is empty until the next capture, while the
    /// status bar above it still shows Screen Recording granted and the mode watching; a pane that
    /// blamed the permission then named the wrong cause. The card's records of the triage gate,
    /// the last calls and the last callout described rows that were gone. The suggestion comes
    /// from scripted sensing (docs/e2e.md "Scripted sensing"), Clear Journal is chosen in
    /// Settings > Journal through Athina's own event path, and a hermetic run senses nothing it
    /// does not script, so the panel is read with no capture since the clear.
    @Test func `debug-panel-cleared`() async {
      await Run.scenario("debug-panel-cleared", arguments: ["--open", "debug"]) { run in
        let control = run.control
        let panel = "Debug Panel"
        // Everything the panel shows, one line per element, kept with the evidence.
        let panelTexts = { (name: String) -> [String] in
          let texts = try await control.find(.everything(in: panel)).flatMap(\.texts)
          try (texts.joined(separator: "\n") + "\n").write(
            to: run.evidence.appendingPathComponent("\(name)-texts.txt"),
            atomically: true,
            encoding: .utf8
          )
          return texts
        }
        // The panel in light and in dark, as evidence: it shows times and paths that change from
        // run to run, so it is no checkpoint.
        let pictures = { (name: String) in
          for appearance in ["light", "dark"] {
            let file = run.evidence.appendingPathComponent("\(name)-\(appearance).png")
            if try await !control.snapshot(window: panel, path: file, appearance: appearance).ok {
              run.log("no \(appearance) picture of the panel \(name)")
            }
          }
        }
        let field = { (texts: [String], label: String) in
          texts.first { $0.hasPrefix("\(label), ") } ?? "\(label) is not shown"
        }
        let rows = { (table: String) in
          Int(try await control.journal("counts").first?[table] ?? "") ?? -1
        }
        // The card rows that describe a deleted row, with what each says once none is left.
        let records = [
          ("Triage gate", "Triage gate, no observation yet"),
          ("Last triage", "Last triage, none yet"),
          ("Mentor gate", "Mentor gate, not reached yet"),
          ("Last mentor", "Last mentor, none yet"),
          ("Callout", "Callout, none yet"),
        ]

        guard try await control.waitWindow(panel, timeout: 20) else {
          throw AppProcess.Failure("the debug panel never opened")
        }
        _ = try await run.scriptedToast()
        let before = try await panelTexts("before")
        try await pictures("before")
        run.check("the panel shows a frame before clearing", true, before.contains("Latest frame"))
        // A row the card already showed empty would pass below without proving anything, so the
        // scenario stops unless each one describes something first.
        for (label, cleared) in records where field(before, label) == cleared {
          throw AppProcess.Failure("\(label) showed nothing to clear before Clear Journal")
        }

        run.check(
          "the menu's Settings… command is chosen",
          true,
          try await control.menu(press: "Settings…").ok
        )
        guard try await control.waitWindow("General", timeout: 10) else {
          throw AppProcess.Failure("Settings never opened")
        }
        run.check(
          "a click on the Journal toolbar item lands",
          true,
          try await control.click(.label("Journal", in: "General")).ok
        )
        guard try await control.waitWindow("Journal", timeout: 5) else {
          throw AppProcess.Failure("the Journal pane never showed")
        }
        // A destructive button takes no click into a window that is not forward, and a hermetic
        // run's never are, so it is pressed as VoiceOver presses it.
        run.check(
          "Clear Journal… is pressed",
          true,
          try await control.press(.identifier("journal.clear", in: "Journal")).ok
        )
        let confirm = Target.role("AXButton", label: "Clear Journal", in: "Journal")
        run.check(
          "the confirmation comes up",
          "Clear Journal",
          try await run.settled("Clear Journal") { try await control.first(confirm)?.label ?? "" }
        )
        run.check(
          "the confirmation's Clear Journal is pressed",
          true,
          try await control.press(confirm).ok
        )
        run.check(
          "the journal holds no observation",
          0,
          try await run.settled(0) { try await rows("observations") }
        )
        run.check("the journal holds no model call", 0, try await rows("calls"))
        _ = try await control.click(.subrole("AXCloseButton", in: "Journal"))

        let cleared = try await run.settled(true) {
          try await panelTexts("cleared").contains("Journal Cleared")
        }
        let after = try await panelTexts("cleared")
        try await pictures("cleared")
        run.check("the frame pane says the journal was cleared", true, cleared)
        run.check(
          "the frame pane says the next capture appears there",
          true,
          after.contains("The next capture appears here.")
        )
        run.check(
          "the frame pane does not blame Screen Recording",
          false,
          after.contains { $0.contains("once Screen Recording is granted") }
        )
        run.check(
          "the status bar still shows Screen Recording granted",
          true,
          after.contains("Screen Recording granted")
        )
        for (label, empty) in records {
          run.check("the card's \(label) names nothing deleted", empty, field(after, label))
        }

        // The next capture fills the pane again, and the gate runs on the new row.
        guard try await run.observeDocument("reading-notes.txt") != nil else {
          throw AppProcess.Failure("reading-notes.txt was not observed after clearing")
        }
        let refilled = try await run.settled(true) {
          try await panelTexts("refilled").contains("Latest frame")
        }
        try await pictures("refilled")
        run.check("the next capture fills the frame pane", true, refilled)
        run.check(
          "the pane no longer says the journal was cleared",
          false,
          try await panelTexts("refilled").contains("Journal Cleared")
        )
      }
    }
  }
#endif
