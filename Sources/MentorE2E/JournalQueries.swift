import Foundation

/// A named read-only query over a Mentor journal, with the columns it prints.
///
/// The harness reads a replay journal from the outside (through `sqlite3`), so
/// what a scenario asserts on is one of these queries rather than SQL written
/// again in each scenario. The column list is the contract: adding a column
/// changes what scenarios read, so it belongs here and is covered by tests.
public struct JournalQuery: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let columns: [String]
    public let sql: String

    public init(name: String, summary: String, columns: [String], sql: String) {
        self.name = name
        self.summary = summary
        self.columns = columns
        self.sql = sql
    }
}

public enum JournalQueries {
    /// Local wall-clock time of a journal's REAL seconds-since-1970 column,
    /// to the millisecond, so a transcript lines up with a log or a tap.
    static func localTime(_ column: String) -> String {
        "strftime('%Y-%m-%d %H:%M:%f', \(column), 'unixepoch', 'localtime')"
    }

    private static func nullable(_ expression: String, as name: String) -> String {
        "coalesce(\(expression), '-') as \(name)"
    }

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

    public static let all: [JournalQuery] = [
        suggestions, calls, followUps, events, observations, counts,
    ]

    public static func named(_ name: String) -> JournalQuery? {
        all.first { $0.name == name }
    }

    /// A tab-separated table with a header line. Values are escaped so one row
    /// is always one line and one column is always one field, whatever text a
    /// title or an OCR line happens to hold.
    public static func table(columns: [String], rows: [[String]]) -> String {
        ([columns.joined(separator: "\t")] + rows.map { row in
            row.map(escape).joined(separator: "\t")
        }).joined(separator: "\n")
    }

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
