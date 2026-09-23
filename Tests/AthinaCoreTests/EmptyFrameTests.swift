import Testing
@testable import AthinaCore

@Suite struct EmptyFrameTests {
    /// Right after Clear Journal, with Screen Recording granted and the person
    /// active, the pane says the journal was cleared and the next capture is
    /// coming, not that a permission is missing.
    @Test func aClearedJournalWhileWatchingSaysTheNextCaptureIsComing() {
        for mode in [SensingMode.watching, .screenOnly] {
            let empty = EmptyFrame(mode: mode, journalCleared: true)
            #expect(empty.title == "Journal Cleared")
            #expect(empty.message == "The next capture appears here.")
        }
    }

    /// Only a mode that captures no frames for want of Screen Recording names it.
    @Test func onlyMissingScreenRecordingNamesIt() {
        for mode in SensingMode.allCases {
            for cleared in [false, true] {
                let names = EmptyFrame(mode: mode, journalCleared: cleared).message.contains("Screen Recording")
                #expect(names == [.accessibilityOnly, .waitingForPermissions].contains(mode), "\(mode), cleared \(cleared)")
            }
        }
    }

    /// A mode that captures nothing says what brings the frames back, even
    /// just after a clear, since the clear is not why none arrives.
    @Test func aModeThatCapturesNothingSaysWhatBringsFramesBack() {
        #expect(EmptyFrame(mode: .paused, journalCleared: true).message == "Frames appear here once watching resumes.")
        #expect(EmptyFrame(mode: .idle, journalCleared: false).message == "Frames appear here once you are active again.")
        #expect(EmptyFrame(mode: .excluded, journalCleared: false).message == "Nothing is captured while an excluded app is in front.")
        #expect(EmptyFrame(mode: .watching, journalCleared: false).title == "Waiting for the First Capture")
    }
}
