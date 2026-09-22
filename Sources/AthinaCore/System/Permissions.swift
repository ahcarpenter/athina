import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

/// The permissions Athina asks for. The first two are what sensing needs;
/// the microphone only serves talking back, and everything else works without
/// it. Speech Recognition is not among them: every recognizer Athina offers
/// (`SpeechBackendID`) runs on this Mac, and none of them asks for it.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case screenRecording
    case accessibility
    case microphone

    public var id: String { rawValue }

    /// Sensing needs these; without both, the pipeline degrades or waits.
    public static let required: [Permission] = [.screenRecording, .accessibility]
    /// Talking back needs this; nothing else does.
    public static let optional: [Permission] = [.microphone]

    public var isRequired: Bool {
        Permission.required.contains(self)
    }

    /// Screen Recording and Accessibility are switched on in System Settings;
    /// the system's own request for them only points there. The microphone is
    /// answered in the system's Allow alert.
    public var isGrantedInSystemSettings: Bool {
        switch self {
        case .screenRecording, .accessibility: true
        case .microphone: false
        }
    }

    public var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        }
    }

    public var purpose: String {
        switch self {
        case .screenRecording:
            "Lets Athina capture the display you are working on when what you are doing changes, and read its text on this Mac. Frames stay in the local journal. Only the latest screenshot goes to the mentor model, and Models settings can turn that off."
        case .accessibility:
            "Lets Athina read the app, window title, and focused element you are using, so it knows what you are working on without guessing from pixels."
        case .microphone:
            "Lets Athina hear you while you hold the talk-back shortcut, and only then. The speech recognizer you choose turns it into text on this Mac: audio never leaves it, and Athina does not store it. When you ask a question, those words go to the mentor model."
        }
    }

    /// Deep link into the matching Privacy & Security pane.
    public var settingsURL: URL {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        }
    }
}

public struct PermissionStatus: Equatable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool
    public var microphone: Bool

    public init(screenRecording: Bool, accessibility: Bool, microphone: Bool = false) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.microphone = microphone
    }

    /// Both sensing permissions. The voice pair is optional and not counted.
    public var allGranted: Bool { screenRecording && accessibility }
    public var anyGranted: Bool { screenRecording || accessibility }
    /// The microphone, which talking back needs.
    public var voiceGranted: Bool { microphone }

    public func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: screenRecording
        case .accessibility: accessibility
        case .microphone: microphone
        }
    }
}

/// The one action the Permissions window offers for a permission, so the
/// window explains first and asks only when the person chooses to.
public enum PermissionAction: Equatable, Sendable {
    /// Granted: there is nothing to do.
    case none
    /// The system has not asked yet: the button brings up its Allow alert.
    case request
    /// The answer lives in System Settings: the button registers Athina in
    /// the matching list and opens that pane.
    case openSystemSettings

    public static func `for`(_ permission: Permission, granted: Bool, undetermined: Bool) -> PermissionAction {
        if granted { return .none }
        if permission.isGrantedInSystemSettings { return .openSystemSettings }
        return undetermined ? .request : .openSystemSettings
    }
}

/// Reads and requests the permissions Athina uses.
public enum PermissionProbe {
    /// Whether the system has never asked about this permission. Only the
    /// alert-based pair can say; the System Settings pair reports false.
    public static func isUndetermined(_ permission: Permission) -> Bool {
        switch permission {
        case .screenRecording, .accessibility:
            false
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        }
    }

    public static func current() -> PermissionStatus {
        PermissionStatus(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        )
    }

    /// Shows the system prompt (once per app identity) and adds the app to the pane's list.
    ///
    /// The microphone handler is `@Sendable` on purpose: TCC calls it on its
    /// own reply queue, and a closure written in a main-actor function is
    /// otherwise inferred to be main-actor isolated, which the runtime checks
    /// on entry and traps on. Nothing in it needs the main actor; the app
    /// polls the status afterwards.
    @MainActor
    public static func request(_ permission: Permission) {
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in }
        }
    }

    @MainActor
    public static func openSystemSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
