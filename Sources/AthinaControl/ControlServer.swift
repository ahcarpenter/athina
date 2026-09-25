import AppKit
import AthinaControlProtocol
import AthinaCore
import CoreGraphics

// The end-to-end harness's control API (README "The control API"), compiled
// into the app only under the ControlAPI package trait and started only on a
// channel `ControlMode` accepted: a replay, unsandboxed, in a directory the
// harness made for the run and holding its secret.

/// What the API needs from the app beyond its windows.
@MainActor
public protocol ControlHost: AnyObject {
  /// The live settings, encoded as the settings file is.
  var controlSettings: ControlValue { get }
  /// A picture of one of the app's windows, settled and taken the way
  /// `--snapshot` takes one.
  func controlCapture(_ window: NSWindow) async throws -> ControlCapture
  /// How `controlCapture` takes its pictures: `ScreenCaptureKit`, or `layer
  /// tree` when the app may not record the screen, which draws glass and
  /// materials otherwise and leaves out the title bar and toolbar.
  var controlCaptureMethod: String { get }
  /// The menu bar item's menu as the app builds it.
  var controlMenu: MenuModel { get }
  /// Runs one of the menu's commands, as choosing it does.
  func controlPerform(_ command: MenuModel.Command)
  /// A mouse-down outside the app's windows at `location`, in screen
  /// coordinates, for the suggestion toast as its global monitor would see
  /// it; false when no toast was up to hear it.
  func controlOutsideClick(at location: CGPoint) -> Bool
  /// Whether one of the app's hot keys is registered, so a person could
  /// press it: set and usable, as Settings > General reports it.
  func controlHotKeyRegistered(_ key: ControlHotKey) -> Bool
  /// One of the app's hot keys going down or coming up, as Carbon reports it.
  func controlHotKey(_ key: ControlHotKey, isDown: Bool)
  /// Words for talking back to hear while its key is down; false when
  /// nothing was listening.
  func controlHear(_ words: String) -> Bool
  /// What a hermetic run's sensing is shown next (`SensingPipeline.observe`).
  func controlObserve(_ scripted: ScriptedObservation) async -> ScriptedOutcome
  /// Input going idle, or coming back, in a hermetic run; false when the
  /// run senses the real Mac.
  func controlSetIdle(_ idle: Bool) async -> Bool
  /// The events the app has handled so far, for `wait-event`.
  var controlEvents: ControlEventLog { get }
  /// The rows of a query that changes nothing, from the app's own journal.
  func controlJournalRows(_ sql: String) async throws -> [[String]]
  /// Moves a replay's clock ahead, as the debug panel's Advance field does:
  /// nil when it moved, otherwise why not.
  func controlAdvanceClock(by seconds: TimeInterval) -> String?
  /// The replay clock's time now, and how far it has been moved ahead.
  var controlClock: (now: Date, movedAhead: TimeInterval) { get }
  /// Opens a link in the app's own text through the handler a click on it
  /// runs; false when the app has no handler for it.
  func controlOpenLink(_ url: URL) -> Bool
}

/// A picture of one of the app's windows.
public struct ControlCapture {
  /// The picture.
  public let image: CGImage
  /// Whether two captures in a row gave this same picture.
  ///
  /// A window that keeps moving on its own, such as a toast's countdown ring,
  /// never does; its picture is the last capture, evidence of a run but never
  /// one to compare with a baseline.
  public let settled: Bool

  /// A picture, settled or not.
  public init(image: CGImage, settled: Bool) {
    self.image = image
    self.settled = settled
  }
}

/// The hot keys a person sets in Settings > General.
public enum ControlHotKey: String, CaseIterable, Sendable {
  case pause
  case talkBack = "talk-back"
}

/// The control API's server, which the app starts once on the channel
/// `ControlMode` accepted and keeps until it quits.
@MainActor
public enum ControlServer {
  /// Listens on the channel until the app quits.
  ///
  /// Throws when the socket cannot be made, which the app reports as it reports
  /// a refusal.
  public static func start(_ channel: ControlChannel, host: ControlHost) throws {
    let commands = ControlCommands(host: host)
    let listener = try ControlListener(channel: channel) { request in
      await commands.handle(request)
    }
    listener.run()
    running = (listener, commands)
  }

  /// Kept for as long as the app runs.
  private static var running: (ControlListener, ControlCommands)?
}
