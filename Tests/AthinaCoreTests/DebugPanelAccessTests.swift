import Foundation
import Testing
@testable import AthinaCore

@Suite struct DebugPanelAccessTests {
    private func settings(showDebugPanel: Bool) -> SensingSettings {
        var settings = SensingSettings()
        settings.showDebugPanel = showDebugPanel
        return settings
    }

    /// A live launch asked for the panel opens it only once the person has
    /// turned it on, so `--open debug` is no way round the switch.
    @Test func aLiveLaunchHonoursTheSwitch() {
        #expect(DebugPanelAccess.opensAtLaunch(clientMode: .live, settings: settings(showDebugPanel: false)) == false)
        #expect(DebugPanelAccess.opensAtLaunch(clientMode: .live, settings: settings(showDebugPanel: true)) == true)
    }

    /// The builder's launches open it whatever the switch says, so a check or
    /// a recording session never changes the owner's setting to reach it.
    @Test func theBuildersLaunchesOpenItWhateverTheSwitchSays() {
        let fixtures = URL(fileURLWithPath: "/fixtures", isDirectory: true)
        let modes: [ModelClientMode] = [
            .replay(directory: fixtures, allowStale: false),
            .replay(directory: fixtures, allowStale: true),
            .record(directory: fixtures),
            .invalid("--replay needs the directory of fixtures to replay"),
        ]
        for mode in modes {
            #expect(DebugPanelAccess.opensAtLaunch(clientMode: mode, settings: settings(showDebugPanel: false)) == true)
            #expect(DebugPanelAccess.opensAtLaunch(clientMode: mode, settings: settings(showDebugPanel: true)) == true)
        }
    }

    /// The menu offers the command exactly while the switch is on, as Safari
    /// shows its Develop menu only while its Advanced setting is on.
    @Test func theMenuOffersTheCommandOnlyWhileTheSwitchIsOn() {
        #expect(DebugPanelAccess.menuOffersCommand(settings: SensingSettings()) == false)
        #expect(DebugPanelAccess.menuOffersCommand(settings: settings(showDebugPanel: false)) == false)
        #expect(DebugPanelAccess.menuOffersCommand(settings: settings(showDebugPanel: true)) == true)
    }
}
