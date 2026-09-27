#if E2EAPI
  import Foundation
  import Testing

  extension Scenarios {
    /// Every link from one Settings pane's text to another shows as a link rather than Markdown,
    /// and one below the fold is out of reach until scrolled to.
    ///
    /// Settings text names another pane by linking to it: the Contexts footer to Privacy, and the
    /// Understanding footer in Models to Journal. Each link has to show as a link, to the pane it
    /// names, rather than as the Markdown it is built from. The Models footer sits below the
    /// fold, so a click on its link is refused as out of sight until the pane is scrolled to it.
    /// Each pane is read through Athina's own accessibility tree, and panes change with a click
    /// the app simulates on its own toolbar; whether a click on a link opens its pane is
    /// real-screen's, on the real screen.
    @Test func `settings-pane-text`() async {
      await Run.scenario("settings-pane-text", arguments: ["--open", "settings:contexts"]) { run in
        let control = run.control
        // Everything a pane shows, one line per element, kept with the evidence.
        let paneTexts = { (window: String, name: String) -> String in
          let texts = try await control.find(.everything(in: window)).flatMap(\.texts)
            .joined(separator: "\n")
          try (texts + "\n").write(
            to: run.evidence.appendingPathComponent("\(name)-texts.txt"),
            atomically: true,
            encoding: .utf8
          )
          return texts
        }

        guard try await control.waitWindow("Contexts", timeout: 20) else {
          throw AppProcess.Failure("Settings never opened on the Contexts pane")
        }
        let contexts = try await paneTexts("Contexts", "contexts")
        try await run.checkpoint("Contexts", "contexts")
        // Markdown that did not parse would show its brackets and the scheme.
        run.check(
          "the Contexts footer shows no raw link Markdown",
          false,
          contexts.contains("](athina-settings:")
        )
        run.check(
          "the Contexts footer shows its link to Privacy as a link",
          "AXLink",
          try await control.first(.identifier("athina-settings:privacy", in: "Contexts"))?.role
        )

        // Settings opens on the pane it last showed; the toolbar changes it. The toolbar's tabs
        // carry no identifier (docs/e2e.md "The control API"), so the tab is found by its label.
        run.check(
          "a click on the Models toolbar item lands",
          true,
          try await control.click(.label("Models", in: "Contexts")).ok
        )
        guard try await control.waitWindow("Models", timeout: 5) else {
          throw AppProcess.Failure("the Models pane never showed")
        }
        let models = try await paneTexts("Models", "models")
        let link = Target.identifier("athina-settings:journal", in: "Models")
        run.check(
          "the Models footer shows no raw link Markdown",
          false,
          models.contains("](athina-settings:")
        )
        run.check(
          "the Models footer shows its link to Journal as a link",
          "AXLink",
          try await control.first(link)?.role
        )

        run.check(
          "a click on the link below the fold is refused",
          "offscreen",
          try await control.click(link).refused
        )
        run.check("the pane scrolls to the link", true, try await control.scroll(link).ok)
        run.check(
          "scrolled into view, a click on the link lands",
          true,
          try await control.click(link).ok
        )
        try await run.checkpoint("Models", "models-footer")
      }
    }
  }
#endif
