import AppKit
import AthinaCore
#if ATHINA_CONTROL
import AthinaControl
import AthinaControlProtocol
#endif

/// Whether this build carries the end-to-end harness's control API: only a
/// build with the ControlAPI package trait, which the development bundle turns
/// on and the release and App Store builds never do (README "The control API").
enum ControlAvailability {
    #if ATHINA_CONTROL
    static let compiledIn = true
    #else
    static let compiledIn = false
    #endif
}

#if ATHINA_CONTROL
extension AppState: ControlHost {
    var controlSettings: ControlValue {
        guard let data = try? JSONEncoder().encode(settings),
              let value = try? JSONDecoder().decode(ControlValue.self, from: data) else { return .null }
        return value
    }

    func controlCapture(_ window: NSWindow) async throws -> CGImage {
        try await Snapshots.captureWithFallback(window: window, hosting: window.contentView ?? NSView())
    }
}
#endif
