import Foundation
import Testing

@testable import AthinaCore

@Suite struct HistoryDaysTests {
  /// Days are counted in UTC here, so the tests read the same in any time zone.
  private static func calendar() throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    return calendar
  }

  /// 2026-09-15 14:32:10 UTC.
  private static let now = Date(timeIntervalSince1970: 1_789_482_730)

  private static func hoursAgo(_ hours: Double) -> Date {
    now.addingTimeInterval(-hours * 3600)
  }

  @Test func namesTodayYesterdayAndEarlierDaysByDate() throws {
    let calendar = try Self.calendar()
    let title = { (date: Date) in HistoryDays.title(for: date, now: Self.now, calendar: calendar) }
    #expect(title(Self.hoursAgo(14)) == "Today")
    #expect(title(Self.hoursAgo(15)) == "Yesterday")
    #expect(title(Self.hoursAgo(38)) == "Yesterday")
    #expect(title(Self.hoursAgo(39)) == "Sep 13")
    #expect(title(Self.hoursAgo(24 * 365)) == "Sep 15, 2025")
  }

  /// A newest-first list stays newest first: days in the order their first
  /// item comes, and items in their own order within a day.
  @Test func keepsTheListsOrderWithinAndAcrossDays() throws {
    struct Item {
      let id: Int
      let at: Date
    }
    let items = [
      Item(id: 5, at: Self.hoursAgo(0.1)),
      Item(id: 4, at: Self.hoursAgo(2)),
      Item(id: 3, at: Self.hoursAgo(20)),
      Item(id: 2, at: Self.hoursAgo(26)),
      Item(id: 1, at: Self.hoursAgo(60)),
    ]
    let days = HistoryDays.group(items, date: \.at, now: Self.now, calendar: try Self.calendar())
    #expect(days.map(\.title) == ["Today", "Yesterday", "Sep 13"])
    #expect(days.map { $0.items.map(\.id) } == [[5, 4], [3, 2], [1]])
    #expect(Set(days.map(\.id)).count == days.count)
  }

  @Test func noItemsMakeNoDays() throws {
    let none: [Date] = []
    let days = HistoryDays.group(none, date: { $0 }, now: Self.now, calendar: try Self.calendar())
    #expect(days.isEmpty)
  }

  /// A list left open over midnight is regrouped when the clock reaches the
  /// next day, so an item made before midnight moves from Today to Yesterday.
  @Test(.timeLimit(.minutes(1))) func theNextDayArrivesWhenTheClockReachesMidnight() async throws {
    let calendar = try Self.calendar()
    let beforeMidnight = Self.now.addingTimeInterval(9 * 3600 + 17 * 60)
    let item = beforeMidnight.addingTimeInterval(-60)
    let clock = AdjustableClock(startingAt: beforeMidnight)
    #expect(HistoryDays.title(for: item, now: clock.date, calendar: calendar) == "Today")

    let waiting = Task { try await HistoryDays.nextDay(on: clock, calendar: calendar) }
    await clock.waitForSleepers()
    clock.advance(by: .seconds(60))
    #expect(clock.sleeperCount == 1)
    clock.advance(by: .seconds(3600))
    let next = try await waiting.value

    #expect(next == clock.date)
    #expect(HistoryDays.title(for: item, now: next, calendar: calendar) == "Yesterday")
  }
}
