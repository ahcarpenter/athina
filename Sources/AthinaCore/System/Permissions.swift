import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Speech

/// The permissions Athina asks for.
///
/// The first two are what sensing needs; the last two only serve talking back,
/// and everything else works without them.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
  case screenRecording
  case accessibility
  case microphone
  case speechRecognition

  /// The raw value, such as `screenRecording`.
  public var id: String { rawValue }

  /// Sensing needs these; without both, the pipeline degrades or waits.
  public static let required: [Permission] = [.screenRecording, .accessibility]
  /// Talking back needs these; nothing else does.
  public static let optional: [Permission] = [.microphone, .speechRecognition]

  /// Whether sensing needs this permission, as opposed to talking back.
  public var isRequired: Bool {
    Permission.required.contains(self)
  }

  /// Screen Recording and Accessibility are switched on in System Settings; the
  /// system's own request for them only points there.
  ///
  /// Microphone and Speech Recognition are answered in the system's Allow
  /// alert.
  public var isGrantedInSystemSettings: Bool {
    switch self {
    case .screenRecording, .accessibility: true
    case .microphone, .speechRecognition: false
    }
  }

  /// The permission's name as System Settings shows it, such as "Screen
  /// Recording".
  public var title: String {
    switch self {
    case .screenRecording: "Screen Recording"
    case .accessibility: "Accessibility"
    case .microphone: "Microphone"
    case .speechRecognition: "Speech Recognition"
    }
  }

  /// What the permission lets Athina do and what stays on this Mac, as the
  /// Permissions window explains it.
  public var purpose: String {
    switch self {
    case .screenRecording:
      """
      Lets Athina capture the display you are working on when what you are doing changes, \
      and read its text on this Mac. Frames stay in the local journal. Only the latest \
      screenshot goes to the mentor model, and Models settings can turn that off.
      """
    case .accessibility:
      """
      Lets Athina read the app, window title, and focused element you are using, so it knows \
      what you are working on without guessing from pixels.
      """
    case .microphone:
      """
      Lets Athina hear you while you hold the talk-back shortcut, and only then. Audio never \
      leaves this Mac, and Athina does not store it.
      """
    case .speechRecognition:
      """
      Lets Athina turn what you say into text on this Mac, with Apple's on-device recognizer \
      and never its servers. When you ask a question, those words go to the mentor model.
      """
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
      URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
      )!
    }
  }
}

/// Which of Athina's permissions are granted.
public struct PermissionStatus: Equatable, Sendable {
  /// Whether Screen Recording is granted.
  public var screenRecording: Bool
  /// Whether Accessibility is granted.
  public var accessibility: Bool
  /// Whether Microphone is granted.
  public var microphone: Bool
  /// Whether Speech Recognition is granted.
  public var speechRecognition: Bool

  /// Creates a status; the voice pair defaults to not granted.
  public init(
    screenRecording: Bool,
    accessibility: Bool,
    microphone: Bool = false,
    speechRecognition: Bool = false
  ) {
    self.screenRecording = screenRecording
    self.accessibility = accessibility
    self.microphone = microphone
    self.speechRecognition = speechRecognition
  }

  /// Both sensing permissions.
  ///
  /// The voice pair is optional and not counted.
  public var allGranted: Bool { screenRecording && accessibility }
  /// Whether at least one sensing permission is granted, so sensing can run
  /// in some mode.
  public var anyGranted: Bool { screenRecording || accessibility }
  /// Both voice permissions, which talking back needs.
  public var voiceGranted: Bool { microphone && speechRecognition }

  /// Returns whether `permission` is granted.
  public func isGranted(_ permission: Permission) -> Bool {
    switch permission {
    case .screenRecording: screenRecording
    case .accessibility: accessibility
    case .microphone: microphone
    case .speechRecognition: speechRecognition
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

  /// Returns the action to offer for a permission.
  ///
  /// - Parameters:
  ///   - permission: The permission the action is for.
  ///   - granted: Whether it is granted, which needs no action.
  ///   - undetermined: Whether the system has never asked about it, which
  ///     only the Microphone and Speech Recognition alerts can be.
  /// - Returns: Nothing when granted, the Allow alert for an alert-based
  ///   permission never asked about, and System Settings otherwise.
  public static func `for`(
    _ permission: Permission,
    granted: Bool,
    undetermined: Bool
  ) -> PermissionAction {
    if granted { return .none }
    if permission.isGrantedInSystemSettings { return .openSystemSettings }
    return undetermined ? .request : .openSystemSettings
  }
}

/// Reads and requests the permissions Athina uses.
public enum PermissionProbe {
  /// Whether the system has never asked about this permission.
  ///
  /// Only the alert-based pair can say; the System Settings pair reports false.
  public static func isUndetermined(_ permission: Permission) -> Bool {
    switch permission {
    case .screenRecording, .accessibility:
      false
    case .microphone:
      AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    case .speechRecognition:
      SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }
  }

  /// Returns which permissions are granted right now.
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

  /// Opens the Privacy & Security pane for `permission` in System Settings.
  @MainActor
  public static func openSystemSettings(for permission: Permission) {
    NSWorkspace.shared.open(permission.settingsURL)
  }
}
