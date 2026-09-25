import Foundation

/// Whether this launch serves the end-to-end harness's control API, chosen once
/// at launch from `--control <directory>` (README "The control API").
///
/// The API lets a scenario find Athina's controls, click and type in its own
/// windows, and read its state, so it must never reach a person's copy of the
/// app: any program on the Mac could then drive Athina, read what it keeps, or
/// start paid model calls. So it is served only when every one of these holds,
/// and refused, with the reason, otherwise:
///
/// - the build carries it at all: the server is compiled in only under the
///   `ControlAPI` package trait, which only the development bundle turns on,
///   so a release or App Store build refuses the flag whatever else is true;
/// - the launch is a replay, which reads no key, keeps its own files, and
///   bills nothing;
/// - the process is not sandboxed (`RuntimeEnvironment`), so a sandboxed build
///   made from the development bundle refuses it too;
/// - the directory is one the harness made for this run: absolute, a real
///   directory owned by this user with mode 0700 exactly, holding
///   the run's secret in `secret`, a file of its own closed to everyone else,
///   and short enough for a Unix socket path inside it.
///
/// A refusal shows in the menu, the debug panel's Mentor card, and the log, as
/// the clock flags' do.
///
/// A launch that serves the API is a hermetic run (README "Hermetic runs"): it
/// takes nothing from the real world and leaves nothing in it, so any number
/// can run beside each other and beside whoever is at the Mac. It senses
/// nothing, listens to no global input, never activates itself, keeps its item
/// out of the menu bar, and parks every window it opens below the desktop
/// picture, or, with `--show-windows`, leaves them where a person can watch.
public enum ControlMode: Equatable, Sendable {
    /// No `--control` on the command line.
    case off
    /// Serve the API on this channel.
    case on(ControlChannel)
    /// `--control` was given and is not served, and why.
    case refused(String)

    public static let flag = "--control"
    /// Leaves a hermetic run's windows on screen rather than parking them, to
    /// watch what a scenario does or to compare its checkpoints with a parked
    /// run's. Read only with `flag`.
    public static let showWindowsFlag = "--show-windows"
    /// The socket the app makes inside the directory.
    public static let socketName = "control.sock"
    /// The file inside the directory that holds the run's secret.
    public static let secretName = "secret"
    /// The fewest characters a secret may have: the harness writes 64 hex digits.
    public static let minimumSecretLength = 32
    /// A Unix socket's path is at most 103 bytes on macOS (`sun_path` holds
    /// 104, the last of them its terminating zero).
    public static let socketPathLimit = 103

    public init(
        arguments: [String],
        clientMode: ModelClientMode,
        environment: RuntimeEnvironment,
        compiledIn: Bool,
        inspect: (URL) -> ControlDirectory = ControlDirectory.inspect
    ) {
        guard let index = arguments.firstIndex(of: ControlMode.flag) else {
            self = .off
            return
        }
        guard compiledIn else {
            self = .refused("\(ControlMode.flag): this Athina was built without the control API")
            return
        }
        guard case .replay = clientMode else {
            self = .refused("\(ControlMode.flag) applies only to \(ModelClientMode.replayFlag)")
            return
        }
        guard !environment.isSandboxed else {
            self = .refused("\(ControlMode.flag): a sandboxed Athina has no control API")
            return
        }
        let value = index + 1 < arguments.count ? arguments[index + 1] : ""
        guard !value.isEmpty, !value.hasPrefix("--") else {
            self = .refused("\(ControlMode.flag) needs the directory the harness made for this run")
            return
        }
        guard value.hasPrefix("/") else {
            self = .refused("\(ControlMode.flag) needs an absolute directory, not \(value)")
            return
        }
        let directory = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        let socketPath = directory.appendingPathComponent(ControlMode.socketName).path
        guard socketPath.utf8.count <= ControlMode.socketPathLimit else {
            self = .refused(
                "\(ControlMode.flag): a socket path is at most \(ControlMode.socketPathLimit) bytes, and one inside this directory would be \(socketPath.utf8.count): \(directory.path)"
            )
            return
        }
        let facts = inspect(directory)
        if let refusal = facts.refusal {
            self = .refused("\(ControlMode.flag): \(refusal): \(directory.path)")
            return
        }
        guard let secret = facts.secret, secret.count >= ControlMode.minimumSecretLength else {
            self = .refused(
                "\(ControlMode.flag): the directory's \(ControlMode.secretName) file must hold at least \(ControlMode.minimumSecretLength) characters: \(directory.path)"
            )
            return
        }
        self = .on(ControlChannel(
            directory: directory, secret: secret, parksWindows: !arguments.contains(ControlMode.showWindowsFlag)
        ))
    }

    /// Why `--control` was not served, or nil when it was or was not asked for.
    public var refusal: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }

    /// Whether this launch is a hermetic run: only one that serves the API,
    /// so a refused `--control` leaves a launch as it would be without it.
    public var isHermetic: Bool {
        if case .on = self { return true }
        return false
    }

    /// Whether a hermetic run parks its windows below the desktop picture.
    public var parksWindows: Bool {
        if case .on(let channel) = self { return channel.parksWindows }
        return false
    }
}

/// Where the control API listens and the secret every request must carry.
public struct ControlChannel: Equatable, Sendable {
    public var directory: URL
    public var secret: String
    /// False under `--show-windows`, which leaves the run's windows on screen.
    public var parksWindows: Bool

    public init(directory: URL, secret: String, parksWindows: Bool = true) {
        self.directory = directory
        self.secret = secret
        self.parksWindows = parksWindows
    }

    public var socketPath: String {
        directory.appendingPathComponent(ControlMode.socketName).path
    }
}

/// What `ControlMode` needs to know about a control directory, read from the
/// file system by `inspect` and written by hand in tests.
public struct ControlDirectory: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case missing
        /// Something other than a real directory: a file, or a symbolic link.
        case notADirectory
        case directory
    }

    public var kind: Kind
    public var ownedByUser: Bool
    /// The permission bits, such as 0o700.
    public var permissions: UInt16
    /// Whether `secret` is a regular file owned by this user and closed to
    /// everyone else.
    public var secretFileIsPrivate: Bool
    /// The secret, trimmed, or nil when there is no secret file to read.
    public var secret: String?

    public init(kind: Kind, ownedByUser: Bool = true, permissions: UInt16 = 0o700, secretFileIsPrivate: Bool = true, secret: String? = nil) {
        self.kind = kind
        self.ownedByUser = ownedByUser
        self.permissions = permissions
        self.secretFileIsPrivate = secretFileIsPrivate
        self.secret = secret
    }

    /// Why this directory will not do, or nil when it will; the secret's
    /// length is `ControlMode`'s to judge.
    var refusal: String? {
        switch kind {
        case .missing: return "there is no such directory"
        case .notADirectory: return "not a directory (a symbolic link is not accepted either)"
        case .directory: break
        }
        guard ownedByUser else { return "the directory must be owned by this user" }
        guard permissions == 0o700 else {
            return "the directory's mode must be exactly 0700, not \(String(permissions, radix: 8))"
        }
        guard secret != nil else { return "the directory holds no \(ControlMode.secretName) file" }
        guard secretFileIsPrivate else {
            return "the \(ControlMode.secretName) file must be a file of this user's that no one else can read"
        }
        return nil
    }

    /// Reads a directory without following a symbolic link at it or at its
    /// secret.
    public static func inspect(_ directory: URL) -> ControlDirectory {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { return ControlDirectory(kind: .missing) }
        guard info.st_mode & S_IFMT == S_IFDIR else { return ControlDirectory(kind: .notADirectory) }
        var facts = ControlDirectory(
            kind: .directory,
            ownedByUser: info.st_uid == getuid(),
            permissions: UInt16(info.st_mode & 0o7777)
        )
        let secretURL = directory.appendingPathComponent(ControlMode.secretName)
        var secretInfo = stat()
        guard lstat(secretURL.path, &secretInfo) == 0 else { return facts }
        facts.secretFileIsPrivate = secretInfo.st_mode & S_IFMT == S_IFREG
            && secretInfo.st_uid == getuid()
            && secretInfo.st_mode & 0o077 == 0
        facts.secret = (try? String(contentsOf: secretURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return facts
    }
}
