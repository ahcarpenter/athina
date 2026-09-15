import Foundation
import Testing
@testable import MentorCore

/// A toast's countdown to expiring on its own, on the test clock.
@Suite(.timeLimit(.minutes(1))) struct ToastCountdownTests {
    private let t0 = Date(timeIntervalSince1970: 1_789_473_600)
    private let timeout = MentorSettings().toastTimeout

    @Test func aToastExpiresAtItsTimeout() {
        var countdown = ToastCountdown()
        #expect(!countdown.hasExpired(at: t0 + 3600))
        countdown.run(for: timeout, from: t0)
        #expect(countdown.deadline == t0 + timeout)
        #expect(!countdown.hasExpired(at: t0 + timeout - 0.5))
        #expect(countdown.hasExpired(at: t0 + timeout))
    }

    /// The pointer over the toast holds the countdown for as long as it stays,
    /// and leaving gives back what was left.
    @Test func thePointerHoldsTheCountdownAndLeavingGivesItBack() {
        let clock = AdjustableClock(startingAt: t0)
        var countdown = ToastCountdown()
        countdown.run(for: timeout, from: clock.date)
        clock.advance(by: .seconds(40))
        countdown.hold(at: clock.date)
        #expect(countdown.held == timeout - 40)
        #expect(countdown.deadline == nil)
        // Ten minutes under the pointer, and it never expires.
        clock.advance(by: .seconds(600))
        #expect(!countdown.hasExpired(at: clock.date))
        countdown.resume(from: clock.date)
        #expect(countdown.held == nil)
        #expect(countdown.deadline == clock.date + timeout - 40)
        clock.advance(by: .seconds(timeout - 41))
        #expect(!countdown.hasExpired(at: clock.date))
        clock.advance(by: .seconds(1))
        #expect(countdown.hasExpired(at: clock.date))
    }

    @Test func aCountdownHeldAtItsLastMomentKeepsTheMinimum() {
        var countdown = ToastCountdown()
        countdown.run(for: timeout, from: t0)
        countdown.hold(at: t0 + timeout - 0.5)
        #expect(countdown.held == ToastCountdown.minimumRemaining)
        countdown.resume(from: t0 + 3600)
        #expect(countdown.deadline == t0 + 3600 + ToastCountdown.minimumRemaining)
    }

    @Test func holdingTwiceKeepsWhatWasLeftTheFirstTimeAndCancelTurnsItOff() {
        var countdown = ToastCountdown()
        countdown.hold(at: t0)
        countdown.resume(from: t0)
        #expect(countdown == ToastCountdown())
        countdown.run(for: timeout, from: t0)
        countdown.hold(at: t0 + 10)
        countdown.hold(at: t0 + 50)
        #expect(countdown.held == timeout - 10)
        countdown.cancel()
        #expect(countdown == ToastCountdown())
        #expect(!countdown.hasExpired(at: t0 + 86400))
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
        #expect(!countdown.hasExpired(at: clock.date))
        clock.advance(by: .seconds(1))
        try await expiry.value
        #expect(countdown.hasExpired(at: clock.date))
    }
}
