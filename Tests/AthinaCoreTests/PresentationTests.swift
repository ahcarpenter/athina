import Testing
@testable import AthinaCore

@Suite struct HotKeyAccessibilityNameTests {
    @Test func spellsModifiersInTheStandardOrder() {
        let key = HotKey(keyCode: 35, modifiers: [.command, .shift, .option, .control])
        #expect(key.accessibilityName == "Control-Option-Shift-Command-P")
        #expect(HotKey.defaultPause.accessibilityName == "Control-Option-Command-P")
    }

    @Test func namesKeysShownAsSymbols() {
        #expect(HotKey(keyCode: 49, modifiers: [.option]).accessibilityName == "Option-Space")
        #expect(HotKey(keyCode: 36, modifiers: [.command]).accessibilityName == "Command-Return")
        #expect(HotKey(keyCode: 123, modifiers: [.control]).accessibilityName == "Control-Left Arrow")
        #expect(HotKey(keyCode: 43, modifiers: [.command]).accessibilityName == "Command-Comma")
        #expect(HotKey(keyCode: 96, modifiers: [.control, .command]).accessibilityName == "Control-Command-F5")
    }
}

@Suite struct PermissionActionTests {
    @Test func grantedNeedsNothing() {
        for permission in Permission.allCases {
            #expect(PermissionAction.for(permission, granted: true, undetermined: true) == .none)
            #expect(PermissionAction.for(permission, granted: true, undetermined: false) == .none)
        }
    }

    @Test func systemSettingsPermissionsAlwaysOpenTheirPane() {
        for permission in [Permission.screenRecording, .accessibility] {
            #expect(PermissionAction.for(permission, granted: false, undetermined: true) == .openSystemSettings)
            #expect(PermissionAction.for(permission, granted: false, undetermined: false) == .openSystemSettings)
        }
    }

    @Test func alertPermissionsAskOnceThenOpenTheirPane() {
        for permission in [Permission.microphone, .speechRecognition] {
            #expect(PermissionAction.for(permission, granted: false, undetermined: true) == .request)
            #expect(PermissionAction.for(permission, granted: false, undetermined: false) == .openSystemSettings)
        }
    }
}
