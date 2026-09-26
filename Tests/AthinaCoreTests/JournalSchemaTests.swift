import Foundation
import Testing

@testable import AthinaCore

/// The journal's schema rules (AGENTS.md "Journal schema changes") as tests
/// rather than review: `clear(at:)` and `applyRetention` reach every table,
/// and a journal an older build created ends up with the same tables, columns
/// and indexes a new one has.
@Suite struct JournalSchemaTests {
  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("athina-tests-\(UUID().uuidString)")
      .appendingPathComponent("journal.sqlite")
  }

  private func rowCounts(in journal: Journal) async throws -> [String: Int] {
    var counts: [String: Int] = [:]
    let tables = try await journal.readOnlyRows(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    )
    for table in tables.map({ $0[0] }) {
      counts[table] = Int(try await journal.readOnlyRows("SELECT COUNT(*) FROM \(table)")[0][0])
    }
    return counts
  }

  /// Puts one row in every table sqlite_master lists, through a connection
  /// of its own, so a table added later gets one without this changing.
  ///
  /// Each column takes a value of its declared type: an INTEGER 1 and a REAL
  /// 0, so every time a row carries is at the epoch, older than any cutoff.
  private func fillEveryTable(of url: URL) throws {
    let db = try SQLiteConnection(path: url.path, create: false)
    let tables = try db.query(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    ) { $0.text(0) ?? "" }
    for table in tables {
      let columns = try db.query("PRAGMA table_info(\(table))") { row in
        (name: row.text(1) ?? "", type: (row.text(2) ?? "").uppercased())
      }
      let values: [SQLiteConnection.Value] = columns.map { column in
        if column.type.contains("INT") { return .int(1) }
        if column.type.contains("REAL") { return .double(0) }
        if column.type.contains("BLOB") { return .blob(Data([0])) }
        return .text("")
      }
      try db.run(
        """
        INSERT INTO \(table) (\(columns.map(\.name).joined(separator: ", ")))
        VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
        """,
        values
      )
    }
  }

  /// A journal with a row in every table, each checked to be there.
  private func filledJournal() async throws -> Journal {
    let url = temporaryURL()
    let journal = try Journal(url: url)
    try fillEveryTable(of: url)
    let counts = try await rowCounts(in: journal)
    #expect(counts.count >= 8)
    #expect(counts.values.allSatisfy { $0 == 1 }, "\(counts)")
    return journal
  }

  @Test func clearEmptiesEveryTableButItsOwnEvent() async throws {
    let journal = try await filledJournal()
    try await journal.clear(at: Date(timeIntervalSince1970: 1_700_000_000))
    var counts = try await rowCounts(in: journal)
    #expect(counts.removeValue(forKey: "events") == 1)
    #expect(counts.values.allSatisfy { $0 == 0 }, "clear(at:) left rows in \(counts)")
    #expect(try await journal.recentEvents(limit: 5).map(\.kind) == [.journalCleared])
  }

  @Test func retentionWithNoAgeAllowedEmptiesEveryTable() async throws {
    let journal = try await filledJournal()
    let policy = RetentionPolicy(thumbnailMaxAge: 0, textMaxAge: 0, sizeCapBytes: 1 << 40)
    _ = try await journal.applyRetention(policy, now: Date(timeIntervalSince1970: 1_700_000_000))
    let counts = try await rowCounts(in: journal)
    #expect(counts.values.allSatisfy { $0 == 0 }, "applyRetention left rows in \(counts)")
  }

  /// Every table as the first build that had it created it: observations,
  /// thumbnails and events as the first build did (#1), suggestions and
  /// model_calls as #2 did, follow_ups as #7 did, refresh_period as #8 did,
  /// and understanding as an earlier build of #8's branch did, with the NOT
  /// NULL schema_version column `migrate` drops. `CREATE TABLE IF NOT
  /// EXISTS` never changes a table that is already there, so a journal that
  /// began this way has every column added since only through `addColumn`.
  ///
  /// A new table goes in here as it first ships, and stays that way.
  private static let oldestTables = """
    CREATE TABLE observations (
        id INTEGER PRIMARY KEY,
        timestamp REAL NOT NULL,
        bundle_id TEXT,
        app_name TEXT NOT NULL,
        window_title TEXT,
        ax_summary TEXT NOT NULL,
        focus_json TEXT NOT NULL,
        ocr_text TEXT NOT NULL,
        text_blocks_json TEXT NOT NULL,
        frame_hash TEXT NOT NULL,
        frame_width INTEGER NOT NULL,
        frame_height INTEGER NOT NULL,
        display_id INTEGER NOT NULL,
        screen_x REAL NOT NULL,
        screen_y REAL NOT NULL,
        screen_w REAL NOT NULL,
        screen_h REAL NOT NULL,
        reason TEXT NOT NULL
    );
    CREATE INDEX observations_timestamp ON observations(timestamp);
    CREATE TABLE thumbnails (
        observation_id INTEGER PRIMARY KEY REFERENCES observations(id) ON DELETE CASCADE,
        timestamp REAL NOT NULL,
        jpeg BLOB NOT NULL
    );
    CREATE INDEX thumbnails_timestamp ON thumbnails(timestamp);
    CREATE TABLE events (
        id INTEGER PRIMARY KEY,
        timestamp REAL NOT NULL,
        kind TEXT NOT NULL,
        bundle_id TEXT,
        app_name TEXT,
        detail TEXT
    );
    CREATE INDEX events_timestamp ON events(timestamp);
    CREATE TABLE suggestions (
        id INTEGER PRIMARY KEY,
        timestamp REAL NOT NULL,
        bundle_id TEXT,
        app_name TEXT NOT NULL,
        window_title TEXT,
        category TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        explanation TEXT NOT NULL,
        confidence REAL NOT NULL,
        observation_id INTEGER,
        model TEXT NOT NULL,
        prompt_version INTEGER NOT NULL,
        feedback TEXT,
        feedback_at REAL
    );
    CREATE INDEX suggestions_timestamp ON suggestions(timestamp);
    CREATE TABLE model_calls (
        id INTEGER PRIMARY KEY,
        timestamp REAL NOT NULL,
        tier TEXT NOT NULL,
        model TEXT NOT NULL,
        prompt_version INTEGER NOT NULL,
        prompt_chars INTEGER NOT NULL,
        image_bytes INTEGER NOT NULL,
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        cache_write_tokens INTEGER NOT NULL,
        cache_read_tokens INTEGER NOT NULL,
        cost REAL NOT NULL,
        latency REAL NOT NULL,
        outcome TEXT NOT NULL,
        detail TEXT
    );
    CREATE INDEX model_calls_timestamp ON model_calls(timestamp);
    CREATE TABLE follow_ups (
        id INTEGER PRIMARY KEY,
        suggestion_id INTEGER NOT NULL,
        timestamp REAL NOT NULL,
        question TEXT NOT NULL,
        answer TEXT,
        error TEXT,
        model TEXT NOT NULL,
        prompt_version INTEGER NOT NULL
    );
    CREATE INDEX follow_ups_timestamp ON follow_ups(timestamp);
    CREATE INDEX follow_ups_suggestion ON follow_ups(suggestion_id);
    CREATE TABLE understanding (
        id INTEGER PRIMARY KEY,
        updated_at REAL NOT NULL,
        started_at REAL NOT NULL,
        revision INTEGER NOT NULL,
        schema_version INTEGER NOT NULL,
        prompt_version INTEGER NOT NULL,
        model TEXT NOT NULL,
        source TEXT NOT NULL,
        cost REAL NOT NULL,
        cumulative_cost REAL NOT NULL,
        content_json TEXT NOT NULL,
        covered_through_observation_id INTEGER
    );
    CREATE INDEX understanding_updated_at ON understanding(updated_at);
    CREATE TABLE refresh_period (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        started_at REAL NOT NULL,
        active_use REAL NOT NULL,
        counted_at REAL NOT NULL
    );
    """

  /// Every table's columns, each as its name, type, NOT NULL, default and
  /// primary key position, sorted by name: `addColumn` appends where a new
  /// journal's CREATE TABLE may put a column in the middle, and no query
  /// depends on the order.
  private func columns(of journal: Journal) async throws -> [[String]] {
    try await journal.readOnlyRows(
      """
      SELECT m.name, p.name, p.type, p."notnull", p.dflt_value, p.pk
      FROM sqlite_master m, pragma_table_info(m.name) p
      WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
      ORDER BY m.name, p.name
      """
    )
  }

  /// Every index with its table and columns in order.
  private func indexes(of journal: Journal) async throws -> [[String]] {
    try await journal.readOnlyRows(
      """
      SELECT m.name, m.tbl_name, i.name
      FROM sqlite_master m, pragma_index_info(m.name) i
      WHERE m.type = 'index' AND m.name NOT LIKE 'sqlite_%'
      ORDER BY m.name, i.seqno
      """
    )
  }

  @Test func aJournalFromTheOldestTablesOpensWithTheNewSchema() async throws {
    let url = temporaryURL()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let oldTables: Set<String>
    do {
      let db = try SQLiteConnection(path: url.path)
      try db.execute(Self.oldestTables)
      oldTables = Set(
        try db.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) ?? "" }
      )
    }
    let upgraded = try Journal(url: url)
    let fresh = try Journal(url: temporaryURL())

    let freshTables = Set(try await rowCounts(in: fresh).keys)
    #expect(
      oldTables == freshTables,
      "a table goes into oldestTables as it first ships: \(freshTables.subtracting(oldTables))"
    )
    #expect(try await columns(of: upgraded) == columns(of: fresh))
    #expect(try await indexes(of: upgraded) == indexes(of: fresh))
  }
}
