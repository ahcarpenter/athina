#if E2EAPI
  import Testing

  extension Scenarios {
    /// About Athina, from the menu, opens the About panel.
    ///
    /// The panel showed the macOS placeholder while the app had no icon at all. Athina has no
    /// app menu, so its own menu carries About. The panel reports no title of its own, so it is
    /// found as the window that was not open before. The menu item is chosen through its own
    /// action, as the open menu chooses it; that the mark keeps one width in the real menu bar is
    /// real-screen's, on the real screen.
    @Test func `about-panel`() async {
      await Run.scenario("about-panel") { run in
        let control = run.control
        let before = Set(try await control.windows().map(\.number))
        run.check(
          "the menu's About Athina is chosen",
          true,
          try await control.menu(press: "About Athina").ok
        )
        // The panel is built the first time it is asked for, so wait for it rather than guess
        // how long that takes.
        var about: AppWindow?
        for _ in 0..<20 {
          about = try await control.windows().first { !before.contains($0.number) }
          if about != nil { break }
          try await Task.sleep(for: .milliseconds(200))
        }
        run.check("About Athina opens a window", true, about != nil)
        guard about != nil else { return }
        let texts = try await control.find(.role("AXStaticText")).flatMap(\.texts)
        run.check("the panel shows the app's name", true, texts.contains("Athina"))
      }
    }
  }
#endif
