import Foundation
import MentorE2E

/// Reads a Mentor journal from the outside, through `sqlite3`.
///
/// The journal is WAL, so a reader must open the database itself rather than
/// copy the file; `sqlite3` does that and is always present. Fields are
/// separated by control characters no journal text can contain, so a title or
/// an OCR line with tabs and newlines in it still parses back into one row.
enum JournalReader {
    static let fieldSeparator = "\u{1f}"
    static let rowSeparator = "\u{1e}"

    static func rows(_ database: String, _ sql: String) -> [[String]] {
        guard FileManager.default.fileExists(atPath: database) else {
            fail("journal: no journal at \(database)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly", "-noheader",
            "-separator", fieldSeparator, "-newline", rowSeparator,
            database, sql,
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { fail("journal: could not run sqlite3: \(error)") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            fail("journal: sqlite3 failed: \(String(decoding: errorData, as: UTF8.self))")
        }
        let text = String(decoding: data, as: UTF8.self)
        return text
            .components(separatedBy: rowSeparator)
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: fieldSeparator) }
    }

    static func run(database: String, query name: String) {
        if name == "queries" {
            for query in JournalQueries.all {
                say("\(query.name.padding(toLength: 13, withPad: " ", startingAt: 0)) \(query.summary)")
            }
            say("capture-race   change moments and whether a focus-change capture followed each")
            return
        }
        if name == "capture-race" {
            captureRace(database: database)
            return
        }
        guard let query = JournalQueries.named(name) else {
            fail("journal: unknown query \"\(name)\"; `mentor-drive journal - queries` lists them")
        }
        say(JournalQueries.table(columns: query.columns, rows: rows(database, query.sql)))
    }

    /// The capture-race proof, read from the journal rather than from timing:
    /// for each change moment, the capture that followed it and why it happened.
    private static func captureRace(database: String) {
        let switches = rows(database, """
            select id, timestamp, kind from events
            where kind in ('appSwitch', 'windowSwitch') order by timestamp, id
            """).compactMap { row -> CaptureRaceReport.Switch? in
            guard row.count == 3, let id = Int(row[0]), let seconds = Double(row[1]) else { return nil }
            return CaptureRaceReport.Switch(id: id, at: Date(timeIntervalSince1970: seconds), kind: row[2])
        }
        let captures = rows(database, "select id, timestamp, reason from observations order by timestamp, id")
            .compactMap { row -> CaptureRaceReport.Capture? in
                guard row.count == 3, let id = Int(row[0]), let seconds = Double(row[1]) else { return nil }
                return CaptureRaceReport.Capture(id: id, at: Date(timeIntervalSince1970: seconds), reason: row[2])
            }

        let report = CaptureRaceReport.evaluate(switches: switches, captures: captures)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let table = report.moments.map { moment in
            [
                moment.switchIDs.map(String.init).joined(separator: ","),
                formatter.string(from: moment.at),
                moment.captureID.map(String.init) ?? "-",
                moment.captureReason ?? "-",
                moment.verdict,
            ]
        }
        say(JournalQueries.table(
            columns: ["switch_ids", "at", "capture", "capture_reason", "verdict"],
            rows: table
        ))
        say("")
        say("moments=\(report.moments.count) kept=\(report.kept) dropped=\(report.dropped) pending=\(report.pending)")
    }
}
