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
