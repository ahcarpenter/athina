import Foundation

/// Text recognition effort for the on-device OCR pass.
public enum OCRLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case fast
    case accurate

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fast: "Fast"
        case .accurate: "Accurate"
        }
    }
}

/// Every threshold and cadence the sensing pipeline uses, in one place.
///
/// Decoding tolerates missing keys so settings files written by older builds
/// keep working when new fields are added: a missing field takes its default.
public struct SensingSettings: Codable, Equatable, Sendable {
    // MARK: Cadence

    /// Delay after an app or window switch before capturing, so the new
    /// window has finished drawing.
    public var focusSettleDelay: TimeInterval = 0.35
    /// Quiet time after a burst of typing or mouse activity before capturing.
    public var inputSettleDelay: TimeInterval = 1.5
    /// Slow floor cadence while the user is active.
    public var floorInterval: TimeInterval = 5
    /// Hard lower bound between two captures, whatever triggered them.
    public var minCaptureInterval: TimeInterval = 0.75
    /// Seconds without any input after which sensing stops until input resumes.
    public var idleThreshold: TimeInterval = 60
    /// How often the pipeline polls input activity while the user is active.
    public var inputPollInterval: TimeInterval = 0.5
    /// How often the pipeline polls input activity while idle.
    public var idlePollInterval: TimeInterval = 2

    // MARK: Frames

    /// Captured frames are downscaled so their longest edge is at most this.
    public var maxFrameDimension: Int = 1280
    /// Frames whose perceptual hash is within this Hamming distance of the
    /// previous kept frame are dropped (unless the focus or text changed).
    public var hashDistanceThreshold: Int = 4
    /// JPEG quality for stored thumbnails, 0...1.
    public var thumbnailJPEGQuality: Double = 0.5
    /// Vision text recognition level. Accurate by default: the fast level
    /// finds no text at all in light-on-dark UI such as terminals and dark
    /// mode editors, at any frame size.
    public var ocrLevel: OCRLevel = .accurate

    // MARK: Journal

    /// Thumbnails are deleted after this long.
    public var thumbnailRetention: TimeInterval = 6 * 3600
    /// Observations and events are deleted after this long.
    public var textRetention: TimeInterval = 7 * 86400
    /// When the journal grows past this, the oldest thumbnails and then the
    /// oldest observations are deleted until it fits.
    public var journalSizeCapBytes: Int64 = 500 * 1024 * 1024
    /// How often retention runs while the app is running.
    public var retentionInterval: TimeInterval = 600

    // MARK: Privacy

    /// Bundle identifiers under which no capture, OCR, or journaling happens.
    public var excludedBundleIDs: [String] = ExcludedApps.defaults
    /// Global hotkey that toggles pause.
    public var pauseHotKey: HotKey = .defaultPause

    // MARK: Mentor loop

    /// The mentor loop's own section, stored under `mentor` in the same file.
    public var mentor = MentorSettings()

    // MARK: Advanced

    /// Settings > Advanced > Enable debug panel: whether that pane offers the
    /// debug panel. Off until the person turns it on, including on an install
    /// from before it existed; a replay or recording opens the panel with
    /// `--open debug` whatever this says (`DebugPanelAccess`).
    public var showDebugPanel = false

    public init() {}

    // MARK: Codable with per-field defaults

    private enum CodingKeys: String, CodingKey {
        case focusSettleDelay, inputSettleDelay, floorInterval, minCaptureInterval
        case idleThreshold, inputPollInterval, idlePollInterval
        case maxFrameDimension, hashDistanceThreshold, thumbnailJPEGQuality, ocrLevel
        case thumbnailRetention, textRetention, journalSizeCapBytes, retentionInterval
        case excludedBundleIDs, pauseHotKey
        case mentor
        case showDebugPanel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SensingSettings()
        focusSettleDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .focusSettleDelay) ?? d.focusSettleDelay
        inputSettleDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .inputSettleDelay) ?? d.inputSettleDelay
        floorInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .floorInterval) ?? d.floorInterval
        minCaptureInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .minCaptureInterval) ?? d.minCaptureInterval
        idleThreshold = try c.decodeIfPresent(TimeInterval.self, forKey: .idleThreshold) ?? d.idleThreshold
        inputPollInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .inputPollInterval) ?? d.inputPollInterval
        idlePollInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .idlePollInterval) ?? d.idlePollInterval
        maxFrameDimension = try c.decodeIfPresent(Int.self, forKey: .maxFrameDimension) ?? d.maxFrameDimension
        hashDistanceThreshold = try c.decodeIfPresent(Int.self, forKey: .hashDistanceThreshold) ?? d.hashDistanceThreshold
        thumbnailJPEGQuality = try c.decodeIfPresent(Double.self, forKey: .thumbnailJPEGQuality) ?? d.thumbnailJPEGQuality
        ocrLevel = try c.decodeIfPresent(OCRLevel.self, forKey: .ocrLevel) ?? d.ocrLevel
        thumbnailRetention = try c.decodeIfPresent(TimeInterval.self, forKey: .thumbnailRetention) ?? d.thumbnailRetention
        textRetention = try c.decodeIfPresent(TimeInterval.self, forKey: .textRetention) ?? d.textRetention
        journalSizeCapBytes = try c.decodeIfPresent(Int64.self, forKey: .journalSizeCapBytes) ?? d.journalSizeCapBytes
        retentionInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .retentionInterval) ?? d.retentionInterval
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? d.excludedBundleIDs
        pauseHotKey = try c.decodeIfPresent(HotKey.self, forKey: .pauseHotKey) ?? d.pauseHotKey
        mentor = try c.decodeIfPresent(MentorSettings.self, forKey: .mentor) ?? d.mentor
        showDebugPanel = try c.decodeIfPresent(Bool.self, forKey: .showDebugPanel) ?? d.showDebugPanel
        self = validated()
    }

    /// Clamps every value into a range the pipeline can operate with.
    public func validated() -> SensingSettings {
        var s = self
        s.focusSettleDelay = s.focusSettleDelay.clamped(to: 0...5)
        s.inputSettleDelay = s.inputSettleDelay.clamped(to: 0.1...30)
        s.floorInterval = s.floorInterval.clamped(to: 1...600)
        s.minCaptureInterval = s.minCaptureInterval.clamped(to: 0.1...60)
        s.idleThreshold = s.idleThreshold.clamped(to: 5...3600)
        s.inputPollInterval = s.inputPollInterval.clamped(to: 0.1...5)
        s.idlePollInterval = s.idlePollInterval.clamped(to: 0.5...30)
        s.maxFrameDimension = s.maxFrameDimension.clamped(to: 320...4096)
        s.hashDistanceThreshold = s.hashDistanceThreshold.clamped(to: 0...PerceptualHash.bitCount)
        s.thumbnailJPEGQuality = s.thumbnailJPEGQuality.clamped(to: 0.1...1)
        s.thumbnailRetention = s.thumbnailRetention.clamped(to: 60...(365 * 86400))
        s.textRetention = max(s.textRetention.clamped(to: 60...(365 * 86400)), s.thumbnailRetention)
        s.journalSizeCapBytes = s.journalSizeCapBytes.clamped(to: (10 * 1024 * 1024)...(100 * 1024 * 1024 * 1024))
        s.retentionInterval = s.retentionInterval.clamped(to: 30...86400)
        s.excludedBundleIDs = ExcludedApps.normalized(s.excludedBundleIDs)
        s.mentor = s.mentor.validated()
        // One combination cannot both pause and listen; the pause key wins.
        if s.mentor.pushToTalkHotKey == s.pauseHotKey { s.mentor.pushToTalkHotKey = nil }
        return s
    }

    /// The excluded bundle identifiers as a lowercase set for matching.
    public var excludedBundleIDSet: Set<String> {
        Set(excludedBundleIDs.map { $0.lowercased() })
    }

    public func isExcluded(bundleID: String?) -> Bool {
        ExcludedApps.matches(bundleID: bundleID, excluded: excludedBundleIDSet)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
