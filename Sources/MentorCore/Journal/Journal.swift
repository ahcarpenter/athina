import Foundation

public struct JournalStats: Equatable, Sendable {
    public var observationCount: Int
    public var thumbnailCount: Int
    public var eventCount: Int
    public var usedBytes: Int64
    public var oldest: Date?
    public var newest: Date?

    public init(observationCount: Int = 0, thumbnailCount: Int = 0, eventCount: Int = 0, usedBytes: Int64 = 0, oldest: Date? = nil, newest: Date? = nil) {
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
public actor Journal {
    public nonisolated let url: URL
    private let db: SQLiteConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// `~/Library/Application Support/mentor/journal.sqlite`, or the same file
    /// in another data directory (see `AppPaths.dataDirectory(for:)`).
    public static func defaultURL(in directory: URL = AppPaths.supportDirectory()) -> URL {
        directory.appendingPathComponent("journal.sqlite")
    }

    /// Opens (creating if needed) the journal file at `url`.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.url = url
        db = try SQLiteConnection(path: url.path)
        try Journal.migrate(db)
    }

    /// A private in-memory journal, for tests.
    public static func inMemory() throws -> Journal {
        try Journal(memoryOnly: ())
    }

    private init(memoryOnly: Void) throws {
        url = URL(string: "sqlite:memory")!
        db = try SQLiteConnection(path: ":memory:")
        try Journal.migrate(db)
    }

    private static func migrate(_ db: SQLiteConnection) throws {
        // auto_vacuum must be set before any table exists to take effect on a new file.
        try db.execute("PRAGMA auto_vacuum = INCREMENTAL")
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("""
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
                observation_id INTEGER,
                model TEXT NOT NULL,
                prompt_version INTEGER NOT NULL,
                feedback TEXT,
                feedback_at REAL
            );
            CREATE INDEX IF NOT EXISTS suggestions_timestamp ON suggestions(timestamp);
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
            """)
        // Columns added after a table shipped: CREATE TABLE IF NOT EXISTS leaves
        // an existing journal's table alone, so add them here instead.
        try addColumn("replayed INTEGER NOT NULL DEFAULT 0", named: "replayed", to: "model_calls", db)
    }

    /// Adds a column to an existing table, once. Nothing happens when the table
    /// was created with it already.
    private static func addColumn(_ definition: String, named name: String, to table: String, _ db: SQLiteConnection) throws {
        let existing = try db.query("PRAGMA table_info(\(table))") { $0.text(1) }
        guard !existing.contains(name) else { return }
        try db.execute("ALTER TABLE \(table) ADD COLUMN \(definition)")
    }

    // MARK: Writes

    /// Stores the observation and its thumbnail. Returns the observation with its new id.
    @discardableResult
    public func record(_ observation: ActivityObservation) throws -> ActivityObservation {
        let focusJSON = String(decoding: try encoder.encode(observation.focus), as: UTF8.self)
        let blocksJSON = String(decoding: try encoder.encode(observation.textBlocks), as: UTF8.self)
        let f = observation.frame
        try db.execute("BEGIN")
        do {
            try db.run("""
                INSERT INTO observations (timestamp, bundle_id, app_name, window_title, ax_summary, focus_json,
                    ocr_text, text_blocks_json, frame_hash, frame_width, frame_height, display_id,
                    screen_x, screen_y, screen_w, screen_h, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .double(observation.timestamp.timeIntervalSince1970),
                    observation.focus.bundleID.map(Value.text) ?? .null,
                    .text(observation.focus.appName),
                    observation.focus.windowTitle.map(Value.text) ?? .null,
                    .text(observation.focus.summary),
                    .text(focusJSON),
                    .text(observation.ocrText),
                    .text(blocksJSON),
                    .text(f.hash.hexString),
                    .int(Int64(f.width)), .int(Int64(f.height)), .int(Int64(f.displayID)),
                    .double(f.screenRect.origin.x), .double(f.screenRect.origin.y),
                    .double(f.screenRect.width), .double(f.screenRect.height),
                    .text(observation.reason.rawValue),
                ])
            let id = db.lastInsertRowID
            if let jpeg = f.jpeg {
                try db.run(
                    "INSERT INTO thumbnails (observation_id, timestamp, jpeg) VALUES (?, ?, ?)",
                    [.int(id), .double(observation.timestamp.timeIntervalSince1970), .blob(jpeg)]
                )
            }
            try db.execute("COMMIT")
            var stored = observation
            stored.id = id
            return stored
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    public func record(_ event: JournalEvent) throws -> JournalEvent {
        try db.run(
            "INSERT INTO events (timestamp, kind, bundle_id, app_name, detail) VALUES (?, ?, ?, ?, ?)",
            [
                .double(event.timestamp.timeIntervalSince1970),
                .text(event.kind.rawValue),
                event.bundleID.map(Value.text) ?? .null,
                event.appName.map(Value.text) ?? .null,
                event.detail.map(Value.text) ?? .null,
            ]
        )
        var stored = event
        stored.id = db.lastInsertRowID
        return stored
    }

    // MARK: Suggestions and model calls

    /// Stores a shown suggestion. Returns it with its new id.
    @discardableResult
    public func record(_ suggestion: Suggestion) throws -> Suggestion {
        try db.run("""
            INSERT INTO suggestions (timestamp, bundle_id, app_name, window_title, category, title, body, explanation,
                confidence, observation_id, model, prompt_version, feedback, feedback_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .double(suggestion.timestamp.timeIntervalSince1970),
                suggestion.bundleID.map(Value.text) ?? .null,
                .text(suggestion.appName),
                suggestion.windowTitle.map(Value.text) ?? .null,
                .text(suggestion.category.rawValue),
                .text(suggestion.title),
                .text(suggestion.body),
                .text(suggestion.explanation),
                .double(suggestion.confidence),
                suggestion.observationID.map(Value.int) ?? .null,
                .text(suggestion.model),
                .int(Int64(suggestion.promptVersion)),
                suggestion.feedback.map { Value.text($0.rawValue) } ?? .null,
                suggestion.feedbackAt.map { Value.double($0.timeIntervalSince1970) } ?? .null,
            ])
        var stored = suggestion
        stored.id = db.lastInsertRowID
        return stored
    }

    /// Records what the user did with a suggestion. Nil when the id is unknown.
    public func updateFeedback(suggestionID: Int64, feedback: SuggestionFeedback, at time: Date) throws -> Suggestion? {
        try db.run(
            "UPDATE suggestions SET feedback = ?, feedback_at = ? WHERE id = ?",
            [.text(feedback.rawValue), .double(time.timeIntervalSince1970), .int(suggestionID)]
        )
        return try suggestion(id: suggestionID)
    }

    public func suggestion(id: Int64) throws -> Suggestion? {
        try db.query("SELECT \(Journal.suggestionColumns) FROM suggestions WHERE id = ?", [.int(id)]) {
            Journal.suggestion(from: $0)
        }.first
    }

    /// Newest first.
    public func recentSuggestions(limit: Int) throws -> [Suggestion] {
        try db.query(
            "SELECT \(Journal.suggestionColumns) FROM suggestions ORDER BY timestamp DESC, id DESC LIMIT ?",
            [.int(Int64(limit))]
        ) { Journal.suggestion(from: $0) }
    }

    @discardableResult
    public func record(_ call: ModelCallRecord) throws -> ModelCallRecord {
        try db.run("""
            INSERT INTO model_calls (timestamp, tier, model, prompt_version, prompt_chars, image_bytes, input_tokens,
                output_tokens, cache_write_tokens, cache_read_tokens, cost, latency, outcome, detail, replayed)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .double(call.timestamp.timeIntervalSince1970),
                .text(call.tier.rawValue),
                .text(call.model),
                .int(Int64(call.promptVersion)),
                .int(Int64(call.promptCharacters)),
                .int(Int64(call.imageBytes)),
                .int(Int64(call.usage.inputTokens)),
                .int(Int64(call.usage.outputTokens)),
                .int(Int64(call.usage.cacheCreationInputTokens)),
                .int(Int64(call.usage.cacheReadInputTokens)),
                .double(call.cost),
                .double(call.latency),
                .text(call.outcome.rawValue),
                call.detail.map(Value.text) ?? .null,
                .int(call.replayed ? 1 : 0),
            ])
        var stored = call
        stored.id = db.lastInsertRowID
        return stored
    }

    /// Newest first.
    public func recentModelCalls(limit: Int) throws -> [ModelCallRecord] {
        try db.query(
            "SELECT \(Journal.modelCallColumns) FROM model_calls ORDER BY timestamp DESC, id DESC LIMIT ?",
            [.int(Int64(limit))]
        ) { Journal.modelCall(from: $0) }
    }

    /// Calls at or after `since`, oldest first, for seeding the hour's spend.
    public func modelCalls(since: Date) throws -> [ModelCallRecord] {
        try db.query(
            "SELECT \(Journal.modelCallColumns) FROM model_calls WHERE timestamp >= ? ORDER BY timestamp ASC, id ASC",
            [.double(since.timeIntervalSince1970)]
        ) { Journal.modelCall(from: $0) }
    }

    // MARK: Reads

    /// The newest `limit` observations at or after `since`, newest first, without thumbnail bytes.
    public func recentObservations(since: Date, limit: Int) throws -> [ActivityObservation] {
        try db.query(
            "SELECT \(Journal.observationColumns) FROM observations WHERE timestamp >= ? ORDER BY timestamp DESC, id DESC LIMIT ?",
            [.double(since.timeIntervalSince1970), .int(Int64(limit))]
        ) { try self.observation(from: $0) }
    }

    /// The newest `limit` entries of both kinds, newest first, without thumbnail bytes.
    public func recentEntries(limit: Int) throws -> [JournalEntry] {
        let observations = try recentObservations(limit: limit).map(JournalEntry.observation)
        let events = try recentEvents(limit: limit).map(JournalEntry.event)
        return Array((observations + events).sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    /// Newest first, without thumbnail bytes.
    public func recentObservations(limit: Int) throws -> [ActivityObservation] {
        try db.query(
            "SELECT \(Journal.observationColumns) FROM observations ORDER BY timestamp DESC, id DESC LIMIT ?",
            [.int(Int64(limit))]
        ) { try self.observation(from: $0) }
    }

    public func recentEvents(limit: Int) throws -> [JournalEvent] {
        try db.query(
            "SELECT id, timestamp, kind, bundle_id, app_name, detail FROM events ORDER BY timestamp DESC, id DESC LIMIT ?",
            [.int(Int64(limit))]
        ) { row in
            JournalEvent(
                id: row.int(0),
                timestamp: Date(timeIntervalSince1970: row.double(1)),
                kind: JournalEvent.Kind(rawValue: row.text(2) ?? "") ?? .started,
                bundleID: row.text(3),
                appName: row.text(4),
                detail: row.text(5)
            )
        }
    }

    /// Observations at or after `since`, oldest first, without thumbnail bytes.
    public func observations(since: Date, limit: Int) throws -> [ActivityObservation] {
        try db.query(
            "SELECT \(Journal.observationColumns) FROM observations WHERE timestamp >= ? ORDER BY timestamp ASC, id ASC LIMIT ?",
            [.double(since.timeIntervalSince1970), .int(Int64(limit))]
        ) { try self.observation(from: $0) }
    }

    public func observation(id: Int64) throws -> ActivityObservation? {
        try db.query(
            "SELECT \(Journal.observationColumns) FROM observations WHERE id = ?", [.int(id)]
        ) { try self.observation(from: $0) }.first
    }

    public func thumbnail(observationID: Int64) throws -> Data? {
        try db.query("SELECT jpeg FROM thumbnails WHERE observation_id = ?", [.int(observationID)]) { $0.blob(0) }
            .first ?? nil
    }

    public func stats() throws -> JournalStats {
        let observationCount = try db.scalarInt("SELECT COUNT(*) FROM observations")
        let thumbnailCount = try db.scalarInt("SELECT COUNT(*) FROM thumbnails")
        let eventCount = try db.scalarInt("SELECT COUNT(*) FROM events")
        let bounds = try db.query("""
            SELECT MIN(t), MAX(t) FROM (
                SELECT timestamp AS t FROM observations UNION ALL SELECT timestamp FROM events
            )
            """) { row -> (Date?, Date?) in
            (row.isNull(0) ? nil : Date(timeIntervalSince1970: row.double(0)),
             row.isNull(1) ? nil : Date(timeIntervalSince1970: row.double(1)))
        }.first ?? (nil, nil)
        return JournalStats(
            observationCount: Int(observationCount),
            thumbnailCount: Int(thumbnailCount),
            eventCount: Int(eventCount),
            usedBytes: try usedBytes(),
            oldest: bounds.0,
            newest: bounds.1
        )
    }

    /// Bytes in use by live pages (free pages are reclaimed by incremental vacuum).
    public func usedBytes() throws -> Int64 {
        let pageSize = try db.scalarInt("PRAGMA page_size")
        let pageCount = try db.scalarInt("PRAGMA page_count")
        let freelist = try db.scalarInt("PRAGMA freelist_count")
        return (pageCount - freelist) * pageSize
    }

    // MARK: Maintenance

    /// Deletes everything and records a single `journalCleared` event.
    public func clear() throws {
        try db.execute("BEGIN")
        do {
            try db.execute("DELETE FROM thumbnails; DELETE FROM observations; DELETE FROM events; DELETE FROM suggestions; DELETE FROM model_calls;")
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try db.execute("PRAGMA incremental_vacuum")
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try record(JournalEvent(kind: .journalCleared))
    }

    /// Applies age limits, then the size cap. Returns what was removed.
    public func applyRetention(_ policy: RetentionPolicy, now: Date = Date()) throws -> RetentionResult {
        var result = RetentionResult(bytesBefore: try usedBytes())

        let thumbnailCutoff = policy.thumbnailCutoff(now: now).timeIntervalSince1970
        try db.run("DELETE FROM thumbnails WHERE timestamp < ?", [.double(thumbnailCutoff)])
        result.thumbnailsDeleted += db.changes

        let textCutoff = policy.textCutoff(now: now).timeIntervalSince1970
        try db.run("DELETE FROM observations WHERE timestamp < ?", [.double(textCutoff)])
        result.observationsDeleted += db.changes
        try db.run("DELETE FROM events WHERE timestamp < ?", [.double(textCutoff)])
        result.eventsDeleted += db.changes
        try db.run("DELETE FROM suggestions WHERE timestamp < ?", [.double(textCutoff)])
        result.suggestionsDeleted += db.changes
        try db.run("DELETE FROM model_calls WHERE timestamp < ?", [.double(textCutoff)])
        result.modelCallsDeleted += db.changes

        try db.execute("PRAGMA incremental_vacuum")
        var used = try usedBytes()
        if used > policy.sizeCapBytes {
            // Oldest thumbnails first, in batches, until under the target.
            while used > policy.sizeTargetBytes {
                try db.run("""
                    DELETE FROM thumbnails WHERE observation_id IN (
                        SELECT observation_id FROM thumbnails ORDER BY timestamp ASC LIMIT 10
                    )
                    """)
                let removed = db.changes
                result.thumbnailsDeleted += removed
                if removed == 0 { break }
                try db.execute("PRAGMA incremental_vacuum")
                used = try usedBytes()
            }
            // Then the oldest observations and events together.
            while used > policy.sizeTargetBytes {
                let oldest = try db.query("""
                    SELECT MIN(t) FROM (
                        SELECT timestamp AS t FROM observations UNION ALL SELECT timestamp FROM events
                    )
                    """) { $0.isNull(0) ? nil : $0.double(0) }.first ?? nil
                guard let oldest else { break }
                let newest = try db.query("""
                    SELECT MAX(t) FROM (
                        SELECT timestamp AS t FROM observations UNION ALL SELECT timestamp FROM events
                    )
                    """) { $0.double(0) }.first ?? oldest
                // Drop the oldest tenth of the remaining time span, at least one row.
                let cutoff = oldest + max(1, (newest - oldest) / 10)
                try db.run("DELETE FROM observations WHERE timestamp <= ?", [.double(cutoff)])
                let observationsRemoved = db.changes
                try db.run("DELETE FROM events WHERE timestamp <= ?", [.double(cutoff)])
                let eventsRemoved = db.changes
                result.observationsDeleted += observationsRemoved
                result.eventsDeleted += eventsRemoved
                if observationsRemoved + eventsRemoved == 0 { break }
                try db.execute("PRAGMA incremental_vacuum")
                used = try usedBytes()
            }
        }
        try db.execute("PRAGMA wal_checkpoint(PASSIVE)")
        result.bytesAfter = try usedBytes()
        return result
    }

    // MARK: Row mapping

    private typealias Value = SQLiteConnection.Value

    private static let observationColumns = """
        id, timestamp, focus_json, text_blocks_json, frame_hash, frame_width, frame_height, display_id,
        screen_x, screen_y, screen_w, screen_h, reason
        """

    private static let suggestionColumns = """
        id, timestamp, bundle_id, app_name, window_title, category, title, body, explanation, confidence,
        observation_id, model, prompt_version, feedback, feedback_at
        """

    private static func suggestion(from row: SQLiteConnection.Statement) -> Suggestion {
        Suggestion(
            id: row.int(0),
            timestamp: Date(timeIntervalSince1970: row.double(1)),
            bundleID: row.text(2),
            appName: row.text(3) ?? "",
            windowTitle: row.text(4),
            category: SuggestionCategory(rawValue: row.text(5) ?? "") ?? .other,
            title: row.text(6) ?? "",
            body: row.text(7) ?? "",
            explanation: row.text(8) ?? "",
            confidence: row.double(9),
            observationID: row.isNull(10) ? nil : row.int(10),
            model: row.text(11) ?? "",
            promptVersion: Int(row.int(12)),
            feedback: row.text(13).flatMap(SuggestionFeedback.init(rawValue:)),
            feedbackAt: row.isNull(14) ? nil : Date(timeIntervalSince1970: row.double(14))
        )
    }

    private static let modelCallColumns = """
        id, timestamp, tier, model, prompt_version, prompt_chars, image_bytes, input_tokens, output_tokens,
        cache_write_tokens, cache_read_tokens, cost, latency, outcome, detail, replayed
        """

    private static func modelCall(from row: SQLiteConnection.Statement) -> ModelCallRecord {
        ModelCallRecord(
            id: row.int(0),
            timestamp: Date(timeIntervalSince1970: row.double(1)),
            tier: ModelTier(rawValue: row.text(2) ?? "") ?? .triage,
            model: row.text(3) ?? "",
            promptVersion: Int(row.int(4)),
            promptCharacters: Int(row.int(5)),
            imageBytes: Int(row.int(6)),
            usage: Usage(
                inputTokens: Int(row.int(7)),
                outputTokens: Int(row.int(8)),
                cacheCreationInputTokens: Int(row.int(9)),
                cacheReadInputTokens: Int(row.int(10))
            ),
            cost: row.double(11),
            latency: row.double(12),
            outcome: ModelCallOutcome(rawValue: row.text(13) ?? "") ?? .error,
            detail: row.text(14),
            replayed: row.int(15) != 0
        )
    }

    private func observation(from row: SQLiteConnection.Statement) throws -> ActivityObservation {
        let focus = try decoder.decode(FocusContext.self, from: Data((row.text(2) ?? "{}").utf8))
        let blocks = try decoder.decode([TextBlock].self, from: Data((row.text(3) ?? "[]").utf8))
        let hash = PerceptualHash(hexString: row.text(4) ?? "") ?? PerceptualHash(words: [0, 0, 0, 0])
        let frame = FrameInfo(
            hash: hash,
            width: Int(row.int(5)),
            height: Int(row.int(6)),
            displayID: UInt32(truncatingIfNeeded: row.int(7)),
            screenRect: CGRect(x: row.double(8), y: row.double(9), width: row.double(10), height: row.double(11)),
            jpeg: nil
        )
        return ActivityObservation(
            id: row.int(0),
            timestamp: Date(timeIntervalSince1970: row.double(1)),
            focus: focus,
            frame: frame,
            textBlocks: blocks,
            reason: CaptureReason(rawValue: row.text(12) ?? "") ?? .floor
        )
    }
}
