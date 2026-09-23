import Foundation

/// What the debug panel's Latest frame pane says while it has no frame to
/// show. It names the reason there is none now, read from the sensing mode
/// and whether Clear Journal just took the last frame away, rather than one
/// fixed line that blames Screen Recording even when it is granted.
public struct EmptyFrame: Equatable, Sendable {
    public var title: String
    public var message: String

    public init(mode: SensingMode, journalCleared: Bool) {
        title = journalCleared ? "Journal Cleared" : "Waiting for the First Capture"
        message = switch mode {
        case .watching, .screenOnly:
            journalCleared ? "The next capture appears here." : "Frames appear here as Athina captures them."
        case .accessibilityOnly, .waitingForPermissions:
            "Frames appear here once Screen Recording is granted."
        case .paused:
            "Frames appear here once watching resumes."
        case .idle:
            "Frames appear here once you are active again."
        case .excluded:
            "Nothing is captured while an excluded app is in front."
        case .stopped:
            "Frames appear here once Athina starts watching."
        }
    }
}
