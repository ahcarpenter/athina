import Foundation

/// The person's answer to the consent page: whether Athina may watch the
/// screen and send what it reads to one provider (docs/privacy.md "Consent").
///
/// Each provider has its own answer (`SensingSettings.consent(for:)`), since
/// each sends to a different company: Anthropic, OpenAI, or OpenCode.
/// Switching to a provider with no Allow asks again.
///
/// Nothing is sensed and nothing is sent until the answer is Allow to the
/// current disclosure: `SensingMode.resolve` keeps the pipeline in
/// `waitingForConsent`, and `MentorScheduler` holds every call. The answer is
/// kept in `settings.json`, so it is the person's own record, withdrawn in
/// Settings > Privacy as easily as it was given.
public struct Consent: Codable, Equatable, Sendable {
  /// What the person chose on the consent page.
  public enum Answer: String, Codable, Sendable {
    /// Allow: Athina may watch and send.
    case allowed
    /// Not Now, or a withdrawal in Settings > Privacy.
    case declined
  }

  /// What the person chose.
  public var answer: Answer
  /// When it was given.
  public var at: Date
  /// The disclosure it answered (`Consent.disclosureVersion`).
  public var disclosureVersion: Int

  /// An answer given at `at` to the disclosure `disclosureVersion`, the
  /// current one unless said.
  public init(answer: Answer, at: Date, disclosureVersion: Int = Consent.disclosureVersion) {
    self.answer = answer
    self.at = at
    self.disclosureVersion = disclosureVersion
  }

  /// The version of what the consent page discloses.
  ///
  /// Bump it when what leaves the Mac, who receives it, or what the journal
  /// keeps changes in a way the person would want to hear about: an Allow
  /// given to an older disclosure no longer counts, and the window asks
  /// again.
  public static let disclosureVersion = 1

  /// The privacy policy the consent page and Settings > Privacy both link
  /// to: docs/privacy.md on the repository's main branch.
  public static let privacyPolicyURL = URL(
    string: "https://github.com/getathina/athina/blob/main/docs/privacy.md"
  )!

  /// Whether this answer lets Athina watch and send: Allow, given to the
  /// current disclosure or a later one.
  public var grants: Bool {
    answer == .allowed && disclosureVersion >= Consent.disclosureVersion
  }

  /// Whether `consent`, the stored answer or nil when none was ever given,
  /// lets Athina watch and send.
  public static func grants(_ consent: Consent?) -> Bool {
    consent?.grants ?? false
  }
}

/// What the consent page says about where screen content goes, for the
/// provider it asks about.
///
/// The rest of the window is the same for every provider: what is sent, what
/// stays on this Mac, and how to tell Athina is watching.
public struct ConsentDisclosure: Equatable, Sendable {
  /// The window's heading.
  public var title: String
  /// The sentence under the heading.
  public var summary: String
  /// Where it goes, under whose terms, and what never leaves.
  public var destination: String
  /// The heading of the box that lists what is sent.
  public var sentHeading: String

  /// The disclosure for `provider`.
  public init(for provider: ModelProvider) {
    let never =
      """
      No keystrokes are sent, and nothing from password fields or from excluded apps such as \
      password managers.
      """
    sentHeading = "What is sent to \(provider.name)"
    switch provider {
    case .anthropic:
      title = "Athina reads your screen and asks Claude about it"
      summary =
        """
        To mentor you, Athina watches what you do on this Mac and sends some of what it sees to \
        Anthropic, the company that makes Claude. Nothing is captured or sent until you choose \
        Allow.
        """
      destination =
        """
        It goes only to api.anthropic.com, with the API key you add in Models settings, and only \
        while the mentor is on. Anthropic handles it under the terms of your API account. \(never)
        """
    case .openAI:
      title = "Athina reads your screen and asks GPT about it"
      summary =
        """
        To mentor you, Athina watches what you do on this Mac and sends some of what it sees to \
        OpenAI, the company that makes ChatGPT and Codex. Nothing is captured or sent until you \
        choose Allow.
        """
      destination =
        """
        It goes only to api.openai.com, with the OpenAI API key you add in Models settings, and \
        only while the mentor is on. OpenAI handles it under the terms of your API account, and \
        Athina asks it not to store the replies. \(never)
        """
    case .openCode:
      title = "Athina reads your screen and asks OpenCode about it"
      summary =
        """
        To mentor you, Athina watches what you do on this Mac and sends some of what it sees to \
        OpenCode, the model service run by Anomaly. Nothing is captured or sent until you choose \
        Allow.
        """
      destination =
        """
        It goes only to opencode.ai, with the OpenCode API key you add in Models settings, and \
        only while the mentor is on. OpenCode passes it to Anthropic or OpenAI, whichever \
        makes the model you choose, and that company keeps it for 30 days under its own data \
        policy. \(never)
        """
    }
  }
}
