import CoreGraphics

/// Decides whether a mouse-down belongs to the suggestion toast or to whatever
/// is behind it, so a click anywhere else dismisses the toast the way a macOS
/// notification banner goes away. Pure so the rule can be tested without a
/// window on screen; the AppKit event monitors only feed it points.
public enum ToastOutsideClick {
    /// Both points are in Cocoa screen coordinates (bottom-left origin), the
    /// coordinate space `NSWindow.frame` and `NSEvent.mouseLocation` use.
    /// A click on the toast, including on its buttons, is never outside.
    public static func dismisses(clickAt point: CGPoint, toastFrame: CGRect) -> Bool {
        !toastFrame.contains(point)
    }
}
