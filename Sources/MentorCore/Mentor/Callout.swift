import CoreGraphics
import Foundation

/// A spot on the screen the mentor tier pointed at, in the pixel coordinates
/// of the frame it saw (origin top-left), with a few words to show beside it.
public struct CalloutRegion: Codable, Equatable, Sendable {
    public static let maxNoteLength = 80

    public var rect: CGRect
    public var note: String

    public init(rect: CGRect, note: String) {
        self.rect = rect
        self.note = String(note.prefix(CalloutRegion.maxNoteLength))
    }
}

/// One display as it is right now, so a frame's display can be checked
/// against the current configuration. Bounds are global display points with
/// the origin at the top-left of the main display, like `FrameInfo.screenRect`.
public struct DisplayBounds: Equatable, Sendable {
    public var id: UInt32
    public var bounds: CGRect

    public init(id: UInt32, bounds: CGRect) {
        self.id = id
        self.bounds = bounds
    }
}

/// Where a callout goes on screen once its anchor checks out.
public struct CalloutPlacement: Equatable, Sendable {
    public var displayID: UInt32
    /// Global display points, origin top-left of the main display.
    public var screenRect: CGRect
    public var note: String

    public init(displayID: UInt32, screenRect: CGRect, note: String) {
        self.displayID = displayID
        self.screenRect = screenRect
        self.note = note
    }
}

/// Why a callout was not placed, or was taken down. Every reason is a way
/// the highlight could have landed on the wrong thing.
public enum CalloutRejection: Error, Equatable, Sendable {
    /// The region is not inside the frame the model saw, or is too small to point at.
    case outsideFrame
    /// The frame is older than `CalloutAnchor.maxFrameAge`.
    case stale(age: TimeInterval)
    /// The window's frame was not readable at capture time or is not now.
    case noWindowFrame
    /// Another app is frontmost.
    case windowNotFrontmost
    /// The same app is frontmost but a different window is.
    case windowChanged
    /// The window is where it was captured no longer.
    case windowMoved
    /// The display the frame came from is gone or has different bounds.
    case displayChanged
    /// The spot lies outside the window the observation was about.
    case outsideWindow
    /// A later frame of the same window no longer shows the framed text at that place.
    case contentChanged

    public var label: String {
        switch self {
        case .outsideFrame: "region outside the frame"
        case .stale(let age): "frame is \(Int(age))s old"
        case .noWindowFrame: "window frame unavailable"
        case .windowNotFrontmost: "window no longer frontmost"
        case .windowChanged: "a different window is frontmost"
        case .windowMoved: "window moved"
        case .displayChanged: "display configuration changed"
        case .outsideWindow: "spot lies outside the window"
        case .contentChanged: "content under the spot changed"
        }
    }
}

/// Maps a region from frame pixels to screen points and decides whether the
/// screen still shows what the frame showed there. Pure, so every rule is
/// unit-tested; the app supplies the live readings.
public enum CalloutAnchor {
    /// A frame older than this is not drawn on: content scrolls and windows
    /// change faster than the mentor tier answers.
    public static let maxFrameAge: TimeInterval = 120
    /// Regions smaller than this in either dimension, in frame pixels, are
    /// noise rather than a spot.
    public static let minimumSize: CGFloat = 4
    /// How far, in points, the window may be from where it was captured.
    public static let windowMoveTolerance: CGFloat = 2

    /// What the app reads right before placing or keeping a callout.
    public struct Live: Equatable, Sendable {
        public var frontmostPID: Int32?
        /// A fresh accessibility read of the frontmost window, or nil when
        /// there is none to read.
        public var focus: FocusContext?
        public var displays: [DisplayBounds]
        public var now: Date

        public init(frontmostPID: Int32?, focus: FocusContext?, displays: [DisplayBounds], now: Date) {
            self.frontmostPID = frontmostPID
            self.focus = focus
            self.displays = displays
            self.now = now
        }
    }

    /// Frame pixels to global display points, the same mapping OCR blocks use,
    /// or nil when the rect is not entirely inside the frame or is too small.
    public static func screenRect(for rect: CGRect, in frame: FrameInfo) -> CGRect? {
        guard rect.width >= minimumSize, rect.height >= minimumSize, frame.width > 0, frame.height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(frame.width), height: CGFloat(frame.height))
        guard bounds.contains(rect) else { return nil }
        let scale = frame.scale
        return CGRect(
            x: frame.screenRect.origin.x + rect.origin.x * scale,
            y: frame.screenRect.origin.y + rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    /// Whether the region may be drawn right now, and where. Checks run from
    /// the cheapest to the most specific so the reason names the first thing
    /// that is wrong.
    public static func resolve(
        _ region: CalloutRegion,
        for observation: ActivityObservation,
        live: Live
    ) -> Result<CalloutPlacement, CalloutRejection> {
        let frame = observation.frame
        guard let screenRect = screenRect(for: region.rect, in: frame) else { return .failure(.outsideFrame) }
        guard let display = live.displays.first(where: { $0.id == frame.displayID }),
              display.bounds == frame.screenRect
        else { return .failure(.displayChanged) }
        let age = live.now.timeIntervalSince(observation.timestamp)
        if age > maxFrameAge { return .failure(.stale(age: age)) }
        guard let capturedWindow = observation.focus.windowFrame else { return .failure(.noWindowFrame) }
        guard live.frontmostPID == observation.focus.pid, let focus = live.focus, focus.pid == observation.focus.pid else {
            return .failure(.windowNotFrontmost)
        }
        guard focus.windowSignature == observation.focus.windowSignature else { return .failure(.windowChanged) }
        guard let liveWindow = focus.windowFrame else { return .failure(.noWindowFrame) }
        guard liveWindow.isClose(to: capturedWindow, within: windowMoveTolerance) else { return .failure(.windowMoved) }
        guard capturedWindow.contains(CGPoint(x: screenRect.midX, y: screenRect.midY)) else { return .failure(.outsideWindow) }
        return .success(CalloutPlacement(displayID: frame.displayID, screenRect: screenRect, note: region.note))
    }

    /// Recognized text that lies mostly inside the region must still be there
    /// in a later frame of the same window, within `tolerance` frame pixels.
    /// The window itself may not have moved, but a terminal scrolls and a
    /// document edits, and the spot the model pointed at goes with them; the
    /// sensing pipeline's next kept frame is the cheapest witness. Frames of
    /// another window, another size, or the same observation say nothing and
    /// pass, as does a region that framed no text at all.
    public static func contentStillMatches(
        region: CGRect,
        original: ActivityObservation,
        latest: ActivityObservation,
        tolerance: CGFloat = 6
    ) -> Bool {
        guard latest.id != original.id,
              latest.focus.windowSignature == original.focus.windowSignature,
              latest.frame.width == original.frame.width, latest.frame.height == original.frame.height
        else { return true }
        let framed = original.textBlocks.filter { block in
            region.intersection(block.imageRect).area >= 0.5 * block.imageRect.area
        }
        guard !framed.isEmpty else { return true }
        let stillThere = framed.filter { block in
            latest.textBlocks.contains { candidate in
                candidate.text == block.text
                    && abs(candidate.imageRect.midX - block.imageRect.midX) <= tolerance
                    && abs(candidate.imageRect.midY - block.imageRect.midY) <= tolerance
            }
        }
        return stillThere.count * 2 >= framed.count
    }
}

/// Where the box and the note go inside the overlay window, and where the
/// window goes on the display. Global coordinates are display points with
/// the origin at the top-left of the main display; local ones are points from
/// the window's top-left, which is what the overlay view uses. The window's
/// origin and size are whole points, because a window is placed on whole
/// points anyway; the box keeps its exact fractional position inside it, so
/// rounding the window never moves the box.
public struct CalloutLayout: Equatable, Sendable {
    /// Room around the box for its stroke and glow.
    public static let glow: CGFloat = 12
    /// Space between the box and the note.
    public static let gap: CGFloat = 6
    /// Height reserved for the note row, enough for two lines.
    public static let noteHeight: CGFloat = 48
    /// The window is at least this wide so a note has room beside a small box.
    public static let minimumWidth: CGFloat = 300
    /// A note wider than this wraps.
    public static let noteMaxWidth: CGFloat = 320

    public var windowRect: CGRect
    public var box: CGRect
    public var noteBelow: Bool

    public init(screenRect: CGRect, display: CGRect) {
        let glow = CalloutLayout.glow
        let noteBand = CalloutLayout.gap + CalloutLayout.noteHeight
        noteBelow = screenRect.maxY + glow + noteBand <= display.maxY || screenRect.minY - glow - noteBand < display.minY
        var origin = CGPoint(
            x: (screenRect.minX - glow).rounded(.down),
            y: (noteBelow ? screenRect.minY - glow : screenRect.minY - glow - noteBand).rounded(.down)
        )
        // Sized from the floored origin, so the fraction it dropped is kept.
        let bottom = noteBelow ? screenRect.maxY + noteBand : screenRect.maxY
        let width = min(ceil(max(screenRect.maxX - origin.x + glow, CalloutLayout.minimumWidth + 2 * glow)), display.width.rounded(.down))
        let height = ceil(bottom - origin.y + glow)
        origin.x = min(max(origin.x, display.minX), display.maxX - width)
        origin.y = min(max(origin.y, display.minY), max(display.minY, display.maxY - height))
        windowRect = CGRect(origin: origin, size: CGSize(width: width, height: height))
        box = CGRect(
            x: screenRect.minX - origin.x, y: screenRect.minY - origin.y,
            width: screenRect.width, height: screenRect.height
        )
    }
}

extension CGRect {
    /// True when every edge is within `tolerance` points of the other rect's.
    func isClose(to other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
