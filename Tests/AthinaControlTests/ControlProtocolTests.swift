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
        #expect(try request.string("window") == "Advanced")
        #expect(try request.bool("force") == true)
        #expect(try request.number("index") == 2)
        #expect(try request.string("label") == nil)
    }

    @Test func aParameterOfTheWrongTypeIsRefusedByName() {
        let request = ControlRequest(id: 1, secret: "s", command: "type", arguments: [
            "text": .number(30), "force": .string("yes"), "timeout": .string("soon"),
        ])
        #expect(throws: ControlArgumentError(key: "text", expected: "text", given: .number(30))) { try request.string("text") }
        #expect(throws: ControlArgumentError(key: "force", expected: "true or false", given: .string("yes"))) { try request.bool("force") }
        #expect(throws: ControlArgumentError(key: "timeout", expected: "a number", given: .string("soon"))) { try request.number("timeout") }
        #expect(ControlArgumentError(key: "force", expected: "true or false", given: .string("yes")).description
            == "force= takes true or false, not yes")
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

    @Test func aCommandLineArgumentIsTypedAsItsParameterTakesIt() {
        #expect(ControlValue.argument("force=true")! == ("force", .bool(true)))
        #expect(ControlValue.argument("present=false")! == ("present", .bool(false)))
        #expect(ControlValue.argument("index=2")! == ("index", .number(2)))
        #expect(ControlValue.argument("timeout=0.5")! == ("timeout", .number(0.5)))
        #expect(ControlValue.argument("equals=true")! == ("equals", .bool(true)))
        #expect(ControlValue.argument("equals=3")! == ("equals", .number(3)))
        #expect(ControlValue.argument(#"equals="30""#)! == ("equals", .string("30")))
        #expect(ControlValue.argument("equals=advanced")! == ("equals", .string("advanced")))
        #expect(ControlValue.argument("window=Debug Panel")! == ("window", .string("Debug Panel")))
        #expect(ControlValue.argument("path=/tmp/a=b.png")! == ("path", .string("/tmp/a=b.png")))
        #expect(ControlValue.argument("text=")! == ("text", .string("")))
        #expect(ControlValue.argument("=x") == nil)
        #expect(ControlValue.argument("novalue") == nil)
    }

    @Test func textGoesAsWrittenEvenWhenItReadsAsJSON() throws {
        #expect(ControlValue.argument("text=30")! == ("text", .string("30")))
        #expect(ControlValue.argument("text=1.50")! == ("text", .string("1.50")))
        #expect(ControlValue.argument("text=true")! == ("text", .string("true")))
        #expect(ControlValue.argument("label=2")! == ("label", .string("2")))
        #expect(ControlValue.argument(#"label="Open Debug Panel""#)! == ("label", .string(#""Open Debug Panel""#)))
        #expect(ControlValue.argument("press=null")! == ("press", .string("null")))
        // Through the codec to the app, the command reads what was typed.
        let (key, value) = ControlValue.argument("text=30")!
        let line = try ControlRequest(id: 1, secret: "s", command: "type", arguments: [key: value]).line()
        #expect(try ControlRequest.decode(line: line.dropLast()).string("text") == "30")
    }

    @Test func aValueNotOfItsParametersTypeGoesAsTextForTheAppToRefuse() throws {
        #expect(ControlValue.argument("force=yes")! == ("force", .string("yes")))
        #expect(ControlValue.argument("index=two")! == ("index", .string("two")))
        #expect(ControlValue.argument("timeout=true")! == ("timeout", .string("true")))
        #expect(ControlValue.argument("dry=1")! == ("dry", .string("1")))
        let (key, value) = ControlValue.argument("force=yes")!
        let request = ControlRequest(id: 1, secret: "s", command: "click", arguments: [key: value])
        #expect(throws: ControlArgumentError(key: "force", expected: "true or false", given: .string("yes"))) { try request.bool("force") }
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
