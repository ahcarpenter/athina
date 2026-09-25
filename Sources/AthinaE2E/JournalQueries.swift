import Foundation

/// A named read-only query over an Athina journal, with the columns it prints.
///
/// The harness reads a replay journal from the outside (through `sqlite3`), so
/// what a scenario asserts on is one of these queries rather than SQL written
/// again in each scenario. The column list is the contract: adding a column
/// changes what scenarios read, so it belongs here and is covered by tests.
public struct JournalQuery: Sendable, Equatable {
  /// What `athina-drive journal <db> <query>` calls the query.
  public let name: String
  /// A line saying what the query shows, for `athina-drive journal - queries`.
  public let summary: String
  /// The header of the printed table, one name per column the SQL selects.
  public let columns: [String]
  /// The read-only SQL that `sqlite3` runs against the journal.
  public let sql: String

  /// Creates a query called `name` that prints `columns` from what `sql`
  /// selects.
  public init(name: String, summary: String, columns: [String], sql: String) {
    self.name = name
    self.summary = summary
    self.columns = columns
    self.sql = sql
  }
}

/// The named journal queries that are plain SQL, and how their results are
/// printed.
///
/// `capture-race`, worked out in Swift, is `JournalDatabase`'s.
public enum JournalQueries {
  /// Local wall-clock time of a journal's REAL seconds-since-1970 column,
  /// to the millisecond, so a transcript lines up with a log or a tap.
  static func localTime(_ column: String) -> String {
    "strftime('%Y-%m-%d %H:%M:%f', \(column), 'unixepoch', 'localtime')"
  }

  private static func nullable(_ expression: String, as name: String) -> String {
    "coalesce(\(expression), '-') as \(name)"
  }

  /// Every suggestion, with the feedback it got and when.
  public static let suggestions = JournalQuery(
    name: "suggestions",
    summary: "every suggestion with its feedback and when the feedback landed",
    columns: ["id", "at", "app", "category", "title", "feedback", "feedback_at", "callout"],
    sql: """
      select id, \(localTime("timestamp")) as at, app_name as app, category, title,
             \(nullable("feedback", as: "feedback")),
             \(nullable(localTime("feedback_at"), as: "feedback_at")),
             callout_shown as callout
      from suggestions order by id
      """
  )

  /// Every model call, with its tier, outcome, cost, latency, and whether it
  /// was replayed, which a replay's calls are even when no fixture answered.
  public static let calls = JournalQuery(
    name: "calls",
    summary: "every model call, its tier, outcome, and whether it was replayed",
    columns: ["id", "at", "tier", "model", "outcome", "replayed", "cost", "latency"],
    sql: """
      select id, \(localTime("timestamp")) as at, tier, model, outcome, replayed,
             printf('%.4f', cost) as cost, printf('%.2f', latency) as latency
      from model_calls order by id
      """
  )

  /// Every follow-up question asked about a suggestion, with its answer or
  /// error.
  public static let followUps = JournalQuery(
    name: "follow-ups",
    summary: "every spoken or typed follow-up with its answer",
    columns: ["id", "suggestion_id", "at", "question", "answer", "error"],
    sql: """
      select id, suggestion_id, \(localTime("timestamp")) as at, question,
             \(nullable("answer", as: "answer")), \(nullable("error", as: "error"))
      from follow_ups order by id
      """
  )

  /// The sensing event log: app and window switches, idle, and pauses.
  public static let events = JournalQuery(
    name: "events",
    summary: "the sensing event log (app and window switches, idle, pauses)",
    columns: ["id", "at", "kind", "app", "detail"],
    sql: """
      select id, \(localTime("timestamp")) as at, kind,
             \(nullable("app_name", as: "app")), \(nullable("detail", as: "detail"))
      from events order by id
      """
  )

  /// Every capture, with its app, window, reason, and the length of its OCR
  /// text.
  public static let observations = JournalQuery(
    name: "observations",
    summary: "every capture, why it happened, and how much text it read",
    columns: ["id", "at", "app", "window", "reason", "ocr_chars"],
    sql: """
      select id, \(localTime("timestamp")) as at, app_name as app,
             \(nullable("window_title", as: "window")), reason,
             length(ocr_text) as ocr_chars
      from observations order by id
      """
  )

  /// One row of row counts, one column per table that tracks a run's
  /// progress, the cheapest way to poll it.
  public static let counts = JournalQuery(
    name: "counts",
    summary: "one row of row counts, the cheapest way to poll a run's progress",
    columns: ["observations", "events", "suggestions", "calls", "follow_ups", "understanding"],
    sql: """
      select (select count(*) from observations) as observations,
             (select count(*) from events) as events,
             (select count(*) from suggestions) as suggestions,
             (select count(*) from model_calls) as calls,
             (select count(*) from follow_ups) as follow_ups,
             (select count(*) from understanding) as understanding
      """
  )

  /// Every query, in the order `athina-drive journal - queries` lists them.
  public static let all: [JournalQuery] = [
    suggestions, calls, followUps, events, observations, counts,
  ]

  /// The query called `name`, or nil when there is none.
  public static func named(_ name: String) -> JournalQuery? {
    all.first { $0.name == name }
  }

  /// A tab-separated table with a header line.
  ///
  /// Values are escaped so one row is always one line and one column is always
  /// one field, whatever text a title or an OCR line happens to hold.
  public static func table(columns: [String], rows: [[String]]) -> String {
    ([columns.joined(separator: "\t")]
      + rows.map { row in
        row.map(escape).joined(separator: "\t")
      }).joined(separator: "\n")
  }

  /// `value` with backslashes, tabs, carriage returns and newlines written
  /// as backslash escapes, so it stays one field of one line.
  public static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\t", with: "\\t")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\n", with: "\\n")
  }

  /// Splits `sqlite3 -separator` output back into rows of fields, undoing
  /// nothing: sqlite3 is asked for a separator no journal text can contain.
  public static func parse(_ output: String, separator: String = "\u{1f}") -> [[String]] {
    output.split(separator: "\n", omittingEmptySubsequences: true).map {
      $0.components(separatedBy: separator)
    }
  }
}
