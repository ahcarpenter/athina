import AppKit
import AthinaCore
import SwiftUI

/// The Advanced pane: tools for looking inside Athina, off until the person
/// turns them on, as Safari's Advanced pane offers its features for web
/// developers. The debug panel opens from here and nowhere else in the app
/// (`DebugPanelAccess`).
struct AdvancedSettings: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Toggle(isOn: $state.settings.showDebugPanel) {
                    Text("Enable debug panel")
                    Text("A window for troubleshooting Athina: the latest capture and the text read from it, each model call and why it was made, and what Athina understands you to be working toward.")
                }
                HStack {
                    Spacer()
                    Button("Open Debug Panel") {
                        NSApp.activate()
                        openWindow(id: WindowID.debug)
                    }
                    .disabled(!state.settings.showDebugPanel)
                }
            } header: {
                Text("Troubleshooting")
            }
        }
        // Turned off, the panel goes too, so it is never left open with
        // nothing in the app that would have opened it.
        .onChange(of: state.settings.showDebugPanel) { _, enabled in
            if !enabled { dismissWindow(id: WindowID.debug) }
        }
    }
}
