import Foundation
import Testing

@testable import AthinaCore

@Suite struct UserFacingTests {
  /// Every error a call can fail with, as `ClaudeClientError` has them.
  static let errors: [ClaudeClientError] = [
    .api(status: 401, type: "authentication_error", message: "invalid x-api-key"),
    .api(status: 403, type: "permission_error", message: "not allowed"),
    .api(status: 404, type: "not_found_error", message: "model: claude-nope"),
    .api(status: 413, type: "request_too_large", message: "too large"),
    .api(status: 429, type: "rate_limit_error", message: "slow down"),
    .api(status: 529, type: "overloaded_error", message: "Overloaded"),
    .api(status: 500, type: "api_error", message: "Internal server error"),
    .api(
      status: 400,
      type: "invalid_request_error",
      message: "Your credit balance is too low to access the Anthropic API."
    ),
    .api(status: 400, type: "invalid_request_error", message: "max_tokens: too large"),
    .transport("The Internet connection appears to be offline."),
    .badResponse("no content"),
    .replay("no fixture for this request"),
    .notSent("paused"),
  ]

  @Test func noSentenceRepeatsTheCodesOwnWords() {
    for error in Self.errors {
      let sentence = UserFacing.sentence(for: error)
      #expect(!sentence.contains("HTTP"), "\(sentence)")
      #expect(!sentence.contains("_error"), "\(sentence)")
      #expect(sentence.hasSuffix("."), "\(sentence)")
    }
  }

  @Test func eachFailureSaysWhatItMeansAndWhatToDo() {
    #expect(
      UserFacing.sentence(for: Self.errors[0])
        == """
        Anthropic did not accept this API key. Check it in the Anthropic Console and paste it \
        again.
        """
    )
    #expect(
      UserFacing.sentence(for: .transport("offline"))
        == "Athina could not reach Anthropic. Check the internet connection and try again."
    )
    #expect(UserFacing.sentence(for: Self.errors[7]).contains("run out of credit"))
    #expect(UserFacing.sentence(for: Self.errors[8]) == "Anthropic refused the request.")
    #expect(UserFacing.sentence(for: Self.errors[5]).contains("busy"))
  }

  /// A follow-up journals `description`; reading it back gives the same
  /// sentence as the error itself, so the toast and Test Connection agree.
  @Test func aJournaledCallErrorReadsBackAsItsSentence() {
    for error in Self.errors {
      #expect(UserFacing.clientError(from: error.description) == error)
      #expect(UserFacing.followUpError(error.description) == UserFacing.sentence(for: error))
    }
  }

  @Test func aJournaledHoldReadsBackAsItsSentence() {
    let holds: [MentorScheduler.Hold] = [
      .noConsent, .disabled, .noAPIKey, .paused, .idle, .excludedApp, .waitingForPermissions,
      .notSensing, .callInFlight, .noContextsDeclared,
    ]
    for hold in holds {
      #expect(UserFacing.followUpError(hold.label) == UserFacing.sentence(for: hold))
      #expect(UserFacing.sentence(for: hold).hasPrefix("Athina did not ask"))
    }
    let until = Date(timeIntervalSince1970: 1_790_000_000)
    let capped = UserFacing.followUpError(MentorScheduler.Hold.spendCapReached(until: until).label)
    #expect(capped.hasPrefix("Athina did not ask: this hour's spend limit is reached."))
    #expect(capped.hasSuffix("\(until.formatted(date: .omitted, time: .shortened))."))
  }

  @Test func theLoopsOwnFailuresAndUnknownTextReadBack() {
    #expect(
      UserFacing.followUpError("the API declined this request")
        == "Anthropic declined to answer this question."
    )
    #expect(
      UserFacing.followUpError("could not parse the follow-up reply")
        == "Athina could not read the answer. Try asking again."
    )
    #expect(UserFacing.followUpError("something new") == "something new")
  }

  @Test func notNowAndNeverSayWhatTheyDid() {
    #expect(
      UserFacing.confirmation(of: .notNow, category: .shortcut, appName: "Xcode", until: "3:23 PM")
        == "Shortcut suggestions in Xcode are quiet until 3:23 PM."
    )
    #expect(
      UserFacing.confirmation(of: .never, category: .risk, appName: "Xcode", until: nil)
        == "Risk suggestions in Xcode are off. Turn them back on in General settings."
    )
    for other in [SuggestionFeedback.tellMeMore, .expired, .expiredUnseen, .dismissed] {
      #expect(UserFacing.confirmation(of: other, category: .risk, appName: "X", until: nil) == nil)
    }
  }
}
