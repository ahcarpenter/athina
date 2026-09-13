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
        scheduler.noteCaptureFinished(at: t0 + 0.3)
        scheduler.noteFocusChange(at: t0 + 0.4)
        // Settle would be at 0.7, but the minimum interval pushes it to 1.05.
        #expect(scheduler.evaluate(now: t0 + 0.7) == .wait(until: t0 + 1.05))
        #expect(scheduler.evaluate(now: t0 + 1.05) == .capture(.focusChange))
    }

    @Test func typingBurstCapturesOnceItSettles() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(at: t0)
        scheduler.noteInput(at: t0 + 1)
        scheduler.noteInput(at: t0 + 2)
        scheduler.noteInput(at: t0 + 2.5)
        #expect(scheduler.evaluate(now: t0 + 3) == .wait(until: t0 + 4))
        #expect(scheduler.evaluate(now: t0 + 4) == .capture(.inputSettled))
        scheduler.noteCaptureFinished(at: t0 + 4)
        // Stale input timestamps are ignored.
        scheduler.noteInput(at: t0 + 1)
        #expect(scheduler.inputSinceLastCapture == false)
    }

    @Test func floorFiresWhileTypingNeverSettles() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(at: t0)
        for i in 1...10 {
            scheduler.noteInput(at: t0 + Double(i) * 0.5)
        }
        #expect(scheduler.evaluate(now: t0 + 5) == .capture(.floor))
    }

    @Test func focusChangeBeatsFloorWhenBothDue() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(at: t0)
        scheduler.noteFocusChange(at: t0 + 4.7)
        #expect(scheduler.evaluate(now: t0 + 5) == .capture(.focusChange))
    }

    @Test func manualCaptureIsImmediate() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(at: t0)
        scheduler.requestManualCapture()
        #expect(scheduler.evaluate(now: t0 + 0.1) == .capture(.manual))
        scheduler.noteCaptureFinished(at: t0 + 0.1)
        #expect(scheduler.manualRequested == false)
    }

    @Test func deactivationClearsPendingTriggers() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteInput(at: t0 + 1)
        scheduler.requestManualCapture()
        scheduler.setActive(false, at: t0 + 1)
        #expect(scheduler.evaluate(now: t0 + 10) == .wait(until: nil))
        scheduler.setActive(true, at: t0 + 10)
        #expect(scheduler.evaluate(now: t0 + 10.3) == .capture(.focusChange))
    }

    @Test func settingsChangesApplyToNextDecision() {
        var scheduler = CaptureScheduler(settings: settings)
        scheduler.setActive(true, at: t0)
        scheduler.noteCaptureFinished(at: t0)
        #expect(scheduler.evaluate(now: t0 + 2) == .wait(until: t0 + 5))
        scheduler.settings.floorInterval = 1
        #expect(scheduler.evaluate(now: t0 + 2) == .capture(.floor))
    }
}
