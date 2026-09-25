import AppKit
import AthinaControlProtocol
import AthinaCore
import CoreGraphics
import Testing

@testable import AthinaControl

/// The control API's `hotkey` presses only a key a person could press: one
/// that is not registered is refused, as Carbon never reports it.
@MainActor
@Suite struct HotKeyCommandTests {
  private func hotKey(
    _ host: ControlTestHost,
    _ arguments: [String: ControlValue]
  ) async -> ControlReply {
    await host.handle("hotkey", arguments)
  }

  @Test func anUnregisteredTalkBackKeyIsRefusedAndHearsNothing() async {
    let host = ControlTestHost()
    let reply = await hotKey(host, ["key": .string("talk-back"), "heard": .string("why")])
    #expect(reply.refused == "disabled")
    #expect(host.presses.isEmpty)
    #expect(host.heard.isEmpty)
  }

  @Test func anUnregisteredPauseKeyIsRefusedInEveryPhase() async {
    let host = ControlTestHost()
    host.registered = [.talkBack]
    for phase in ["press", "down", "up"] {
      let reply = await hotKey(host, ["key": .string("pause"), "phase": .string(phase)])
      #expect(reply.refused == "disabled")
    }
    #expect(host.presses.isEmpty)
  }
}
