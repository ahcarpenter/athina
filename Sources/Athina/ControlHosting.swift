import AppKit
import AthinaCore
import CoreGraphics
import Foundation

#if ControlAPI
  import AthinaControl
  import AthinaControlProtocol
#endif

/// Whether this build carries the end-to-end harness's control API: only a
/// build with the ControlAPI package trait, which the development bundle turns
/// on and the release and App Store builds never do (README "The control API").
enum ControlAvailability {
  #if ControlAPI
    static let compiledIn = true
  #else
    static let compiledIn = false
  #endif
}

#if ControlAPI
  extension AppState: ControlHost {
    var controlSettings: ControlValue {
      guard let data = try? JSONEncoder().encode(settings),
        let value = try? JSONDecoder().decode(ControlValue.self, from: data)
      else { return .null }
      return value
    }

    /// Settled as `--snapshot` settles a window, and captured this run's one
    /// way.
    func controlCapture(_ window: NSWindow) async throws -> CGImage {
      guard let bitmap = try await Snapshots.settledCapture(of: window) else {
        throw ControlCaptureError(window: window.title)
      }
      return try bitmap.cgImage()
    }

    var controlCaptureMethod: String {
      Snapshots.capturesWithScreenCaptureKit ? "ScreenCaptureKit" : "layer tree"
    }

    var controlMenu: MenuModel { menuModel }

    func controlPerform(_ command: MenuModel.Command) {
      perform(command)
    }

    func controlOutsideClick(at location: CGPoint) -> Bool {
      clickOutside(at: location)
    }

    func controlHotKeyRegistered(_ key: ControlHotKey) -> Bool {
      switch key {
      case .pause: hotKeyRegistered
      case .talkBack: pushToTalkRegistered
      }
    }

    func controlHotKey(_ key: ControlHotKey, isDown: Bool) {
      if isDown {
        hotKeyPressed(Self.slot(of: key))
      } else {
        hotKeyReleased(Self.slot(of: key))
      }
    }

    private static func slot(of key: ControlHotKey) -> HotKeyCenter.Slot {
      switch key {
      case .pause: .pause
      case .talkBack: .pushToTalk
      }
    }

    func controlHear(_ words: String) -> Bool {
      hear(words)
    }
  }

  /// No two captures of the window in a row were the same picture: it kept
  /// changing, or ScreenCaptureKit kept missing it.
  struct ControlCaptureError: LocalizedError {
    let window: String
    var errorDescription: String? {
      "the window \"\(window)\" never gave the same picture twice in a row: it kept changing, or ScreenCaptureKit kept missing it"
    }
  }
#endif
