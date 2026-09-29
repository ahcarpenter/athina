import Testing

@testable import AthinaCore

@Suite struct PermissionActionTests {
  @Test func grantedNeedsNothing() {
    for permission in Permission.allCases {
      #expect(PermissionAction.for(permission, granted: true, undetermined: true) == .none)
      #expect(PermissionAction.for(permission, granted: true, undetermined: false) == .none)
    }
  }

  @Test func systemSettingsPermissionsAlwaysOpenTheirPane() {
    for permission in [Permission.screenRecording, .accessibility] {
      #expect(
        PermissionAction.for(permission, granted: false, undetermined: true) == .openSystemSettings
      )
      #expect(
        PermissionAction.for(permission, granted: false, undetermined: false) == .openSystemSettings
      )
    }
  }

  @Test func alertPermissionsAskOnceThenOpenTheirPane() {
    for permission in [Permission.microphone, .speechRecognition] {
      #expect(PermissionAction.for(permission, granted: false, undetermined: true) == .request)
      #expect(
        PermissionAction.for(permission, granted: false, undetermined: false) == .openSystemSettings
      )
    }
  }
}

@Suite struct SuggestionCategoryWarningTests {
  /// The kinds that warn of something going wrong are drawn as warnings, and
  /// none of them wears a checkmark that reads as all clear.
  @Test func warningsAreTheKindsThatSaySomethingGoesWrong() {
    let warnings = SuggestionCategory.allCases.filter(\.isWarning)
    #expect(Set(warnings) == [.correctness, .risk, .wontAchieveGoal, .unwantedSideEffect])
    #expect(!warnings.contains { $0.symbol.hasPrefix("checkmark") })
  }
}
