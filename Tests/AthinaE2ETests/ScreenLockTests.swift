import Darwin
import Foundation
import Testing

/// The harness's machine-wide screen lock (`scripts/e2e/lib/lock.sh`), driven
/// through the stock `/bin/bash` and `/usr/bin/lockf` the way a run takes it,
/// under the harness's own `set -euo pipefail`, on a lock file of each test's
/// own so tests never wait on a real run or on each other.
@Suite struct ScreenLockTests {
    private static let library = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AthinaE2ETests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("scripts/e2e/lib/lock.sh").path

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("athina-screen-lock-\(UUID().uuidString)", isDirectory: true)

    private var lock: String { directory.appendingPathComponent("screen.lock").path }
    private var holderFile: String { lock + ".holder" }

    private struct Finished {
        let status: Int32
        let output: String
        let seconds: Double
    }

    private func process(_ script: String, checkout: String, arguments: [String] = []) throws -> (Process, URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("output-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -euo pipefail\nsource '\(Self.library)'\n\(script)", "bash"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ATHINA_E2E_SCREEN_LOCK"] = lock
        environment["ROOT"] = checkout
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return (process, output)
    }

    private func run(_ script: String, checkout: String = "/checkouts/two", arguments: [String] = []) throws -> Finished {
        let started = Date()
        let (process, output) = try self.process(script, checkout: checkout, arguments: arguments)
        process.waitUntilExit()
        let text = try String(contentsOf: output, encoding: .utf8)
        return Finished(status: process.terminationStatus, output: text, seconds: Date().timeIntervalSince(started))
    }

    /// A harness that takes the lock as `what`, says so by making `ready`, and
    /// then holds it for `seconds` in short foreground steps, the way a run's
    /// waits do.
    private func startHolder(_ what: String, seconds: Double, checkout: String = "/checkouts/one") throws -> Process {
        let ready = directory.appendingPathComponent("ready-\(UUID().uuidString)").path
        let steps = Int(seconds / 0.1)
        let (process, _) = try self.process(
            """
            screen_lock_acquire '\(what)' || exit 1
            touch '\(ready)'
            for _ in $(seq 1 \(steps)); do sleep 0.1; done
            """,
            checkout: checkout
        )
        try waitFor("the holder to take the lock") { FileManager.default.fileExists(atPath: ready) }
        return process
    }

    private func waitFor(_ what: String, within seconds: Double = 10, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw WaitTimedOut(what: what) }
            usleep(50_000)
        }
    }

    private struct WaitTimedOut: Error { let what: String }

    // MARK: Which commands lock

    @Test(arguments: ["run", "warm", "clean"])
    func commandsOnTheScreenOrTheWarmHomeTakeTheLock(command: String) throws {
        #expect(try run("screen_lock_needed \"$1\"", arguments: [command]).status == 0)
    }

    @Test(arguments: ["list", "doctor", "journal", "help", ""])
    func commandsThatTouchNeitherNeverWait(command: String) throws {
        #expect(try run("screen_lock_needed \"$1\"", arguments: [command]).status == 1)
    }

    // MARK: Who holds it

    @Test func theFirstAncestorWithTheFileOpenHoldsIt() throws {
        let found = try run("first_holding_ancestor \"$(printf '30\\n20\\n10')\" \"$(printf '99\\n20\\n10')\"")
        #expect(found.status == 0)
        #expect(found.output == "20\n")
        let none = try run("first_holding_ancestor \"$(printf '30\\n20')\" \"$(printf '99\\n2')\"")
        #expect(none.status == 1)
        #expect(none.output.isEmpty)
    }

    @Test func aHolderSaysWhoItIsAndTakesItDownOnRelease() throws {
        let finished = try run(
            """
            screen_lock_acquire 'run menubar-keyboard' || exit 1
            cat "$SCREEN_LOCK_HOLDER"
            screen_lock_release
            [ -e "$SCREEN_LOCK_HOLDER" ] && echo still-there
            echo "pid=$$"
            """,
            checkout: "/checkouts/one"
        )
        #expect(finished.status == 0)
        let lines = finished.output.split(separator: "\n").map(String.init)
        let pid = try #require(lines.last)
        #expect(lines.contains("checkout=/checkouts/one"))
        #expect(lines.contains("what=run menubar-keyboard"))
        #expect(lines.filter { $0 == pid }.count == 2)  // the holder file's and the shell's own
        #expect(lines.contains { $0.hasPrefix("since=20") })
        #expect(!lines.contains("still-there"))
        // Released: the next run takes it at once.
        #expect(try run("screen_lock_acquire 'run next' 0").status == 0)
    }

    // MARK: Exclusion

    @Test func aSecondRunWaitsForTheFirstAndNamesIt() throws {
        let holder = try startHolder("run menubar-keyboard", seconds: 1.5)
        let waiter = try run("screen_lock_acquire 'run other-app-click' && echo acquired")
        holder.waitUntilExit()
        #expect(waiter.status == 0)
        #expect(waiter.output.contains("acquired"))
        #expect(waiter.seconds >= 0.8, "the second run did not wait: \(waiter.seconds)s")
        let waiting = try #require(waiter.output.split(separator: "\n").first { $0.contains("waiting for the screen lock") })
        #expect(waiting.contains("held by /checkouts/one running \"run menubar-keyboard\" (pid \(holder.processIdentifier)) since "))
        #expect(waiter.output.split(separator: "\n").filter { $0.contains("waiting") }.count == 1)
        #expect(waiter.output.contains("took the screen lock after "))
    }

    @Test func aTimeoutGivesUpWithTheHolderNamed() throws {
        let holder = try startHolder("warm", seconds: 10)
        defer { holder.terminate() }
        let waiter = try run("screen_lock_acquire 'run all' 1")
        #expect(waiter.status == 75)
        #expect(waiter.output.contains("gave up on the screen lock after 1s; still held by /checkouts/one running \"warm\""))
    }

    @Test func aTimeoutMustBeWholeSeconds() throws {
        let waiter = try run("screen_lock_acquire 'run all' soon")
        #expect(waiter.status == 64)
        #expect(waiter.output.contains("--lock-timeout takes a whole number of seconds"))
    }

    @Test func aHolderThatWasKilledLeavesNoStaleLock() throws {
        let holder = try startHolder("run capture-race", seconds: 60)
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        // The holder file is left behind by a kill -9; the lock is not.
        #expect(FileManager.default.fileExists(atPath: holderFile))
        let next = try run("screen_lock_acquire 'run next' 5 && echo acquired")
        #expect(next.status == 0)
        #expect(next.output.contains("acquired"))
        #expect(next.seconds < 3)
    }

    @Test func aRunStoppedWhileWaitingLeavesNothingQueued() throws {
        let holder = try startHolder("run menubar-width", seconds: 10)
        defer { holder.terminate() }
        let (waiter, output) = try process("screen_lock_acquire 'run all'", checkout: "/checkouts/two")
        try waitFor("the waiter to queue") {
            (try? String(contentsOf: output, encoding: .utf8))?.contains("waiting for the screen lock") ?? false
        }
        let queued = try run("pgrep -P \(waiter.processIdentifier) -x lockf")
        let lockf = try #require(Int32(queued.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(waiter.processIdentifier, SIGTERM)
        waiter.waitUntilExit()
        try waitFor("its lockf to go") { kill(lockf, 0) != 0 }
    }

    // MARK: A hand-held lockf

    @Test func aHandHeldLockfAndAHarnessRunExcludeEachOther() throws {
        // A stale holder file from a run that is gone must not be reported.
        let old = try startHolder("run gone", seconds: 60)
        kill(old.processIdentifier, SIGKILL)
        old.waitUntilExit()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("hand-ready").path
        let hand = Process()
        hand.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        hand.arguments = ["-k", lock, "/bin/sh", "-c", "touch '\(ready)'; sleep 10"]
        try hand.run()
        defer { hand.terminate() }
        try waitFor("the hand-held lockf") { FileManager.default.fileExists(atPath: ready) }

        // A harness already queued behind it is not named as a holder.
        let (queued, queuedOutput) = try process("screen_lock_acquire 'run queued' 5", checkout: "/checkouts/three")
        defer { queued.terminate() }
        try waitFor("the first waiter to queue") {
            (try? String(contentsOf: queuedOutput, encoding: .utf8))?.contains("waiting for the screen lock") ?? false
        }

        let waiter = try run("screen_lock_acquire 'run all' 1")
        #expect(waiter.status == 75)
        let named = "held outside the harness (pid \(hand.processIdentifier): /usr/bin/lockf -k \(lock) /bin/sh -c touch"
        #expect(waiter.output.contains(named))
        #expect(!waiter.output.contains("pid \(queued.processIdentifier)"))
        #expect(!waiter.output.contains("run gone"))
    }

    // MARK: Re-entrancy

    @Test func aRunStartedUnderAHandHeldLockfDoesNotWaitOnIt() throws {
        let hand = Process()
        hand.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        let script = "source '\(Self.library)'; screen_lock_acquire 'run all' 2 && echo acquired && cat \"$SCREEN_LOCK_HOLDER\""
        hand.arguments = ["-k", lock, "/bin/bash", "-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["ATHINA_E2E_SCREEN_LOCK"] = lock
        environment["ROOT"] = "/checkouts/one"
        hand.environment = environment
        let pipe = Pipe()
        hand.standardOutput = pipe
        hand.standardError = pipe
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try hand.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        hand.waitUntilExit()
        #expect(hand.terminationStatus == 0)
        #expect(output.contains("already held by pid \(hand.processIdentifier), which started this run"))
        // It says who is on the screen, since the hand-held lockf cannot.
        #expect(output.contains("owner=\(hand.processIdentifier)"))
        #expect(output.contains("what=run all"))
    }

    @Test func aHarnessStartedByOneThatHoldsTheLockDoesNotWaitOnIt() throws {
        let finished = try run(
            """
            screen_lock_acquire 'run all' || exit 1
            /bin/bash -c "source '\(Self.library)'; screen_lock_acquire 'run menubar-mark' 2 && echo nested-acquired"
            """
        )
        #expect(finished.status == 0)
        #expect(finished.output.contains("nested-acquired"))
        #expect(!finished.output.contains("waiting"))
    }
}
