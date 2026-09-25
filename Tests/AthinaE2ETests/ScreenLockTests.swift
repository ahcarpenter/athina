import Darwin
import Foundation
import Testing

/// The harness's machine-wide screen lock and each checkout's own lock
/// (`scripts/e2e/lib/lock.sh`), driven through the stock `/bin/bash` and
/// `/usr/bin/lockf` the way a run takes them, under the harness's own
/// `set -euo pipefail`, on lock files of each test's own so tests never wait
/// on a real run or on each other.
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

  private func process(
    _ script: String,
    checkout: String,
    arguments: [String] = []
  ) throws -> (Process, URL) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let output = directory.appendingPathComponent("output-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments =
      ["-c", "set -euo pipefail\nsource '\(Self.library)'\n\(script)", "bash"] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["ATHINA_E2E_SCREEN_LOCK"] = lock
    environment["ROOT"] = checkout
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    return (process, output)
  }

  private func run(
    _ script: String,
    checkout: String = "/checkouts/two",
    arguments: [String] = []
  ) throws -> Finished {
    let started = Date()
    let (process, output) = try self.process(script, checkout: checkout, arguments: arguments)
    process.waitUntilExit()
    let text = try String(contentsOf: output, encoding: .utf8)
    return Finished(
      status: process.terminationStatus,
      output: text,
      seconds: Date().timeIntervalSince(started)
    )
  }

  /// A checkout of this test's own, whose checkout lock is under it.
  private func checkout(_ name: String) -> String { directory.appendingPathComponent(name).path }

  /// A harness that takes `lock` as `what`, says so by making `ready`, and
  /// then holds it for `seconds` in short foreground steps, the way a run's
  /// waits do.
  private func startHolder(
    _ what: String,
    seconds: Double,
    checkout: String = "/checkouts/one",
    lock: String = "SCREEN_LOCK"
  ) throws -> Process {
    let ready = directory.appendingPathComponent("ready-\(UUID().uuidString)").path
    let steps = Int(seconds / 0.1)
    let (process, _) = try self.process(
      """
      lock_acquire \(lock) '\(what)' || exit 1
      touch '\(ready)'
      for _ in $(seq 1 \(steps)); do sleep 0.1; done
      """,
      checkout: checkout
    )
    try waitFor("the holder to take the lock") { FileManager.default.fileExists(atPath: ready) }
    return process
  }

  private func waitFor(_ what: String, within seconds: Double = 10, _ condition: () -> Bool) throws
  {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
      if Date() > deadline { throw WaitTimedOut(what: what) }
      usleep(50_000)
    }
  }

  private struct WaitTimedOut: Error { let what: String }

  // MARK: Which commands lock

  @Test(arguments: ["warm", "clean"])
  func commandsOnTheScreenOrTheWarmHomeTakeTheLock(command: String) throws {
    #expect(try run("screen_lock_needed \"$1\"", arguments: [command]).status == 0)
  }

  /// `run` takes it for each real-screen scenario instead, so its API-tier
  /// scenarios, which are hermetic, never wait on the screen.
  @Test func runTakesItOnlyForEachRealScreenScenario() throws {
    #expect(try run("screen_lock_needed run").status == 1)
  }

  @Test(arguments: ["list", "doctor", "journal", "help", ""])
  func commandsThatTouchNeitherNeverWait(command: String) throws {
    #expect(try run("screen_lock_needed \"$1\"", arguments: [command]).status == 1)
  }

  @Test(arguments: ["run", "warm"])
  func commandsThatBuildAndRunFromTheCheckoutTakeItsLock(command: String) throws {
    #expect(try run("checkout_lock_needed \"$1\"", arguments: [command]).status == 0)
  }

  @Test(arguments: ["clean", "list", "doctor", "journal", "help", ""])
  func commandsThatNeitherBuildNorRunNeverWaitOnTheCheckout(command: String) throws {
    #expect(try run("checkout_lock_needed \"$1\"", arguments: [command]).status == 1)
  }

  // MARK: Who holds it

  @Test func theFirstAncestorWithTheFileOpenHoldsIt() throws {
    let found = try run(
      "first_holding_ancestor \"$(printf '30\\n20\\n10')\" \"$(printf '99\\n20\\n10')\""
    )
    #expect(found.status == 0)
    #expect(found.output == "20\n")
    let none = try run("first_holding_ancestor \"$(printf '30\\n20')\" \"$(printf '99\\n2')\"")
    #expect(none.status == 1)
    #expect(none.output.isEmpty)
  }

  @Test func aHolderSaysWhoItIsAndTakesItDownOnRelease() throws {
    let finished = try run(
      """
      lock_acquire SCREEN_LOCK 'run menubar-keyboard' || exit 1
      cat "$SCREEN_LOCK_HOLDER"
      lock_release SCREEN_LOCK
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
    #expect(try run("lock_acquire SCREEN_LOCK 'run next' 0").status == 0)
  }

  // MARK: Exclusion

  @Test func aSecondRunWaitsForTheFirstAndNamesIt() throws {
    let holder = try startHolder("run menubar-keyboard", seconds: 1.5)
    let waiter = try run("lock_acquire SCREEN_LOCK 'run other-app-click' && echo acquired")
    holder.waitUntilExit()
    #expect(waiter.status == 0)
    #expect(waiter.output.contains("acquired"))
    #expect(waiter.seconds >= 0.8, "the second run did not wait: \(waiter.seconds)s")
    let waiting = try #require(
      waiter.output.split(separator: "\n").first { $0.contains("waiting for the screen lock") }
    )
    let holderLine = "held by /checkouts/one running \"run menubar-keyboard\" "
    #expect(waiting.contains(holderLine + "(pid \(holder.processIdentifier)) since "))
    #expect(waiter.output.split(separator: "\n").filter { $0.contains("waiting") }.count == 1)
    #expect(waiter.output.contains("took the screen lock after "))
  }

  @Test func aTimeoutGivesUpWithTheHolderNamed() throws {
    let holder = try startHolder("warm", seconds: 10)
    defer { holder.terminate() }
    let waiter = try run("lock_acquire SCREEN_LOCK 'run all' 1")
    #expect(waiter.status == 75)
    #expect(
      waiter.output.contains(
        "gave up on the screen lock after 1s; still held by /checkouts/one running \"warm\""
      )
    )
  }

  @Test func aTimeoutMustBeWholeSeconds() throws {
    let waiter = try run("lock_acquire SCREEN_LOCK 'run all' soon")
    #expect(waiter.status == 64)
    #expect(waiter.output.contains("--lock-timeout takes a whole number of seconds"))
  }

  @Test func aHolderThatWasKilledLeavesNoStaleLock() throws {
    let holder = try startHolder("run capture-race", seconds: 60)
    kill(holder.processIdentifier, SIGKILL)
    holder.waitUntilExit()
    // The holder file is left behind by a kill -9; the lock is not.
    #expect(FileManager.default.fileExists(atPath: holderFile))
    // A lock still held would last the holder's 60 s and give up at 5; the
    // wait covers only a `sleep` the holder left, which inherited the lock.
    let next = try run("lock_acquire SCREEN_LOCK 'run next' 5 && echo acquired")
    #expect(next.status == 0)
    #expect(next.output.contains("acquired"))
  }

  @Test func aRunStoppedWhileWaitingLeavesNothingQueued() throws {
    let holder = try startHolder("run menubar-width", seconds: 10)
    defer { holder.terminate() }
    let (waiter, output) = try process(
      "lock_acquire SCREEN_LOCK 'run all'",
      checkout: "/checkouts/two"
    )
    try waitFor("the waiter to queue") {
      (try? String(contentsOf: output, encoding: .utf8))?.contains("waiting for the screen lock")
        ?? false
    }
    let queued = try run("pgrep -P \(waiter.processIdentifier) -x lockf")
    let lockf = try #require(Int32(queued.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    kill(waiter.processIdentifier, SIGTERM)
    waiter.waitUntilExit()
    try waitFor("its lockf to go") { kill(lockf, 0) != 0 }
  }

  // MARK: Waiting for idle input first

  /// A file the test writes the seconds of idle input into, and the shell
  /// function `idle` that reads it back the way `hid_idle_seconds` reads
  /// the real ones.
  private func idleReader(_ seconds: Int) throws -> (file: String, function: String) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("idle-\(UUID().uuidString)").path
    try setIdle(seconds, in: file)
    return (file, "idle() { cat '\(file)'; }")
  }

  private func setIdle(_ seconds: Int, in file: String) throws {
    try "\(seconds)\n".write(toFile: file, atomically: true, encoding: .utf8)
  }

  /// A real-screen run's lock request, needing 15 seconds of quiet, then
  /// any further arguments, printing `acquired` once it holds the lock.
  private func whenIdle(_ reader: (file: String, function: String), _ extra: String = "") -> String
  {
    """
    \(reader.function)
    lock_acquire_when_idle SCREEN_LOCK 'run real-screen' '' 15 idle \(extra) && echo acquired
    """
  }

  private func says(_ output: URL, _ text: String) -> Bool {
    (try? String(contentsOf: output, encoding: .utf8))?.contains(text) ?? false
  }

  @Test func aQuietMacTakesTheLockAtOnce() throws {
    let finished = try run(whenIdle(try idleReader(20)))
    #expect(finished.status == 0)
    #expect(finished.output.contains("acquired"))
    #expect(finished.output.contains("input idle for 20s"))
    #expect(!finished.output.contains("waiting for 15s of idle input"))
  }

  @Test func theLockWaitsForQuietBeforeItIsTaken() throws {
    let reader = try idleReader(0)
    let (waiter, output) = try process(whenIdle(reader), checkout: "/checkouts/two")
    try waitFor("the run to wait for quiet") {
      says(output, "waiting for 15s of idle input before taking the screen lock")
    }
    // Nothing is held while it waits for quiet: another run takes the lock at once.
    let other = try run("lock_acquire SCREEN_LOCK 'run other' 0 && echo other-acquired")
    #expect(other.output.contains("other-acquired"))
    try setIdle(16, in: reader.file)
    waiter.waitUntilExit()
    #expect(waiter.terminationStatus == 0)
    #expect(says(output, "input idle for 16s"))
    #expect(says(output, "acquired"))
  }

  @Test func aMacThatNeverGoesQuietGivesUpWithoutTheLock() throws {
    let finished = try run(whenIdle(try idleReader(2), "1"))
    #expect(finished.status == 75)
    #expect(
      finished.output.contains(
        "input never went idle for 15s in 1s, so the screen lock was not taken"
      )
    )
    #expect(try run("lock_acquire SCREEN_LOCK 'run next' 0").status == 0)
  }

  @Test func inputThatComesBackDuringTheLockWaitGivesTheLockBack() throws {
    let reader = try idleReader(20)
    let holder = try startHolder("run menubar-keyboard", seconds: 60)
    defer { holder.terminate() }
    let (waiter, output) = try process(whenIdle(reader), checkout: "/checkouts/two")
    try waitFor("the run to queue for the lock") { says(output, "waiting for the screen lock") }
    try setIdle(0, in: reader.file)
    holder.terminate()
    holder.waitUntilExit()
    try waitFor("the run to give the lock back") {
      says(output, "gave it back until the Mac is quiet again")
    }
    // Given back: another run takes it while this one waits for quiet.
    #expect(try run("lock_acquire SCREEN_LOCK 'run other' 0").status == 0)
    try setIdle(20, in: reader.file)
    waiter.waitUntilExit()
    #expect(waiter.terminationStatus == 0)
    #expect(says(output, "acquired"))
  }

  // MARK: The checkout lock

  @Test func aSecondRunFromTheSameCheckoutWaitsForTheFirstAndNamesIt() throws {
    let one = checkout("one")
    let holder = try startHolder(
      "run menubar-keyboard",
      seconds: 1.5,
      checkout: one,
      lock: "CHECKOUT_LOCK"
    )
    let waiter = try run(
      "lock_acquire CHECKOUT_LOCK 'run other-app-click' && echo acquired",
      checkout: one
    )
    holder.waitUntilExit()
    #expect(waiter.status == 0)
    #expect(waiter.output.contains("acquired"))
    #expect(waiter.seconds >= 0.8, "the second run did not wait: \(waiter.seconds)s")
    let waiting = try #require(
      waiter.output.split(separator: "\n").first { $0.contains("waiting for the checkout lock") }
    )
    #expect(waiting.contains("\(one)/build/athina-e2e.lock"))
    #expect(
      waiting.contains(
        "held by \(one) running \"run menubar-keyboard\" (pid \(holder.processIdentifier)) since "
      )
    )
    #expect(waiter.output.contains("took the checkout lock after "))
  }

  @Test func aRunFromAnotherCheckoutNeverWaitsOnIt() throws {
    let holder = try startHolder(
      "run menubar-keyboard",
      seconds: 10,
      checkout: checkout("one"),
      lock: "CHECKOUT_LOCK"
    )
    defer { holder.terminate() }
    let other = try run(
      "lock_acquire CHECKOUT_LOCK 'run all' 0 && echo acquired",
      checkout: checkout("two")
    )
    #expect(other.status == 0)
    #expect(other.output.contains("took the checkout lock, which was free"))
    // Nor does the checkout lock stand in for the screen lock.
    let screen = try run(
      "lock_acquire SCREEN_LOCK 'run all' 0 && echo acquired",
      checkout: checkout("one")
    )
    #expect(screen.status == 0)
    #expect(screen.output.contains("acquired"))
  }

  @Test func aHarnessStartedByOneThatHoldsTheCheckoutDoesNotWaitOnIt() throws {
    let one = checkout("one")
    let finished = try run(
      """
      lock_acquire CHECKOUT_LOCK 'run all' || exit 1
      /bin/bash -c "source '\(Self.library)'; lock_acquire CHECKOUT_LOCK 'run menubar-mark' 2 \
      && echo nested-acquired"
      """,
      checkout: one
    )
    #expect(finished.status == 0)
    #expect(finished.output.contains("the checkout lock is already held by pid "))
    #expect(finished.output.contains("nested-acquired"))
    #expect(!finished.output.contains("waiting"))
  }

  @Test func releasingBothTakesDownBothHolderFiles() throws {
    let one = checkout("one")
    let finished = try run(
      """
      lock_acquire CHECKOUT_LOCK 'run all' || exit 1
      lock_acquire SCREEN_LOCK 'run all' || exit 1
      [ -e "$CHECKOUT_LOCK_HOLDER" ] && [ -e "$SCREEN_LOCK_HOLDER" ] && echo both-held
      locks_release
      [ -e "$CHECKOUT_LOCK_HOLDER" ] || [ -e "$SCREEN_LOCK_HOLDER" ] || echo both-gone
      """,
      checkout: one
    )
    #expect(finished.status == 0)
    #expect(finished.output.contains("both-held"))
    #expect(finished.output.contains("both-gone"))
    #expect(try run("lock_acquire CHECKOUT_LOCK 'run next' 0", checkout: one).status == 0)
  }

  @Test func aRunKilledWhileWaitingForTheScreenLeavesItsCheckoutFree() throws {
    let one = checkout("one")
    let screen = try startHolder("run menubar-width", seconds: 10, checkout: checkout("two"))
    defer { screen.terminate() }
    let (waiter, output) = try process(
      "lock_acquire CHECKOUT_LOCK 'run all' && lock_acquire SCREEN_LOCK 'run all'",
      checkout: one
    )
    try waitFor("the run to queue for the screen") {
      (try? String(contentsOf: output, encoding: .utf8))?.contains("waiting for the screen lock")
        ?? false
    }
    kill(waiter.processIdentifier, SIGKILL)
    waiter.waitUntilExit()
    let next = try run("lock_acquire CHECKOUT_LOCK 'run next' 1 && echo acquired", checkout: one)
    #expect(next.status == 0)
    #expect(next.output.contains("acquired"))
  }

  @Test func aRunUnderAHandHeldScreenLockDoesNotWaitOnItsCheckout() throws {
    let one = checkout("one")
    let holder = try startHolder(
      "run menubar-keyboard",
      seconds: 10,
      checkout: one,
      lock: "CHECKOUT_LOCK"
    )
    defer { holder.terminate() }
    let hand = Process()
    hand.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    let script = "set -euo pipefail; source '\(Self.library)'; checkout_lock_acquire 'run all'"
    hand.arguments = ["-k", lock, "/bin/bash", "-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["ATHINA_E2E_SCREEN_LOCK"] = lock
    environment["ROOT"] = one
    hand.environment = environment
    let pipe = Pipe()
    hand.standardOutput = pipe
    hand.standardError = pipe
    let started = Date()
    try hand.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    hand.waitUntilExit()
    #expect(hand.terminationStatus == 75)
    #expect(Date().timeIntervalSince(started) < 5, "it waited on the run that holds its checkout")
    #expect(
      output.contains(
        "the screen lock is held by pid \(hand.processIdentifier), which started this run"
      )
    )
    #expect(
      output.contains(
        "still held by \(one) running \"run menubar-keyboard\" (pid \(holder.processIdentifier))"
      )
    )
    // Free, it takes it.
    holder.terminate()
    holder.waitUntilExit()
    let free = try run("checkout_lock_acquire 'run all' && echo acquired", checkout: one)
    #expect(free.status == 0)
    #expect(free.output.contains("took the checkout lock, which was free"))
  }

  // MARK: A hand-held lockf

  @Test func aHandHeldLockfAndAHarnessRunExcludeEachOther() throws {
    // A stale holder file from a run that is gone must not be reported.
    let old = try startHolder("run gone", seconds: 60)
    kill(old.processIdentifier, SIGKILL)
    old.waitUntilExit()

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Both the hand-held lockf and the harness queued behind it stay until
    // the test is done with them, however slow the Mac is: either one
    // leaving early changes who the waiter names.
    let ready = directory.appendingPathComponent("hand-ready").path
    let stop = directory.appendingPathComponent("hand-stop").path
    let hand = Process()
    hand.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    hand.arguments = [
      "-k", lock, "/bin/sh", "-c",
      "touch '\(ready)'; for _ in $(seq 1 600); do [ -e '\(stop)' ] && exit 0; sleep 0.1; done",
    ]
    try hand.run()
    defer {
      FileManager.default.createFile(atPath: stop, contents: nil)
      hand.waitUntilExit()
    }
    try waitFor("the hand-held lockf") { FileManager.default.fileExists(atPath: ready) }

    // A harness already queued behind it is not named as a holder.
    let (queued, queuedOutput) = try process(
      "lock_acquire SCREEN_LOCK 'run queued' 60",
      checkout: "/checkouts/three"
    )
    defer { queued.terminate() }
    try waitFor("the first waiter to queue") {
      (try? String(contentsOf: queuedOutput, encoding: .utf8))?.contains(
        "waiting for the screen lock"
      ) ?? false
    }
    // It says so before it starts the lockf it queues on.
    try waitFor("the first waiter's lockf") {
      (try? run("pgrep -P \(queued.processIdentifier) -x lockf").status) == 0
    }

    let waiter = try run("lock_acquire SCREEN_LOCK 'run all' 1")
    #expect(waiter.status == 75)
    let named =
      """
      held outside the harness (pid \(hand.processIdentifier): /usr/bin/lockf -k \(lock) \
      /bin/sh -c touch
      """
    #expect(waiter.output.contains(named))
    #expect(!waiter.output.contains("pid \(queued.processIdentifier)"))
    #expect(!waiter.output.contains("run gone"))
  }

  // MARK: Re-entrancy

  @Test func aRunStartedUnderAHandHeldLockfDoesNotWaitOnIt() throws {
    let hand = Process()
    hand.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    let script =
      """
      source '\(Self.library)'; lock_acquire SCREEN_LOCK 'run all' 2 && echo acquired && cat \
      \"$SCREEN_LOCK_HOLDER\"
      """
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
    #expect(
      output.contains("already held by pid \(hand.processIdentifier), which started this run")
    )
    // It says who is on the screen, since the hand-held lockf cannot.
    #expect(output.contains("owner=\(hand.processIdentifier)"))
    #expect(output.contains("what=run all"))
  }

  @Test func aHarnessStartedByOneThatHoldsTheLockDoesNotWaitOnIt() throws {
    let finished = try run(
      """
      lock_acquire SCREEN_LOCK 'run all' || exit 1
      /bin/bash -c "source '\(Self.library)'; lock_acquire SCREEN_LOCK 'run menubar-mark' 2 && \
      echo nested-acquired"
      """
    )
    #expect(finished.status == 0)
    #expect(finished.output.contains("nested-acquired"))
    #expect(!finished.output.contains("waiting"))
  }
}
