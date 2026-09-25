import AppKit
import AthinaCore
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
              let value = try? JSONDecoder().decode(ControlValue.self, from: data) else { return .null }
        return value
    }

    /// Taken the way this run's `--snapshot` takes a window, and again while
    /// ScreenCaptureKit misses it.
    func controlCapture(_ window: NSWindow) async throws -> CGImage {
        let hosting = window.contentView ?? NSView()
        for _ in 0..<8 {
            if let image = try await Snapshots.capture(window: window, hosting: hosting) { return image }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw ControlCaptureError(window: window.title)
    }

    var controlMenu: MenuModel { menuModel }

    func controlPerform(_ command: MenuModel.Command) {
        perform(command)
    }

    func controlOutsideClick(at location: CGPoint) -> Bool {
        clickOutside(at: location)
    }

    func controlHotKey(_ key: ControlHotKey, isDown: Bool) {
        let slot: HotKeyCenter.Slot = switch key {
        case .pause: .pause
        case .talkBack: .pushToTalk
        }
        if isDown {
            hotKeyPressed(slot)
        } else {
            hotKeyReleased(slot)
        }
    }

    func controlHear(_ words: String) -> Bool {
        hear(words)
    }
}

/// ScreenCaptureKit missed the window every time it was asked for it.
struct ControlCaptureError: LocalizedError {
    let window: String
    var errorDescription: String? { "ScreenCaptureKit kept missing the window \"\(window)\"" }
}
#endif
