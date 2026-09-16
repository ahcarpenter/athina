import Foundation
import Testing
@testable import MentorCore

@Suite struct CaptureSchedulerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var settings: SensingSettings {
        var s = SensingSettings()
        s.focusSettleDelay = 0.3
        s.inputSettleDelay = 1.5
        s.floorInterval = 5
        s.minCaptureInterval = 0.75
        return s
    }

    @Test func inactiveSchedulerNeverCaptures() {
        let scheduler = CaptureScheduler(settings: settings)
        #expect(scheduler.evaluate(now: t0) == .wait(until: nil))
        #expect(scheduler.nextDue(now: t0) == nil)
    }

    @Test func activationQueuesPromptCaptureAfterFocusSettle() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        #expect(scheduler.evaluate(now: t0) == .wait(until: t0 + 0.3))
        #expect(scheduler.evaluate(now: t0 + 0.3) == .capture(.focusChange))
    }

    @Test func focusChangeWaitsForMinimumInterval() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(startedAt: t0 + 0.3, at: t0 + 0.3)
        scheduler.noteFocusChange(at: t0 + 0.4)
        // Settle would be at 0.7, but the minimum interval pushes it to 1.05.
        #expect(scheduler.evaluate(now: t0 + 0.7) == .wait(until: t0 + 1.05))
        #expect(scheduler.evaluate(now: t0 + 1.05) == .capture(.focusChange))
    }

    @Test func typingBurstCapturesOnceItSettles() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(startedAt: t0, at: t0)
        scheduler.noteInput(at: t0 + 1)
        scheduler.noteInput(at: t0 + 2)
        scheduler.noteInput(at: t0 + 2.5)
        #expect(scheduler.evaluate(now: t0 + 3) == .wait(until: t0 + 4))
        #expect(scheduler.evaluate(now: t0 + 4) == .capture(.inputSettled))
        scheduler.noteCaptureFinished(startedAt: t0 + 4, at: t0 + 4)
        // Stale input timestamps are ignored.
        scheduler.noteInput(at: t0 + 1)
        #expect(scheduler.inputSinceLastCapture == false)
    }

    @Test func floorFiresWhileTypingNeverSettles() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(startedAt: t0, at: t0)
        for i in 1...10 {
            scheduler.noteInput(at: t0 + Double(i) * 0.5)
        }
        #expect(scheduler.evaluate(now: t0 + 5) == .capture(.floor))
    }

    @Test func focusChangeBeatsFloorWhenBothDue() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(startedAt: t0, at: t0)
        scheduler.noteFocusChange(at: t0 + 4.7)
        #expect(scheduler.evaluate(now: t0 + 5) == .capture(.focusChange))
    }

    @Test func manualCaptureIsImmediate() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(startedAt: t0, at: t0)
        scheduler.requestManualCapture(at: t0 + 0.1)
        #expect(scheduler.evaluate(now: t0 + 0.1) == .capture(.manual))
        scheduler.noteCaptureFinished(startedAt: t0 + 0.1, at: t0 + 0.1)
        #expect(scheduler.manualRequested == false)
    }

    @Test func deactivationClearsPendingTriggers() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteInput(at: t0 + 1)
        scheduler.requestManualCapture(at: t0 + 1)
        scheduler.setActive(false, at: t0 + 1)
        #expect(scheduler.evaluate(now: t0 + 10) == .wait(until: nil))
        scheduler.setActive(true, at: t0 + 10)
        #expect(scheduler.evaluate(now: t0 + 10.3) == .capture(.focusChange))
    }

    @Test func settingsChangesApplyToNextDecision() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(startedAt: t0, at: t0)
        #expect(scheduler.evaluate(now: t0 + 2) == .wait(until: t0 + 5))
        scheduler.settings.floorInterval = 1
        #expect(scheduler.evaluate(now: t0 + 2) == .capture(.floor))
    }

    // MARK: Triggers noted while a capture is in flight

    @Test func focusChangeDuringCaptureIsCapturedAfterItSettles() {
        var slowSettle = settings
        slowSettle.focusSettleDelay = 1
        var scheduler = CaptureScheduler(settings: slowSettle)
        let clock = AdjustableClock(startingAt: t0)
        scheduler.setActive(true, at: clock.date)
        clock.advance(by: .seconds(1))
        let startedAt = clock.date
        clock.advance(by: .milliseconds(500))
        let switchedAt = clock.date
        scheduler.noteFocusChange(at: switchedAt)
        clock.advance(by: .milliseconds(125))
        scheduler.noteCaptureFinished(startedAt: startedAt, at: clock.date)
        // The switch settles after the minimum interval ends, so its settle delay decides.
        #expect(scheduler.evaluate(now: clock.date) == .wait(until: switchedAt.addingTimeInterval(1)))
        clock.advance(by: .milliseconds(750))
        #expect(scheduler.evaluate(now: clock.date) == .wait(until: switchedAt.addingTimeInterval(1)))
        clock.advance(by: .milliseconds(125))
        #expect(scheduler.evaluate(now: clock.date) == .capture(.focusChange))
    }

    @Test func inputDuringCaptureIsCapturedAfterItSettles() {
        var scheduler = CaptureScheduler(settings: settings)
        let clock = AdjustableClock(startingAt: t0)
        scheduler.setActive(true, at: clock.date)
        clock.advance(by: .seconds(1))
        let startedAt = clock.date
        clock.advance(by: .milliseconds(250))
        let typedAt = clock.date
        scheduler.noteInput(at: typedAt)
        clock.advance(by: .milliseconds(250))
        scheduler.noteCaptureFinished(startedAt: startedAt, at: clock.date)
        #expect(scheduler.inputSinceLastCapture)
        #expect(scheduler.evaluate(now: clock.date) == .wait(until: typedAt.addingTimeInterval(1.5)))
        clock.advance(by: .milliseconds(1250))
        #expect(scheduler.evaluate(now: clock.date) == .capture(.inputSettled))
    }

    @Test func manualRequestDuringCaptureIsCapturedNext() {
        var scheduler = CaptureScheduler(settings: settings)
        let clock = AdjustableClock(startingAt: t0)
        scheduler.setActive(true, at: clock.date)
        clock.advance(by: .seconds(1))
        let startedAt = clock.date
        clock.advance(by: .milliseconds(250))
        scheduler.requestManualCapture(at: clock.date)
        clock.advance(by: .milliseconds(250))
        scheduler.noteCaptureFinished(startedAt: startedAt, at: clock.date)
        #expect(scheduler.manualRequested)
        // Immediate, as a manual request between captures is.
        #expect(scheduler.evaluate(now: clock.date) == .capture(.manual))
    }

    @Test func triggersNotedBeforeCaptureStartedAreConsumedByIt() {
        var scheduler = CaptureScheduler(settings: settings)
        let clock = AdjustableClock(startingAt: t0)
        scheduler.setActive(true, at: clock.date)
        clock.advance(by: .seconds(1))
        scheduler.noteInput(at: clock.date)
        clock.advance(by: .milliseconds(500))
        // Noted at the instant the capture starts, which counts as before it.
        let startedAt = clock.date
        scheduler.noteFocusChange(at: startedAt)
        scheduler.requestManualCapture(at: startedAt)
        clock.advance(by: .milliseconds(500))
        let finishedAt = clock.date
        scheduler.noteCaptureFinished(startedAt: startedAt, at: finishedAt)
        #expect(scheduler.pendingFocusChangeAt == nil)
        #expect(scheduler.inputSinceLastCapture == false)
        #expect(scheduler.manualRequested == false)
        #expect(scheduler.evaluate(now: finishedAt) == .wait(until: finishedAt.addingTimeInterval(5)))
    }

    @Test func triggersDuringCaptureWaitForMinimumInterval() {
        var scheduler = CaptureScheduler(settings: settings)
        let clock = AdjustableClock(startingAt: t0)
        scheduler.setActive(true, at: clock.date)
        clock.advance(by: .seconds(1))
        let startedAt = clock.date
        clock.advance(by: .milliseconds(500))
        scheduler.noteInput(at: clock.date)
        clock.advance(by: .seconds(1))
        scheduler.noteFocusChange(at: clock.date)
        clock.advance(by: .milliseconds(250))
        let finishedAt = clock.date
        scheduler.noteCaptureFinished(startedAt: startedAt, at: finishedAt)
        // Both settle before the minimum interval ends, and neither captures sooner than it allows.
        let earliest = finishedAt.addingTimeInterval(0.75)
        #expect(scheduler.evaluate(now: finishedAt) == .wait(until: earliest))
        clock.advance(by: .milliseconds(500))
        #expect(scheduler.evaluate(now: clock.date) == .wait(until: earliest))
        clock.advance(by: .milliseconds(250))
        #expect(scheduler.evaluate(now: clock.date) == .capture(.focusChange))
    }
}
