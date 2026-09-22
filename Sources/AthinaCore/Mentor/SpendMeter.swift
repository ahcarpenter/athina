import Foundation

/// Per-hour spend accounting. Spend is bucketed by clock hour: the cap
/// releases at the top of the next hour, and the cadence multiplier grows as
/// the hour's total approaches the cap.
public struct SpendMeter: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var at: Date
        public var cost: Double

        public init(at: Date, cost: Double) {
            self.at = at
            self.cost = cost
        }
    }

    /// The multiplier never exceeds this, so calls keep trickling until the cap.
    public static let maximumMultiplier = 8.0

    public var cap: Double
    public private(set) var entries: [Entry] = []

    public init(cap: Double) {
        self.cap = cap
    }

    public static func hourStart(of date: Date) -> Date {
        Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
    }

    public static func nextHourStart(after date: Date) -> Date {
        hourStart(of: date).addingTimeInterval(3600)
    }

    public mutating func record(cost: Double, at: Date) {
        entries.append(Entry(at: at, cost: max(0, cost)))
    }

    /// Drops entries from earlier hours.
    public mutating func prune(now: Date) {
        let start = SpendMeter.hourStart(of: now)
        entries.removeAll { $0.at < start }
    }

    public func spent(now: Date) -> Double {
        let start = SpendMeter.hourStart(of: now)
        return entries.filter { $0.at >= start }.reduce(0) { $0 + $1.cost }
    }

    public func callCount(now: Date) -> Int {
        let start = SpendMeter.hourStart(of: now)
        return entries.filter { $0.at >= start }.count
    }

    /// Spent over cap, 0 when there is no cap.
    public func fraction(now: Date) -> Double {
        guard cap > 0 else { return 0 }
        return spent(now: now) / cap
    }

    public func isCapped(now: Date) -> Bool {
        cap > 0 && fraction(now: now) >= 1
    }

    /// How much slower both cadences run at this point in the hour.
    public func cadenceMultiplier(now: Date) -> Double {
        SpendMeter.multiplier(forFraction: fraction(now: now))
    }

    /// 1x at zero spend, 2x at half the cap, 4x at three quarters, capped at
    /// `maximumMultiplier`. Continuous, so the slowdown creeps in rather than jumping.
    public static func multiplier(forFraction fraction: Double) -> Double {
        guard fraction > 0 else { return 1 }
        guard fraction < 1 else { return maximumMultiplier }
        return min(maximumMultiplier, max(1, 1 / (1 - fraction)))
    }
}
