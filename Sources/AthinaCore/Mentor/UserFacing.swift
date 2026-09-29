import Foundation

/// What Athina says to a person about a failure or a hold, in its own words
/// rather than the code's.
///
/// The code's own text (`ClaudeClientError.description`, `Hold.label`) stays
/// in the call log, the debug panel and the journal, where a follow-up's
/// error also reaches the model's history of the exchange; these sentences
/// are only what Test Connection, the toast and the Suggestions window show
/// and VoiceOver reads, with the code's text kept as the tooltip. Pure, so
/// every mapping is proven on values.
public enum UserFacing {
  /// What a failed call means for the person, and what they can do about it.
  public static func sentence(for error: ClaudeClientError) -> String {
    switch error {
    case .api(let status, let type, let message):
      apiSentence(status: status, type: type, message: message)
    case .transport:
      "Athina could not reach Anthropic. Check the internet connection and try again."
    case .badResponse:
      "Anthropic's answer could not be read. Try again."
    case .replay:
      "There is no recorded answer to replay for this call."
    case .notSent(let reason):
      "Athina did not send the call, since \(reason)."
    }
  }

  /// Why a question was not asked, when a hold kept it from the model.
  public static func sentence(for hold: MentorScheduler.Hold) -> String {
    switch hold {
    case .noConsent:
      """
      Athina did not ask: it is not allowed to watch and send. Choose Allow Watching in the \
      Athina menu.
      """
    case .disabled:
      "Athina did not ask: suggestions are off in General settings."
    case .noAPIKey:
      "Athina did not ask: there is no API key. Add one in Models settings."
    case .paused:
      "Athina did not ask: it is paused."
    case .idle:
      "Athina did not ask: it is idle."
    case .excludedApp:
      "Athina did not ask: the app in front is excluded."
    case .waitingForPermissions:
      "Athina did not ask: it is waiting for permissions."
    case .notSensing:
      "Athina did not ask: it is not watching right now."
    case .callInFlight:
      "Athina did not ask: another call was still in flight."
    case .spendCapReached(let until):
      """
      Athina did not ask: this hour's spend limit is reached. It can ask again at \
      \(until.formatted(date: .omitted, time: .shortened)).
      """
    case .noContextsDeclared:
      "Athina did not ask: it mentors only inside your contexts, and none is declared."
    case .notAChangeMoment, .stale, .tooSoon, .nearIdentical:
      "Athina did not ask this time. Try again in a moment."
    }
  }

  /// A follow-up's journaled error, which is a hold's label or a call's
  /// error text (`MentorLoop`), as the person reads it.
  ///
  /// Text this cannot place is shown as it is.
  public static func followUpError(_ raw: String) -> String {
    if let hold = holdsByLabel[raw] { return sentence(for: hold) }
    if raw.hasPrefix(spendCapPrefix) {
      return "Athina did not ask: this hour's spend limit is reached. It can ask again at "
        + String(raw.dropFirst(spendCapPrefix.count)) + "."
    }
    if let error = clientError(from: raw) { return sentence(for: error) }
    switch raw {
    case "the API declined this request":
      return "Anthropic declined to answer this question."
    case "the follow-up reply had an empty answer", "could not parse the follow-up reply":
      return "Athina could not read the answer. Try asking again."
    default:
      return raw
    }
  }

  /// The line that confirms Not Now or Never for This, saying what it did and
  /// until when, so its consequence is never only in a tooltip.
  ///
  /// - Parameters:
  ///   - feedback: The answer; only Not Now and Never for This have a line.
  ///   - category: The kind of suggestion answered.
  ///   - appName: The app it was about.
  ///   - until: When Not Now's quiet ends, as the person's clock shows it.
  /// - Returns: The line, or nil for an answer that changes nothing.
  public static func confirmation(
    of feedback: SuggestionFeedback,
    category: SuggestionCategory,
    appName: String,
    until: String?
  ) -> String? {
    let kind = "\(category.label) suggestions in \(appName)"
    switch feedback {
    case .notNow:
      return until.map { "\(kind) are quiet until \($0)." } ?? "\(kind) are quiet for a while."
    case .never:
      return "\(kind) are off. Turn them back on in General settings."
    case .tellMeMore, .expired, .expiredUnseen, .dismissed:
      return nil
    }
  }

  // MARK: - Reading journaled text back

  /// What `Hold.label` writes for each hold with nothing varying in it.
  private static let holdsByLabel: [String: MentorScheduler.Hold] = Dictionary(
    uniqueKeysWithValues: [
      MentorScheduler.Hold.noConsent, .disabled, .noAPIKey, .paused, .idle, .excludedApp,
      .waitingForPermissions, .notSensing, .callInFlight, .noContextsDeclared,
    ].map { ($0.label, $0) }
  )

  private static let spendCapPrefix = "spend cap reached until "

  /// The error `ClaudeClientError.description` wrote, read back.
  static func clientError(from raw: String) -> ClaudeClientError? {
    for (prefix, make) in [
      ("network: ", ClaudeClientError.transport),
      ("bad response: ", ClaudeClientError.badResponse),
      ("replay: ", ClaudeClientError.replay),
      ("not sent: ", ClaudeClientError.notSent),
    ] where raw.hasPrefix(prefix) {
      return make(String(raw.dropFirst(prefix.count)))
    }
    // "type (HTTP status): message"
    guard let open = raw.range(of: " (HTTP "),
      let close = raw.range(of: "): ", range: open.upperBound..<raw.endIndex),
      let status = Int(raw[open.upperBound..<close.lowerBound])
    else { return nil }
    return .api(
      status: status,
      type: String(raw[..<open.lowerBound]),
      message: String(raw[close.upperBound...])
    )
  }

  private static func apiSentence(status: Int, type: String, message: String) -> String {
    switch (status, type) {
    case (401, _), (_, "authentication_error"):
      return
        """
        Anthropic did not accept this API key. Check it in the Anthropic Console and paste it \
        again.
        """
    case (403, _), (_, "permission_error"):
      return
        "This API key is not allowed to do that. Check its permissions in the Anthropic Console."
    case (404, _), (_, "not_found_error"):
      return
        """
        Anthropic does not offer the chosen model to this API key. Choose another in Models \
        settings.
        """
    case (413, _), (_, "request_too_large"):
      return "The request was too large for Anthropic to accept."
    case (429, _), (_, "rate_limit_error"):
      return "Anthropic is limiting requests from this API key. Try again in a minute."
    case (529, _), (_, "overloaded_error"):
      return "Anthropic is busy right now. Try again in a minute."
    case (400, _) where message.localizedCaseInsensitiveContains("credit balance"):
      return "The Anthropic account has run out of credit. Add credit in the Anthropic Console."
    case (500..., _):
      return "Anthropic had a problem answering. Try again in a minute."
    default:
      return "Anthropic refused the request."
    }
  }
}
