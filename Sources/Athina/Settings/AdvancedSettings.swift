import AppKit
import AthinaCore
import SwiftUI

/// The Advanced pane: tools for looking inside Athina, off until the person
/// turns them on, as Safari's Advanced pane offers its features for web
/// developers.
///
/// Turned on, the debug panel opens from here and from the menu bar menu's
/// Debug Panel command, as Safari's switch adds its Develop menu
/// (`DebugPanelAccess`).
struct AdvancedSettings: View {
  @Environment(AppState.self)
  private var state

  @Environment(\.openWindow)
  private var openWindow

  @Environment(\.dismissWindow)
  private var dismissWindow

  var body: some View {
    @Bindable var state = state
    Form {
      Section {
        Toggle(isOn: $state.settings.showDebugPanel) {
          Text("Enable debug panel")
          Text(
            "A window for troubleshooting Athina: the latest capture and the text read from it, each model call and why it was made, and what Athina understands you to be working toward."
          )
        }
        .accessibilityIdentifier("advanced.enableDebugPanel")
        HStack {
          Spacer()
          Button("Open Debug Panel") {
            AppActivation.request()
            openWindow(id: WindowID.debug)
          }
          .disabled(!state.settings.showDebugPanel)
          .accessibilityIdentifier("advanced.openDebugPanel")
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
