import Foundation
import Testing
@testable import AthinaE2E

@Suite struct DriveArgumentsTests {
    @Test func parsesPositionalsAndOptions() throws {
        let invocation = try DriveArguments.parse(["click", "item", "1234", "--shot", "bar.png"])
        #expect(invocation.command == "click")
        #expect(invocation.positionals == ["item", "1234"])
        #expect(invocation.option("--shot") == "bar.png")
        #expect(try invocation.pid(1) == 1234)
    }

    @Test func parsesValuelessFlags() throws {
        let invocation = try DriveArguments.parse(["key", "53", "--cmd"])
        #expect(invocation.flag("--cmd"))
        #expect(!invocation.flag("--shift"))
        #expect(try invocation.number(0) == 53)
    }

    @Test func rejectsUnknownCommand() {
        #expect(throws: DriveUsageError.self) {
            try DriveArguments.parse(["quit-mentor"])
        }
    }

    @Test func rejectsUnknownOption() {
        #expect(throws: DriveUsageError.self) {
            try DriveArguments.parse(["toast", "1234", "--force"])
        }
    }

    @Test func rejectsOptionWithNoValue() {
        #expect(throws: DriveUsageError.self) {
            try DriveArguments.parse(["click", "item", "1234", "--shot"])
        }
    }

    @Test func rejectsWrongNumberOfArguments() {
        #expect(throws: DriveUsageError.self) { try DriveArguments.parse(["toast"]) }
        #expect(throws: DriveUsageError.self) { try DriveArguments.parse(["toast", "1", "2"]) }
    }

    @Test func rejectsArgumentsThatAreNotPids() throws {
        let invocation = try DriveArguments.parse(["toast", "0"])
        #expect(throws: DriveUsageError.self) { try invocation.pid(0) }
        let negative = try DriveArguments.parse(["toast", "-3"])
        #expect(throws: DriveUsageError.self) { try negative.pid(0) }
    }

    @Test func helpIsAUsageError() {
        #expect(throws: DriveUsageError.self) { try DriveArguments.parse(["--help"]) }
        #expect(throws: DriveUsageError.self) { try DriveArguments.parse([]) }
    }

    @Test func everyCommandDocumentsItself() {
        for command in DriveArguments.commands {
            #expect(!command.summary.isEmpty, "\(command.name) has no summary")
            #expect(command.minimum <= command.maximum, "\(command.name) has an impossible arity")
            #expect(DriveArguments.usage(for: command).contains(command.name))
        }
        #expect(Set(DriveArguments.commands.map(\.name)).count == DriveArguments.commands.count)
    }
}
