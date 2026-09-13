import CoreGraphics
import Testing
@testable import MentorCore

@Suite struct ToastOutsideClickTests {
    /// A toast at the top right of a 1440x900 screen, the placement
    /// `ToastController` uses.
    private let frame = CGRect(x: 1048, y: 730, width: 380, height: 146)

    @Test func clicksOnTheToastKeepIt() {
        #expect(!ToastOutsideClick.dismisses(clickAt: CGPoint(x: 1238, y: 800), toastFrame: frame))
        // The close button, top right, and the button bar along the bottom edge.
        #expect(!ToastOutsideClick.dismisses(clickAt: CGPoint(x: 1408, y: 860), toastFrame: frame))
        #expect(!ToastOutsideClick.dismisses(clickAt: CGPoint(x: 1090, y: 742), toastFrame: frame))
        // The bottom-left corner is part of the toast.
        #expect(!ToastOutsideClick.dismisses(clickAt: CGPoint(x: 1048, y: 730), toastFrame: frame))
    }

    @Test func clicksAnywhereElseDismissIt() {
        // Another app's window behind the toast, and the desktop below it.
        #expect(ToastOutsideClick.dismisses(clickAt: CGPoint(x: 600, y: 400), toastFrame: frame))
        #expect(ToastOutsideClick.dismisses(clickAt: CGPoint(x: 1238, y: 720), toastFrame: frame))
        // Just past each edge, including the top-right corner the frame excludes.
        #expect(ToastOutsideClick.dismisses(clickAt: CGPoint(x: 1047, y: 800), toastFrame: frame))
        #expect(ToastOutsideClick.dismisses(clickAt: CGPoint(x: 1428, y: 876), toastFrame: frame))
        // A second screen to the left of the main one.
        #expect(ToastOutsideClick.dismisses(clickAt: CGPoint(x: -300, y: 500), toastFrame: frame))
    }

    @Test func anEmptyFrameNeverSwallowsAClick() {
        #expect(ToastOutsideClick.dismisses(clickAt: .zero, toastFrame: .zero))
    }
}
