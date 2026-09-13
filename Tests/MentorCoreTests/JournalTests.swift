import CoreGraphics
import Foundation
import Testing
@testable import MentorCore

@Suite struct JournalTests {
    private func makeObservation(at time: Date, app: String = "Xcode", text: String = "hello", jpegBytes: Int = 64) -> ActivityObservation {
        let focus = FocusContext(
            timestamp: time, pid: 42, bundleID: "com.apple.dt.Xcode", appName: app,
            windowTitle: "main.swift", focusedRole: "AXTextArea", focusedValue: "let x = 1", focusedValueLength: 9
        )
        let frame = FrameInfo(
            hash: PerceptualHash(words: [1, 2, 3, 4]), width: 1280, height: 800, displayID: 1,
            screenRect: CGRect(x: 0, y: 0, width: 2560, height: 1600),
            jpeg: Data(repeating: 0xAB, count: jpegBytes)
        )
        let block = TextBlock(
            text: text, confidence: 0.9,
            imageRect: CGRect(x: 10, y: 20, width: 100, height: 12),
            screenRect: CGRect(x: 20, y: 40, width: 200, height: 24)
        )
        return ActivityObservation(timestamp: time, focus: focus, frame: frame, textBlocks: [block], reason: .floor)
    }

    private func temporaryJournal() throws -> Journal {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mentor-tests-\(UUID().uuidString)")
        return try Journal(url: dir.appendingPathComponent("journal.sqlite"))
    }

    @Test func observationRoundTrips() async throws {
        let journal = try Journal.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = try await journal.record(makeObservation(at: now))
        #expect(stored.id > 0)

        let fetched = try #require(try await journal.observation(id: stored.id))
        #expect(fetched.timestamp == now)
        #expect(fetched.focus.appName == "Xcode")
        #expect(fetched.focus.focusedValue == "let x = 1")
        #expect(fetched.frame.hash == PerceptualHash(words: [1, 2, 3, 4]))
        #expect(fetched.frame.screenRect.width == 2560)
        #expect(fetched.textBlocks.first?.text == "hello")
        #expect(fetched.textBlocks.first?.screenRect.origin.x == 20)
        #expect(fetched.reason == .floor)
        #expect(fetched.frame.jpeg == nil)

        let thumbnail = try await journal.thumbnail(observationID: stored.id)
        #expect(thumbnail == Data(repeating: 0xAB, count: 64))
    }

    @Test func eventsAndEntriesInterleaveNewestFirst() async throws {
        let journal = try Journal.inMemory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await journal.record(makeObservation(at: base))
        try await journal.record(JournalEvent(timestamp: base + 1, kind: .appSwitch, appName: "Safari"))
        try await journal.record(makeObservation(at: base + 2))
        try await journal.record(JournalEvent(timestamp: base + 3, kind: .idleStart))

        let entries = try await journal.recentEntries(limit: 3)
        #expect(entries.count == 3)
        #expect(entries.map(\.timestamp) == [base + 3, base + 2, base + 1])
        if case .event(let event) = entries[0] {
            #expect(event.kind == .idleStart)
        } else {
            Issue.record("expected an event first")
        }
        let since = try await journal.observations(since: base + 1, limit: 10)
        #expect(since.count == 1)
    }

    @Test func statsCountRows() async throws {
        let journal = try Journal.inMemory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await journal.record(makeObservation(at: base))
        try await journal.record(JournalEvent(timestamp: base + 5, kind: .paused))
        let stats = try await journal.stats()
        #expect(stats.observationCount == 1)
        #expect(stats.thumbnailCount == 1)
        #expect(stats.eventCount == 1)
        #expect(stats.oldest == base)
        #expect(stats.newest == base + 5)
        #expect(stats.usedBytes > 0)
    }

    @Test func clearRemovesEverythingAndRecordsEvent() async throws {
        let journal = try Journal.inMemory()
        try await journal.record(makeObservation(at: Date()))
        try await journal.record(JournalEvent(kind: .appSwitch))
        try await journal.clear()
        let stats = try await journal.stats()
        #expect(stats.observationCount == 0)
        #expect(stats.thumbnailCount == 0)
        #expect(stats.eventCount == 1)
        let events = try await journal.recentEvents(limit: 5)
        #expect(events.first?.kind == .journalCleared)
    }

    @Test func ageRetentionDropsThumbnailsBeforeText() async throws {
        let journal = try Journal.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = try await journal.record(makeObservation(at: now - 3 * 3600))
        let ancient = try await journal.record(makeObservation(at: now - 10 * 86400))
        let fresh = try await journal.record(makeObservation(at: now - 60))
        try await journal.record(JournalEvent(timestamp: now - 10 * 86400, kind: .appSwitch))
        try await journal.record(JournalEvent(timestamp: now - 60, kind: .appSwitch))

        let policy = RetentionPolicy(thumbnailMaxAge: 3600, textMaxAge: 7 * 86400, sizeCapBytes: 1 << 30)
        let result = try await journal.applyRetention(policy, now: now)

        #expect(result.thumbnailsDeleted == 2)
        #expect(result.observationsDeleted == 1)
        #expect(result.eventsDeleted == 1)
        #expect(try await journal.observation(id: old.id) != nil)
        #expect(try await journal.thumbnail(observationID: old.id) == nil)
        #expect(try await journal.observation(id: ancient.id) == nil)
        #expect(try await journal.thumbnail(observationID: fresh.id) != nil)
    }

    @Test func sizeCapEvictsOldestThumbnailsThenObservations() async throws {
        let journal = try temporaryJournal()
        // Empty tables and indexes each hold a page, so caps below are relative to that floor.
        let emptyBytes = try await journal.usedBytes()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<40 {
            try await journal.record(makeObservation(at: now - Double(40 - i) * 10, jpegBytes: 20_000))
        }
        let before = try await journal.usedBytes()
        #expect(before > 700_000)

        let cap: Int64 = 600_000
        let policy = RetentionPolicy(thumbnailMaxAge: 86400, textMaxAge: 86400, sizeCapBytes: cap)
        let result = try await journal.applyRetention(policy, now: now)

        #expect(result.thumbnailsDeleted > 0)
        #expect(result.bytesAfter <= policy.sizeTargetBytes)
        let stats = try await journal.stats()
        // Text survives a thumbnail-only sweep: the cap is met without deleting observations.
        #expect(stats.observationCount == 40)
        #expect(stats.thumbnailCount < 40)
        // The remaining thumbnails are the newest ones.
        let newest = try await journal.recentObservations(limit: 1).first!
        #expect(try await journal.thumbnail(observationID: newest.id) != nil)
        let oldest = try await journal.observations(since: .distantPast, limit: 1).first!
        #expect(try await journal.thumbnail(observationID: oldest.id) == nil)

        // A cap smaller than the text alone forces observation deletion too.
        let tiny = RetentionPolicy(thumbnailMaxAge: 86400, textMaxAge: 86400, sizeCapBytes: emptyBytes + 30_000)
        let second = try await journal.applyRetention(tiny, now: now)
        #expect(second.observationsDeleted > 0)
        let after = try await journal.stats()
        #expect(after.observationCount < 40)
        #expect(after.observationCount > 0)
        #expect(after.usedBytes <= tiny.sizeCapBytes)
    }

    @Test func journalPersistsAcrossReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mentor-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("journal.sqlite")
        do {
            let journal = try Journal(url: url)
            try await journal.record(makeObservation(at: Date()))
        }
        let reopened = try Journal(url: url)
        let stats = try await reopened.stats()
        #expect(stats.observationCount == 1)
        #expect(stats.thumbnailCount == 1)
    }
}

@Suite struct RetentionPolicyTests {
    @Test func cutoffsFollowAges() {
        let now = Date(timeIntervalSince1970: 10_000)
        let policy = RetentionPolicy(thumbnailMaxAge: 100, textMaxAge: 1000, sizeCapBytes: 1000)
        #expect(policy.thumbnailCutoff(now: now) == now - 100)
        #expect(policy.textCutoff(now: now) == now - 1000)
        #expect(policy.sizeTargetBytes == 800)
    }

    @Test func textNeverExpiresBeforeThumbnails() {
        let now = Date(timeIntervalSince1970: 10_000)
        let policy = RetentionPolicy(thumbnailMaxAge: 1000, textMaxAge: 100, sizeCapBytes: 1000)
        #expect(policy.textCutoff(now: now) == now - 1000)
    }

    @Test func policyFromSettings() {
        var settings = SensingSettings()
        settings.thumbnailRetention = 60
        settings.textRetention = 120
        settings.journalSizeCapBytes = 20 * 1024 * 1024
        let policy = RetentionPolicy(settings: settings)
        #expect(policy.thumbnailMaxAge == 60)
        #expect(policy.textMaxAge == 120)
        #expect(policy.sizeCapBytes == 20 * 1024 * 1024)
    }
}
