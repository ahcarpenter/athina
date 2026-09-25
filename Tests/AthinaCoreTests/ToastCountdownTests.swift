import Foundation
import Testing

@testable import AthinaCore

/// A toast's countdown to expiring on its own, on the test clock, driven the
/// way the app drives it: run when shown, held on hover, run again with what
/// was held on leave, and expired by a wait until the deadline it names.
@Suite(.timeLimit(.minutes(1))) struct ToastCountdownTests {
  private let t0 = Date(timeIntervalSince1970: 1_789_473_600)
  private let timeout = MentorSettings().toastTimeout

  @Test func aToastRunsForItsTimeout() {
    var countdown = ToastCountdown()
    #expect(countdown.deadline == nil)
    countdown.run(for: timeout, from: t0)
    #expect(countdown.deadline == t0 + timeout)
    #expect(countdown.held == nil)
  }

  /// The pointer over the toast holds the countdown for as long as it stays,
  /// and leaving gives back what was left.
  @Test func thePointerHoldsTheCountdownAndLeavingGivesItBack() async throws {
    let clock = AdjustableClock(startingAt: t0)
    var countdown = ToastCountdown()
    countdown.run(for: timeout, from: clock.date)
    clock.advance(by: .seconds(40))
    countdown.hold(at: clock.date)
    #expect(countdown.held == timeout - 40)
    #expect(countdown.deadline == nil)
    // Ten minutes under the pointer: nothing to wait on, and nothing lost.
    clock.advance(by: .seconds(600))
    let held = try #require(countdown.held)
    #expect(held == timeout - 40)
    #expect(countdown.deadline == nil)

    countdown.run(for: held, from: clock.date)
    #expect(countdown.held == nil)
    let deadline = try #require(countdown.deadline)
    #expect(deadline == clock.date + timeout - 40)
    let expiry = Task { try await clock.sleep(untilDate: deadline) }
    await clock.waitForSleepers()
    clock.advance(by: .seconds(timeout - 41))
    #expect(clock.sleeperCount == 1)
    clock.advance(by: .seconds(1))
    try await expiry.value
    #expect(clock.date == deadline)
  }

  @Test func aCountdownHeldAtItsLastMomentKeepsTheMinimum() throws {
    var countdown = ToastCountdown()
    countdown.run(for: timeout, from: t0)
    countdown.hold(at: t0 + timeout - 0.5)
    let held = try #require(countdown.held)
    #expect(held == ToastCountdown.minimumRemaining)
    countdown.run(for: held, from: t0 + 3600)
    #expect(countdown.deadline == t0 + 3600 + ToastCountdown.minimumRemaining)
  }

  @Test func holdingTwiceKeepsWhatWasLeftTheFirstTimeAndCancelTurnsItOff() {
    var countdown = ToastCountdown()
    countdown.hold(at: t0)
    #expect(countdown == ToastCountdown())
    countdown.run(for: timeout, from: t0)
    countdown.hold(at: t0 + 10)
    countdown.hold(at: t0 + 50)
    #expect(countdown.held == timeout - 10)
    countdown.cancel()
    #expect(countdown == ToastCountdown())
  }

  /// What the app does with the deadline: a wait on its clock that ends
  /// exactly when the toast expires.
  @Test func theWaitForTheDeadlineEndsExactlyWhenTheToastExpires() async throws {
    let clock = AdjustableClock(startingAt: t0)
    var countdown = ToastCountdown()
    countdown.run(for: timeout, from: clock.date)
    let deadline = try #require(countdown.deadline)
    let expiry = Task { try await clock.sleep(untilDate: deadline) }
    await clock.waitForSleepers()
    clock.advance(by: .seconds(timeout - 1))
    #expect(clock.sleeperCount == 1)
    clock.advance(by: .seconds(1))
    try await expiry.value
    #expect(clock.date == deadline)
  }
}
