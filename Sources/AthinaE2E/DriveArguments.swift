import Foundation

/// The command line of `athina-drive`, parsed and checked before anything on
/// the screen is touched.
///
/// Every scenario reaches the accessibility tree, the pointer, and the journal
/// through this one tool, so a mistyped drive step must fail with a usage
/// message rather than click somewhere unintended.
public struct DriveInvocation: Equatable, Sendable {
    public let command: String
    public let positionals: [String]
    public let options: [String: String]

    public init(command: String, positionals: [String], options: [String: String]) {
        self.command = command
        self.positionals = positionals
        self.options = options
    }
}

public struct DriveUsageError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum DriveArguments {
    public struct Command: Sendable, Equatable {
        public let name: String
        public let arguments: String
        public let summary: String
        public let minimum: Int
        public let maximum: Int
        /// Options this command understands, as `--name` (a value) or `--name!` (a flag).
        public let options: [String]
    }

    public static let commands: [Command] = [
        Command(name: "permissions", arguments: "", summary: "whether this shell has Accessibility and Screen Recording", minimum: 0, maximum: 0, options: []),
        Command(name: "ready", arguments: "<pid>", summary: "print READY once the app's menu bar extra exists", minimum: 1, maximum: 1, options: []),
        Command(name: "windows", arguments: "<pid>", summary: "the on-screen windows of a pid, with ids and frames", minimum: 1, maximum: 1, options: []),
        Command(name: "toast", arguments: "<pid>", summary: "the window id of the suggestion toast, or nothing", minimum: 1, maximum: 1, options: []),
        Command(name: "bar", arguments: "[pid]", summary: "menu bar extras and menu titles with frames, gaps, and empty space", minimum: 0, maximum: 1, options: []),
        Command(name: "front", arguments: "", summary: "the frontmost app and its pid", minimum: 0, maximum: 0, options: []),
        Command(name: "activate", arguments: "<pid>", summary: "bring a pid to the front", minimum: 1, maximum: 1, options: []),
        Command(name: "ax", arguments: "<pid> <dump|texts|menuitems|menu|pressextra|cancelmenu|get|press|pressx|focus|set> [role] [match] [value]", summary: "read or press elements through accessibility", minimum: 2, maximum: 6, options: ["--scope"]),
        Command(name: "click", arguments: "<item <pid> | at <x> <y> | window <pid> <x> <y>>", summary: "post a real HID click, aborting if the pointer is moved", minimum: 2, maximum: 4, options: ["--shot"]),
        Command(name: "raise", arguments: "<pid> [title]", summary: "bring one of a pid's windows to the front, which journals a window switch", minimum: 1, maximum: 2, options: []),
        Command(name: "close", arguments: "<pid> <title>", summary: "close one of a pid's windows through its close button", minimum: 2, maximum: 2, options: []),
        Command(name: "menupick", arguments: "<pid> <row> <item>", summary: "hover a submenu row and click one of its items with the pointer", minimum: 3, maximum: 3, options: []),
        Command(name: "tap", arguments: "<session|pid> [pid]", summary: "listen-only event tap logging mouse-downs and what is under them", minimum: 1, maximum: 2, options: []),
        Command(name: "announce", arguments: "<pid>", summary: "log every AXAnnouncementRequested the app posts", minimum: 1, maximum: 1, options: []),
        Command(name: "flip", arguments: "<x> <y> <w> <h>", summary: "a click-through helper window that changes text and colour on SIGUSR1", minimum: 4, maximum: 4, options: []),
        Command(name: "journal", arguments: "<db> <query>", summary: "a named read-only query over a journal; `journal - queries` lists them", minimum: 2, maximum: 2, options: []),
        Command(name: "key", arguments: "<keycode>", summary: "post a key press", minimum: 1, maximum: 1, options: ["--cmd!", "--shift!"]),
        Command(name: "shot", arguments: "<window <id> | region <x> <y> <w> <h>> <out.png>", summary: "capture a window by id or a screen region", minimum: 2, maximum: 6, options: []),
        Command(name: "api", arguments: "<command> [key=value ...]", summary: "one request to a replay's control API, in ATHINA_CONTROL_DIR; prints the answer, or one field of it with --field", minimum: 1, maximum: 24, options: ["--field"]),
    ]

    public static func command(named name: String) -> Command? {
        commands.first { $0.name == name }
    }

    public static func parse(_ argv: [String]) throws -> DriveInvocation {
        guard let name = argv.first else { throw DriveUsageError(usage()) }
        if name == "-h" || name == "--help" || name == "help" { throw DriveUsageError(usage()) }
        guard let command = command(named: name) else {
            throw DriveUsageError("athina-drive: unknown command \"\(name)\"\n\n\(usage())")
        }

        var positionals: [String] = []
        var options: [String: String] = [:]
        var rest = Array(argv.dropFirst())
        while let argument = rest.first {
            rest.removeFirst()
            guard argument.hasPrefix("--") else {
                positionals.append(argument)
                continue
            }
            if command.options.contains("\(argument)!") {
                options[argument] = ""
                continue
            }
            guard command.options.contains(argument) else {
                throw DriveUsageError("athina-drive \(name): unknown option \"\(argument)\"\n\n\(usage(for: command))")
            }
            guard let value = rest.first else {
                throw DriveUsageError("athina-drive \(name): \"\(argument)\" needs a value\n\n\(usage(for: command))")
            }
            rest.removeFirst()
            options[argument] = value
        }

        guard positionals.count >= command.minimum, positionals.count <= command.maximum else {
            throw DriveUsageError(
                "athina-drive \(name): expected \(arity(command)), got \(positionals.count)\n\n\(usage(for: command))"
            )
        }
        return DriveInvocation(command: name, positionals: positionals, options: options)
    }

    private static func arity(_ command: Command) -> String {
        command.minimum == command.maximum
            ? "\(command.minimum) argument\(command.minimum == 1 ? "" : "s")"
            : "\(command.minimum) to \(command.maximum) arguments"
    }

    public static func usage(for command: Command? = nil) -> String {
        guard let command else {
            let width = (commands.map(\.name.count).max() ?? 8) + 2
            let lines = commands.map { "  \($0.name.padding(toLength: width, withPad: " ", startingAt: 0))\($0.arguments)" }
            return (["usage: athina-drive <command> [arguments]", ""] + lines).joined(separator: "\n")
        }
        return "usage: athina-drive \(command.name) \(command.arguments)\n  \(command.summary)"
    }
}

public extension DriveInvocation {
    func positional(_ index: Int) throws -> String {
        guard index < positionals.count else {
            throw DriveUsageError("athina-drive \(command): missing argument \(index + 1)")
        }
        return positionals[index]
    }

    func pid(_ index: Int) throws -> Int32 {
        let raw = try positional(index)
        guard let value = Int32(raw), value > 0 else {
            throw DriveUsageError("athina-drive \(command): \"\(raw)\" is not a pid")
        }
        return value
    }

    func number(_ index: Int) throws -> Double {
        let raw = try positional(index)
        guard let value = Double(raw) else {
            throw DriveUsageError("athina-drive \(command): \"\(raw)\" is not a number")
        }
        return value
    }

    func option(_ name: String) -> String? { options[name] }
    func flag(_ name: String) -> Bool { options[name] != nil }
}
