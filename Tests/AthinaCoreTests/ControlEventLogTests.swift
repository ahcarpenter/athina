import Foundation
import Testing

@testable import AthinaCore

/// The events the control API's `wait-event` waits on, in the order the app
/// handled them.
@Suite struct ControlEventLogTests {
  let date = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func eventsAreNumberedInOrderAndTheCadenceIsLeftOut() {
    var log = ControlEventLog()
    log.append(SensingEvent.modeChanged(.watching))
    log.append(SensingEvent.cadence(CadenceStatus()))
    log.append(
      MentorEvent.event(
        JournalEvent(id: 7, timestamp: date, kind: .understanding, detail: "revision 1")
      )
    )
    #expect(log.sequence == 2)
    #expect(log.entries.map(\.name) == ["mode", "event"])
    #expect(log.entries.map(\.sequence) == [1, 2])
    #expect(log.entries[1].fields["kind"] == "understanding")
    #expect(log.entries[1].fields["detail"] == "revision 1")
  }

  @Test func theFirstMatchAfterASequenceIsFound() {
    var log = ControlEventLog()
    for mode in [SensingMode.watching, .idle, .watching, .paused] {
      log.append(SensingEvent.modeChanged(mode))
    }
    #expect(log.first(named: "mode")?.sequence == 1)
    #expect(log.first(named: "mode", after: 1, matching: ["mode": "watching"])?.sequence == 3)
    #expect(log.first(named: "mode", after: 3, matching: ["mode": "watching"]) == nil)
    #expect(log.first(named: "suggestion") == nil)
  }

  @Test func onlyTheNewestAreKept() {
    var log = ControlEventLog(capacity: 3)
    for _ in 0..<5 { log.append(SensingEvent.modeChanged(.watching)) }
    #expect(log.entries.map(\.sequence) == [3, 4, 5])
    #expect(log.sequence == 5)
  }
}
