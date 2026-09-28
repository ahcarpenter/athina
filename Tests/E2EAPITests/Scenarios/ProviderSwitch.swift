#if E2EAPI
  import Foundation
  import Testing

  extension Scenarios {
    /// Choosing another model provider in Settings > Models asks for consent naming that
    /// company before anything more is sensed or sent, and switching back to one already
    /// allowed asks nothing.
    ///
    /// Each provider sends to a different company, so each needs its own Allow
    /// (docs/privacy.md "Consent"). With Anthropic allowed, as the seed has it, choosing OpenAI
    /// in the Models pane's provider pop-up records the choice, holds sensing and every call, and
    /// opens the consent window naming OpenAI; Allow records the answer for OpenAI alone and the
    /// replay carries on, its calls journaled as going by OpenAI. Choosing Anthropic again needs
    /// no new answer. A pop-up's item is chosen through its menu's own action (`choose`), since
    /// opening the menu would hold a hermetic run; the click on Allow is simulated inside Athina
    /// on the control its own accessibility tree names.
    @Test func `provider-switch`() async {
      await Run.scenario("provider-switch", arguments: ["--open", "settings:models"]) { run in
        let control = run.control
        let consentWindow = "Athina and Your Privacy"
        let paneTexts = { (name: String) -> [String] in
          let texts = try await control.find(.everything(in: "Models")).flatMap(\.texts)
          try (texts.joined(separator: "\n") + "\n").write(
            to: run.evidence.appendingPathComponent("\(name)-texts.txt"),
            atomically: true,
            encoding: .utf8
          )
          return texts
        }

        guard try await control.waitWindow("Models", timeout: 20) else {
          throw AppProcess.Failure("Settings never opened on the Models pane")
        }
        _ = try await paneTexts("anthropic")
        run.check(
          "the provider pop-up shows Anthropic",
          "Anthropic",
          try await control.first(.identifier("models.provider", in: "Models"))?.value
        )
        run.check(
          "Anthropic is the provider at launch",
          true,
          try await control.waitSetting("mentor.provider", equals: .string("anthropic")).ok
        )
        try await run.picture("Models", "models-anthropic")

        run.check(
          "OpenAI is chosen in the provider pop-up",
          true,
          try await control.choose(.identifier("models.provider", in: "Models"), item: "OpenAI").ok
        )
        run.check(
          "OpenAI is recorded as the provider",
          true,
          try await control.waitSetting("mentor.provider", equals: .string("openai")).ok
        )
        guard try await control.waitWindow(consentWindow, timeout: 10) else {
          throw AppProcess.Failure("the consent window never opened for OpenAI")
        }
        let consent = try await control.find(.everything(in: consentWindow)).flatMap(\.texts)
        run.check(
          "the consent window names OpenAI and its host",
          true,
          consent.contains { $0.contains("OpenAI") }
            && consent.contains { $0.contains("api.openai.com") }
        )
        try await run.picture(consentWindow, "consent-openai")
        let menu = try await control.menu().map(\.title)
        run.check(
          "the menu says Athina is not watching until OpenAI is allowed",
          true,
          menu.contains("Not watching until you allow it")
        )
        let calls = try await control.journal("counts").first?["calls"]

        run.check(
          "the click on Allow lands",
          true,
          try await control.click(.identifier("consent.allow", in: consentWindow)).ok
        )
        run.check(
          "Allow is recorded for OpenAI",
          true,
          try await control.waitSetting(
            "providerConsents.openai.answer",
            equals: .string("allowed")
          ).ok
        )
        run.check(
          "Anthropic's answer is kept as it was",
          true,
          try await control.waitSetting("consent.answer", equals: .string("allowed")).ok
        )
        run.check(
          "Allow closes the consent window",
          true,
          try await control.waitWindow(consentWindow, present: false, timeout: 5)
        )
        let suggestion = try await run.scriptedToast()
        run.log("suggestion \(suggestion) came up after OpenAI was allowed")
        let rows = try await control.journal("calls")
        let since = rows.dropFirst(Int(calls ?? "0") ?? 0)
        run.check("calls were made after Allow", true, !since.isEmpty)
        run.check(
          "every call after Allow went by OpenAI",
          true,
          since.allSatisfy { $0["provider"] == "openai" }
        )
        try await run.picture("Models", "models-openai")

        run.check(
          "Anthropic is chosen in the provider pop-up",
          true,
          try await control.choose(.identifier("models.provider", in: "Models"), item: "Anthropic")
            .ok
        )
        run.check(
          "Anthropic is recorded as the provider again",
          true,
          try await control.waitSetting("mentor.provider", equals: .string("anthropic")).ok
        )
        run.check(
          "switching back to an allowed provider asks nothing",
          false,
          try await control.waitWindow(consentWindow, timeout: 3)
        )
      }
    }
  }
#endif
