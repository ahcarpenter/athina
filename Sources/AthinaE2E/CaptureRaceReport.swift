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
  /// An app or window switch the journal recorded, from its `events` table.
  public struct Switch: Equatable, Sendable {
    /// The event's row id in the journal.
    public let id: Int
    /// The switch's timestamp in the journal.
    public let at: Date
    /// The event kind, `appSwitch` or `windowSwitch`.
    public let kind: String
    /// Creates a switch from its event's row id, time and kind.
    public init(id: Int, at: Date, kind: String) {
      self.id = id
      self.at = at
      self.kind = kind
    }
  }

  /// A capture the journal recorded, from its `observations` table.
  public struct Capture: Equatable, Sendable {
    /// The observation's row id in the journal.
    public let id: Int
    /// When the capture finished, as the observation's timestamp records it.
    public let at: Date
    /// Why the capture was taken, the observation's `reason` column
    /// (`focusChange` for one a switch asked for).
    public let reason: String
    /// Creates a capture from its observation's row id, time and reason.
    public init(id: Int, at: Date, reason: String) {
      self.id = id
      self.at = at
      self.reason = reason
    }
  }

  /// What became of one change moment.
  public enum Verdict: String, Sendable {
    /// The next capture was a focus-change capture: the moment was kept.
    case kept
    /// A capture followed, but for another reason: the moment was dropped.
    case dropped
    /// The run ended before any capture followed; neither kept nor dropped.
    case pending
  }

  /// One change moment: a burst of switches with no capture between them,
  /// and the capture that answered it.
  public struct Moment: Equatable, Sendable {
    /// The row ids of the switches in the burst, in order.
    public let switchIDs: [Int]
    /// The timestamp of the burst's first switch.
    public let at: Date
    /// The row id of the first capture after the burst, or nil when none
    /// followed.
    public let captureID: Int?
    /// That capture's reason, or nil when none followed.
    public let captureReason: String?
    /// The raw value of the moment's `Verdict`.
    public let verdict: String
  }

  /// Every change moment in a journal, in order, with the tally of each
  /// verdict.
  public struct Report: Equatable, Sendable {
    /// The change moments, earliest first.
    public let moments: [Moment]
    /// How many moments a focus-change capture answered.
    public var kept: Int { moments.filter { $0.verdict == Verdict.kept.rawValue }.count }
    /// How many moments a capture for another reason answered.
    public var dropped: Int { moments.filter { $0.verdict == Verdict.dropped.rawValue }.count }
    /// How many moments no capture followed before the run ended.
    public var pending: Int { moments.filter { $0.verdict == Verdict.pending.rawValue }.count }
  }

  /// The capture reason the sensing pipeline journals for a capture a switch
  /// asked for.
  public static let focusChangeReason = "focusChange"

  /// Groups `switches` into change moments and judges each by the first of
  /// `captures` after it.
  ///
  /// Neither list needs to be in order; both are sorted by time, then row
  /// id.
  public static func evaluate(switches: [Switch], captures: [Capture]) -> Report {
    let ordered = switches.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    let capturesInOrder = captures.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    var moments: [Moment] = []

    var group: [Switch] = []
    func close(with capture: Capture?) {
      guard let first = group.first else { return }
      let verdict: Verdict =
        switch capture?.reason {
        case .none: .pending
        case .some(focusChangeReason): .kept
        default: .dropped
        }
      moments.append(
        Moment(
          switchIDs: group.map(\.id),
          at: first.at,
          captureID: capture?.id,
          captureReason: capture?.reason,
          verdict: verdict.rawValue
        )
      )
      group = []
    }

    for switchEvent in ordered {
      // A capture between the open group and this switch closes the group.
      if let first = group.first,
        let capture = capturesInOrder.first(where: { $0.at > first.at && $0.at <= switchEvent.at })
      {
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
