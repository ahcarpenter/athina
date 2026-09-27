import AppKit
import AthinaCore

/// Brings Athina forward for a window the person asked for.
///
/// Every such request goes through here, never `NSApp.activate()` directly,
/// so a hermetic run (`ControlMode.isHermetic`, docs/e2e.md "Hermetic runs") never
/// takes the front from whoever is using the Mac.
@MainActor
enum AppActivation {
  static func request() {
    guard !AppState.shared.controlMode.isHermetic else { return }
    NSApp.activate()
  }
}
