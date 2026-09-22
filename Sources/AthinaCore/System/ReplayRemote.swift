import Foundation

/// What every request a script sends a running replay has in common: a
/// distributed notification addressed to one replay by its pid, which only a
/// replay listens for, answered at a file the request names (`ClockRemote`
/// moves the clock, `TalkBackRemote` plays a recording into the listener).
public enum ReplayRemote {
    /// Writes a replay's answer to a request at the path the request named,
    /// and only where a request may make a replay write: a file that does not
    /// exist yet, inside the system temporary directory, never inside the
    /// live data folder. Does nothing when the request named none, and throws
    /// rather than writing otherwise, which the caller logs.
    ///
    /// Nothing authenticates this channel. The notification name is a
    /// constant and a replay's pid is in `ps`, so any process in the login
    /// session can ask a running replay to answer somewhere; an unconstrained
    /// path would make that a way to create or replace any file the user can
    /// write, the live settings among them. Refusing to replace a file closes
    /// the rest: the exclusive create fails on a symlink too. It costs
    /// `scripts/advance-clock.sh` and `scripts/talk-back.sh` nothing: each
    /// names a fresh `mktemp` path that it has already removed, in the
    /// per-user temporary directory (`getconf DARWIN_USER_TEMP_DIR`) that
    /// `NSTemporaryDirectory` names.
    ///
    /// The path is resolved once and that one path is both checked and written
    /// to. Checking what was asked for and writing to it are not the same
    /// thing: `..` after a symlink means one path to `AppPaths.resolvedPath`,
    /// which folds `..` away before resolving links, and another to the
    /// kernel, which follows the link first. A request could name
    /// `<temp>/link-into-the-live-folder/../file` and pass a check that read
    /// `<temp>/file` while the write landed in the live data folder.
    public static func write(
        _ data: Data,
        at url: URL?,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        supportDirectory: URL = AppPaths.supportDirectory()
    ) throws {
        guard let url else { return }
        let target = URL(fileURLWithPath: AppPaths.resolvedPath(url))
        guard AppPaths.isAt(target, orInside: temporaryDirectory),
              !AppPaths.isAt(target, orInside: supportDirectory) else {
            throw Refusal(reason: "\(target.path) is not somewhere a request may be answered: it must be inside \(temporaryDirectory.path) and outside \(supportDirectory.path)")
        }
        do {
            try data.write(to: target, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw Refusal(reason: "\(target.path) already exists, and a request never replaces a file")
        }
    }

    /// Where the request asks for its answer, or nil when it asked for none.
    /// A relative path is refused rather than resolved, because the app's
    /// working directory is `/` when it was started with `open`.
    public static func replyURL(from userInfo: [AnyHashable: Any]?, key: String) -> URL? {
        guard let path = userInfo?[key] as? String, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    public struct Refusal: Error, Equatable {
        public var reason: String
    }
}
