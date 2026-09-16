import Foundation

/// Which variant of Mentor's mark the menu bar shows, and the pure function
/// that decides it.
///
/// The mark is one drawing: a profile in a crested Corinthian helmet. Every
/// variant keeps that silhouette and the same width, so the modes read as one
/// family rather than as six different icons, and so the item never shifts the
/// menu bar's other extras sideways when Mentor's state changes.
///
/// Two signals already carried elsewhere decide the variant, and this function
/// is the only place they are combined: `SensingMode` says what the pipeline is
/// doing, and `MentorStatus.Availability` says whether the mentor tier can
/// advise about it. Neither is changed here.
public enum MenuBarMark: String, CaseIterable, Sendable {
    /// Sensing, and the mentor can advise: the resting state.
    case watching
    /// Sensing is on, but the user has been away from the keyboard.
    case idle
    /// The user stopped Mentor, or it has not started.
    case paused
    /// The frontmost app is one the user excluded.
    case excluded
    /// Mentor cannot work until the user does something: grant a permission,
    /// or paste an API key.
    case needsSomething
    /// Mentor is sensing but is not advising for now: it is off in Settings,
    /// or the hourly spend cap has been reached and will roll over.
    case held

    /// The mark for a sensing mode and the mentor's availability.
    ///
    /// The sensing mode decides first, because a mode that is not watching is
    /// the more important thing to say: nothing is being captured at all.
    /// Availability only distinguishes the three watching modes from each
    /// other. While calls are replayed or recorded there is no live
    /// availability to report, so those modes read as plain watching.
    public static func resolve(
        mode: SensingMode,
        availability: MentorStatus.Availability,
        offline: Bool
    ) -> MenuBarMark {
        switch mode {
        case .waitingForPermissions: return .needsSomething
        case .excluded: return .excluded
        case .paused, .stopped: return .paused
        case .idle: return .idle
        case .watching, .screenOnly, .accessibilityOnly:
            guard !offline else { return .watching }
            switch availability {
            case .ready: return .watching
            case .noAPIKey: return .needsSomething
            case .disabled, .capReached: return .held
            }
        }
    }
}
