#if E2EAPI
  import Testing

  extension Scenarios {
    /// A control inside a Settings sheet is clicked in the sheet, and one under the sheet is
    /// refused as covered while it is up.
    ///
    /// A sheet is a window of its own, attached to the window it covers, though it shows in that
    /// window's accessibility tree. Settings > Contexts' Add Context… brings up the New Context
    /// sheet: while it is up, a click on Add Context… under it is refused as covered, a name typed
    /// after a click on the sheet's Name field lands in that field, and the sheet's own Cancel is
    /// clicked in the sheet and takes it down, adding no context, after which Add Context… is in
    /// reach again. Every click is simulated inside Athina, through AppKit's own event path, on
    /// the control its own accessibility tree names.
    @Test func `settings-sheet`() async {
      await Run.scenario("settings-sheet", arguments: ["--open", "settings:contexts"]) { run in
        let control = run.control
        let add = Target.identifier("contexts.addContext", in: "Contexts")
        let name = Target.identifier("contextEditor.name", in: "Contexts")
        let sheets = { try await control.find(.role("AXSheet", in: "Contexts")).count }
        let nameValue = { try await control.first(name)?.value ?? "" }

        guard try await control.waitWindow("Contexts", timeout: 20) else {
          throw AppProcess.Failure("Settings never opened on the Contexts pane")
        }
        run.check("no sheet is up at first", 0, try await sheets())
        run.check("a click on Add Context… lands", true, try await control.click(add).ok)
        run.check("the New Context sheet comes up", 1, try await run.settled(1, sheets))
        try await run.checkpoint("Contexts", "sheet-up")

        run.check(
          "with the sheet up, a click on Add Context… under it is refused",
          "covered",
          try await control.click(add).refused
        )
        run.check("a click on the sheet's Name field lands", true, try await control.click(name).ok)
        run.check(
          "a name is typed into the sheet",
          true,
          try await control.type("deep work", in: "Contexts").ok
        )
        run.check(
          "the sheet's Name field holds it",
          "deep work",
          try await run.settled("deep work", nameValue)
        )
        try await run.checkpoint("Contexts", "sheet-typed")
        run.check(
          "a click on the sheet's own Cancel lands",
          true,
          try await control.click(.identifier("contextEditor.cancel", in: "Contexts")).ok
        )
        run.check("the sheet goes", 0, try await run.settled(0, sheets))
        run.check(
          "Cancel adds no context",
          0,
          try await control.setting("mentor.contexts").array?.count
        )
        run.check(
          "with the sheet gone, a click on Add Context… lands again",
          true,
          try await control.click(add).ok
        )
        run.check("the New Context sheet comes up again", 1, try await run.settled(1, sheets))
      }
    }
  }
#endif
