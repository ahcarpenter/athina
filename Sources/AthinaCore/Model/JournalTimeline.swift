import Foundation

/// The debug panel's timeline: journal rows newest first, each shown once.
///
/// Rows reach it two ways that overlap. The live stream carries every row the
/// moment it is journaled, and a load reads the newest rows back from the
/// journal. At launch sensing journals its first events before the load runs,
/// so the load and the stream both carry them, in either order and with more
/// arriving while the load is still reading. Rows are therefore merged by
/// their journal id rather than appended, and kept in one order however they
/// arrived.
///
/// The journal gives a new row the id of one it has deleted once a table
/// empties, after a clear or when retention removes every row. What arrives is
/// never older than what is held, so a row under an id already here takes the
/// place of the one held.
public struct JournalTimeline: Equatable, Sendable {
    public private(set) var entries: [JournalEntry] = []
    public let limit: Int

    public init(limit: Int, entries: [JournalEntry] = []) {
        self.limit = limit
        merge(entries)
    }

    /// One row from the live stream.
    public mutating func insert(_ entry: JournalEntry) {
        merge([entry])
    }

    /// Rows read back from the journal, or any other batch. A row whose id is
    /// already here replaces the one held.
    public mutating func merge(_ batch: [JournalEntry]) {
        var held = Dictionary(uniqueKeysWithValues: entries.indices.compactMap { index in
            entries[index].journalKey.map { ($0, index) }
        })
        for entry in batch {
            // A row the journal could not store has no id of its own, so it is
            // never taken for another row.
            guard let key = entry.journalKey else {
                entries.append(entry)
                continue
            }
            if let index = held[key] {
                entries[index] = entry
            } else {
                held[key] = entries.endIndex
                entries.append(entry)
            }
        }
        entries.sort(by: JournalEntry.newerFirst)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}

extension JournalEntry {
    /// The order timelines show rows in: newest first, and among rows journaled
    /// at the same instant the later id first, observations ahead of events.
    public static func newerFirst(_ a: JournalEntry, _ b: JournalEntry) -> Bool {
        if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
        switch (a, b) {
        case (.observation(let x), .observation(let y)): return x.id > y.id
        case (.event(let x), .event(let y)): return x.id > y.id
        case (.observation, .event): return true
        case (.event, .observation): return false
        }
    }

    /// The row's identity in the journal, or nil when it was never stored.
    var journalKey: String? {
        switch self {
        case .observation(let o): o.id > 0 ? id : nil
        case .event(let e): e.id > 0 ? id : nil
        }
    }
}
