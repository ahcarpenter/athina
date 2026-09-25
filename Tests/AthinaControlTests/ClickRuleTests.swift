import CoreGraphics
import Testing
@testable import AthinaControl

@Suite struct ClickRuleTests {
    // A 600 x 268 Settings window whose toolbar and title bar take the top
    // 88 points; the window's coordinates start at the bottom left.
    let window = CGRect(x: 0, y: 0, width: 600, height: 268)
    let content = CGRect(x: 0, y: 0, width: 600, height: 180)
    let button = CGRect(x: 430, y: 20, width: 137, height: 24)
    let tab = CGRect(x: 438, y: 190, width: 64, height: 56)

    func rule(
        role: String = "AXButton", enabled: Bool = true, frame: CGRect? = nil, inChrome: Bool = false,
        clips: [CGRect] = [], hasSheet: Bool = false, hit: ClickRule.Hit = .content
    ) -> ClickRule {
        ClickRule(
            role: role, enabled: enabled, frame: frame ?? button, inChrome: inChrome, clips: clips,
            windowBounds: window, contentRect: content, hasSheet: hasSheet, hit: hit
        )
    }

    @Test func aVisibleEnabledControlIsClicked() {
        #expect(rule().refusal == nil)
    }

    @Test func aDimmedControlIsRefused() {
        #expect(rule(enabled: false).refusal == .disabled)
    }

    @Test func aLinkIsNeverRefusedForBeingDimmed() {
        // SwiftUI reports every link inside Text as not enabled.
        #expect(rule(role: "AXLink", enabled: false).refusal == nil)
    }

    @Test func aControlScrolledOutOfItsScrollAreaIsOffscreen() {
        let scrollArea = CGRect(x: 0, y: 0, width: 600, height: 180)
        #expect(rule(clips: [scrollArea]).refusal == nil)
        #expect(rule(frame: CGRect(x: 430, y: -200, width: 137, height: 24), clips: [scrollArea]).refusal == .offscreen)
        // A footer link laid out below the fold, still inside the window's frame.
        #expect(rule(frame: CGRect(x: 430, y: 190, width: 84, height: 14), clips: [CGRect(x: 0, y: 0, width: 600, height: 150)]).refusal == .offscreen)
    }

    @Test func aControlWithNoSizeIsOffscreen() {
        #expect(rule(frame: CGRect(x: 10, y: 10, width: 0, height: 0)).refusal == .offscreen)
    }

    @Test func aContentControlIsJudgedAgainstTheContent() {
        // Under the toolbar, where a content control cannot be clicked.
        #expect(rule(frame: CGRect(x: 100, y: 200, width: 50, height: 20)).refusal == .offscreen)
    }

    @Test func aToolbarControlIsJudgedAgainstTheWholeWindow() {
        #expect(rule(frame: tab, inChrome: true, hit: .chrome).refusal == nil)
        #expect(rule(frame: CGRect(x: 700, y: 190, width: 64, height: 56), inChrome: true, hit: .chrome).refusal == .offscreen)
    }

    @Test func aHitElsewhereIsCovered() {
        #expect(rule(hit: .nothing).refusal == .covered)
        #expect(rule(hit: .chrome).refusal == .covered)
        #expect(rule(frame: tab, inChrome: true, hit: .content).refusal == .covered)
    }

    @Test func aSheetOverTheWindowCoversEveryControl() {
        #expect(rule(hasSheet: true).refusal == .covered)
        #expect(rule(frame: tab, inChrome: true, hasSheet: true, hit: .chrome).refusal == .covered)
    }

    @Test func dimmedIsSaidBeforeOffscreenAndOffscreenBeforeCovered() {
        #expect(rule(enabled: false, frame: CGRect(x: 10, y: -100, width: 10, height: 10), hit: .nothing).refusal == .disabled)
        #expect(rule(frame: CGRect(x: 10, y: -100, width: 10, height: 10), hit: .nothing).refusal == .offscreen)
    }
}
