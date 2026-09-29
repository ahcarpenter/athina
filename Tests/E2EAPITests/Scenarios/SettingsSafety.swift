#if E2EAPI
  import AthinaControlProtocol
  import Foundation
  import Testing

  extension Scenarios {
    /// A context or an excluded app removed in Settings comes back with Undo, and VoiceOver
    /// hears both.
    ///
    /// Settings > Mentoring: a context is added through the New Context sheet, its Remove button
    /// removes it, a row under the list offers Undo, and Undo puts it back as it was. Settings >
    /// Privacy: Keychain Access's Remove button takes it off the excluded apps, and Undo puts it
    /// back at its own place in the list, ahead of the rest. Each removal and each Undo is
    /// announced. A Remove button is destructive, so it is pressed through accessibility rather
    /// than clicked, as AppKit keeps a click into a window that is not in front from destroying
    /// anything (docs/e2e.md "The control API").
    @Test func `settings-undo`() async {
      await Run.scenario("settings-undo", arguments: ["--open", "settings:mentoring"]) { run in
        let control = run.control
        let name = Target.identifier("contextEditor.name", in: "Mentoring")
        let contextNames = {
          try await control.setting("mentor.contexts").array?.compactMap {
            $0[path: "name"]?.string
          }
            ?? []
        }
        let excluded = {
          try await control.setting("excludedBundleIDs").array?.compactMap(\.string) ?? []
        }
        let announced = { (text: String) in
          try await control.waitEvent("announcement", matching: ["text": text]) != nil
        }

        guard try await control.waitWindow("Mentoring", timeout: 20) else {
          throw AppProcess.Failure("Settings never opened on the Mentoring pane")
        }
        guard try await control.click(.identifier("contexts.addContext", in: "Mentoring")).ok,
          try await control.click(name).ok,
          try await control.type("deep work\r", in: "Mentoring").ok
        else { throw AppProcess.Failure("no context could be added") }
        run.check(
          "a context is added to remove",
          ["deep work"],
          try await run.settled(["deep work"], contextNames)
        )

        run.check(
          "the context's Remove button is pressed",
          true,
          try await control.press(.label("Remove deep work", in: "Mentoring")).ok
        )
        run.check("the context is removed", [], try await run.settled([], contextNames))
        run.check("VoiceOver hears the removal", true, try await announced("Removed deep work"))
        try await run.picture("Mentoring", "context-removed")
        let undoContext = Target.identifier("contexts.undoRemove", in: "Mentoring")
        run.check("a row offers Undo", true, try await control.first(undoContext) != nil)
        run.check("a click on Undo lands", true, try await control.click(undoContext).ok)
        run.check(
          "Undo puts the context back",
          ["deep work"],
          try await run.settled(["deep work"], contextNames)
        )
        run.check("VoiceOver hears it come back", true, try await announced("Restored deep work"))
        run.check(
          "the Undo row goes once it is used",
          true,
          try await run.settled(true) { try await control.first(undoContext) == nil }
        )

        guard try await control.click(.label("Privacy", in: "Mentoring")).ok,
          try await control.waitWindow("Privacy", timeout: 5)
        else { throw AppProcess.Failure("the Privacy pane never showed") }
        let before = try await excluded()
        run.check(
          "Keychain Access is excluded first",
          "com.apple.keychainaccess",
          before.first
        )
        let remove = Target.label("Remove Keychain Access", in: "Privacy")
        _ = try await control.scroll(remove)
        run.check(
          "Keychain Access's Remove button is pressed",
          true,
          try await control.press(remove).ok
        )
        run.check(
          "Keychain Access is no longer excluded",
          false,
          try await run.settled(false) { try await excluded().contains("com.apple.keychainaccess") }
        )
        run.check(
          "VoiceOver hears the removal",
          true,
          try await announced("Removed Keychain Access")
        )
        let undoApp = Target.identifier("privacy.undoRemoveApp", in: "Privacy")
        _ = try await control.scroll(undoApp)
        try await run.picture("Privacy", "app-removed")
        run.check("a click on Undo lands", true, try await control.click(undoApp).ok)
        run.check(
          "Undo puts Keychain Access back at its place",
          before,
          try await run.settled(before, excluded)
        )
      }
    }

    /// A number typed outside a Settings row's range is set to the nearest allowed one as the
    /// edit ends, and the row says so; a replayed Test Connection's result is announced.
    ///
    /// Settings > Models' Spend at most takes $5,000 typed and ended with Tab: the setting
    /// becomes $1,000.00, the most it can be, and the row and VoiceOver both say it was set to
    /// that and what the range is, where before the number changed out of sight. $0 settles at
    /// $0.05 the same way, and an amount inside the range is taken as typed, with no correction.
    /// The row's help names the range from the start. Test Connection, which a replay answers
    /// from its recording, says what it found in the row and to VoiceOver.
    @Test func `settings-corrections`() async {
      await Run.scenario("settings-corrections", arguments: ["--open", "settings:models"]) { run in
        let control = run.control
        let field = Target.identifier("models.spendCap", in: "Models")
        let cap = { try await control.setting("mentor.hourlySpendCap").number }
        let texts = {
          try await control.find(.everything(in: "Models")).flatMap(\.texts).joined(separator: "\n")
        }
        // Clicks into the field, selects what it holds, and types over it, ending the edit with
        // Tab the way a person moves on.
        let typeAmount = { (typed: String) in
          guard try await control.scroll(field).ok, try await control.click(field).ok,
            try await control.type("a", holding: [.command], in: "Models").ok
          else { return false }
          return try await control.type(typed + "\t", in: "Models").ok
        }
        let correction = { (to: String) in
          "Set to \(to), since it can be from $0.05 to $1,000.00."
        }

        guard try await control.waitWindow("Models", timeout: 20) else {
          throw AppProcess.Failure("Settings never opened on the Models pane")
        }
        run.check(
          "the row's help names its range",
          true,
          try await texts().contains("From $0.05 to $1,000.00.")
        )

        run.check("$5,000 is typed into Spend at most", true, try await typeAmount("5000"))
        run.check("the setting is the most it can be", 1000, try await run.settled(1000, cap))
        run.check(
          "the row says what it was set to and the range",
          true,
          try await run.settled(true) { try await texts().contains(correction("$1,000.00")) }
        )
        run.check(
          "VoiceOver hears the correction",
          true,
          try await control.waitEvent("announcement", matching: ["text": correction("$1,000.00")])
            != nil
        )
        try await run.picture("Models", "corrected")

        run.check("$0 is typed into Spend at most", true, try await typeAmount("0"))
        run.check("the setting is the least it can be", 0.05, try await run.settled(0.05, cap))
        run.check(
          "the row says what it was set to",
          true,
          try await run.settled(true) { try await texts().contains(correction("$0.05")) }
        )
        let lastCorrection = try await control.waitEvent(
          "announcement",
          matching: ["text": correction("$0.05")]
        )

        run.check("$3 is typed into Spend at most", true, try await typeAmount("3"))
        run.check("an amount in range is taken as typed", 3, try await run.settled(3, cap))
        run.check(
          "no correction is shown for it",
          false,
          try await run.settled(false) { try await texts().contains("Set to ") }
        )

        let test = Target.role("AXButton", label: "Test Connection", in: "Models")
        _ = try await control.scroll(test)
        run.check("a click on Test Connection lands", true, try await control.click(test).ok)
        let result = try await control.waitEvent(
          "announcement",
          after: lastCorrection?.sequence,
          matching: ["priority": "medium"]
        )
        run.check(
          "VoiceOver hears what the test found",
          true,
          result?.event["text"]?.hasPrefix("Replayed: ") == true
            || result?.event["text"]?.contains("recorded") == true
        )
      }
    }
  }
#endif
