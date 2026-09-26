#if E2EAPI
  import Testing

  extension Scenarios {
    /// `--open settings:advanced` after a flag that takes no value still opens Settings on that
    /// pane.
    ///
    /// AppKit pairs each argument that starts with a dash with the one after it, so a flag that
    /// takes no value, such as `--allow-stale-fixtures`, paired with `--open` and left the pane's
    /// name over as a document to open, and an app asked to open a document at launch opens none
    /// of its windows.
    @Test func `launch-arguments`() async {
      await Run.scenario(
        "launch-arguments",
        arguments: ["--allow-stale-fixtures", "--open", "settings:advanced"]
      ) { run in
        run.check(
          "Settings opens on the Advanced pane",
          true,
          try await run.control.waitWindow("Advanced", timeout: 20)
        )
      }
    }
  }
#endif
