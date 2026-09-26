import AppKit
import AthinaControlProtocol
import AthinaCore

@testable import AthinaControl

/// A stand-in for the app behind the control API's commands, holding what
/// each command reached and answering as each test sets it.
@MainActor
final class ControlTestHost: ControlHost {
  var registered: Set<ControlHotKey> = []
  var presses: [(ControlHotKey, Bool)] = []
  var heard: [String] = []
  var observed: [ScriptedObservation] = []
  var observeOutcome = ScriptedOutcome.notScripted
  var idles: [Bool] = []
  var scripted = true
  var controlEvents = ControlEventLog()
  var journalRows: [[String]] = []
  var advanceRefusal: String?
  var advanced: [TimeInterval] = []
  var controlClock: (now: Date, movedAhead: TimeInterval) = (Date(timeIntervalSince1970: 0), 0)

  var controlSettings: ControlValue { .null }
  func controlCapture(_ window: NSWindow) async throws -> ControlCapture {
    throw CancellationError()
  }
  var controlMenu: MenuModel { MenuModel(items: []) }
  func controlPerform(_ command: MenuModel.Command) {}
  func controlOutsideClick(at location: CGPoint) -> Bool { false }
  func controlHotKeyRegistered(_ key: ControlHotKey) -> Bool { registered.contains(key) }
  func controlHotKey(_ key: ControlHotKey, isDown: Bool) { presses.append((key, isDown)) }
  func controlHear(_ words: String) -> Bool {
    heard.append(words)
    return true
  }
  func controlObserve(_ scripted: ScriptedObservation) async -> ScriptedOutcome {
    observed.append(scripted)
    return observeOutcome
  }
  func controlSetIdle(_ idle: Bool) async -> Bool {
    idles.append(idle)
    return scripted
  }
  func controlJournalRows(_ sql: String) async throws -> [[String]] { journalRows }
  func controlAdvanceClock(by seconds: TimeInterval) -> String? {
    if let advanceRefusal { return advanceRefusal }
    advanced.append(seconds)
    return nil
  }
  func controlOpenLink(_ url: URL) -> Bool { false }

  /// Answers one request as the app would.
  func handle(_ command: String, _ arguments: [String: ControlValue] = [:]) async -> ControlReply {
    await ControlCommands(host: self).handle(
      ControlRequest(id: 1, secret: "", command: command, arguments: arguments)
    )
  }
}
