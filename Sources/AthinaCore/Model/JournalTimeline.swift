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

    /// Rows read back from the journal, or any other batch. A row already here
    /// is kept as it is.
    public mutating func merge(_ batch: [JournalEntry]) {
        var known = Set(entries.compactMap(\.journalKey))
        var added = false
        for entry in batch {
            // A row the journal could not store has no id of its own, so it is
            // never taken for another row.
            if let key = entry.journalKey {
                guard known.insert(key).inserted else { continue }
            }
            entries.append(entry)
            added = true
        }
        guard added else { return }
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
