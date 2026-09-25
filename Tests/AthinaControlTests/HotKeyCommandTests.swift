import AppKit
import AthinaControlProtocol
import AthinaCore
import Testing
@testable import AthinaControl

/// The control API's `hotkey` presses only a key a person could press: one
/// that is not registered is refused, as Carbon never reports it.
@MainActor
@Suite struct HotKeyCommandTests {
    final class Host: ControlHost {
        var registered: Set<ControlHotKey> = []
        var presses: [(ControlHotKey, Bool)] = []
        var heard: [String] = []

        var controlSettings: ControlValue { .null }
        func controlCapture(_ window: NSWindow) async throws -> CGImage {
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
    }

    private func hotKey(_ host: Host, _ arguments: [String: ControlValue]) async -> ControlReply {
        await ControlCommands(host: host).handle(
            ControlRequest(id: 1, secret: "", command: "hotkey", arguments: arguments)
        )
    }

    @Test func anUnregisteredTalkBackKeyIsRefusedAndHearsNothing() async {
        let host = Host()
        let reply = await hotKey(host, ["key": .string("talk-back"), "heard": .string("why")])
        #expect(reply.refused == "disabled")
        #expect(host.presses.isEmpty)
        #expect(host.heard.isEmpty)
    }

    @Test func anUnregisteredPauseKeyIsRefusedInEveryPhase() async {
        let host = Host()
        host.registered = [.talkBack]
        for phase in ["press", "down", "up"] {
            let reply = await hotKey(host, ["key": .string("pause"), "phase": .string(phase)])
            #expect(reply.refused == "disabled")
        }
        #expect(host.presses.isEmpty)
    }
}
