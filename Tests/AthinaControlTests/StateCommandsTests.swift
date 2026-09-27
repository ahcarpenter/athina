import AthinaControlProtocol
import AthinaCore
import Foundation
import Testing

@testable import AthinaControl

/// The control API's commands over the app's state: its settings, scripted
/// sensing, the events it has handled, its journal and its clock.
@MainActor
@Suite struct StateCommandsTests {
  let date = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func observeScriptsAWindowAndSaysWhereItsEventsStart() async {
    let host = ControlTestHost()
    host.controlEvents.append(SensingEvent.modeChanged(.watching))
    host.observeOutcome = .notKept("near-duplicate")
    let reply = await host.handle(
      "observe",
      [
        "app": .string("TextEdit"), "bundle": .string("com.apple.TextEdit"),
        "window": .string("notes.txt"), "text": .string("line one\nline two"),
      ]
    )
    #expect(reply.ok)
    #expect(reply["after"] == .number(1))
    #expect(reply["kept"] == .bool(false))
    #expect(reply["why"] == .string("near-duplicate"))
    #expect(
      host.observed == [
        ScriptedObservation(
          appName: "TextEdit",
          bundleID: "com.apple.TextEdit",
          windowTitle: "notes.txt",
          text: "line one\nline two"
        )
      ]
    )
  }

  @Test func observeNeedsAnAppAndItsBundle() async {
    let host = ControlTestHost()
    let reply = await host.handle("observe", ["app": .string("TextEdit")])
    #expect(!reply.ok)
    #expect(host.observed.isEmpty)
  }

  @Test func observeIsRefusedInARunThatSensesTheRealMac() async {
    let host = ControlTestHost()
    host.scripted = false
    let window = await host.handle(
      "observe",
      ["app": .string("TextEdit"), "bundle": .string("com.apple.TextEdit")]
    )
    #expect(window.refused == "unscripted")
    let idle = await host.handle("observe", ["idle": .bool(true)])
    #expect(idle.refused == "unscripted")
  }

  @Test func idleGoesAlone() async {
    let host = ControlTestHost()
    let mixed = await host.handle("observe", ["idle": .bool(true), "app": .string("TextEdit")])
    #expect(!mixed.ok)
    #expect(host.idles.isEmpty)
    let alone = await host.handle("observe", ["idle": .bool(false)])
    #expect(alone.ok)
    #expect(host.idles == [false])
  }

  @Test func waitEventFindsTheFirstMatchAfterTheSequenceGiven() async {
    let host = ControlTestHost()
    host.controlEvents.append(
      SensingEvent.event(JournalEvent(id: 1, timestamp: date, kind: .started))
    )
    host.controlEvents.append(
      SensingEvent.event(
        JournalEvent(id: 2, timestamp: date, kind: .appSwitch, appName: "TextEdit")
      )
    )
    host.controlEvents.append(
      SensingEvent.event(JournalEvent(id: 3, timestamp: date, kind: .appSwitch, appName: "Notes"))
    )

    let first = await host.handle(
      "wait-event",
      ["name": .string("event"), "kind": .string("appSwitch"), "timeout": .number(0)]
    )
    #expect(first["sequence"] == .number(2))
    #expect(first["event"]?[path: "app"] == .string("TextEdit"))

    let later = await host.handle(
      "wait-event",
      [
        "name": .string("event"), "kind": .string("appSwitch"), "after": .number(2),
        "timeout": .number(0),
      ]
    )
    #expect(later["event"]?[path: "app"] == .string("Notes"))
  }

  @Test func waitEventSaysWhatNeverCame() async {
    let host = ControlTestHost()
    host.controlEvents.append(SensingEvent.modeChanged(.watching))
    let reply = await host.handle(
      "wait-event",
      ["name": .string("mode"), "mode": .string("idle"), "timeout": .number(0)]
    )
    #expect(!reply.ok)
    #expect(reply["latest"] == .number(1))
    #expect(reply["error"]?.string?.contains("mode=idle") == true)
  }

  @Test func waitEventNeedsAKnownName() async {
    let reply = await ControlTestHost().handle("wait-event", ["name": .string("toast")])
    #expect(!reply.ok)
  }

  @Test func journalAnswersANamedQueryKeyedByColumn() async {
    let host = ControlTestHost()
    host.journalRows = [["1", "12", "0", "2", "0", "1"]]
    let reply = await host.handle("journal", ["query": .string("counts")])
    #expect(reply.ok)
    #expect(reply["rows"]?[path: "0.suggestions"] == .string("0"))
    #expect(reply["rows"]?[path: "0.calls"] == .string("2"))
    let unknown = await host.handle("journal", ["query": .string("drop table events")])
    #expect(!unknown.ok)
  }

  @Test func advanceMovesTheClockOrSaysWhyNot() async {
    let host = ControlTestHost()
    host.controlClock = (date, 90)
    let moved = await host.handle("advance", ["seconds": .number(90)])
    #expect(moved.ok)
    #expect(host.advanced == [90])
    #expect(moved["movedAhead"] == .number(90))
    host.advanceRefusal = "this launch has no replay clock"
    let refused = await host.handle("advance", ["seconds": .number(90)])
    #expect(refused["error"] == .string("this launch has no replay clock"))
    #expect(host.advanced == [90])
  }

  @Test func advanceTakesAnIntervalAsTheAdvanceFieldDoes() async {
    let host = ControlTestHost()
    let moved = await host.handle("advance", ["interval": .string("1d12h")])
    #expect(moved.ok)
    #expect(host.advanced == [129_600])
    let unreadable = await host.handle("advance", ["interval": .string("soon")])
    #expect(unreadable["error"] == .string("\"soon\" is not an interval such as 15m, 2h, or 1d"))
    let both = await host.handle(
      "advance",
      ["seconds": .number(90), "interval": .string("15m")]
    )
    #expect(both["error"] == .string("advance takes seconds= or interval=, not both"))
    let neither = await host.handle("advance", [:])
    #expect(!neither.ok)
    #expect(host.advanced == [129_600])
  }

  @Test func anUnsetSettingReadsAndIsWaitedForAsNull() async {
    let host = ControlTestHost()
    host.controlSettings = .object(["mentor": .object([:])])
    let read = await host.handle("settings", ["key": .string("mentor.pushToTalkHotKey")])
    #expect(read["value"] == .null)
    let waited = await host.handle(
      "wait-setting",
      ["key": .string("mentor.pushToTalkHotKey"), "equals": .null, "timeout": .number(0)]
    )
    #expect(waited.ok)
  }
}
