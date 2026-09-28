import Foundation

/// The person's answer to the consent window: whether Athina may watch the
/// screen and send what it reads to Anthropic (docs/privacy.md "Consent").
///
/// Nothing is sensed and nothing is sent until the answer is Allow to the
/// current disclosure: `SensingMode.resolve` keeps the pipeline in
/// `waitingForConsent`, and `MentorScheduler` holds every call. The answer is
/// kept in `settings.json`, so it is the person's own record, withdrawn in
/// Settings > Privacy as easily as it was given.
public struct Consent: Codable, Equatable, Sendable {
  /// What the person chose in the consent window.
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

  /// The version of what the consent window discloses.
  ///
  /// Bump it when what leaves the Mac, who receives it, or what the journal
  /// keeps changes in a way the person would want to hear about: an Allow
  /// given to an older disclosure no longer counts, and the window asks
  /// again.
  public static let disclosureVersion = 1

  /// The privacy policy the consent window and Settings > Privacy both link
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
