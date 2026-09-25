import Foundation

/// What Athina believes the user is working toward and what has happened so
/// far: the part of its context that outlives a single call.
///
/// The model writes it; the app only stores it, bounds it, and renders it back
/// into the next prompt. Every field is a plain sentence so a person can read
/// the whole record in the debug panel and see exactly what is being carried.
public struct Understanding: Codable, Equatable, Sendable {
  /// Something the user appears to be working toward, and why Athina thinks so.
  public struct Goal: Codable, Equatable, Sendable, Identifiable {
    public var goal: String
    /// What on screen or in the journal supports this reading.
    public var evidence: String
    /// How sure the model is, 0 to 1.
    public var confidence: Double

    public var id: String { goal }

    public init(goal: String, evidence: String, confidence: Double) {
      self.goal = goal
      self.evidence = evidence
      self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      goal = (try c.decodeIfPresent(String.self, forKey: .goal) ?? "").withPlainDashes
      evidence = (try c.decodeIfPresent(String.self, forKey: .evidence) ?? "").withPlainDashes
      confidence = (try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0).clamped(to: 0...1)
    }
  }

  /// Inferred goals, strongest first after `normalized()`.
  public var goals: [Goal]
  /// What has happened so far, condensed, oldest first.
  public var timeline: [String]
  /// What Athina has already said and how the user answered.
  public var mentorHistory: [String]
  /// Questions or worries worth watching for.
  public var openConcerns: [String]

  public init(
    goals: [Goal] = [],
    timeline: [String] = [],
    mentorHistory: [String] = [],
    openConcerns: [String] = []
  ) {
    self.goals = goals
    self.timeline = timeline
    self.mentorHistory = mentorHistory
    self.openConcerns = openConcerns
  }

  private enum CodingKeys: String, CodingKey {
    case goals, timeline
    case mentorHistory = "mentor_history"
    case openConcerns = "open_concerns"
  }

  /// Every field defaults, so a record written by an older prompt version
  /// still decodes into whatever this build understands.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    goals = try c.decodeIfPresent([Goal].self, forKey: .goals) ?? []
    timeline = try c.decodeIfPresent([String].self, forKey: .timeline) ?? []
    mentorHistory = try c.decodeIfPresent([String].self, forKey: .mentorHistory) ?? []
    openConcerns = try c.decodeIfPresent([String].self, forKey: .openConcerns) ?? []
    self = normalized()
  }

  // MARK: Shape

  /// Drops blank entries, replaces any dash the model reached for, and sorts
  /// goals strongest first.
  ///
  /// Two goals with the same text collapse into the stronger one, so a goal's
  /// text can serve as its identity.
  public func normalized() -> Understanding {
    func clean(_ line: String) -> String {
      line.withPlainDashes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func clean(_ lines: [String]) -> [String] {
      lines.map { clean($0) }.filter { !$0.isEmpty }
    }
    var seen = Set<String>()
    return Understanding(
      goals:
        goals
        .map { Goal(goal: clean($0.goal), evidence: clean($0.evidence), confidence: $0.confidence) }
        .filter { !$0.goal.isEmpty }
        .sorted {
          $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.goal < $1.goal
        }
        .filter { seen.insert($0.goal).inserted },
      timeline: clean(timeline),
      mentorHistory: clean(mentorHistory),
      openConcerns: clean(openConcerns)
    )
  }

  /// True when there is nothing worth carrying or showing.
  public var isEmpty: Bool {
    goals.isEmpty && timeline.isEmpty && mentorHistory.isEmpty && openConcerns.isEmpty
  }

  /// The goal Athina is most confident about: the one a suggestion is judged
  /// against and the one the menu shows.
  public var primaryGoal: Goal? { goals.first }

  /// Roughly how much prompt the rendered record costs.
  public var estimatedTokens: Int { TokenEstimate.tokens(in: promptBlock) }

  /// The record trimmed until it fits `tokenBudget`: the oldest timeline
  /// entries go first, then the oldest mentor history, then the least recent
  /// concern, then the weakest goal.
  ///
  /// The strongest goal always survives, so a tiny budget still answers "what
  /// is this person trying to do".
  public func bounded(toTokens tokenBudget: Int) -> Understanding {
    var result = normalized()
    let budget = max(1, tokenBudget)
    while result.estimatedTokens > budget {
      if result.timeline.count > 1 {
        result.timeline.removeFirst()
      } else if result.mentorHistory.count > 1 {
        result.mentorHistory.removeFirst()
      } else if !result.openConcerns.isEmpty {
        result.openConcerns.removeLast()
      } else if !result.timeline.isEmpty {
        result.timeline.removeFirst()
      } else if !result.mentorHistory.isEmpty {
        result.mentorHistory.removeFirst()
      } else if result.goals.count > 1 {
        result.goals.removeLast()
      } else {
        break
      }
    }
    return result
  }

  // MARK: Rendering

  /// The full record as the mentor and refresh tiers see it.
  public var promptBlock: String {
    var lines: [String] = []
    if goals.isEmpty {
      lines.append("What they appear to be working toward: not established yet.")
    } else {
      lines.append("What they appear to be working toward, most likely first:")
      for (index, goal) in goals.enumerated() {
        lines.append("\(index + 1). \(goal.goal) (confidence \(percent(goal.confidence)))")
        if !goal.evidence.isEmpty { lines.append("   evidence: \(goal.evidence)") }
      }
    }
    appendSection(&lines, title: "What has happened so far, oldest first:", items: timeline)
    appendSection(
      &lines,
      title: "What you have already told them, and their answer:",
      items: mentorHistory
    )
    appendSection(&lines, title: "Open concerns to watch for:", items: openConcerns)
    return lines.joined(separator: "\n")
  }

  /// One compact paragraph for the triage message, so triage can notice an
  /// action that conflicts with the goal without carrying the whole record.
  public var paragraph: String {
    var parts: [String] = []
    if goals.isEmpty {
      parts.append("No goal has been established yet.")
    } else {
      let stated = goals.prefix(3).map { "\($0.goal) (confidence \(percent($0.confidence)))" }
      parts.append("The user appears to be working toward: \(stated.joined(separator: "; ")).")
    }
    if let latest = timeline.last {
      parts.append("Most recently: \(latest)")
    }
    if !openConcerns.isEmpty {
      parts.append("Open concerns: \(openConcerns.prefix(2).joined(separator: "; ")).")
    }
    return parts.joined(separator: " ")
  }

  private func appendSection(_ lines: inout [String], title: String, items: [String]) {
    guard !items.isEmpty else { return }
    lines.append("")
    lines.append(title)
    lines.append(contentsOf: items.map { "- \($0)" })
  }

  private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }
}

/// Which call wrote a revision of the understanding.
public enum UnderstandingSource: String, Codable, Sendable, CaseIterable {
  /// Folded into a mentor call's reply, so it cost nothing beyond that call.
  case mentorCall
  /// Its own periodic refresh call, made because no mentor call had refreshed
  /// the record within the refresh interval.
  case periodic

  public var label: String {
    switch self {
    case .mentorCall: "carried by a mentor call"
    case .periodic: "periodic refresh"
    }
  }
}

/// Why an understanding is no longer current.
public enum UnderstandingExpiry: Equatable, Sendable {
  /// Nothing happened for longer than the settable idle gap.
  case idleGap(TimeInterval)
  /// It was last written on an earlier day.
  case newDay

  public var label: String {
    switch self {
    case .idleGap(let gap):
      "no activity for \(gap < 3600 ? "\(Int(gap / 60))m" : "\(Int(gap / 3600))h")"
    case .newDay: "a new day started"
    }
  }

  /// Why a reading written at `writtenAt` no longer describes the present, or
  /// nil while it still does.
  ///
  /// The idle gap runs from the user's last activity, or from the write when
  /// nothing has been observed since it, as after a relaunch.
  public static func of(
    writtenAt: Date,
    now: Date,
    idleGap: TimeInterval,
    lastActivityAt: Date?,
    calendar: Calendar = .current
  ) -> UnderstandingExpiry? {
    if !calendar.isDate(writtenAt, inSameDayAs: now) { return .newDay }
    let lastActive = max(writtenAt, lastActivityAt ?? writtenAt)
    if now.timeIntervalSince(lastActive) > idleGap { return .idleGap(idleGap) }
    return nil
  }
}

/// One stored revision of the understanding.
///
/// Revisions are inserted, never updated, so the journal keeps the trail of how
/// the reading developed and retention and Clear Journal treat them like every
/// other journal row.
public struct UnderstandingRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: Int64
  /// When this revision was written.
  public var updatedAt: Date
  /// When the understanding these revisions belong to first formed.
  ///
  /// Reset starts a new one; so does expiry.
  public var startedAt: Date
  /// 1 for the first revision, one more for each refresh that folds into it.
  public var revision: Int
  /// `MentorPrompts.version` at the time of writing.
  public var promptVersion: Int
  public var model: String
  public var source: UnderstandingSource
  /// What this revision's own call cost; zero when a mentor call carried it.
  public var cost: Double
  /// Everything refresh calls have cost since `startedAt`.
  public var cumulativeCost: Double
  public var content: Understanding
  /// The highest observation id the call that wrote this revision read, so the
  /// next write reads every observation journaled after it.
  ///
  /// Nil when that call read none.
  public var coveredThroughObservationID: Int64?

  public init(
    id: Int64 = 0,
    updatedAt: Date,
    startedAt: Date,
    revision: Int,
    promptVersion: Int,
    model: String,
    source: UnderstandingSource,
    cost: Double,
    cumulativeCost: Double,
    content: Understanding,
    coveredThroughObservationID: Int64? = nil
  ) {
    self.id = id
    self.updatedAt = updatedAt
    self.startedAt = startedAt
    self.revision = revision
    self.promptVersion = promptVersion
    self.model = model
    self.source = source
    self.cost = cost
    self.cumulativeCost = cumulativeCost
    self.content = content
    self.coveredThroughObservationID = coveredThroughObservationID
  }

  /// The next revision after this one, carrying the run's start, count, and cost forward.
  public func next(
    content: Understanding,
    at time: Date,
    model: String,
    source: UnderstandingSource,
    cost: Double,
    promptVersion: Int,
    coveredThroughObservationID: Int64? = nil
  ) -> UnderstandingRecord {
    UnderstandingRecord(
      updatedAt: time,
      startedAt: startedAt,
      revision: revision + 1,
      promptVersion: promptVersion,
      model: model,
      source: source,
      cost: cost,
      cumulativeCost: cumulativeCost + cost,
      content: content,
      coveredThroughObservationID: coveredThroughObservationID
    )
  }

  /// The first revision of a fresh understanding.
  public static func first(
    content: Understanding,
    at time: Date,
    model: String,
    source: UnderstandingSource,
    cost: Double,
    promptVersion: Int,
    coveredThroughObservationID: Int64? = nil
  ) -> UnderstandingRecord {
    UnderstandingRecord(
      updatedAt: time,
      startedAt: time,
      revision: 1,
      promptVersion: promptVersion,
      model: model,
      source: source,
      cost: cost,
      cumulativeCost: cost,
      content: content,
      coveredThroughObservationID: coveredThroughObservationID
    )
  }
}
