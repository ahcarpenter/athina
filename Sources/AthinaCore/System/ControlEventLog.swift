import Foundation

/// The events a launch serving the control API has handled, numbered in the
/// order it handled them, for the API's `wait-event` (docs/e2e.md "The control
/// API").
///
/// It holds what the sensing pipeline and the mentor loop publish, each once
/// the app has acted on it: a `suggestion` is logged once its toast is up.
/// Only the newest `capacity` are kept. The cadence bookkeeping the pipeline
/// publishes several times a second is left out.
public struct ControlEventLog: Equatable, Sendable {
  /// One event, by the name `wait-event` asks for and its fields as text.
  public struct Entry: Equatable, Sendable {
    /// Where it came in the order the app handled events, from 1.
    public var sequence: Int

    /// What kind of event it is: `observation`, `focus`, `mode`, `event`,
    /// `status`, `suggestion`, `feedback`, `followUp` or `call`.
    public var name: String

    /// What `wait-event` matches on and answers with.
    public var fields: [String: String]
  }

  /// The most entries kept.
  public let capacity: Int

  /// The newest entries, oldest first.
  public private(set) var entries: [Entry] = []

  /// The sequence of the newest entry, 0 before any.
  public private(set) var sequence = 0

  /// Creates an empty log keeping at most `capacity` entries.
  public init(capacity: Int = 2000) {
    self.capacity = max(1, capacity)
  }

  /// Logs an event the pipeline published; the cadence is left out.
  public mutating func append(_ event: SensingEvent) {
    switch event {
    case .observation(let observation):
      append(
        "observation",
        [
          "id": String(observation.id), "app": observation.focus.appName,
          "bundle": observation.focus.bundleID ?? "", "window": observation.focus.windowTitle ?? "",
          "reason": observation.reason.rawValue, "characters": String(observation.ocrText.count),
        ]
      )
    case .focusChanged(let focus):
      append(
        "focus",
        [
          "app": focus.appName, "bundle": focus.bundleID ?? "", "window": focus.windowTitle ?? "",
          "excluded": String(focus.isExcluded),
        ]
      )
    case .modeChanged(let mode):
      append("mode", ["mode": mode.rawValue])
    case .event(let event):
      append(event)
    case .cadence:
      break
    }
  }

  /// Logs an event the mentor loop published.
  public mutating func append(_ event: MentorEvent) {
    switch event {
    case .status(let status):
      append(
        "status",
        [
          "availability": status.availability.label, "mode": status.mode.rawValue,
          "inFlight": status.inFlight?.rawValue ?? "",
          "understanding": status.understanding.map { String($0.revision) } ?? "",
        ]
      )
    case .suggestion(let suggestion):
      append(
        "suggestion",
        [
          "id": String(suggestion.id), "title": suggestion.title,
          "category": suggestion.category.rawValue, "app": suggestion.appName,
          "observation": suggestion.observationID.map(String.init) ?? "",
        ]
      )
    case .feedback(let suggestion):
      append(
        "feedback",
        [
          "id": String(suggestion.id), "title": suggestion.title,
          "feedback": suggestion.feedback?.rawValue ?? "",
        ]
      )
    case .followUp(let followUp):
      append(
        "followUp",
        [
          "id": String(followUp.id), "suggestion": String(followUp.suggestionID),
          "question": followUp.question, "answered": String(followUp.answer != nil),
          "error": followUp.error ?? "",
        ]
      )
    case .call(let call):
      append(
        "call",
        [
          "id": String(call.id), "tier": call.tier.rawValue, "outcome": call.outcome.rawValue,
          "replayed": String(call.replayed),
        ]
      )
    case .event(let event):
      append(event)
    }
  }

  private mutating func append(_ event: JournalEvent) {
    append(
      "event",
      [
        "id": String(event.id), "kind": event.kind.rawValue, "app": event.appName ?? "",
        "detail": event.detail ?? "",
      ]
    )
  }

  private mutating func append(_ name: String, _ fields: [String: String]) {
    sequence += 1
    entries.append(Entry(sequence: sequence, name: name, fields: fields))
    if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
  }

  /// The first entry after `sequence` named `name` whose fields hold every
  /// value in `matching`, or nil when none has come yet.
  public func first(
    named name: String,
    after sequence: Int = 0,
    matching: [String: String] = [:]
  ) -> Entry? {
    entries.first { entry in
      entry.sequence > sequence && entry.name == name
        && matching.allSatisfy { entry.fields[$0.key] == $0.value }
    }
  }
}
