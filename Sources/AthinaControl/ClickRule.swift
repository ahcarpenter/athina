import CoreGraphics

/// Whether a simulated click on a control would land where a person's would,
/// judged before the click is posted. A refusal names why a check can expect:
///
/// - `disabled`: the control is dimmed. SwiftUI reports a link inside Text as
///   not enabled whatever its state, so a link is never refused for that.
/// - `offscreen`: it has no size, a scroll area it sits in has scrolled it out
///   of sight, or its centre is outside the part of the window it belongs to:
///   the content for a control in the window's content, the whole window for
///   one in the toolbar or title bar.
/// - `covered`: a sheet is up over the window, or the window's own hit test at
///   the control's centre lands on something else: in the content for a
///   toolbar or title bar control, or outside the content for a content one.
///
/// Every frame is in the window's coordinates, so nothing another app or
/// another run has on screen can change the answer.
public struct ClickRule: Equatable, Sendable {
    public enum Refusal: String, Equatable, Sendable {
        case disabled, offscreen, covered
    }

    /// Where the window's own hit test landed.
    public enum Hit: Equatable, Sendable {
        /// On nothing at all.
        case nothing
        /// On a view inside the window's content view.
        case content
        /// On the window's frame: its title bar or toolbar.
        case chrome
    }

    public var role: String
    public var enabled: Bool
    public var frame: CGRect
    /// Whether the control is in the toolbar or the title bar.
    public var inChrome: Bool
    /// The frames of the scroll areas the control sits in.
    public var clips: [CGRect]
    /// The window's own bounds, and the part of it its content shows in.
    public var windowBounds: CGRect
    public var contentRect: CGRect
    public var hasSheet: Bool
    public var hit: Hit

    public init(
        role: String, enabled: Bool, frame: CGRect, inChrome: Bool = false, clips: [CGRect] = [],
        windowBounds: CGRect, contentRect: CGRect, hasSheet: Bool = false, hit: Hit
    ) {
        self.role = role
        self.enabled = enabled
        self.frame = frame
        self.inChrome = inChrome
        self.clips = clips
        self.windowBounds = windowBounds
        self.contentRect = contentRect
        self.hasSheet = hasSheet
        self.hit = hit
    }

    public var centre: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Why the click would not land, or nil when it would.
    public var refusal: Refusal? {
        if !enabled, role != "AXLink" { return .disabled }
        guard frame.width > 0, frame.height > 0 else { return .offscreen }
        guard clips.allSatisfy({ $0.contains(centre) }) else { return .offscreen }
        guard (inChrome ? windowBounds : contentRect).contains(centre) else { return .offscreen }
        if hasSheet { return .covered }
        switch hit {
        case .nothing: return .covered
        case .content: return inChrome ? .covered : nil
        case .chrome: return inChrome ? nil : .covered
        }
    }
}
