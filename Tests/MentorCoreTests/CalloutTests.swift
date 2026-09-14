import CoreGraphics
import Foundation
import Testing
@testable import MentorCore

/// Frame-to-screen mapping and every reason a callout is refused or taken
/// down. The frame fixture is 1280 by 800 pixels on a 2560 by 1600 point
/// display, so every frame pixel is two screen points.
@Suite struct CalloutAnchorTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let window = CGRect(x: 100, y: 50, width: 2000, height: 1400)
    private let region = CalloutRegion(rect: CGRect(x: 100, y: 50, width: 200, height: 40), note: "this flag")

    private func observation(windowFrame: CGRect? = nil, at time: Date? = nil) -> ActivityObservation {
        var observation = Fixtures.observation(id: 7, at: time ?? t0)
        observation.focus.windowFrame = windowFrame ?? window
        return observation
    }

    private func liveFocus(pid: Int32 = 42, window title: String? = "main.swift", frame: CGRect? = nil) -> FocusContext {
        FocusContext(pid: pid, bundleID: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: title, windowFrame: frame ?? window)
    }

    private func live(
        pid: Int32? = 42,
        focus: FocusContext? = nil,
        displays: [DisplayBounds]? = nil,
        now: Date? = nil
    ) -> CalloutAnchor.Live {
        CalloutAnchor.Live(
            frontmostPID: pid,
            focus: focus ?? liveFocus(),
            displays: displays ?? [DisplayBounds(id: 1, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1600))],
            now: now ?? t0 + 20
        )
    }

    @Test func framePixelsMapToScreenPointsAtRetinaScale() {
        let frame = observation().frame
        #expect(frame.scale == 2)
        #expect(CalloutAnchor.screenRect(for: region.rect, in: frame) == CGRect(x: 200, y: 100, width: 400, height: 80))
        // A frame from a second display carries that display's origin.
        var second = frame
        second.screenRect = CGRect(x: 1728, y: -200, width: 2560, height: 1600)
        #expect(CalloutAnchor.screenRect(for: region.rect, in: second) == CGRect(x: 1928, y: -100, width: 400, height: 80))
        // The same mapping OCR blocks get, so a callout on a block frames it exactly.
        let block = observation().textBlocks[1]
        #expect(CalloutAnchor.screenRect(for: block.imageRect, in: frame) == block.screenRect)
    }

    @Test func regionsOutsideOrTooSmallForTheFrameAreRefused() {
        let frame = observation().frame
        #expect(CalloutAnchor.screenRect(for: CGRect(x: -1, y: 0, width: 10, height: 10), in: frame) == nil)
        #expect(CalloutAnchor.screenRect(for: CGRect(x: 1200, y: 100, width: 100, height: 10), in: frame) == nil)
        #expect(CalloutAnchor.screenRect(for: CGRect(x: 10, y: 790, width: 10, height: 20), in: frame) == nil)
        #expect(CalloutAnchor.screenRect(for: CGRect(x: 10, y: 10, width: 3, height: 10), in: frame) == nil)
        #expect(CalloutAnchor.screenRect(for: CGRect(x: 10, y: 10, width: 10, height: 0), in: frame) == nil)
        // Touching the edge is inside.
        #expect(CalloutAnchor.screenRect(for: CGRect(x: 0, y: 0, width: 1280, height: 800), in: frame) != nil)
        let outside = CalloutRegion(rect: CGRect(x: 1270, y: 10, width: 20, height: 10), note: "x")
        #expect(CalloutAnchor.resolve(outside, for: observation(), live: live()) == .failure(.outsideFrame))
    }

    @Test func aValidAnchorPlacesTheCalloutOnTheFrameDisplay() {
        let result = CalloutAnchor.resolve(region, for: observation(), live: live())
        #expect(result == .success(CalloutPlacement(displayID: 1, screenRect: CGRect(x: 200, y: 100, width: 400, height: 80), note: "this flag")))
    }

    @Test func aStaleFrameIsRefused() {
        let atLimit = CalloutAnchor.resolve(region, for: observation(), live: live(now: t0 + CalloutAnchor.maxFrameAge))
        #expect(atLimit.isSuccess)
        let past = CalloutAnchor.resolve(region, for: observation(), live: live(now: t0 + CalloutAnchor.maxFrameAge + 1))
        #expect(past == .failure(.stale(age: CalloutAnchor.maxFrameAge + 1)))
    }

    @Test func anotherAppInFrontIsRefused() {
        #expect(CalloutAnchor.resolve(region, for: observation(), live: live(pid: 43)) == .failure(.windowNotFrontmost))
        #expect(CalloutAnchor.resolve(region, for: observation(), live: live(pid: nil)) == .failure(.windowNotFrontmost))
        #expect(CalloutAnchor.resolve(region, for: observation(), live: live(focus: liveFocus(pid: 43))) == .failure(.windowNotFrontmost))
        var unread = live()
        unread.focus = nil
        #expect(CalloutAnchor.resolve(region, for: observation(), live: unread) == .failure(.windowNotFrontmost))
    }

    @Test func anotherWindowOfTheSameAppIsRefused() {
        let other = live(focus: liveFocus(window: "other.swift"))
        #expect(CalloutAnchor.resolve(region, for: observation(), live: other) == .failure(.windowChanged))
    }

    @Test func aMovedOrResizedWindowIsRefusedWithinTolerance() {
        let nudged = live(focus: liveFocus(frame: window.offsetBy(dx: 1, dy: -1)))
        #expect(CalloutAnchor.resolve(region, for: observation(), live: nudged).isSuccess)
        let moved = live(focus: liveFocus(frame: window.offsetBy(dx: 0, dy: 3)))
        #expect(CalloutAnchor.resolve(region, for: observation(), live: moved) == .failure(.windowMoved))
        let resized = live(focus: liveFocus(frame: CGRect(x: 100, y: 50, width: 2010, height: 1400)))
        #expect(CalloutAnchor.resolve(region, for: observation(), live: resized) == .failure(.windowMoved))
    }

    @Test func aWindowWithoutAFrameIsRefusedEitherWay() {
        var captured = observation()
        captured.focus.windowFrame = nil
        #expect(CalloutAnchor.resolve(region, for: captured, live: live()) == .failure(.noWindowFrame))
        var liveContext = liveFocus()
        liveContext.windowFrame = nil
        #expect(CalloutAnchor.resolve(region, for: observation(), live: live(focus: liveContext)) == .failure(.noWindowFrame))
    }

    @Test func aChangedDisplayConfigurationIsRefused() {
        let gone = live(displays: [DisplayBounds(id: 2, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1600))])
        #expect(CalloutAnchor.resolve(region, for: observation(), live: gone) == .failure(.displayChanged))
        let resized = live(displays: [DisplayBounds(id: 1, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117))])
        #expect(CalloutAnchor.resolve(region, for: observation(), live: resized) == .failure(.displayChanged))
        let moved = live(displays: [DisplayBounds(id: 1, bounds: CGRect(x: -2560, y: 0, width: 2560, height: 1600))])
        #expect(CalloutAnchor.resolve(region, for: observation(), live: moved) == .failure(.displayChanged))
    }

    @Test func aSpotOutsideTheWindowIsRefused() {
        // Screen (2400, 1400) to (2520, 1480): its centre is right of the window's edge at 2100.
        let beside = CalloutRegion(rect: CGRect(x: 1200, y: 700, width: 60, height: 40), note: "x")
        #expect(CalloutAnchor.resolve(beside, for: observation(), live: live()) == .failure(.outsideWindow))
    }

    @Test func checksRunFromCheapestToMostSpecific() {
        // Several things wrong at once: the frame check comes before the display check.
        let outside = CalloutRegion(rect: CGRect(x: 5000, y: 0, width: 10, height: 10), note: "x")
        #expect(CalloutAnchor.resolve(outside, for: observation(), live: live(displays: [])) == .failure(.outsideFrame))
        // A gone display is reported before staleness, which is reported before the window.
        #expect(CalloutAnchor.resolve(region, for: observation(), live: live(pid: 43, displays: [], now: t0 + 600)) == .failure(.displayChanged))
        #expect(CalloutAnchor.resolve(region, for: observation(), live: live(pid: 43, now: t0 + 600)) == .failure(.stale(age: 600)))
    }

    @Test func aLaterFrameMustStillShowTheFramedTextInPlace() {
        // The fixture's blocks sit at y 0, 20, ... in 100 by 12 px boxes; the region frames the second line.
        let original = Fixtures.observation(id: 7, at: t0, text: "one\ntwo\nthree")
        let spot = CGRect(x: 6, y: 16, width: 108, height: 20)
        let same = Fixtures.observation(id: 8, at: t0 + 5, text: "one\ntwo\nthree")
        #expect(CalloutAnchor.contentStillMatches(region: spot, original: original, latest: same))
        // Scrolled by one line: "two" is now where "one" was, and "three" sits under the box.
        let scrolled = Fixtures.observation(id: 9, at: t0 + 5, text: "two\nthree\nfour")
        #expect(!CalloutAnchor.contentStillMatches(region: spot, original: original, latest: scrolled))
        // The line was edited in place.
        let edited = Fixtures.observation(id: 10, at: t0 + 5, text: "one\ntoo\nthree")
        #expect(!CalloutAnchor.contentStillMatches(region: spot, original: original, latest: edited))
        // A few pixels of drift is recognition noise, not a change.
        var drifted = same
        drifted.textBlocks = drifted.textBlocks.map { block in
            var moved = block
            moved.imageRect = block.imageRect.offsetBy(dx: 3, dy: -2)
            return moved
        }
        #expect(CalloutAnchor.contentStillMatches(region: spot, original: original, latest: drifted))
        // Frames that say nothing about the spot pass: another window, another
        // frame size, the same observation, or a region that framed no text.
        #expect(CalloutAnchor.contentStillMatches(region: spot, original: original, latest: Fixtures.observation(id: 11, at: t0 + 5, window: "other", text: "x")))
        var resized = scrolled
        resized.frame.width = 640
        #expect(CalloutAnchor.contentStillMatches(region: spot, original: original, latest: resized))
        #expect(CalloutAnchor.contentStillMatches(region: spot, original: original, latest: original))
        let blank = CGRect(x: 500, y: 500, width: 40, height: 40)
        #expect(CalloutAnchor.contentStillMatches(region: blank, original: original, latest: scrolled))
    }

    @Test func rejectionLabelsRead() {
        #expect(CalloutRejection.stale(age: 130.4).label == "frame is 130s old")
        #expect(CalloutRejection.windowMoved.label == "window moved")
    }

    @Test func theNoteIsCappedAndTheRegionRoundTrips() throws {
        let long = CalloutRegion(rect: region.rect, note: String(repeating: "n", count: 200))
        #expect(long.note.count == CalloutRegion.maxNoteLength)
        let data = try JSONEncoder().encode(region)
        #expect(try JSONDecoder().decode(CalloutRegion.self, from: data) == region)
    }

    @Test func theLoopKeepsARegionOnlyWhenTheModelSawTheImageAndItFits() {
        let frame = observation().frame
        let raw = MentorVerdict.Payload.Region(x: 100, y: 50, width: 200, height: 40, note: "this \u{2014} flag ")
        #expect(MentorLoop.region(from: raw, frame: frame, sawImage: true) == CalloutRegion(rect: region.rect, note: "this - flag"))
        #expect(MentorLoop.region(from: raw, frame: frame, sawImage: false) == nil)
        #expect(MentorLoop.region(from: nil, frame: frame, sawImage: true) == nil)
        let outside = MentorVerdict.Payload.Region(x: 1200, y: 50, width: 200, height: 40, note: "x")
        #expect(MentorLoop.region(from: outside, frame: frame, sawImage: true) == nil)
    }
}

@Suite struct CalloutLayoutTests {
    private let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func theWindowSitsOnWholePointsAndTheBoxKeepsItsExactPlace() {
        let spot = CGRect(x: 1225.8, y: 639.12, width: 97.2, height: 26.98)
        let layout = CalloutLayout(screenRect: spot, display: display)
        #expect(layout.windowRect.origin == CGPoint(x: 1213, y: 627))
        #expect(layout.windowRect.size == CGSize(width: 324, height: 106))
        #expect(layout.windowRect.origin.x.rounded() == layout.windowRect.origin.x)
        // Box top-left back in screen points is the spot, to the hundredth.
        #expect(abs(layout.windowRect.minX + layout.box.minX - spot.minX) < 0.001)
        #expect(abs(layout.windowRect.minY + layout.box.minY - spot.minY) < 0.001)
        #expect(layout.box.size == spot.size)
        #expect(layout.noteBelow)
        // The note row fits under the box inside the window.
        #expect(layout.box.maxY + CalloutLayout.gap + CalloutLayout.noteHeight <= layout.windowRect.height)
    }

    @Test func theNoteGoesAboveWhenThereIsNoRoomBelow() {
        let spot = CGRect(x: 100, y: 1080, width: 200, height: 20)
        let layout = CalloutLayout(screenRect: spot, display: display)
        #expect(!layout.noteBelow)
        #expect(layout.windowRect.maxY <= display.maxY)
        #expect(layout.windowRect.minY == 1080 - CalloutLayout.glow - CalloutLayout.gap - CalloutLayout.noteHeight)
        #expect(abs(layout.windowRect.minY + layout.box.minY - spot.minY) < 0.001)
    }

    @Test func theWindowStaysOnTheDisplay() {
        let right = CalloutLayout(screenRect: CGRect(x: 1700, y: 500, width: 20, height: 20), display: display)
        #expect(right.windowRect.maxX <= display.maxX)
        #expect(right.windowRect.width == CalloutLayout.minimumWidth + 2 * CalloutLayout.glow)
        #expect(abs(right.windowRect.minX + right.box.minX - 1700) < 0.001)
        let left = CalloutLayout(screenRect: CGRect(x: 2, y: 2, width: 20, height: 20), display: display)
        #expect(left.windowRect.origin == .zero)
        #expect(left.box.origin == CGPoint(x: 2, y: 2))
        let second = CalloutLayout(screenRect: CGRect(x: 1740.5, y: -100.25, width: 40, height: 20), display: CGRect(x: 1728, y: -200, width: 2560, height: 1440))
        #expect(second.windowRect.minX >= 1728)
        #expect(abs(second.windowRect.minX + second.box.minX - 1740.5) < 0.001)
        #expect(abs(second.windowRect.minY + second.box.minY + 100.25) < 0.001)
    }
}

extension Result where Success: Equatable, Failure: Equatable {
    static func == (lhs: Result<Success, Failure>, rhs: Result<Success, Failure>) -> Bool {
        switch (lhs, rhs) {
        case (.success(let a), .success(let b)): a == b
        case (.failure(let a), .failure(let b)): a == b
        default: false
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
