import Foundation

/// A Athina journal read from the outside, through `sqlite3`.
///
/// The journal is WAL, so a reader opens the database rather than copying the
/// file, and `sqlite3` is always present. Fields are separated by control
/// characters no journal text can contain, so a title or an OCR line with tabs
/// and newlines in it still parses back into one row.
public struct JournalDatabase: Sendable {
  public struct Failure: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
  }

  public static let fieldSeparator = "\u{1f}"
  public static let rowSeparator = "\u{1e}"

  public let path: String
  public init(path: String) { self.path = path }

  public func rows(_ sql: String) throws -> [[String]] {
    guard FileManager.default.fileExists(atPath: path) else {
      throw Failure("no journal at \(path)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
      "-readonly", "-noheader",
      "-separator", Self.fieldSeparator, "-newline", Self.rowSeparator,
      path, sql,
    ]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    do { try process.run() } catch { throw Failure("could not run sqlite3: \(error)") }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure("sqlite3 failed: \(String(decoding: errorData, as: UTF8.self))")
    }
    return String(decoding: data, as: UTF8.self)
      .components(separatedBy: Self.rowSeparator)
      .filter { !$0.isEmpty }
      .map { $0.components(separatedBy: Self.fieldSeparator) }
  }

  public func table(_ query: JournalQuery) throws -> String {
    JournalQueries.table(columns: query.columns, rows: try rows(query.sql))
  }

  /// The change moments in this journal and whether a focus-change capture
  /// followed each, with the same columns however the run was driven.
  public func captureRace() throws -> (table: String, report: CaptureRaceReport.Report) {
    let switches = try rows(
      """
      select id, timestamp, kind from events
      where kind in ('appSwitch', 'windowSwitch') order by timestamp, id
      """
    ).compactMap { row -> CaptureRaceReport.Switch? in
      guard row.count == 3, let id = Int(row[0]), let seconds = Double(row[1]) else { return nil }
      return CaptureRaceReport.Switch(
        id: id,
        at: Date(timeIntervalSince1970: seconds),
        kind: row[2]
      )
    }
    let captures = try rows("select id, timestamp, reason from observations order by timestamp, id")
      .compactMap { row -> CaptureRaceReport.Capture? in
        guard row.count == 3, let id = Int(row[0]), let seconds = Double(row[1]) else { return nil }
        return CaptureRaceReport.Capture(
          id: id,
          at: Date(timeIntervalSince1970: seconds),
          reason: row[2]
        )
      }
    let report = CaptureRaceReport.evaluate(switches: switches, captures: captures)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let table = JournalQueries.table(
      columns: ["switch_ids", "at", "capture", "capture_reason", "verdict"],
      rows: report.moments.map { moment in
        [
          moment.switchIDs.map(String.init).joined(separator: ","),
          formatter.string(from: moment.at),
          moment.captureID.map(String.init) ?? "-",
          moment.captureReason ?? "-",
          moment.verdict,
        ]
      }
    )
    return (table, report)
  }
}
