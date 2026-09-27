#if E2EAPI
  import Foundation
  import Testing

  extension Scenarios {
    /// A suggestion is answered from the menu with no pointer: Answer Suggestion is live while it
    /// is up, Tell Me More keeps it up, and Not Now is recorded and takes it down.
    ///
    /// The suggestion toast never takes keyboard focus, so the menu offers its answers too,
    /// where the keyboard and VoiceOver reach them: Answer Suggestion holds them, live while a
    /// suggestion is up and dimmed otherwise. Tell Me More from there opens the toast's
    /// explanation and keeps it up, and Not Now answers it and takes it down. The toast comes
    /// from scripted sensing (README "Scripted sensing") and each answer is chosen through the
    /// handler the menu runs; that an accessibility press on the menu bar item opens the menu and
    /// keeps the toast up is macOS's routing, which the real-screen tier proves.
    @Test func `toast-menu-answers`() async {
      await Run.scenario("toast-menu-answers") { run in
        let control = run.control
        let toast = "Athina suggestion"
        let toastUp = { (present: Bool) in
          try await control.waitWindow(toast, present: present, timeout: 5)
        }
        // The Answer Suggestion submenu's items, whether each is live, kept with the evidence.
        let answers = { (name: String) -> [String: Bool] in
          let items =
            try await control.menu().first { $0.title == "Answer Suggestion" }?.items?
            .filter { !$0.separator } ?? []
          try (items.map { "\($0.title)=\($0.enabled)" }.joined(separator: "\n") + "\n")
            .write(
              to: run.evidence.appendingPathComponent("\(name).txt"),
              atomically: true,
              encoding: .utf8
            )
          return Dictionary(items.map { ($0.title, $0.enabled) }) { first, _ in first }
        }
        let recorded = { (suggestion: String, feedback: String) in
          try await control.waitEvent(
            "feedback",
            matching: ["id": suggestion, "feedback": feedback]
          )?
          .event["feedback"]
        }

        let suggestion = try await run.scriptedToast()
        // Pictures kept as evidence: the toast shows what changes from run to run and moves on
        // its own, so it is no checkpoint (README "Checkpoints").
        try await run.picture(toast, "toast")
        let up = try await answers("answers-up")
        for answer in ["Tell Me More", "Not Now", "Never for This", "Close Suggestion"] {
          run.check("the menu offers \(answer) while the suggestion is up", true, up[answer])
        }

        run.check(
          "Tell Me More is chosen from the menu",
          true,
          try await control.menu(press: "Answer Suggestion > Tell Me More").ok
        )
        run.check(
          "Tell Me More is recorded",
          "tellMeMore",
          try await recorded(suggestion, "tellMeMore")
        )
        run.check("the toast stays up after Tell Me More", true, try await toastUp(true))
        run.check(
          "the toast shows its explanation",
          "Show Less",
          try await control.first(.identifier("toast.tellMeMore", in: toast))?.label
        )
        try await run.picture(toast, "toast-told-more")

        run.check(
          "Not Now is chosen from the menu",
          true,
          try await control.menu(press: "Answer Suggestion > Not Now").ok
        )
        run.check("Not Now is recorded", "notNow", try await recorded(suggestion, "notNow"))
        run.check("the toast goes after Not Now", true, try await toastUp(false))
        run.check("the journal holds Not Now", "notNow", try await run.feedback(of: suggestion))
        let after = try await answers("answers-after")
        run.check("the menu's answers are dimmed once none is up", false, after["Not Now"])
        run.check(
          "an answer from the menu with none up is refused",
          "disabled",
          try await control.menu(press: "Answer Suggestion > Never for This").refused
        )
      }
    }
  }
#endif
