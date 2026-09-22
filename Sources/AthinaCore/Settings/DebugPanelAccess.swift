import Foundation

/// Who reaches the debug panel, and how. It is a builder's window, so the app
/// offers it only once the person turns on Settings > Advanced > Show debug
/// panel (`SensingSettings.showDebugPanel`), and then only from that pane.
/// The builder's own launches, a replay or a recording, open it with
/// `--open debug` whatever the switch says, so an end-to-end check or a
/// recording session never has to change the owner's setting to see it.
public enum DebugPanelAccess {
    /// Whether `--open debug` presents the panel at launch. A live launch
    /// honours the switch; a replay, a recording, and a command line that
    /// could not be read (which never calls live either) do not ask it.
    public static func opensAtLaunch(clientMode: ModelClientMode, settings: SensingSettings) -> Bool {
        switch clientMode {
        case .live: settings.showDebugPanel
        case .record, .replay, .invalid: true
        }
    }
}
