import Foundation
import Testing
@testable import MentorCore

@Suite struct SpendMeterTests {
    private let t0: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 13
        components.hour = 14
        components.minute = 10
        return Calendar.current.date(from: components)!
    }()

    @Test func totalsAreBucketedByClockHour() {
        var meter = SpendMeter(cap: 1)
        meter.record(cost: 0.2, at: t0)
        meter.record(cost: 0.3, at: t0 + 600)
        #expect(meter.spent(now: t0 + 900) == 0.5)
        #expect(meter.callCount(now: t0 + 900) == 2)
        // 14:10 plus 50 minutes is 15:00: a new bucket.
        let nextHour = t0 + 3000
        #expect(meter.spent(now: nextHour) == 0)
        meter.prune(now: nextHour)
        #expect(meter.entries.isEmpty)
        #expect(SpendMeter.nextHourStart(after: t0) == t0 + 3000)
    }

    @Test func multiplierGrowsTowardTheCap() {
        #expect(SpendMeter.multiplier(forFraction: 0) == 1)
        #expect(SpendMeter.multiplier(forFraction: 0.5) == 2)
        #expect(SpendMeter.multiplier(forFraction: 0.75) == 4)
        #expect(SpendMeter.multiplier(forFraction: 0.95) == SpendMeter.maximumMultiplier)
        #expect(SpendMeter.multiplier(forFraction: 1) == SpendMeter.maximumMultiplier)
        #expect(SpendMeter.multiplier(forFraction: 3) == SpendMeter.maximumMultiplier)
    }

    @Test func meterSlowsThenStops() {
        var meter = SpendMeter(cap: 1)
        #expect(meter.cadenceMultiplier(now: t0) == 1)
        meter.record(cost: 0.5, at: t0)
        #expect(meter.cadenceMultiplier(now: t0) == 2)
        #expect(!meter.isCapped(now: t0))
        meter.record(cost: 0.5, at: t0 + 1)
        #expect(meter.isCapped(now: t0 + 1))
        #expect(meter.fraction(now: t0 + 1) == 1)
        // The cap releases when the hour rolls over.
        #expect(!meter.isCapped(now: t0 + 3000))
        #expect(meter.cadenceMultiplier(now: t0 + 3000) == 1)
    }

    @Test func negativeCostsAndZeroCapAreHarmless() {
        var meter = SpendMeter(cap: 0)
        meter.record(cost: -5, at: t0)
        #expect(meter.spent(now: t0) == 0)
        #expect(meter.fraction(now: t0) == 0)
        #expect(!meter.isCapped(now: t0))
    }

    @Test func priceTableEstimatesFromUsageFields() {
        let table = PriceTable.defaults
        let usage = Usage(inputTokens: 1_000_000, outputTokens: 100_000, cacheCreationInputTokens: 200_000, cacheReadInputTokens: 500_000)
        let haiku = try! #require(table.cost(of: usage, model: ModelCatalog.haiku45.id))
        // 1 + 0.5 + 0.25 + 0.05
        #expect(abs(haiku - 1.80) < 1e-9)
        let fable = try! #require(table.cost(of: usage, model: ModelCatalog.fable51.id))
        // 10 + 5 + 2.5 + 0.125
        #expect(abs(fable - 17.625) < 1e-9)
        #expect(table.cost(of: usage, model: "unknown-model") == nil)
        #expect(table.checkedOn == PriceTable.defaultCheckedOn)
    }

    @Test func priceTableValidationRestoresMissingRowsAndClampsNegatives() {
        var table = PriceTable(checkedOn: "2026-01-01", prices: [
            ModelCatalog.opus5.id: ModelPrice(inputPerMillion: -1, outputPerMillion: 25, cacheWritePerMillion: 6.25, cacheReadPerMillion: 0.5),
        ])
        table = table.validated()
        #expect(table.prices[ModelCatalog.opus5.id]?.inputPerMillion == 0)
        #expect(table.prices[ModelCatalog.haiku45.id] == PriceTable.defaults.prices[ModelCatalog.haiku45.id])
        #expect(table.checkedOn == "2026-01-01")
    }
}
