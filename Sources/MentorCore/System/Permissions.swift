import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import Speech

/// The permissions Mentor asks for. The first two are what sensing needs;
/// the last two only serve talking back, and everything else works without them.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case screenRecording
    case accessibility
    case microphone
    case speechRecognition

    public var id: String { rawValue }

    /// Sensing needs these; without both, the pipeline degrades or waits.
    public static let required: [Permission] = [.screenRecording, .accessibility]
    /// Talking back needs these; nothing else does.
    public static let optional: [Permission] = [.microphone, .speechRecognition]

    public var isRequired: Bool {
        Permission.required.contains(self)
    }

    public var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        }
    }

    public var purpose: String {
        switch self {
        case .screenRecording:
            "Lets Mentor capture the display you are working on at a low, change-driven cadence and read its text on this Mac. Frames stay in the local journal; only the latest screenshot goes to the mentor model, and Settings > Mentor can turn that off."
        case .accessibility:
            "Lets Mentor read the focused app, window title, and focused element of the app you are using, so it knows what you are working on without guessing from pixels."
        case .microphone:
            "Lets Mentor hear you while you hold the talk-back key, and only then. Audio never leaves this Mac and is not stored."
        case .speechRecognition:
            "Lets Mentor turn what you said into text on this Mac, with Apple's on-device recognizer and never its servers. The words go to the mentor model as your follow-up question."
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
        case .speechRecognition:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        }
    }
}

public struct PermissionStatus: Equatable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool
    public var microphone: Bool
    public var speechRecognition: Bool

    public init(screenRecording: Bool, accessibility: Bool, microphone: Bool = false, speechRecognition: Bool = false) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.microphone = microphone
        self.speechRecognition = speechRecognition
    }

    /// Both sensing permissions. The voice pair is optional and not counted.
    public var allGranted: Bool { screenRecording && accessibility }
    public var anyGranted: Bool { screenRecording || accessibility }
    /// Both voice permissions, which talking back needs.
    public var voiceGranted: Bool { microphone && speechRecognition }

    public func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: screenRecording
        case .accessibility: accessibility
        case .microphone: microphone
        case .speechRecognition: speechRecognition
        }
    }
}

/// Reads and requests the permissions Mentor uses.
public enum PermissionProbe {
    public static func current() -> PermissionStatus {
        PermissionStatus(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speechRecognition: SFSpeechRecognizer.authorizationStatus() == .authorized
        )
    }

    /// Shows the system prompt (once per app identity) and adds the app to the pane's list.
    ///
    /// The microphone and speech handlers are `@Sendable` on purpose: TCC
    /// calls them on its own reply queue, and a closure written in a
    /// main-actor function is otherwise inferred to be main-actor isolated,
    /// which the runtime checks on entry and traps on. Nothing in them needs
    /// the main actor; the app polls the status afterwards.
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
        case .speechRecognition:
            SFSpeechRecognizer.requestAuthorization { @Sendable _ in }
        }
    }

    @MainActor
    public static func openSystemSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
