import Foundation

/// A Claude model Athina knows how to call and price.
public struct ClaudeModel: Equatable, Sendable, Identifiable {
  /// The API model id, sent in a request and keying the price table.
  public var id: String
  /// The name Settings shows, such as `Claude Opus 5`.
  public var displayName: String
  /// Whether `output_config.effort` is accepted; Haiku 4.5 rejects it.
  public var supportsEffort: Bool

  /// Creates a catalog entry.
  public init(id: String, displayName: String, supportsEffort: Bool) {
    self.id = id
    self.displayName = displayName
    self.supportsEffort = supportsEffort
  }
}

/// The models offered in Settings.
///
/// Ids and capabilities were checked against the Anthropic documentation on
/// `PriceTable.defaultCheckedOn`.
public enum ModelCatalog {
  /// Claude Haiku 4.5, the default triage model.
  public static let haiku45 = ClaudeModel(
    id: "claude-haiku-4-5-20251001",
    displayName: "Claude Haiku 4.5",
    supportsEffort: false
  )
  /// Claude Sonnet 5, offered for every tier.
  public static let sonnet5 = ClaudeModel(
    id: "claude-sonnet-5",
    displayName: "Claude Sonnet 5",
    supportsEffort: true
  )
  /// Claude Opus 5, the default mentor and understanding model.
  public static let opus5 = ClaudeModel(
    id: "claude-opus-5",
    displayName: "Claude Opus 5",
    supportsEffort: true
  )
  /// Claude Fable 5.1, the priciest model in the catalog.
  public static let fable51 = ClaudeModel(
    id: "claude-fable-5-1",
    displayName: "Claude Fable 5.1",
    supportsEffort: true
  )

  /// Every model in the catalog, in the order the price table lists them.
  public static let all: [ClaudeModel] = [haiku45, sonnet5, opus5, fable51]
  /// Models offered for the triage tier: the cheap default plus every
  /// effort-capable model, so extra-high effort is reachable there too.
  public static let triageChoices: [ClaudeModel] = [haiku45, sonnet5, opus5, fable51]
  /// Models offered for the mentor tier.
  public static let mentorChoices: [ClaudeModel] = [sonnet5, opus5, fable51]
  /// Models offered for the understanding refresh.
  ///
  /// Rewriting the record is summarising work, so the cheap model is offered
  /// here as well.
  public static let understandingChoices: [ClaudeModel] = [haiku45, sonnet5, opus5, fable51]

  /// Returns the catalog model with `id`, or nil when the catalog has none.
  public static func model(id: String) -> ClaudeModel? {
    all.first { $0.id == id }
  }

  /// Returns the display name for the model `id`, or `id` itself when the
  /// catalog does not know it.
  public static func displayName(for id: String) -> String {
    model(id: id)?.displayName ?? id
  }
}

/// Prices per million tokens for one model.
public struct ModelPrice: Codable, Equatable, Sendable {
  /// Dollars per million input tokens read outside the cache.
  public var inputPerMillion: Double
  /// Dollars per million output tokens.
  public var outputPerMillion: Double
  /// Five-minute cache write, 1.25x the base input price.
  public var cacheWritePerMillion: Double
  /// Cache read, 0.1x the base input price (0.025x on Claude Fable 5.1).
  public var cacheReadPerMillion: Double

  /// Creates a price row.
  public init(
    inputPerMillion: Double,
    outputPerMillion: Double,
    cacheWritePerMillion: Double,
    cacheReadPerMillion: Double
  ) {
    self.inputPerMillion = inputPerMillion
    self.outputPerMillion = outputPerMillion
    self.cacheWritePerMillion = cacheWritePerMillion
    self.cacheReadPerMillion = cacheReadPerMillion
  }

  /// Estimated cost in dollars of one response's usage.
  public func cost(of usage: Usage) -> Double {
    (Double(usage.inputTokens) * inputPerMillion
      + Double(usage.outputTokens) * outputPerMillion
      + Double(usage.cacheCreationInputTokens) * cacheWritePerMillion
      + Double(usage.cacheReadInputTokens) * cacheReadPerMillion) / 1_000_000
  }
}

/// Editable price table, with the date the defaults were checked.
public struct PriceTable: Codable, Equatable, Sendable {
  /// ISO date on which `defaults` matched the Anthropic pricing page.
  public static let defaultCheckedOn = "2026-09-13"

  /// The ISO date the prices were checked on, as Settings > Models shows it.
  public var checkedOn: String
  /// Each model's prices, keyed by model id.
  public var prices: [String: ModelPrice]

  /// Creates a price table.
  public init(checkedOn: String, prices: [String: ModelPrice]) {
    self.checkedOn = checkedOn
    self.prices = prices
  }

  /// The built-in prices, checked against the Anthropic pricing page on
  /// `defaultCheckedOn`.
  ///
  /// Settings > Models can restore them.
  public static let defaults = PriceTable(
    checkedOn: defaultCheckedOn,
    prices: [
      ModelCatalog.haiku45.id: ModelPrice(
        inputPerMillion: 1,
        outputPerMillion: 5,
        cacheWritePerMillion: 1.25,
        cacheReadPerMillion: 0.10
      ),
      ModelCatalog.sonnet5.id: ModelPrice(
        inputPerMillion: 2,
        outputPerMillion: 10,
        cacheWritePerMillion: 2.50,
        cacheReadPerMillion: 0.20
      ),
      ModelCatalog.opus5.id: ModelPrice(
        inputPerMillion: 5,
        outputPerMillion: 25,
        cacheWritePerMillion: 6.25,
        cacheReadPerMillion: 0.50
      ),
      ModelCatalog.fable51.id: ModelPrice(
        inputPerMillion: 10,
        outputPerMillion: 50,
        cacheWritePerMillion: 12.50,
        cacheReadPerMillion: 0.25
      ),
    ]
  )

  /// Returns the prices for the model id `model`, or nil when it has no row.
  public func price(for model: String) -> ModelPrice? {
    prices[model]
  }

  /// Nil when the model has no price row.
  public func cost(of usage: Usage, model: String) -> Double? {
    price(for: model)?.cost(of: usage)
  }

  /// Keeps every price non-negative and makes sure the catalog models all have a row.
  public func validated() -> PriceTable {
    var table = self
    for (id, price) in PriceTable.defaults.prices where table.prices[id] == nil {
      table.prices[id] = price
    }
    for (id, price) in table.prices {
      table.prices[id] = ModelPrice(
        inputPerMillion: max(0, price.inputPerMillion),
        outputPerMillion: max(0, price.outputPerMillion),
        cacheWritePerMillion: max(0, price.cacheWritePerMillion),
        cacheReadPerMillion: max(0, price.cacheReadPerMillion)
      )
    }
    return table
  }
}
