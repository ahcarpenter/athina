import Foundation

/// Past suggestions grouped by the day they were made, as the Suggestions
/// window lists them: each day under a heading, so a row needs only its time.
public enum HistoryDays {
  /// One day's suggestions, in the order they were given.
  public struct Day<Item>: Identifiable {
    /// The start of the day, in the calendar the days were grouped in.
    public let start: Date
    /// "Today", "Yesterday", or the date (`HistoryDays.title`).
    public let title: String
    /// The day's items, in the order they were given.
    public let items: [Item]

    /// The day's start, which no other day shares.
    public var id: Date { start }
  }

  /// Groups `items` by the day `date` gives each, keeping their order within
  /// a day and ordering days by their first item, so a list that is newest
  /// first stays newest first.
  ///
  /// - Parameters:
  ///   - items: The items to group, in the order they are listed.
  ///   - date: When an item was made.
  ///   - now: The present, from the injected `AthinaClock`, which says which
  ///     day is today.
  ///   - calendar: The calendar and time zone days are counted in.
  /// - Returns: One day per calendar day that holds an item.
  public static func group<Item>(
    _ items: [Item],
    date: (Item) -> Date,
    now: Date,
    calendar: Calendar
  ) -> [Day<Item>] {
    var starts: [Date] = []
    var byStart: [Date: [Item]] = [:]
    for item in items {
      let start = calendar.startOfDay(for: date(item))
      if byStart[start] == nil { starts.append(start) }
      byStart[start, default: []].append(item)
    }
    return starts.map { start in
      Day(
        start: start,
        title: title(for: start, now: now, calendar: calendar),
        items: byStart[start] ?? []
      )
    }
  }

  /// The heading for the day `day` falls in: "Today", "Yesterday", the date
  /// ("Sep 13") within this year, and the date with its year ("Sep 13, 2025")
  /// before it.
  public static func title(for day: Date, now: Date, calendar: Calendar) -> String {
    if calendar.isDate(day, inSameDayAs: now) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(day, inSameDayAs: yesterday)
    {
      return "Yesterday"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
    formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
    return formatter.string(from: day)
  }
}
