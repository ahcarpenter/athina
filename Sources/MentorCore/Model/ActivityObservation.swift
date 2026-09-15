import CoreGraphics
import Foundation

/// What the accessibility API says the user is focused on.
public struct FocusContext: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var pid: Int32
    public var bundleID: String?
    public var appName: String
    public var windowTitle: String?
    /// Focused window frame in global display coordinates (origin top-left of the main display).
    public var windowFrame: CGRect?
    public var focusedRole: String?
    public var focusedSubrole: String?
    public var focusedTitle: String?
    public var focusedDescription: String?
    /// Focused element text, truncated to `FocusContext.maxValueLength`.
    public var focusedValue: String?
    /// Length of the untruncated focused element text.
    public var focusedValueLength: Int?
    /// True when the app is on the excluded list: only the app identity is recorded.
    public var isExcluded: Bool
    /// False when the Accessibility permission is missing or the app exposes nothing.
    public var accessibilityAvailable: Bool

    public static let maxValueLength = 4000

    public init(
        timestamp: Date = Date(),
        pid: Int32,
        bundleID: String?,
        appName: String,
        windowTitle: String? = nil,
        windowFrame: CGRect? = nil,
        focusedRole: String? = nil,
        focusedSubrole: String? = nil,
        focusedTitle: String? = nil,
        focusedDescription: String? = nil,
        focusedValue: String? = nil,
        focusedValueLength: Int? = nil,
        isExcluded: Bool = false,
        accessibilityAvailable: Bool = true
    ) {
        self.timestamp = timestamp
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
        self.focusedRole = focusedRole
        self.focusedSubrole = focusedSubrole
        self.focusedTitle = focusedTitle
        self.focusedDescription = focusedDescription
        self.focusedValue = focusedValue
        self.focusedValueLength = focusedValueLength
        self.isExcluded = isExcluded
        self.accessibilityAvailable = accessibilityAvailable
    }

    /// Identifies "which window": changes on app switch, window switch, and title change.
    public var windowSignature: String {
        "\(bundleID ?? "pid:\(pid)")|\(windowTitle ?? "")"
    }

    /// Identifies the focused text so a settled capture after typing is kept
    /// even when the frame hash barely moves.
    public var textSignature: String {
        "\(focusedRole ?? "")|\(focusedValueLength ?? 0)|\(focusedValue?.hashValue ?? 0)"
    }

    /// One-paragraph description for the journal and debug panel.
    public var summary: String {
        if isExcluded {
            return "\(appName) (excluded, not read)"
        }
        guard accessibilityAvailable else {
            return "\(appName) (accessibility unavailable)"
        }
        var parts: [String] = []
        if let windowTitle, !windowTitle.isEmpty { parts.append("window \"\(windowTitle)\"") }
        if let focusedRole {
            var role = focusedRole
            if let focusedSubrole { role += "/\(focusedSubrole)" }
            if let focusedTitle, !focusedTitle.isEmpty { role += " \"\(focusedTitle)\"" }
            parts.append("focus \(role)")
        }
        if let focusedValue, !focusedValue.isEmpty {
            let excerpt = focusedValue.prefix(160).replacingOccurrences(of: "\n", with: "⏎")
            let suffix = (focusedValueLength ?? 0) > 160 ? "…" : ""
            parts.append("text \"\(excerpt)\(suffix)\"")
        }
        return parts.isEmpty ? appName : "\(appName): " + parts.joined(separator: "; ")
    }
}

/// A region of recognized text, in frame pixels and in global display points.
public struct TextBlock: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Float
    /// Bounding box in captured-frame pixel coordinates, origin top-left.
    public var imageRect: CGRect
    /// Bounding box in global display coordinates, origin top-left of the main display.
    public var screenRect: CGRect

    public init(text: String, confidence: Float, imageRect: CGRect, screenRect: CGRect) {
        self.text = text
        self.confidence = confidence
        self.imageRect = imageRect
        self.screenRect = screenRect
    }
}

/// A kept, downscaled capture of the display the user was working on.
public struct FrameInfo: Codable, Equatable, Sendable {
    public var hash: PerceptualHash
    public var width: Int
    public var height: Int
    public var displayID: UInt32
    /// The display rectangle the frame shows, in global display coordinates.
    public var screenRect: CGRect
    /// JPEG thumbnail. Nil when it has been deleted by retention or not loaded.
    public var jpeg: Data?

    public init(hash: PerceptualHash, width: Int, height: Int, displayID: UInt32, screenRect: CGRect, jpeg: Data?) {
        self.hash = hash
        self.width = width
        self.height = height
        self.displayID = displayID
        self.screenRect = screenRect
        self.jpeg = jpeg
    }

    /// Points per frame pixel.
    public var scale: CGFloat {
        width > 0 ? screenRect.width / CGFloat(width) : 1
    }
}

/// Why a capture happened.
public enum CaptureReason: String, Codable, Sendable, CaseIterable {
    case focusChange
    case inputSettled
    case floor
    case manual

    public var label: String {
        switch self {
        case .focusChange: "focus change"
        case .inputSettled: "input settled"
        case .floor: "floor cadence"
        case .manual: "manual"
        }
    }
}

/// One kept observation: the subscription unit for later phases.
public struct ActivityObservation: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64
    public var timestamp: Date
    public var focus: FocusContext
    public var frame: FrameInfo
    public var textBlocks: [TextBlock]
    public var reason: CaptureReason

    public init(id: Int64 = 0, timestamp: Date, focus: FocusContext, frame: FrameInfo, textBlocks: [TextBlock], reason: CaptureReason) {
        self.id = id
        self.timestamp = timestamp
        self.focus = focus
        self.frame = frame
        self.textBlocks = textBlocks
        self.reason = reason
    }

    /// Recognized text, one block per line, in reading order as Vision returned it.
    public var ocrText: String {
        textBlocks.map(\.text).joined(separator: "\n")
    }
}

/// What the pipeline is doing right now.
public enum SensingMode: String, Codable, Sendable, CaseIterable {
    /// Accessibility and screen capture both running.
    case watching
    /// Screen Recording denied: accessibility context only, no frames.
    case accessibilityOnly
    /// Accessibility denied: frames and OCR only, app identity from the workspace.
    case screenOnly
    /// Neither permission granted: nothing is sensed.
    case waitingForPermissions
    case paused
    case idle
    case excluded
    case stopped

    public var label: String {
        switch self {
        case .watching: "Watching"
        case .accessibilityOnly: "Accessibility only"
        case .screenOnly: "Screen only"
        case .waitingForPermissions: "Waiting for permissions"
        case .paused: "Paused"
        case .idle: "Idle"
        case .excluded: "Excluded app"
        case .stopped: "Stopped"
        }
    }

    /// True when the pipeline is allowed to capture frames in this mode.
    public var capturesFrames: Bool {
        switch self {
        case .watching, .screenOnly: true
        default: false
        }
    }

    /// True when the user has asked to watch and nothing blocks it except cadence.
    public var isActive: Bool {
        switch self {
        case .watching, .accessibilityOnly, .screenOnly: true
        default: false
        }
    }
}

/// A discrete happening worth remembering alongside observations.
public struct JournalEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case started
        case stopped
        case appSwitch
        case windowSwitch
        case idleStart
        case idleEnd
        case paused
        case resumed
        case excluded
        case permissionsChanged
        case journalCleared
        case retention
        /// The mentor loop showed a suggestion.
        case suggested
        /// The user acted on a suggestion, or it expired.
        case feedback
        /// The user said something about a suggestion while holding the talk-back key.
        case talkBack
        /// The standing understanding expired or was reset. Refreshes are not
        /// journaled here; they are in the model call log.
        case understanding

        public var label: String {
            switch self {
            case .started: "Started"
            case .stopped: "Stopped"
            case .appSwitch: "App switch"
            case .windowSwitch: "Window switch"
            case .idleStart: "Idle"
            case .idleEnd: "Active again"
            case .paused: "Paused"
            case .resumed: "Resumed"
            case .excluded: "Excluded app"
            case .permissionsChanged: "Permissions"
            case .journalCleared: "Journal cleared"
            case .retention: "Retention"
            case .suggested: "Suggestion"
            case .feedback: "Feedback"
            case .talkBack: "Talk back"
            case .understanding: "Understanding"
            }
        }
    }

    public var id: Int64
    public var timestamp: Date
    public var kind: Kind
    public var bundleID: String?
    public var appName: String?
    public var detail: String?

    public init(id: Int64 = 0, timestamp: Date = Date(), kind: Kind, bundleID: String? = nil, appName: String? = nil, detail: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.bundleID = bundleID
        self.appName = appName
        self.detail = detail
    }
}

/// A journal row of either kind, for timelines.
public enum JournalEntry: Equatable, Sendable, Identifiable {
    case observation(ActivityObservation)
    case event(JournalEvent)

    public var id: String {
        switch self {
        case .observation(let o): "o\(o.id)"
        case .event(let e): "e\(e.id)"
        }
    }

    public var timestamp: Date {
        switch self {
        case .observation(let o): o.timestamp
        case .event(let e): e.timestamp
        }
    }
}

/// Live cadence information for the debug panel.
public struct CadenceStatus: Equatable, Sendable {
    public var mode: SensingMode
    public var lastCaptureAt: Date?
    public var lastCaptureReason: CaptureReason?
    public var nextDueAt: Date?
    public var nextDueReason: CaptureReason?
    /// When the user last pressed a key or moved the mouse, as of the last input poll.
    public var lastInputAt: Date?
    public var keptCount: Int
    public var droppedCount: Int
    public var lastDropDistance: Int?
    public var lastError: String?

    public init(
        mode: SensingMode = .stopped,
        lastCaptureAt: Date? = nil,
        lastCaptureReason: CaptureReason? = nil,
        nextDueAt: Date? = nil,
        nextDueReason: CaptureReason? = nil,
        lastInputAt: Date? = nil,
        keptCount: Int = 0,
        droppedCount: Int = 0,
        lastDropDistance: Int? = nil,
        lastError: String? = nil
    ) {
        self.mode = mode
        self.lastCaptureAt = lastCaptureAt
        self.lastCaptureReason = lastCaptureReason
        self.nextDueAt = nextDueAt
        self.nextDueReason = nextDueReason
        self.lastInputAt = lastInputAt
        self.keptCount = keptCount
        self.droppedCount = droppedCount
        self.lastDropDistance = lastDropDistance
        self.lastError = lastError
    }
}

/// Everything the pipeline publishes. Later phases subscribe to this stream.
public enum SensingEvent: Sendable {
    /// A frame was kept, recognized, and journaled.
    case observation(ActivityObservation)
    /// The accessibility context changed (app, window, or focused element).
    case focusChanged(FocusContext)
    /// The pipeline mode changed.
    case modeChanged(SensingMode)
    /// An event was journaled.
    case event(JournalEvent)
    /// Cadence bookkeeping changed (published at most a few times per second).
    case cadence(CadenceStatus)
}
