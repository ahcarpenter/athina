import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case screenRecording
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    public var purpose: String {
        switch self {
        case .screenRecording:
            "Lets Mentor capture the display you are working on at a low, change-driven cadence and read its text on this Mac. Frames stay in the local journal and never leave your machine."
        case .accessibility:
            "Lets Mentor read the focused app, window title, and focused element of the app you are using, so it knows what you are working on without guessing from pixels."
        }
    }

    /// Deep link into the matching Privacy & Security pane.
    public var settingsURL: URL {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

public struct PermissionStatus: Equatable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool

    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }

    public var allGranted: Bool { screenRecording && accessibility }
    public var anyGranted: Bool { screenRecording || accessibility }

    public func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: screenRecording
        case .accessibility: accessibility
        }
    }
}

/// Reads and requests the two permissions Mentor needs.
public enum PermissionProbe {
    public static func current() -> PermissionStatus {
        PermissionStatus(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    /// Shows the system prompt (once per app identity) and adds the app to the pane's list.
    @MainActor
    public static func request(_ permission: Permission) {
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    @MainActor
    public static func openSystemSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
