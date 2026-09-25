import Foundation
import Testing
@testable import AthinaControlProtocol
import AthinaCore

@Suite struct ControlProtocolTests {
    @Test func aRequestRoundTripsAsOneLine() throws {
        let request = ControlRequest(id: 7, secret: "s3cret", command: "click", arguments: [
            "window": .string("Advanced"), "force": .bool(true), "index": .number(2),
        ])
        let line = try request.line()
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(try ControlRequest.decode(line: line.dropLast()) == request)
        #expect(request.string("window") == "Advanced")
        #expect(request.bool("force") == true)
        #expect(request.number("index") == 2)
    }

    @Test func aRequestMissingAFieldIsNotARequest() {
        #expect(throws: (any Error).self) { try ControlRequest.decode(line: Data(#"{"id":1,"command":"ping","arguments":{}}"#.utf8)) }
        #expect(throws: (any Error).self) { try ControlRequest.decode(line: Data("not json".utf8)) }
    }

    @Test func anAnswerSaysOkRefusedOrError() throws {
        let ok = ControlReply.ok(["value": .number(3)])
        #expect(ok.ok && ok.refused == nil)
        let refused = ControlReply.refused("disabled", "the control is dimmed")
        #expect(!refused.ok && refused.refused == "disabled" && refused["error"] == .string("the control is dimmed"))
        let error = ControlReply.error("no such command")
        #expect(!error.ok && error.refused == nil)
        let line = refused.line()
        #expect(line.last == 0x0A)
        #expect(try ControlReply.decode(line: line.dropLast()) == refused)
    }

    @Test func aDottedPathReadsIntoObjectsAndArrays() {
        let answer = ControlReply.ok(["elements": .array([.object(["enabled": .bool(false), "frame": .array([.number(1), .number(2)])])])]).json
        #expect(answer[path: "elements.0.enabled"] == .bool(false))
        #expect(answer[path: "elements.0.frame.1"] == .number(2))
        #expect(answer[path: "elements.1.enabled"] == nil)
        #expect(answer[path: "ok"] == .bool(true))
        #expect(answer[path: "elements.x"] == nil)
    }

    @Test func textIsWhatAShellScriptReads() {
        #expect(ControlValue.string("a b").text == "a b")
        #expect(ControlValue.number(3).text == "3")
        #expect(ControlValue.number(0.5).text == "0.5")
        #expect(ControlValue.bool(true).text == "true")
        #expect(ControlValue.null.text == "null")
        #expect(ControlValue.array([.number(1), .string("x")]).text == #"[1,"x"]"#)
    }

    @Test func aCommandLineArgumentIsJSONWhenItCanBe() {
        #expect(ControlValue.argument("force=true")! == ("force", .bool(true)))
        #expect(ControlValue.argument("index=2")! == ("index", .number(2)))
        #expect(ControlValue.argument(#"label="Open Debug Panel""#)! == ("label", .string("Open Debug Panel")))
        #expect(ControlValue.argument("window=Debug Panel")! == ("window", .string("Debug Panel")))
        #expect(ControlValue.argument("path=/tmp/a=b.png")! == ("path", .string("/tmp/a=b.png")))
        #expect(ControlValue.argument("text=")! == ("text", .string("")))
        #expect(ControlValue.argument("=x") == nil)
        #expect(ControlValue.argument("novalue") == nil)
    }

    @Test func theSecretMustMatchWhole() {
        let secret = String(repeating: "f0", count: 32)
        #expect(ControlSecret.matches(secret, secret))
        #expect(!ControlSecret.matches(String(secret.dropLast()), secret))
        #expect(!ControlSecret.matches(secret + "0", secret))
        #expect(!ControlSecret.matches("", secret))
        #expect(!ControlSecret.matches(String(secret.dropLast()) + "1", secret))
        #expect(!ControlSecret.matches("", ""), "an empty secret never matches")
    }

    @Test func theMarkerIsLongEnoughToBeFoundInABinary() {
        // Swift keeps a string of 15 bytes or fewer inside the code rather
        // than as text in the binary, where scripts/check-no-control-api.sh
        // looks for it.
        #expect(ControlProtocol.name.utf8.count > 15)
    }
}

@Suite struct ControlFileNameTests {
    @Test func theAppAndTheClientNameTheSameFiles() {
        #expect(ControlProtocol.socketName == AthinaCore.ControlMode.socketName)
        #expect(ControlProtocol.secretName == AthinaCore.ControlMode.secretName)
    }
}
