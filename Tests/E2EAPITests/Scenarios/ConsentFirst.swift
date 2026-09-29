#if E2EAPI
  import Foundation
  import Testing

  extension Scenarios {
    /// With no consent recorded, the consent page comes first and nothing is sensed or sent
    /// until Allow; withdrawing in Settings > Privacy stops both at once.
    ///
    /// A first launch, and every install from before the consent window existed, starts with no
    /// Allow on record (docs/privacy.md "Consent"). The Setup window then opens on its consent
    /// page, titled "Athina and Your Privacy", ahead of the permissions page, and while it waits
    /// a window scripted in front is neither journaled nor sent, and the menu says Athina is not
    /// watching and offers Allow Watching…. Allow, clicked in the window, starts sensing and the
    /// mentor loop and, with every permission granted and no key needed in a replay, closes the
    /// window (`SetupFlow.afterAllow`), shown by the replay's first suggestion coming up;
    /// Withdraw Consent in Settings > Privacy then stops both at once, and
    /// the pane offers Review and Allow…. Every click is simulated inside Athina on the control
    /// its own accessibility tree names, and the journal is read through the app's named
    /// queries.
    @Test func `consent-first`() async {
      await Run.scenario("consent-first", consented: false) { run in
        let control = run.control
        let consentWindow = "Athina and Your Privacy"
        // Everything the journal holds about what the person did, and every model call: what
        // must not grow while there is no Allow.
        let activity = {
          let counts = try await control.journal("counts").first ?? [:]
          let switches = try await control.journal("events").filter {
            ["appSwitch", "windowSwitch", "excluded", "idleStart", "idleEnd"].contains(
              $0["kind"] ?? ""
            )
          }
          return
            "\(counts["observations"] ?? "?") observations, \(switches.count) switches, "
            + "\(counts["calls"] ?? "?") calls"
        }
        let menuTitles = { (name: String) -> [String] in
          let titles = try await control.menu().map { $0.separator ? "-" : $0.title }
          try (titles.joined(separator: "\n") + "\n")
            .write(
              to: run.evidence.appendingPathComponent("\(name)-menu-items.txt"),
              atomically: true,
              encoding: .utf8
            )
          return titles
        }
        let notWatching = "Not watching until you allow it"

        guard try await control.waitWindow(consentWindow, timeout: 20) else {
          throw AppProcess.Failure("the consent page never opened")
        }
        run.check("the consent page is open at launch", true, true)
        run.check(
          "no permissions page opens ahead of consent",
          true,
          try await control.waitWindow("Permissions", present: false, timeout: 0)
        )
        try await run.picture(consentWindow, "consent-window")
        run.check(
          "the consent page names Anthropic",
          true,
          try await control.find(.everything(in: consentWindow)).flatMap(\.texts)
            .contains { $0.contains("Anthropic") }
        )

        // Windows in front while the consent page waits unanswered.
        for document in ["reading-notes.txt", "cleanup-script.txt"] {
          let observed = try await run.observeDocument(document)
          run.check("\(document) in front before Allow is not kept", false, observed?.kept)
        }
        run.check(
          "the replay clock moves a minute on before Allow",
          true,
          try await control.advance(seconds: 60).ok
        )
        run.check(
          "nothing is sensed, journaled or sent before Allow",
          "0 observations, 0 switches, 0 calls",
          try await activity()
        )
        let before = try await menuTitles("before")
        run.check("the menu says Athina is not watching", true, before.contains(notWatching))
        run.check("the menu offers Allow Watching…", true, before.contains("Allow Watching…"))
        run.check(
          "the menu offers no talk-back set-up before Allow",
          false,
          before.contains("Set Up Talk Back…")
        )

        run.check(
          "the click on Allow lands",
          true,
          try await control.click(.identifier("consent.allow", in: consentWindow)).ok
        )
        run.check(
          "Allow is recorded",
          true,
          try await control.waitSetting("consent.answer", equals: .string("allowed")).ok
        )
        run.check(
          "Allow closes the consent page",
          true,
          try await control.waitWindow(consentWindow, present: false, timeout: 5)
        )
        let suggestion = try await run.scriptedToast()
        run.log("suggestion \(suggestion) came up after Allow")
        let after = try await menuTitles("after")
        run.check(
          "the menu drops Allow Watching… once allowed",
          false,
          after.contains("Allow Watching…")
        )
        run.check("the menu no longer says it is not watching", false, after.contains(notWatching))

        _ = try await control.menu(press: "Settings…")
        guard let settings = try await Self.firstSettingsPane(control) else {
          throw AppProcess.Failure("Settings never opened")
        }
        if settings != "Privacy" {
          run.check(
            "a click on the Privacy toolbar item lands",
            true,
            try await control.click(.label("Privacy", in: settings)).ok
          )
        }
        guard try await control.waitWindow("Privacy", timeout: 5) else {
          throw AppProcess.Failure("the Privacy pane never showed")
        }
        try await run.picture("Privacy", "privacy-allowed")
        run.check(
          "the click on Withdraw Consent lands",
          true,
          try await control.click(.identifier("privacy.withdrawConsent", in: "Privacy")).ok
        )
        run.check(
          "the withdrawal is recorded",
          true,
          try await control.waitSetting("consent.answer", equals: .string("declined")).ok
        )
        run.check(
          "the pane offers Review and Allow… once withdrawn",
          true,
          try await run.settled(true) {
            try await control.first(.identifier("privacy.reviewConsent", in: "Privacy")) != nil
          }
        )
        try await run.picture("Privacy", "privacy-withdrawn")

        let atWithdrawal = try await activity()
        run.log("journal at the withdrawal: \(atWithdrawal)")
        let observed = try await run.observeDocument("reading-notes.txt")
        run.check("a window in front after the withdrawal is not kept", false, observed?.kept)
        run.check(
          "the replay clock moves a minute on after the withdrawal",
          true,
          try await control.advance(seconds: 60).ok
        )
        run.check(
          "the withdrawal stops sensing and calling at once",
          atWithdrawal,
          try await activity()
        )
        let withdrawn = try await menuTitles("withdrawn")
        run.check(
          "the menu says Athina is not watching again",
          true,
          withdrawn.contains(notWatching)
        )
        run.check(
          "the consent page does not reopen on its own",
          true,
          try await control.waitWindow(consentWindow, present: false, timeout: 0)
        )
      }
    }

    /// The Settings pane that is open, found by its window title.
    private static func firstSettingsPane(_ control: Control) async throws -> String? {
      let panes = ["General", "Contexts", "Models", "Capture", "Journal", "Privacy", "Advanced"]
      for _ in 0..<50 {
        let titles = Set(try await control.windows().map(\.title))
        if let open = panes.first(where: titles.contains) { return open }
        try await Task.sleep(for: .milliseconds(200))
      }
      return nil
    }
  }
#endif
