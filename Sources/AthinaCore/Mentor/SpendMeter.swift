import Foundation

/// Per-hour spend accounting.
///
/// Spend is bucketed by clock hour: the cap releases at the top of the next
/// hour, and the cadence multiplier grows as the hour's total approaches the
/// cap.
public struct SpendMeter: Equatable, Sendable {
  /// One call's cost and when it happened.
  public struct Entry: Equatable, Sendable {
    /// When the call happened, which decides the hour it counts toward.
    public var at: Date
    /// What the call cost, in dollars.
    public var cost: Double

    /// Creates an entry.
    public init(at: Date, cost: Double) {
      self.at = at
      self.cost = cost
    }
  }

  /// The multiplier never exceeds this, so calls keep trickling until the cap.
  public static let maximumMultiplier = 8.0

  /// The most an hour may spend, in dollars; 0 means no cap.
  public var cap: Double
  /// The calls recorded, oldest first, until `prune(now:)` drops earlier
  /// hours.
  public private(set) var entries: [Entry] = []

  /// Creates a meter with nothing spent.
  public init(cap: Double) {
    self.cap = cap
  }

  /// Returns the start of the clock hour containing `date`.
  public static func hourStart(of date: Date) -> Date {
    Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
  }

  /// Returns the start of the clock hour after the one containing `date`,
  /// when the cap releases.
  public static func nextHourStart(after date: Date) -> Date {
    hourStart(of: date).addingTimeInterval(3600)
  }

  /// Records a call's cost, in dollars, at the time it happened; a negative
  /// cost counts as zero.
  public mutating func record(cost: Double, at: Date) {
    entries.append(Entry(at: at, cost: max(0, cost)))
  }

  /// Drops entries from earlier hours.
  public mutating func prune(now: Date) {
    let start = SpendMeter.hourStart(of: now)
    entries.removeAll { $0.at < start }
  }

  /// Returns the dollars spent in the clock hour containing `now`.
  public func spent(now: Date) -> Double {
    let start = SpendMeter.hourStart(of: now)
    return entries.filter { $0.at >= start }.reduce(0) { $0 + $1.cost }
  }

  /// Returns how many calls were recorded in the clock hour containing
  /// `now`.
  public func callCount(now: Date) -> Int {
    let start = SpendMeter.hourStart(of: now)
    return entries.filter { $0.at >= start }.count
  }

  /// Spent over cap, 0 when there is no cap.
  public func fraction(now: Date) -> Double {
    guard cap > 0 else { return 0 }
    return spent(now: now) / cap
  }

  /// Returns whether the hour's spend has reached the cap; never with no
  /// cap.
  public func isCapped(now: Date) -> Bool {
    cap > 0 && fraction(now: now) >= 1
  }

  /// How much slower both cadences run at this point in the hour.
  public func cadenceMultiplier(now: Date) -> Double {
    SpendMeter.multiplier(forFraction: fraction(now: now))
  }

  /// 1x at zero spend, 2x at half the cap, 4x at three quarters, capped at
  /// `maximumMultiplier`.
  ///
  /// Continuous, so the slowdown creeps in rather than jumping.
  public static func multiplier(forFraction fraction: Double) -> Double {
    guard fraction > 0 else { return 1 }
    guard fraction < 1 else { return maximumMultiplier }
    return min(maximumMultiplier, max(1, 1 / (1 - fraction)))
  }
}
