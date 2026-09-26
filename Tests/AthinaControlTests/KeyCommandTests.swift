import AthinaControlProtocol
import Testing

@testable import AthinaControl

/// The control API's `key` refuses a request it cannot turn into one key
/// press, naming what is wrong, before it posts anything.
@MainActor
@Suite struct KeyCommandTests {
  private func key(_ arguments: [String: ControlValue]) async -> ControlReply {
    await ControlTestHost().handle("key", arguments)
  }

  @Test func aKeyCodeIsNeeded() async {
    for code: ControlValue in [.null, .number(-1), .number(1.5), .number(70_000)] {
      var arguments: [String: ControlValue] = ["window": .string("General")]
      if code != .null { arguments["code"] = code }
      let reply = await key(arguments)
      #expect(!reply.ok)
      #expect(reply["error"]?.string == "key needs code=<virtual key code>")
    }
  }

  @Test func onlyTheFourModifiersAreNamed() async {
    let reply = await key([
      "window": .string("General"),
      "code": .number(17),
      "modifiers": .string("control,fn"),
    ])
    #expect(!reply.ok)
    #expect(
      reply["error"]?.string == "key modifiers= are control, option, shift and command, not fn"
    )
  }

  @Test func theKeyCodeTravelsAsANumber() {
    #expect(ControlCommands.commands.contains("key"))
    #expect(ControlProtocol.kinds["code"] == .number)
  }
}
