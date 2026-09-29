import CoreGraphics
import Foundation
internal import GRDB

/// A summary of what the journal holds: its counts, size on disk, and the time
/// span it covers.
public struct JournalStats: Equatable, Sendable {
  /// The number of observations stored.
  public var observationCount: Int
  /// The number of thumbnails stored; fewer than the observations once
  /// thumbnail retention has run.
  public var thumbnailCount: Int
  /// The number of events stored.
  public var eventCount: Int
  /// Bytes in use by the database's live pages, excluding free pages.
  public var usedBytes: Int64
  /// The timestamp of the oldest observation or event, or nil when there are
  /// none.
  public var oldest: Date?
  /// The timestamp of the newest observation or event, or nil when there are
  /// none.
  public var newest: Date?

  /// Creates a summary from its counts, size, and time span.
  public init(
    observationCount: Int = 0,
    thumbnailCount: Int = 0,
    eventCount: Int = 0,
    usedBytes: Int64 = 0,
    oldest: Date? = nil,
    newest: Date? = nil
  ) {
    self.observationCount = observationCount
    self.thumbnailCount = thumbnailCount
    self.eventCount = eventCount
    self.usedBytes = usedBytes
    self.oldest = oldest
    self.newest = newest
  }
}

/// The local activity journal: a SQLite database of observations and events.
///
/// Thumbnails live in their own table so text retention can outlast them and
/// so timeline queries never load image bytes they do not need.
///
/// The database is reached through GRDB. A journal file is a pool of
/// connections in write-ahead-log mode: one writer, which every write goes
/// through, and readers beside it, so the live lists (`liveSuggestions(limit:)`
/// and the rest) fetch again after a write without holding the next one up.
public actor Journal {
  /// The journal's SQLite file.
  public nonisolated let url: URL
  /// A `DatabasePool` for a journal file, a `DatabaseQueue` for one in memory.
  private let db: any DatabaseWriter
  private let encoder = JSONEncoder()

  /// `~/Library/Application Support/athina/journal.sqlite`, or the same file
  /// in another data directory (see `LaunchFiles`).
  public static func defaultURL(in directory: URL = AppPaths.supportDirectory()) -> URL {
    directory.appendingPathComponent("journal.sqlite")
  }

  /// Opens (creating if needed) the journal file at `url`.
  public init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    self.url = url
    db = try DatabasePool(path: url.path, configuration: Journal.configuration)
    try db.write(Journal.migrate)
  }

  private init(memoryOnly: Void) throws {
    url = URL(string: "sqlite:memory")!
    db = try DatabaseQueue(configuration: Journal.configuration)
    try db.write(Journal.migrate)
  }

  /// A private in-memory journal, for tests.
  public static func inMemory() throws -> Journal {
    try Journal(memoryOnly: ())
  }

  /// How every connection is opened.
  ///
  /// GRDB turns on foreign keys, and for a file it turns on write-ahead
  /// logging with `synchronous = NORMAL` once the writer is open.
  private static var configuration: Configuration {
    var configuration = Configuration()
    configuration.busyMode = .timeout(2)
    configuration.prepareDatabase { db in
      // auto_vacuum must be set before any table exists to take effect on a
      // new file, which is before GRDB's switch to write-ahead logging, since
      // that writes one. Readers write nothing.
      guard !db.configuration.readonly else { return }
      try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
    }
    return configuration
  }

  private static func migrate(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE IF NOT EXISTS observations (
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
        CREATE INDEX IF NOT EXISTS observations_timestamp ON observations(timestamp);
        CREATE TABLE IF NOT EXISTS thumbnails (
            observation_id INTEGER PRIMARY KEY REFERENCES observations(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL,
            jpeg BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS thumbnails_timestamp ON thumbnails(timestamp);
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY,
            timestamp REAL NOT NULL,
            kind TEXT NOT NULL,
            bundle_id TEXT,
            app_name TEXT,
            detail TEXT
        );
        CREATE INDEX IF NOT EXISTS events_timestamp ON events(timestamp);
        CREATE TABLE IF NOT EXISTS suggestions (
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
            judged_goal TEXT,
            observation_id INTEGER,
            model TEXT NOT NULL,
            prompt_version INTEGER NOT NULL,
            feedback TEXT,
            feedback_at REAL,
            region_json TEXT,
            callout_shown INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS suggestions_timestamp ON suggestions(timestamp);
        CREATE TABLE IF NOT EXISTS follow_ups (
            id INTEGER PRIMARY KEY,
            suggestion_id INTEGER NOT NULL,
            timestamp REAL NOT NULL,
            question TEXT NOT NULL,
            answer TEXT,
            error TEXT,
            model TEXT NOT NULL,
            prompt_version INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS follow_ups_timestamp ON follow_ups(timestamp);
        CREATE INDEX IF NOT EXISTS follow_ups_suggestion ON follow_ups(suggestion_id);
        CREATE TABLE IF NOT EXISTS understanding (
            id INTEGER PRIMARY KEY,
            updated_at REAL NOT NULL,
            started_at REAL NOT NULL,
            revision INTEGER NOT NULL,
            prompt_version INTEGER NOT NULL,
            model TEXT NOT NULL,
            source TEXT NOT NULL,
            cost REAL NOT NULL,
            cumulative_cost REAL NOT NULL,
            content_json TEXT NOT NULL,
            covered_through_observation_id INTEGER
        );
        CREATE INDEX IF NOT EXISTS understanding_updated_at ON understanding(updated_at);
        CREATE TABLE IF NOT EXISTS refresh_period (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            started_at REAL NOT NULL,
            active_use REAL NOT NULL,
            counted_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS model_calls (
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
        CREATE INDEX IF NOT EXISTS model_calls_timestamp ON model_calls(timestamp);
        """
    )
    // Columns added or dropped after a table shipped: CREATE TABLE IF NOT
    // EXISTS leaves an existing journal's table alone, so change them here.
    try addColumn("replayed INTEGER NOT NULL DEFAULT 0", named: "replayed", to: "model_calls", db)
    try addColumn(
      "provider TEXT NOT NULL DEFAULT 'anthropic'",
      named: "provider",
      to: "model_calls",
      db
    )
    try addColumn("region_json TEXT", named: "region_json", to: "suggestions", db)
    try addColumn(
      "callout_shown INTEGER NOT NULL DEFAULT 0",
      named: "callout_shown",
      to: "suggestions",
      db
    )
    try addColumn("judged_goal TEXT", named: "judged_goal", to: "suggestions", db)
    try dropColumn(named: "schema_version", from: "understanding", db)
  }

  private static func columns(of table: String, _ db: Database) throws -> [String] {
    try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)", arguments: [table])
  }

  /// Adds a column to an existing table, once.
  ///
  /// Nothing happens when the table was created with it already.
  private static func addColumn(
    _ definition: String,
    named name: String,
    to table: String,
    _ db: Database
  ) throws {
    guard !(try columns(of: table, db)).contains(name) else { return }
    try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(definition)")
  }

  /// Drops a column from an existing table, once.
  ///
  /// Nothing happens when the table was created without it.
  private static func dropColumn(
    named name: String,
    from table: String,
    _ db: Database
  ) throws {
    guard (try columns(of: table, db)).contains(name) else { return }
    try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN \(name)")
  }

  // MARK: Writes

  /// Stores the observation and its thumbnail.
  ///
  /// Returns the observation with its new id.
  @discardableResult
  public func record(_ observation: ActivityObservation) throws -> ActivityObservation {
    let focusJSON = String(decoding: try encoder.encode(observation.focus), as: UTF8.self)
    let blocksJSON = String(decoding: try encoder.encode(observation.textBlocks), as: UTF8.self)
    let f = observation.frame
    let id = try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO observations (timestamp, bundle_id, app_name, window_title, ax_summary,
              focus_json, ocr_text, text_blocks_json, frame_hash, frame_width, frame_height,
              display_id, screen_x, screen_y, screen_w, screen_h, reason)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          observation.timestamp.timeIntervalSince1970,
          observation.focus.bundleID,
          observation.focus.appName,
          observation.focus.windowTitle,
          observation.focus.summary,
          focusJSON,
          observation.ocrText,
          blocksJSON,
          f.hash.hexString,
          f.width,
          f.height,
          Int64(f.displayID),
          Double(f.screenRect.origin.x),
          Double(f.screenRect.origin.y),
          Double(f.screenRect.width),
          Double(f.screenRect.height),
          observation.reason.rawValue,
        ]
      )
      let id = db.lastInsertedRowID
      if let jpeg = f.jpeg {
        try db.execute(
          sql: "INSERT INTO thumbnails (observation_id, timestamp, jpeg) VALUES (?, ?, ?)",
          arguments: [id, observation.timestamp.timeIntervalSince1970, jpeg]
        )
      }
      return id
    }
    var stored = observation
    stored.id = id
    return stored
  }

  /// Stores an event.
  ///
  /// Returns it with its new id.
  @discardableResult
  public func record(_ event: JournalEvent) throws -> JournalEvent {
    var stored = event
    stored.id = try db.write { db in try Journal.insert(event, db) }
    return stored
  }

  private static func insert(_ event: JournalEvent, _ db: Database) throws -> Int64 {
    try db.execute(
      sql:
        "INSERT INTO events (timestamp, kind, bundle_id, app_name, detail) VALUES (?, ?, ?, ?, ?)",
      arguments: [
        event.timestamp.timeIntervalSince1970,
        event.kind.rawValue,
        event.bundleID,
        event.appName,
        event.detail,
      ]
    )
    return db.lastInsertedRowID
  }

  /// Stores a suggestion the mentor made, before `publishGate` decides
  /// whether it is shown.
  ///
  /// Returns it with its new id.
  @discardableResult
  public func record(_ suggestion: Suggestion) throws -> Suggestion {
    let regionJSON = try suggestion.region.map {
      String(decoding: try encoder.encode($0), as: UTF8.self)
    }
    var stored = suggestion
    stored.id = try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO suggestions (timestamp, bundle_id, app_name, window_title, category, title,
              body, explanation, confidence, judged_goal, observation_id, model, prompt_version,
              feedback, feedback_at, region_json, callout_shown)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          suggestion.timestamp.timeIntervalSince1970,
          suggestion.bundleID,
          suggestion.appName,
          suggestion.windowTitle,
          suggestion.category.rawValue,
          suggestion.title,
          suggestion.body,
          suggestion.explanation,
          suggestion.confidence,
          suggestion.judgedGoal,
          suggestion.observationID,
          suggestion.model,
          suggestion.promptVersion,
          suggestion.feedback?.rawValue,
          suggestion.feedbackAt?.timeIntervalSince1970,
          regionJSON,
          suggestion.calloutShown,
        ]
      )
      return db.lastInsertedRowID
    }
    return stored
  }

  /// Stores one talk-back exchange.
  ///
  /// Returns it with its new id.
  @discardableResult
  public func record(_ followUp: FollowUp) throws -> FollowUp {
    var stored = followUp
    stored.id = try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO follow_ups (suggestion_id, timestamp, question, answer, error, model,
              prompt_version)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          followUp.suggestionID,
          followUp.timestamp.timeIntervalSince1970,
          followUp.question,
          followUp.answer,
          followUp.error,
          followUp.model,
          followUp.promptVersion,
        ]
      )
      return db.lastInsertedRowID
    }
    return stored
  }

  /// Stores a model call record.
  ///
  /// Returns it with its new id.
  @discardableResult
  public func record(_ call: ModelCallRecord) throws -> ModelCallRecord {
    var stored = call
    stored.id = try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO model_calls (timestamp, tier, model, prompt_version, prompt_chars,
              image_bytes, input_tokens, output_tokens, cache_write_tokens, cache_read_tokens,
              cost, latency, outcome, detail, replayed, provider)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          call.timestamp.timeIntervalSince1970,
          call.tier.rawValue,
          call.model,
          call.promptVersion,
          call.promptCharacters,
          call.imageBytes,
          call.usage.inputTokens,
          call.usage.outputTokens,
          call.usage.cacheCreationInputTokens,
          call.usage.cacheReadInputTokens,
          call.cost,
          call.latency,
          call.outcome.rawValue,
          call.detail,
          call.replayed,
          call.provider.rawValue,
        ]
      )
      return db.lastInsertedRowID
    }
    return stored
  }

  /// Stores a revision of the understanding.
  ///
  /// Revisions are inserted, never updated, so the journal keeps the trail of
  /// how the reading developed.
  @discardableResult
  public func record(_ record: UnderstandingRecord) throws -> UnderstandingRecord {
    let contentJSON = String(decoding: try encoder.encode(record.content), as: UTF8.self)
    var stored = record
    stored.id = try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO understanding (updated_at, started_at, revision, prompt_version,
              model, source, cost, cumulative_cost, content_json, covered_through_observation_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          record.updatedAt.timeIntervalSince1970,
          record.startedAt.timeIntervalSince1970,
          record.revision,
          record.promptVersion,
          record.model,
          record.source.rawValue,
          record.cost,
          record.cumulativeCost,
          contentJSON,
          record.coveredThroughObservationID,
        ]
      )
      return db.lastInsertedRowID
    }
    return stored
  }

  // MARK: Suggestions and model calls

  /// Records what the user did with a suggestion, unless what it already
  /// holds stands (`SuggestionFeedback.replaces(_:)`): a non-answer never
  /// replaces anything, and Tell me more is recorded once.
  ///
  /// The check and the write are one transaction, so feedback sent twice at
  /// once, from the toast and the History window, still keeps to the rule.
  /// Nil when the id is unknown or the feedback already there stands.
  public func updateFeedback(
    suggestionID: Int64,
    feedback: SuggestionFeedback,
    at time: Date
  ) throws -> Suggestion? {
    try db.write { db in
      guard let current = try Journal.suggestion(id: suggestionID, db),
        feedback.replaces(current.feedback)
      else { return nil }
      try db.execute(
        sql: "UPDATE suggestions SET feedback = ?, feedback_at = ? WHERE id = ?",
        arguments: [feedback.rawValue, time.timeIntervalSince1970, suggestionID]
      )
      return try Journal.suggestion(id: suggestionID, db)
    }
  }

  /// Records that a callout was drawn for the suggestion.
  ///
  /// The flag only ever turns on. Nil when the id is unknown.
  public func noteCalloutShown(suggestionID: Int64) throws -> Suggestion? {
    try db.write { db in
      try db.execute(
        sql: "UPDATE suggestions SET callout_shown = 1 WHERE id = ?",
        arguments: [suggestionID]
      )
      return try Journal.suggestion(id: suggestionID, db)
    }
  }

  // MARK: Follow-ups

  /// The exchange about one suggestion, oldest first.
  public func followUps(suggestionID: Int64) throws -> [FollowUp] {
    try db.read { db in
      try Journal.rows(
        db,
        """
        SELECT \(Journal.followUpColumns) FROM follow_ups WHERE suggestion_id = ? ORDER BY \
        timestamp ASC, id ASC
        """,
        [suggestionID],
        Journal.makeFollowUp
      )
    }
  }

  /// Newest first, across every suggestion.
  public func recentFollowUps(limit: Int) throws -> [FollowUp] {
    try db.read { db in try Journal.recentFollowUps(limit: limit, db) }
  }

  private static func recentFollowUps(limit: Int, _ db: Database) throws -> [FollowUp] {
    try rows(
      db,
      "SELECT \(followUpColumns) FROM follow_ups ORDER BY timestamp DESC, id DESC LIMIT ?",
      [limit],
      makeFollowUp
    )
  }

  /// Returns the suggestion with this id, or nil if there is none.
  public func suggestion(id: Int64) throws -> Suggestion? {
    try db.read { db in try Journal.suggestion(id: id, db) }
  }

  private static func suggestion(id: Int64, _ db: Database) throws -> Suggestion? {
    try rows(db, "SELECT \(suggestionColumns) FROM suggestions WHERE id = ?", [id], makeSuggestion)
      .first
  }

  /// Newest first.
  public func recentSuggestions(limit: Int) throws -> [Suggestion] {
    try db.read { db in try Journal.recentSuggestions(limit: limit, db) }
  }

  private static func recentSuggestions(limit: Int, _ db: Database) throws -> [Suggestion] {
    try rows(
      db,
      "SELECT \(suggestionColumns) FROM suggestions ORDER BY timestamp DESC, id DESC LIMIT ?",
      [limit],
      makeSuggestion
    )
  }

  /// Newest first.
  public func recentModelCalls(limit: Int) throws -> [ModelCallRecord] {
    try db.read { db in try Journal.recentModelCalls(limit: limit, db) }
  }

  private static func recentModelCalls(limit: Int, _ db: Database) throws -> [ModelCallRecord] {
    try rows(
      db,
      "SELECT \(modelCallColumns) FROM model_calls ORDER BY timestamp DESC, id DESC LIMIT ?",
      [limit],
      makeModelCall
    )
  }

  /// Calls at or after `since`, oldest first, for seeding the hour's spend.
  public func modelCalls(since: Date) throws -> [ModelCallRecord] {
    try db.read { db in
      try Journal.rows(
        db,
        """
        SELECT \(Journal.modelCallColumns) FROM model_calls WHERE timestamp >= ? ORDER BY \
        timestamp ASC, id ASC
        """,
        [since.timeIntervalSince1970],
        Journal.makeModelCall
      )
    }
  }

  // MARK: Live lists

  /// The newest `limit` suggestions, newest first, as `recentSuggestions(limit:)`
  /// reads them: now, and again after every change to them, for the History
  /// window.
  ///
  /// Like every live list here, it starts from what is in the journal when
  /// iteration begins and misses no write after that, so a list shown from
  /// launch has every row written since, however soon after the launch it came.
  /// A burst of writes may arrive as one fresh list, and a list the reader has
  /// not taken yet is replaced by the next.
  public nonisolated func liveSuggestions(
    limit: Int
  ) -> some AsyncSequence<[Suggestion], any Error> {
    live { db in try Journal.recentSuggestions(limit: limit, db) }
  }

  /// The newest `limit` follow-ups across every suggestion, newest first:
  /// now, and again after every change, for the History window's exchanges.
  public nonisolated func liveFollowUps(limit: Int) -> some AsyncSequence<[FollowUp], any Error> {
    live { db in try Journal.recentFollowUps(limit: limit, db) }
  }

  /// The newest `limit` model calls, newest first: now, and again after every
  /// change, for the debug panel's call log.
  public nonisolated func liveModelCalls(
    limit: Int
  ) -> some AsyncSequence<[ModelCallRecord], any Error> {
    live { db in try Journal.recentModelCalls(limit: limit, db) }
  }

  /// The newest `limit` entries of both kinds, newest first, as
  /// `recentEntries(limit:)` reads them: now, and again after every change,
  /// for the debug panel's timeline.
  ///
  /// Each fetch counts the text blocks of every observation it lists, which
  /// reads all their text, so it is for a list that is on screen.
  public nonisolated func liveEntries(limit: Int) -> some AsyncSequence<[JournalEntry], any Error> {
    live { db in try Journal.recentEntries(limit: limit, db) }
  }

  /// What `fetch` reads, fetched again after every transaction that changes
  /// a table it reads.
  ///
  /// The tables a fetch reads never depend on the rows it finds, so GRDB can
  /// fetch from a reader while the writer goes on.
  private nonisolated func live<Value: Sendable>(
    _ fetch: @escaping @Sendable (Database) throws -> Value
  ) -> some AsyncSequence<Value, any Error> {
    ValueObservation.trackingConstantRegion(fetch)
      .values(in: db, bufferingPolicy: .bufferingNewest(1))
  }

  // MARK: Understanding

  /// The current revision, or nil when none has been written or an
  /// `understanding` event, an expiry or a reset, was journaled after the
  /// latest one.
  ///
  /// Deciding expiry is the caller's job; the event it journals is what keeps
  /// an expired revision from being current again, while the revision itself
  /// stays in the trail.
  public func latestUnderstanding() throws -> UnderstandingRecord? {
    try db.read { db in
      try Journal.rows(
        db,
        """
        SELECT \(Journal.understandingColumns) FROM (
            SELECT \(Journal.understandingColumns) FROM understanding
            ORDER BY updated_at DESC, id DESC LIMIT 1
        ) AS latest
        WHERE NOT EXISTS (
            SELECT 1 FROM events WHERE kind = ? AND events.timestamp > latest.updated_at)
        """,
        [JournalEvent.Kind.understanding.rawValue],
        Journal.makeUnderstanding
      ).first
    }
  }

  /// Forgets every revision, for "Reset Understanding".
  public func clearUnderstanding() throws {
    try db.writeWithoutTransaction { db in
      try db.execute(sql: "DELETE FROM understanding")
      try db.execute(sql: "PRAGMA incremental_vacuum")
    }
  }

  /// Keeps the count toward the next understanding refresh in place of the
  /// one before it, or forgets it when `period` is nil.
  public func storeRefreshPeriod(_ period: RefreshPeriod?) throws {
    try db.write { db in
      guard let period else {
        try db.execute(sql: "DELETE FROM refresh_period")
        return
      }
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO refresh_period (id, started_at, active_use, counted_at) VALUES \
          (1, ?, ?, ?)
          """,
        arguments: [
          period.startedAt.timeIntervalSince1970,
          period.activeUse,
          period.countedAt.timeIntervalSince1970,
        ]
      )
    }
  }

  /// The count toward the next understanding refresh, or nil when none is kept.
  public func refreshPeriod() throws -> RefreshPeriod? {
    try db.read { db in
      try Journal.rows(db, "SELECT started_at, active_use, counted_at FROM refresh_period") {
        row in
        RefreshPeriod(
          startedAt: Date(timeIntervalSince1970: row[0]),
          activeUse: row[1],
          countedAt: Date(timeIntervalSince1970: row[2])
        )
      }.first
    }
  }

  // MARK: Reads

  /// The latest time anything in the journal is stamped with, or nil when
  /// it holds nothing.
  public func newestTimestamp() throws -> Date? {
    try db.read { db in
      try Double.fetchOne(
        db,
        sql: """
          SELECT MAX(newest) FROM (
              SELECT MAX(timestamp) AS newest FROM observations
              UNION ALL SELECT MAX(timestamp) FROM events
              UNION ALL SELECT MAX(MAX(timestamp), COALESCE(MAX(feedback_at), 0)) FROM suggestions
              UNION ALL SELECT MAX(timestamp) FROM follow_ups
              UNION ALL SELECT MAX(timestamp) FROM model_calls
              UNION ALL SELECT MAX(updated_at) FROM understanding
              UNION ALL SELECT MAX(counted_at) FROM refresh_period
          )
          """
      ).map(Date.init(timeIntervalSince1970:))
    }
  }

  /// The newest `limit` observations at or after `since` or with an id above
  /// `cursor`, newest first, without thumbnail bytes.
  ///
  /// A nil bound matches nothing on its own.
  public func recentObservations(
    since: Date?,
    after cursor: Int64? = nil,
    limit: Int
  ) throws -> [ActivityObservation] {
    try db.read { db in
      try Journal.rows(
        db,
        """
        SELECT \(Journal.observationColumns) FROM observations WHERE timestamp >= ? OR id > ? \
        ORDER BY timestamp DESC, id DESC LIMIT ?
        """,
        [since?.timeIntervalSince1970, cursor, limit],
        Journal.makeObservation
      )
    }
  }

  /// Newest first, without thumbnail bytes.
  public func recentObservations(limit: Int) throws -> [ActivityObservation] {
    try db.read { db in try Journal.recentObservations(limit: limit, db) }
  }

  private static func recentObservations(
    limit: Int,
    _ db: Database
  ) throws -> [ActivityObservation] {
    try rows(
      db,
      "SELECT \(observationColumns) FROM observations ORDER BY timestamp DESC, id DESC LIMIT ?",
      [limit],
      makeObservation
    )
  }

  /// How many observations are at or after `since` or have an id above
  /// `cursor`, so a capped read can say how many it left unread.
  public func observationCount(since: Date?, after cursor: Int64?) throws -> Int {
    try db.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM observations WHERE timestamp >= ? OR id > ?",
        arguments: [since?.timeIntervalSince1970, cursor]
      ) ?? 0
    }
  }

  /// The newest `limit` entries of both kinds, newest first, each observation
  /// as its summary.
  public func recentEntries(limit: Int) throws -> [JournalEntry] {
    try db.read { db in try Journal.recentEntries(limit: limit, db) }
  }

  private static func recentEntries(limit: Int, _ db: Database) throws -> [JournalEntry] {
    // SQLite counts the blocks, so no observation's text is decoded here.
    let observations = try rows(
      db,
      """
      SELECT id, timestamp, app_name, window_title, reason, json_array_length(text_blocks_json)
      FROM observations ORDER BY timestamp DESC, id DESC LIMIT ?
      """,
      [limit]
    ) { row in
      JournalEntry.observation(
        ObservationSummary(
          id: row[0],
          timestamp: Date(timeIntervalSince1970: row[1]),
          appName: row[2],
          windowTitle: row[3],
          reason: CaptureReason(rawValue: row[4]) ?? .floor,
          textBlockCount: row[5]
        )
      )
    }
    let events = try recentEvents(limit: limit, db).map(JournalEntry.event)
    return Array((observations + events).sorted(by: JournalEntry.newerFirst).prefix(limit))
  }

  /// Returns the newest `limit` events, newest first.
  public func recentEvents(limit: Int) throws -> [JournalEvent] {
    try db.read { db in try Journal.recentEvents(limit: limit, db) }
  }

  private static func recentEvents(limit: Int, _ db: Database) throws -> [JournalEvent] {
    try rows(
      db,
      """
      SELECT id, timestamp, kind, bundle_id, app_name, detail FROM events ORDER BY timestamp \
      DESC, id DESC LIMIT ?
      """,
      [limit]
    ) { row in
      JournalEvent(
        id: row[0],
        timestamp: Date(timeIntervalSince1970: row[1]),
        kind: JournalEvent.Kind(rawValue: row[2]) ?? .started,
        bundleID: row[3],
        appName: row[4],
        detail: row[5]
      )
    }
  }

  /// Observations at or after `since`, oldest first, without thumbnail bytes.
  public func observations(since: Date, limit: Int) throws -> [ActivityObservation] {
    try db.read { db in
      try Journal.rows(
        db,
        """
        SELECT \(Journal.observationColumns) FROM observations WHERE timestamp >= ? ORDER BY \
        timestamp ASC, id ASC LIMIT ?
        """,
        [since.timeIntervalSince1970, limit],
        Journal.makeObservation
      )
    }
  }

  /// Returns the observation with this id, without thumbnail bytes, or nil if
  /// there is none.
  public func observation(id: Int64) throws -> ActivityObservation? {
    try db.read { db in
      try Journal.rows(
        db,
        "SELECT \(Journal.observationColumns) FROM observations WHERE id = ?",
        [id],
        Journal.makeObservation
      ).first
    }
  }

  /// Returns the JPEG thumbnail stored with an observation.
  ///
  /// Nil when the observation had no thumbnail or retention has deleted it.
  public func thumbnail(observationID: Int64) throws -> Data? {
    try db.read { db in
      try Data.fetchOne(
        db,
        sql: "SELECT jpeg FROM thumbnails WHERE observation_id = ?",
        arguments: [observationID]
      )
    }
  }

  /// Returns every row of `sql`, a query that changes nothing, each column as text.
  ///
  /// It is how the control API answers the end-to-end harness's named journal
  /// queries from the app's own connection (docs/e2e.md "The control API"). Each
  /// column is the text SQLite gives it and a NULL is empty text, as the
  /// `sqlite3` tool prints them. A statement that would write is refused
  /// before it runs.
  public func readOnlyRows(_ sql: String) throws -> [[String]] {
    try db.read { db in
      let statement = try db.makeStatement(sql: sql)
      guard statement.isReadonly else {
        throw DatabaseError(
          resultCode: .SQLITE_READONLY,
          message: "only a statement that changes nothing is run here"
        )
      }
      let columns = statement.columnCount
      return try Journal.rows(statement) { row in
        (0..<columns).map { (row[$0] as String?) ?? "" }
      }
    }
  }

  /// Returns the journal's counts, size, and time span, for Settings and the
  /// debug panel.
  public func stats() throws -> JournalStats {
    try db.read { db in
      let count = { (table: String) in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
      }
      let bounds = try Row.fetchOne(
        db,
        sql: """
          SELECT MIN(t), MAX(t) FROM (
              SELECT timestamp AS t FROM observations UNION ALL SELECT timestamp FROM events
          )
          """
      )
      let oldest: Double? = bounds?[0]
      let newest: Double? = bounds?[1]
      return JournalStats(
        observationCount: try count("observations"),
        thumbnailCount: try count("thumbnails"),
        eventCount: try count("events"),
        usedBytes: try Journal.usedBytes(db),
        oldest: oldest.map(Date.init(timeIntervalSince1970:)),
        newest: newest.map(Date.init(timeIntervalSince1970:))
      )
    }
  }

  /// Bytes in use by live pages (free pages are reclaimed by incremental vacuum).
  public func usedBytes() throws -> Int64 {
    try db.read(Journal.usedBytes)
  }

  private static func usedBytes(_ db: Database) throws -> Int64 {
    let pragma = { (name: String) in try Int64.fetchOne(db, sql: "PRAGMA \(name)") ?? 0 }
    return try (pragma("page_count") - pragma("freelist_count")) * pragma("page_size")
  }

  // MARK: Maintenance

  /// Deletes everything and records a single `journalCleared` event at `now`.
  public func clear(at now: Date) throws {
    try db.writeWithoutTransaction { db in
      try db.inTransaction {
        try db.execute(
          sql: """
            DELETE FROM thumbnails; DELETE FROM observations; DELETE FROM events;
            DELETE FROM suggestions; DELETE FROM follow_ups; DELETE FROM model_calls;
            DELETE FROM understanding; DELETE FROM refresh_period;
            """
        )
        return .commit
      }
      try db.execute(sql: "PRAGMA incremental_vacuum")
      try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
      _ = try Journal.insert(JournalEvent(timestamp: now, kind: .journalCleared), db)
    }
  }

  /// Applies age limits, then the size cap.
  ///
  /// Returns what was removed.
  public func applyRetention(_ policy: RetentionPolicy, now: Date) throws -> RetentionResult {
    try db.writeWithoutTransaction { db in
      try Journal.applyRetention(policy, now: now, db)
    }
  }

  private static func applyRetention(
    _ policy: RetentionPolicy,
    now: Date,
    _ db: Database
  ) throws -> RetentionResult {
    var result = RetentionResult(bytesBefore: try usedBytes(db))
    /// Runs a statement and returns how many rows it changed.
    let run = { (sql: String, arguments: StatementArguments) -> Int in
      try db.execute(sql: sql, arguments: arguments)
      return db.changesCount
    }

    let thumbnailCutoff = policy.thumbnailCutoff(now: now).timeIntervalSince1970
    result.thumbnailsDeleted += try run(
      "DELETE FROM thumbnails WHERE timestamp < ?",
      [thumbnailCutoff]
    )

    let textCutoff = policy.textCutoff(now: now).timeIntervalSince1970
    result.observationsDeleted += try run(
      "DELETE FROM observations WHERE timestamp < ?",
      [textCutoff]
    )
    result.eventsDeleted += try run("DELETE FROM events WHERE timestamp < ?", [textCutoff])
    result.suggestionsDeleted += try run(
      "DELETE FROM suggestions WHERE timestamp < ?",
      [textCutoff]
    )
    result.followUpsDeleted += try run("DELETE FROM follow_ups WHERE timestamp < ?", [textCutoff])
    result.modelCallsDeleted += try run(
      "DELETE FROM model_calls WHERE timestamp < ?",
      [textCutoff]
    )
    result.understandingDeleted += try run(
      "DELETE FROM understanding WHERE updated_at < ?",
      [textCutoff]
    )
    _ = try run("DELETE FROM refresh_period WHERE started_at < ?", [textCutoff])

    try db.execute(sql: "PRAGMA incremental_vacuum")
    var used = try usedBytes(db)
    if used > policy.sizeCapBytes {
      // Oldest thumbnails first, in batches, until under the target.
      while used > policy.sizeTargetBytes {
        let removed = try run(
          """
          DELETE FROM thumbnails WHERE observation_id IN (
              SELECT observation_id FROM thumbnails ORDER BY timestamp ASC LIMIT 10
          )
          """,
          []
        )
        result.thumbnailsDeleted += removed
        if removed == 0 { break }
        try db.execute(sql: "PRAGMA incremental_vacuum")
        used = try usedBytes(db)
      }
      // Then the oldest observations, events, and understanding together.
      while used > policy.sizeTargetBytes {
        let span = try Row.fetchOne(
          db,
          sql: """
            SELECT MIN(t), MAX(t) FROM (
                SELECT timestamp AS t FROM observations UNION ALL SELECT timestamp FROM events
            )
            """
        )
        guard let oldest = span?[0] as Double? else { break }
        let newest = span?[1] as Double? ?? oldest
        // Drop the oldest tenth of the remaining time span, at least one row.
        let cutoff = oldest + max(1, (newest - oldest) / 10)
        let observationsRemoved = try run(
          "DELETE FROM observations WHERE timestamp <= ?",
          [cutoff]
        )
        let eventsRemoved = try run("DELETE FROM events WHERE timestamp <= ?", [cutoff])
        result.understandingDeleted += try run(
          "DELETE FROM understanding WHERE updated_at <= ?",
          [cutoff]
        )
        _ = try run("DELETE FROM refresh_period WHERE started_at <= ?", [cutoff])
        result.observationsDeleted += observationsRemoved
        result.eventsDeleted += eventsRemoved
        if observationsRemoved + eventsRemoved == 0 { break }
        try db.execute(sql: "PRAGMA incremental_vacuum")
        used = try usedBytes(db)
      }
    }
    try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
    result.bytesAfter = try usedBytes(db)
    return result
  }

  // MARK: Row mapping

  /// Maps every row `sql` returns, each while the statement is still on it,
  /// so a column reads as SQLite's own conversion of it.
  private static func rows<T>(
    _ db: Database,
    _ sql: String,
    _ arguments: StatementArguments = StatementArguments(),
    _ map: (Row) throws -> T
  ) throws -> [T] {
    try rows(try db.cachedStatement(sql: sql), arguments, map)
  }

  private static func rows<T>(
    _ statement: Statement,
    _ arguments: StatementArguments = StatementArguments(),
    _ map: (Row) throws -> T
  ) throws -> [T] {
    let cursor = try Row.fetchCursor(statement, arguments: arguments)
    var mapped: [T] = []
    while let row = try cursor.next() { mapped.append(try map(row)) }
    return mapped
  }

  /// Decodes the JSON columns, which Swift concurrency lets every fetch share.
  private static let decoder = JSONDecoder()

  private static let observationColumns = """
    id, timestamp, focus_json, text_blocks_json, frame_hash, frame_width, frame_height, display_id,
    screen_x, screen_y, screen_w, screen_h, reason
    """

  private static let suggestionColumns = """
    id, timestamp, bundle_id, app_name, window_title, category, title, body, explanation, \
    confidence,
    judged_goal, observation_id, model, prompt_version, feedback, feedback_at, region_json, \
    callout_shown
    """

  private static let followUpColumns = """
    id, suggestion_id, timestamp, question, answer, error, model, prompt_version
    """

  private static func makeFollowUp(from row: Row) -> FollowUp {
    FollowUp(
      id: row[0],
      suggestionID: row[1],
      timestamp: Date(timeIntervalSince1970: row[2]),
      question: row[3],
      answer: row[4],
      error: row[5],
      model: row[6],
      promptVersion: row[7]
    )
  }

  private static func makeSuggestion(from row: Row) -> Suggestion {
    let region = (row[16] as String?).flatMap {
      try? decoder.decode(CalloutRegion.self, from: Data($0.utf8))
    }
    let feedbackAt: Double? = row[15]
    return Suggestion(
      id: row[0],
      timestamp: Date(timeIntervalSince1970: row[1]),
      bundleID: row[2],
      appName: row[3],
      windowTitle: row[4],
      category: SuggestionCategory(rawValue: row[5]) ?? .other,
      title: row[6],
      body: row[7],
      explanation: row[8],
      confidence: row[9],
      judgedGoal: row[10],
      observationID: row[11],
      model: row[12],
      promptVersion: row[13],
      feedback: (row[14] as String?).flatMap(SuggestionFeedback.init(rawValue:)),
      feedbackAt: feedbackAt.map(Date.init(timeIntervalSince1970:)),
      region: region,
      calloutShown: row[17]
    )
  }

  private static let modelCallColumns = """
    id, timestamp, tier, model, prompt_version, prompt_chars, image_bytes, input_tokens, \
    output_tokens,
    cache_write_tokens, cache_read_tokens, cost, latency, outcome, detail, replayed, provider
    """

  private static func makeModelCall(from row: Row) -> ModelCallRecord {
    ModelCallRecord(
      id: row[0],
      timestamp: Date(timeIntervalSince1970: row[1]),
      tier: ModelTier(rawValue: row[2]) ?? .triage,
      model: row[3],
      promptVersion: row[4],
      promptCharacters: row[5],
      imageBytes: row[6],
      usage: Usage(
        inputTokens: row[7],
        outputTokens: row[8],
        cacheCreationInputTokens: row[9],
        cacheReadInputTokens: row[10]
      ),
      cost: row[11],
      latency: row[12],
      outcome: ModelCallOutcome(rawValue: row[13]) ?? .error,
      detail: row[14],
      replayed: row[15],
      provider: ModelProvider(rawValue: row[16] ?? "") ?? .anthropic
    )
  }

  private static let understandingColumns = """
    id, updated_at, started_at, revision, prompt_version, model, source, cost,
    cumulative_cost, content_json, covered_through_observation_id
    """

  private static func makeUnderstanding(from row: Row) throws -> UnderstandingRecord {
    UnderstandingRecord(
      id: row[0],
      updatedAt: Date(timeIntervalSince1970: row[1]),
      startedAt: Date(timeIntervalSince1970: row[2]),
      revision: row[3],
      promptVersion: row[4],
      model: row[5],
      source: UnderstandingSource(rawValue: row[6]) ?? .periodic,
      cost: row[7],
      cumulativeCost: row[8],
      content: try decoder.decode(Understanding.self, from: Data((row[9] as String).utf8)),
      coveredThroughObservationID: row[10]
    )
  }

  private static func makeObservation(from row: Row) throws -> ActivityObservation {
    let focus = try decoder.decode(FocusContext.self, from: Data((row[2] as String).utf8))
    let blocks = try decoder.decode([TextBlock].self, from: Data((row[3] as String).utf8))
    let hash = PerceptualHash(hexString: row[4]) ?? PerceptualHash(words: [0, 0, 0, 0])
    let displayID: Int64 = row[7]
    let frame = FrameInfo(
      hash: hash,
      width: row[5],
      height: row[6],
      displayID: UInt32(truncatingIfNeeded: displayID),
      screenRect: CGRect(x: row[8] as Double, y: row[9], width: row[10], height: row[11]),
      jpeg: nil
    )
    return ActivityObservation(
      id: row[0],
      timestamp: Date(timeIntervalSince1970: row[1]),
      focus: focus,
      frame: frame,
      textBlocks: blocks,
      reason: CaptureReason(rawValue: row[12]) ?? .floor
    )
  }
}
