#if E2EAPI
  import AthinaControlProtocol
  import Testing

  extension Scenarios {
    /// The toast's Tell Me More, Show Less, Close, Not Now and Never for This buttons each do
    /// what they say when clicked, and a click outside Athina takes it down.
    ///
    /// Tell Me More opens the explanation and is recorded once, however often the toast is
    /// folded and opened again; Show Less folds it and keeps it up; Close takes it down and, once
    /// the suggestion is answered, records nothing over the answer. Show Last Suggestion brings
    /// it back, Not Now answers it and snoozes the kind of suggestion in that app, Never for This
    /// answers it and stops that kind there, and a click outside Athina's windows takes it down.
    /// After Not Now and Never for This a note in the toast's place says what the answer did.
    /// VoiceOver hears the suggestion that came unasked after what it is saying, with its kind
    /// and app and, once, where its answers are, and the one brought back on request at once.
    /// Each button is clicked through AppKit's own event path in the toast's panel, parked below
    /// the desktop picture, so a click that lands proves the button can be hit and is wired. The
    /// toast comes from scripted sensing (docs/e2e.md "Scripted sensing"); that a real click in
    /// another app reaches it is the real-screen tier's to prove.
    @Test func `toast-buttons`() async {
      await Run.scenario("toast-buttons") { run in
        let control = run.control
        let toast = "Athina suggestion"
        let more = Target.identifier("toast.tellMeMore", in: toast)
        let toastUp = { (present: Bool) in
          try await control.waitWindow(toast, present: present, timeout: 5)
        }
        let press = { (identifier: String) in
          try await control.click(.identifier(identifier, in: toast)).ok
        }
        let moreLabel = { try await control.first(more)?.label ?? "" }
        let showLast = {
          _ = try await control.menu(press: "Show Last Suggestion")
          guard try await toastUp(true) else {
            throw AppProcess.Failure("Show Last Suggestion brought no toast back")
          }
        }
        // How many of the rules in the setting at `key` name TextEdit.
        let rulesForTextEdit = { (key: String) in
          try await control.setting(key).array?.filter { $0[path: "appName"]?.string == "TextEdit" }
            .count
        }
        let recorded = { (suggestion: String, feedback: String) in
          try await control.waitEvent(
            "feedback",
            matching: ["id": suggestion, "feedback": feedback]
          )?
          .event["feedback"]
        }
        // Everything the note panel shows, once it is up.
        let note = "Athina note"
        let noteText = {
          guard try await control.waitWindow(note, timeout: 5) else { return "" }
          return try await control.find(.everything(in: note)).flatMap(\.texts)
            .joined(separator: "\n")
        }
        let announced = { (after: Int?, priority: String) in
          try await control.waitEvent(
            "announcement",
            after: after,
            matching: ["priority": priority]
          )?
          .event["text"] ?? ""
        }

        let suggestion = try await run.scriptedToast()
        let unasked = try await announced(nil, "medium")
        run.check(
          "VoiceOver hears the unasked suggestion's kind and app, after what it is saying",
          true,
          unasked.hasPrefix("Athina, ") && unasked.contains(" in TextEdit: ")
        )
        run.check(
          "VoiceOver hears once where the suggestion's answers are",
          true,
          unasked.hasSuffix("Answer it from the Athina menu.")
        )
        // Pictures kept as evidence: the toast shows what changes from run to run and moves on
        // its own, so it is no checkpoint (docs/ci.md "Checkpoints").
        try await run.picture(toast, "toast")

        run.check("a click on Tell Me More lands", true, try await press("toast.tellMeMore"))
        run.check(
          "Tell Me More is recorded",
          "tellMeMore",
          try await recorded(suggestion, "tellMeMore")
        )
        run.check("the toast stays up to show the explanation", true, try await toastUp(true))
        run.check(
          "the button now folds it",
          "Show Less",
          try await run.settled("Show Less", moreLabel)
        )
        try await run.picture(toast, "told-more")

        run.check("a click on Show Less lands", true, try await press("toast.tellMeMore"))
        run.check(
          "the toast folds and stays up",
          "Tell Me More",
          try await run.settled("Tell Me More", moreLabel)
        )
        run.check("a click on Tell Me More again lands", true, try await press("toast.tellMeMore"))
        run.check(
          "the toast opens again",
          "Show Less",
          try await run.settled("Show Less", moreLabel)
        )
        let toldMore = try await control.journal("events").filter {
          $0["kind"] == "feedback" && ($0["detail"] ?? "").hasPrefix("Tell me more")
        }
        run.check("Tell Me More is recorded once", 1, toldMore.count)

        run.check("a click on Close lands", true, try await press("toast.close"))
        run.check("Close takes the toast down", true, try await toastUp(false))
        run.check(
          "Close records nothing over the answer",
          "tellMeMore",
          try await run.feedback(of: suggestion)
        )

        try await showLast()
        run.check("a click on Not Now lands", true, try await press("toast.notNow"))
        run.check("Not Now is recorded", "notNow", try await recorded(suggestion, "notNow"))
        run.check("Not Now takes the toast down", true, try await toastUp(false))
        run.check(
          "Not Now snoozes this kind of suggestion in TextEdit",
          1,
          try await rulesForTextEdit("mentor.snoozes")
        )
        run.check(
          "a note in the toast's place says how long that kind is quiet",
          true,
          try await noteText().contains("suggestions in TextEdit are quiet until")
        )

        let beforeShowLast = try await control.waitEvent(
          "feedback",
          matching: ["feedback": "notNow"]
        )
        try await showLast()
        let asked = try await announced(beforeShowLast?.sequence, "high")
        run.check(
          "VoiceOver hears the suggestion brought back on request at once",
          true,
          asked.hasPrefix("Athina, ") && !asked.contains("Answer it from the Athina menu.")
        )
        run.check("a click on Never for This lands", true, try await press("toast.never"))
        run.check("Never for This is recorded", "never", try await recorded(suggestion, "never"))
        run.check("Never for This takes the toast down", true, try await toastUp(false))
        run.check(
          "Never for This stops this kind of suggestion in TextEdit",
          1,
          try await rulesForTextEdit("mentor.neverRules")
        )
        run.check(
          "a note in the toast's place says that kind is off, and where to turn it back on",
          true,
          try await noteText().contains(
            "suggestions in TextEdit are off. Turn them back on in Mentoring settings."
          )
        )

        // Well away from the toast, at the top right of the main display, and from the menu bar
        // item a hermetic run does not have.
        try await showLast()
        run.check(
          "a click outside Athina's windows reaches the toast",
          true,
          try await control.outsideClick(x: 40, y: 400)["heard"]?.bool
        )
        run.check(
          "a click outside Athina's windows takes the toast down",
          true,
          try await toastUp(false)
        )
        run.check(
          "the answer stands after the click outside",
          "never",
          try await run.feedback(of: suggestion)
        )
      }
    }
  }
#endif
