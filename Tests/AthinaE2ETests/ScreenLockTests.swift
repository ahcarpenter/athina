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
    let (process, output) = try self.process(script, checkout: checkout, arguments: arguments)
    process.waitUntilExit()
    let text = try String(contentsOf: output, encoding: .utf8)
    return Finished(status: process.terminationStatus, output: text)
  }

  /// A checkout of this test's own, whose checkout lock is under it.
  private func checkout(_ name: String) -> String { directory.appendingPathComponent(name).path }

  /// A harness holding a lock until the test lets it go.
  private struct Holder {
    let process: Process
    let stop: String

    var processIdentifier: Int32 { process.processIdentifier }

    /// Lets the lock go, and waits until the holder is gone.
    func release() {
      FileManager.default.createFile(atPath: stop, contents: nil)
      process.waitUntilExit()
    }
  }

  /// A harness that takes `lock` as `what`, says so by making `ready`, and
  /// then holds it until the test releases it.
  ///
  /// It holds it in short foreground steps, the way a run's waits do, for as
  /// long as the test takes, however slow the Mac is: a test waits on what
  /// the holder has done, never on how long it held. After five minutes it
  /// gives the lock back anyway, so one a failed test left behind cannot
  /// keep it.
  private func startHolder(
    _ what: String,
    checkout: String = "/checkouts/one",
    lock: String = "SCREEN_LOCK"
  ) throws -> Holder {
    let ready = directory.appendingPathComponent("ready-\(UUID().uuidString)").path
    let stop = directory.appendingPathComponent("stop-\(UUID().uuidString)").path
    let (process, _) = try self.process(
      """
      lock_acquire \(lock) '\(what)' || exit 1
      touch '\(ready)'
      for (( step = 0; step < 3000; step++ )); do
        [ -e '\(stop)' ] && exit 0
        sleep 0.1
      done
      """,
      checkout: checkout
    )
    try waitFor("the holder to take the lock") { FileManager.default.fileExists(atPath: ready) }
    return Holder(process: process, stop: stop)
  }

  /// Waits until `condition` holds, for as long as a loaded Mac needs.
  ///
  /// The limit only keeps a broken lock from hanging the suite.
  private func waitFor(_ what: String, within seconds: Double = 60, _ condition: () -> Bool) throws
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
    let holder = try startHolder("run menubar-keyboard")
    defer { holder.release() }
    let waiter = try waitBehind(holder, "lock_acquire SCREEN_LOCK 'run other-app-click'")
    #expect(waiter.status == 0)
    #expect(waiter.output.contains("acquired"))
    let waiting = try #require(
      waiter.output.split(separator: "\n").first { $0.contains("waiting for the screen lock") }
    )
    let holderLine = "held by /checkouts/one running \"run menubar-keyboard\" "
    #expect(waiting.contains(holderLine + "(pid \(holder.processIdentifier)) since "))
    #expect(waiter.output.split(separator: "\n").filter { $0.contains("waiting") }.count == 1)
    #expect(waiter.output.contains("took the screen lock after "))
  }

  /// Runs `acquire` from another checkout while `holder` holds the lock it
  /// takes, and checks it queues and holds nothing until the holder lets go,
  /// in that order rather than by how long it took.
  private func waitBehind(
    _ holder: Holder,
    _ acquire: String,
    checkout: String = "/checkouts/two"
  ) throws -> Finished {
    let (waiter, output) = try process("\(acquire) && echo acquired", checkout: checkout)
    try waitFor("the second run to queue") { says(output, "waiting for the ") }
    #expect(waiter.isRunning)
    #expect(!says(output, "acquired"), "the second run took the lock the first one holds")
    holder.release()
    waiter.waitUntilExit()
    return Finished(
      status: waiter.terminationStatus,
      output: try String(contentsOf: output, encoding: .utf8)
    )
  }

  @Test func aTimeoutGivesUpWithTheHolderNamed() throws {
    let holder = try startHolder("warm")
    defer { holder.release() }
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
    let holder = try startHolder("run capture-race")
    defer { holder.release() }
    kill(holder.processIdentifier, SIGKILL)
    holder.process.waitUntilExit()
    // The holder file is left behind by a kill -9; the lock is not.
    #expect(FileManager.default.fileExists(atPath: holderFile))
    // A lock still held would last the holder's five minutes and give up
    // first; the wait covers only a `sleep` the holder left, which inherited
    // the lock and ends on its own.
    let next = try run("lock_acquire SCREEN_LOCK 'run next' 60 && echo acquired")
    #expect(next.status == 0)
    #expect(next.output.contains("acquired"))
  }

  @Test func aRunStoppedWhileWaitingLeavesNothingQueued() throws {
    let holder = try startHolder("run menubar-width")
    defer { holder.release() }
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

  /// A real-screen run's lock request, with `idle` defined by `function`,
  /// needing 15 seconds of quiet, then any further arguments, printing
  /// `acquired` once it holds the lock.
  private func whenIdle(_ function: String, _ extra: String = "") -> String {
    """
    \(function)
    lock_acquire_when_idle SCREEN_LOCK 'run real-screen' '' 15 idle \(extra) && echo acquired
    """
  }

  private func says(_ output: URL, _ text: String) -> Bool {
    (try? String(contentsOf: output, encoding: .utf8))?.contains(text) ?? false
  }

  @Test func aQuietMacTakesTheLockAtOnce() throws {
    let finished = try run(whenIdle(try idleReader(20).function))
    #expect(finished.status == 0)
    #expect(finished.output.contains("acquired"))
    #expect(finished.output.contains("input idle for 20s"))
    #expect(!finished.output.contains("waiting for 15s of idle input"))
  }

  @Test func theLockWaitsForQuietBeforeItIsTaken() throws {
    let reader = try idleReader(0)
    let (waiter, output) = try process(whenIdle(reader.function), checkout: "/checkouts/two")
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
    let finished = try run(whenIdle(try idleReader(2).function, "1"))
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
    let holder = try startHolder("run menubar-keyboard")
    defer { holder.release() }
    let (waiter, output) = try process(whenIdle(reader.function), checkout: "/checkouts/two")
    try waitFor("the run to queue for the lock") { says(output, "waiting for the screen lock") }
    try setIdle(0, in: reader.file)
    holder.release()
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

  @Test func theLimitCountsTheIdleWaitsOfEveryRoundButNotTheLockWait() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let calls = directory.appendingPathComponent("idle-calls-\(UUID().uuidString)").path
    // Quiet at the third read alone, so the first round waits two seconds for
    // it, input comes back while the run waits for the lock, and the second
    // round never sees quiet: the same every time, however slow the Mac is.
    let counted = """
      idle() { echo x >>'\(calls)'; [ "$(wc -l <'\(calls)')" -eq 3 ] && echo 20 || echo 0; }
      """
    let holder = try startHolder("run menubar-keyboard")
    defer { holder.release() }
    let (waiter, output) = try process(whenIdle(counted, "5"), checkout: "/checkouts/two")
    try waitFor("the run to queue for the lock") { says(output, "waiting for the screen lock") }
    // Longer than the whole limit, which a lock wait does not use up.
    usleep(6_000_000)
    #expect(waiter.isRunning)
    holder.release()
    waiter.waitUntilExit()
    #expect(waiter.terminationStatus == 75)
    #expect(says(output, "gave it back until the Mac is quiet again"))
    #expect(says(output, "input never went idle for 15s in 5s, so the screen lock was not taken"))
    // One idle read per second waited in either round, one each time a round
    // gives up or ends, and one after the lock: the limit plus three, only
    // when the second round has just what the first left of the limit.
    let reads = try String(contentsOfFile: calls, encoding: .utf8).split(separator: "\n").count
    #expect(reads == 5 + 3)
  }

  // MARK: The checkout lock

  @Test func aSecondRunFromTheSameCheckoutWaitsForTheFirstAndNamesIt() throws {
    let one = checkout("one")
    let holder = try startHolder("run menubar-keyboard", checkout: one, lock: "CHECKOUT_LOCK")
    defer { holder.release() }
    let waiter = try waitBehind(
      holder,
      "lock_acquire CHECKOUT_LOCK 'run other-app-click'",
      checkout: one
    )
    #expect(waiter.status == 0)
    #expect(waiter.output.contains("acquired"))
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
      checkout: checkout("one"),
      lock: "CHECKOUT_LOCK"
    )
    defer { holder.release() }
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
    let screen = try startHolder("run menubar-width", checkout: checkout("two"))
    defer { screen.release() }
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
    // A checkout lock still held would give up first; the wait covers only
    // the queued lockf, which closes the checkout lock's descriptor as it starts.
    let next = try run("lock_acquire CHECKOUT_LOCK 'run next' 60 && echo acquired", checkout: one)
    #expect(next.status == 0)
    #expect(next.output.contains("acquired"))
  }

  @Test func aRunUnderAHandHeldScreenLockDoesNotWaitOnItsCheckout() throws {
    let one = checkout("one")
    let holder = try startHolder("run menubar-keyboard", checkout: one, lock: "CHECKOUT_LOCK")
    defer { holder.release() }
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
    try hand.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    hand.waitUntilExit()
    // Asked with no timeout, it gave up at once rather than wait on the run
    // that holds its checkout, which holds it until it is released below.
    #expect(hand.terminationStatus == 75)
    #expect(output.contains("gave up on the checkout lock after 0s"))
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
    holder.release()
    let free = try run("checkout_lock_acquire 'run all' && echo acquired", checkout: one)
    #expect(free.status == 0)
    #expect(free.output.contains("took the checkout lock, which was free"))
  }

  // MARK: A hand-held lockf

  @Test func aHandHeldLockfAndAHarnessRunExcludeEachOther() throws {
    // A stale holder file from a run that is gone must not be reported.
    let old = try startHolder("run gone")
    defer { old.release() }
    kill(old.processIdentifier, SIGKILL)
    old.process.waitUntilExit()

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Both the hand-held lockf and the harness queued behind it stay until
    // the test is done with them, however slow the Mac is: either one
    // leaving early changes who the waiter names. Each gives up after five
    // minutes, as a holder does, so neither outlives a failed test for long.
    let ready = directory.appendingPathComponent("hand-ready").path
    let stop = directory.appendingPathComponent("hand-stop").path
    let hand = Process()
    hand.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    hand.arguments = [
      "-k", lock, "/bin/sh", "-c",
      "touch '\(ready)'; for _ in $(seq 1 3000); do [ -e '\(stop)' ] && exit 0; sleep 0.1; done",
    ]
    try hand.run()
    defer {
      FileManager.default.createFile(atPath: stop, contents: nil)
      hand.waitUntilExit()
    }
    try waitFor("the hand-held lockf") { FileManager.default.fileExists(atPath: ready) }

    // A harness already queued behind it is not named as a holder.
    let (queued, queuedOutput) = try process(
      "lock_acquire SCREEN_LOCK 'run queued' 300",
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
