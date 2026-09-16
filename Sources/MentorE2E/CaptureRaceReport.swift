import Foundation

/// Reads a replay journal's switch events and captures and says, for each
/// change moment, whether a focus-change capture followed it.
///
/// The journal records when a capture finished, not when it started, so the
/// harness judges a change moment from the outside, the way a person would:
/// a switch is honoured when the next capture after it says it happened
/// because focus changed. When a capture in flight swallows the switch, the
/// next capture comes from the floor cadence or from input instead, and the
/// screen the person moved to is captured late or not at all.
///
/// Switches with no capture between them are one change moment: the scheduler
/// keeps one pending focus change, so one capture answers the whole burst.
public enum CaptureRaceReport {
    public struct Switch: Equatable, Sendable {
        public let id: Int
        public let at: Date
        public let kind: String
        public init(id: Int, at: Date, kind: String) {
            self.id = id
            self.at = at
            self.kind = kind
        }
    }

    public struct Capture: Equatable, Sendable {
        public let id: Int
        public let at: Date
        public let reason: String
        public init(id: Int, at: Date, reason: String) {
            self.id = id
            self.at = at
            self.reason = reason
        }
    }

    public enum Verdict: String, Sendable {
        /// The next capture was a focus-change capture: the moment was kept.
        case kept
        /// A capture followed, but for another reason: the moment was dropped.
        case dropped
        /// The run ended before any capture followed; neither kept nor dropped.
        case pending
    }

    public struct Moment: Equatable, Sendable {
        public let switchIDs: [Int]
        public let at: Date
        public let captureID: Int?
        public let captureReason: String?
        public let verdict: String
    }

    public struct Report: Equatable, Sendable {
        public let moments: [Moment]
        public var kept: Int { moments.filter { $0.verdict == Verdict.kept.rawValue }.count }
        public var dropped: Int { moments.filter { $0.verdict == Verdict.dropped.rawValue }.count }
        public var pending: Int { moments.filter { $0.verdict == Verdict.pending.rawValue }.count }
    }

    public static let focusChangeReason = "focusChange"

    public static func evaluate(switches: [Switch], captures: [Capture]) -> Report {
        let ordered = switches.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        let capturesInOrder = captures.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        var moments: [Moment] = []

        var group: [Switch] = []
        func close(with capture: Capture?) {
            guard let first = group.first else { return }
            let verdict: Verdict = switch capture?.reason {
            case .none: .pending
            case .some(focusChangeReason): .kept
            default: .dropped
            }
            moments.append(Moment(
                switchIDs: group.map(\.id),
                at: first.at,
                captureID: capture?.id,
                captureReason: capture?.reason,
                verdict: verdict.rawValue
            ))
            group = []
        }

        for switchEvent in ordered {
            // A capture between the open group and this switch closes the group.
            if let first = group.first,
               let capture = capturesInOrder.first(where: { $0.at > first.at && $0.at <= switchEvent.at }) {
                close(with: capture)
            }
            group.append(switchEvent)
        }
        if let first = group.first {
            close(with: capturesInOrder.first { $0.at > first.at })
        }
        return Report(moments: moments)
    }
}
