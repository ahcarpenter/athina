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

  @Test(arguments: ModelProvider.allCases)
  func noSentenceRepeatsTheCodesOwnWords(provider: ModelProvider) {
    for error in Self.errors {
      let sentence = UserFacing.sentence(for: error, provider: provider)
      #expect(!sentence.contains("HTTP"), "\(sentence)")
      #expect(!sentence.contains("_error"), "\(sentence)")
      #expect(sentence.hasSuffix("."), "\(sentence)")
    }
  }

  /// Every sentence about a call names the provider it went to, never
  /// another.
  @Test(arguments: ModelProvider.allCases)
  func aCallsSentenceNamesOnlyItsProvider(provider: ModelProvider) {
    let others = ModelProvider.allCases.filter { $0 != provider }
    for error in Self.errors {
      let sentence = UserFacing.sentence(for: error, provider: provider)
      if case .api = error { #expect(sentence.contains(provider.name), "\(sentence)") }
      for other in others {
        #expect(!sentence.contains(other.name), "\(sentence)")
      }
    }
  }

  @Test func eachFailureSaysWhatItMeansAndWhatToDo() {
    #expect(
      UserFacing.sentence(for: Self.errors[0], provider: .anthropic)
        == """
        Anthropic did not accept this API key. Check it in your Anthropic account and paste it \
        again.
        """
    )
    #expect(
      UserFacing.sentence(for: Self.errors[0], provider: .openAI)
        == """
        OpenAI did not accept this API key. Check it in your OpenAI account and paste it again.
        """
    )
    #expect(
      UserFacing.sentence(for: .transport("offline"), provider: .openCode)
        == "Athina could not reach OpenCode. Check the internet connection and try again."
    )
    #expect(
      UserFacing.sentence(for: Self.errors[7], provider: .anthropic).contains("run out of credit")
    )
    #expect(
      UserFacing.sentence(for: Self.errors[8], provider: .anthropic)
        == "Anthropic refused the request."
    )
    #expect(UserFacing.sentence(for: Self.errors[5], provider: .openAI).contains("busy"))
  }

  /// A follow-up journals `description`; reading it back gives the same
  /// sentence as the error itself, so the toast and Test Connection agree.
  @Test(arguments: ModelProvider.allCases)
  func aJournaledCallErrorReadsBackAsItsSentence(provider: ModelProvider) {
    for error in Self.errors {
      #expect(UserFacing.clientError(from: error.description) == error)
      #expect(
        UserFacing.followUpError(error.description, provider: provider)
          == UserFacing.sentence(for: error, provider: provider)
      )
    }
  }

  @Test func aJournaledHoldReadsBackAsItsSentence() {
    let holds: [MentorScheduler.Hold] = [
      .noConsent, .disabled, .noAPIKey, .paused, .idle, .excludedApp, .waitingForPermissions,
      .notSensing, .callInFlight, .noContextsDeclared,
    ]
    for hold in holds {
      #expect(
        UserFacing.followUpError(hold.label, provider: .openAI) == UserFacing.sentence(for: hold)
      )
      #expect(UserFacing.sentence(for: hold).hasPrefix("Athina did not ask"))
    }
    let until = Date(timeIntervalSince1970: 1_790_000_000)
    let capped = UserFacing.followUpError(
      MentorScheduler.Hold.spendCapReached(until: until).label,
      provider: .anthropic
    )
    #expect(capped.hasPrefix("Athina did not ask: this hour's spend limit is reached."))
    #expect(capped.hasSuffix("\(until.formatted(date: .omitted, time: .shortened))."))
  }

  @Test func theLoopsOwnFailuresAndUnknownTextReadBack() {
    #expect(
      UserFacing.followUpError("the API declined this request", provider: .anthropic)
        == "Anthropic declined to answer this question."
    )
    #expect(
      UserFacing.followUpError("the API declined this request", provider: .openCode)
        == "OpenCode declined to answer this question."
    )
    #expect(
      UserFacing.followUpError("could not parse the follow-up reply", provider: .openAI)
        == "Athina could not read the answer. Try asking again."
    )
    #expect(UserFacing.followUpError("something new", provider: .anthropic) == "something new")
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
