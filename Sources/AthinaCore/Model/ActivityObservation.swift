import CoreGraphics
import Foundation

/// What the accessibility API says the user is focused on.
public struct FocusContext: Codable, Equatable, Sendable {
  /// When the reading was taken.
  public var timestamp: Date
  /// The process id of the frontmost app.
  public var pid: Int32
  /// The app's bundle identifier, or nil for an app without one.
  public var bundleID: String?
  /// The app's localized name, falling back to its bundle identifier or pid.
  public var appName: String
  /// The title of the app's focused window, or its main window when none is
  /// focused, or nil when there is none or it has no title.
  public var windowTitle: String?
  /// Focused window frame in global display coordinates (origin top-left of the main display).
  public var windowFrame: CGRect?
  /// The focused element's accessibility role, such as AXTextArea.
  public var focusedRole: String?
  /// The focused element's accessibility subrole, when it has one.
  public var focusedSubrole: String?
  /// The focused element's accessibility title, when it has one.
  public var focusedTitle: String?
  /// The focused element's accessibility description, such as Source editor.
  public var focusedDescription: String?
  /// Focused element text, truncated to `FocusContext.maxValueLength`.
  public var focusedValue: String?
  /// Length of the untruncated focused element text.
  public var focusedValueLength: Int?
  /// True when the app is on the excluded list: only the app identity is recorded.
  public var isExcluded: Bool
  /// False when the Accessibility permission is missing or the app exposes nothing.
  public var accessibilityAvailable: Bool

  /// The longest focused element text kept, in characters.
  public static let maxValueLength = 4000

  /// Creates a reading; by default only the app is known, it is not
  /// excluded, and accessibility is available.
  public init(
    timestamp: Date,
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
  /// The text Vision recognized in the block.
  public var text: String
  /// Vision's confidence in the text, from 0 to 1.
  public var confidence: Float
  /// Bounding box in captured-frame pixel coordinates, origin top-left.
  public var imageRect: CGRect
  /// Bounding box in global display coordinates, origin top-left of the main display.
  public var screenRect: CGRect

  /// Creates a block of recognized text.
  public init(text: String, confidence: Float, imageRect: CGRect, screenRect: CGRect) {
    self.text = text
    self.confidence = confidence
    self.imageRect = imageRect
    self.screenRect = screenRect
  }
}

/// A kept, downscaled capture of the display the user was working on.
public struct FrameInfo: Codable, Equatable, Sendable {
  /// The image's perceptual hash, whose Hamming distance to the previous
  /// kept frame's decides whether a capture is a near duplicate.
  public var hash: PerceptualHash
  /// The image's width in pixels, after downscaling.
  public var width: Int
  /// The image's height in pixels, after downscaling.
  public var height: Int
  /// The Core Graphics id of the display the frame shows.
  public var displayID: UInt32
  /// The display rectangle the frame shows, in global display coordinates.
  public var screenRect: CGRect
  /// JPEG thumbnail.
  ///
  /// Nil when it has been deleted by retention or not loaded.
  public var jpeg: Data?

  /// Creates the record of a kept frame.
  public init(
    hash: PerceptualHash,
    width: Int,
    height: Int,
    displayID: UInt32,
    screenRect: CGRect,
    jpeg: Data?
  ) {
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

  /// A short lowercase phrase for the reason, shown in the debug panel.
  ///
  /// It also reaches the model in the context the prompts are built from, so
  /// changing one changes what the model is told.
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
  /// The journal's row id, or 0 until the observation is journaled.
  public var id: Int64
  /// When the capture started.
  public var timestamp: Date
  /// The accessibility reading the capture was made under.
  public var focus: FocusContext
  /// The kept frame.
  public var frame: FrameInfo
  /// The text recognized in the frame, in the order Vision returned it.
  public var textBlocks: [TextBlock]
  /// Why the capture was made.
  public var reason: CaptureReason

  /// Creates an observation; its id stays 0 until the journal stores it.
  public init(
    id: Int64 = 0,
    timestamp: Date,
    focus: FocusContext,
    frame: FrameInfo,
    textBlocks: [TextBlock],
    reason: CaptureReason
  ) {
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

  /// The mode's name, capitalized, as the debug panel's badge shows it.
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
  /// What happened.
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

    /// The kind's name, capitalized, as the debug panel's timeline shows it.
    ///
    /// Lowercased, it also reaches the model in the recent events, so changing
    /// one changes what the model is told.
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

  /// The journal's row id, or 0 until the event is journaled.
  public var id: Int64
  /// When it happened.
  public var timestamp: Date
  /// What happened.
  public var kind: Kind
  /// The bundle identifier of the app the event is about, if any.
  public var bundleID: String?
  /// The name of the app the event is about, if any.
  public var appName: String?
  /// A few words more, such as the app switched from.
  public var detail: String?

  /// Creates an event; its id stays 0 until the journal stores it.
  public init(
    id: Int64 = 0,
    timestamp: Date,
    kind: Kind,
    bundleID: String? = nil,
    appName: String? = nil,
    detail: String? = nil
  ) {
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

  /// A key unique across both kinds of row: the row id after an o for an
  /// observation or an e for an event.
  public var id: String {
    switch self {
    case .observation(let o): "o\(o.id)"
    case .event(let e): "e\(e.id)"
    }
  }

  /// When the observation was captured or the event happened.
  public var timestamp: Date {
    switch self {
    case .observation(let o): o.timestamp
    case .event(let e): e.timestamp
    }
  }
}

/// Live cadence information for the debug panel.
public struct CadenceStatus: Equatable, Sendable {
  /// The pipeline's mode.
  public var mode: SensingMode
  /// When the last capture attempt finished, whether or not its frame was
  /// kept, or nil before the first.
  public var lastCaptureAt: Date?
  /// Why the last kept frame was captured, or nil before the first.
  public var lastCaptureReason: CaptureReason?
  /// When the next capture falls due, or nil while the pipeline is not
  /// capturing.
  public var nextDueAt: Date?
  /// Why the next capture falls due, or nil while the pipeline is not
  /// capturing.
  public var nextDueReason: CaptureReason?
  /// When the user last pressed a key or moved the mouse, as of the last input poll.
  public var lastInputAt: Date?
  /// How many captures were kept since the pipeline started.
  public var keptCount: Int
  /// How many captures were dropped as near duplicates of the last kept
  /// frame since the pipeline started.
  public var droppedCount: Int
  /// The last dropped capture's hash distance to the last kept frame, or nil
  /// before the first drop.
  public var lastDropDistance: Int?
  /// The last error the pipeline hit, prefixed with its stage, such as
  /// capture or ocr; a capture that succeeds clears it.
  public var lastError: String?

  /// Creates a status; by default the pipeline is stopped and has captured
  /// nothing.
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

/// Everything the pipeline publishes.
///
/// Later phases subscribe to this stream.
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
