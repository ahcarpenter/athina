import Foundation

/// A model Athina knows how to call and price, at one provider.
public struct ClaudeModel: Equatable, Sendable, Identifiable {
  /// The request shape a model is called with.
  public enum API: Sendable {
    /// Anthropic's Messages API.
    case messages
    /// OpenAI's Responses API.
    case responses
  }

  /// The model id the provider takes, sent in a request.
  public var id: String
  /// The name Settings and the menu show, such as `Claude Opus 5`.
  public var displayName: String
  /// Whether a reasoning effort is accepted; Haiku 4.5 rejects it.
  public var supportsEffort: Bool
  /// Whose API serves it, with whose key.
  public var provider: ModelProvider
  /// The request shape it is called with.
  public var api: API

  /// Creates a catalog entry.
  public init(
    id: String,
    displayName: String,
    supportsEffort: Bool,
    provider: ModelProvider = .anthropic,
    api: API = .messages
  ) {
    self.id = id
    self.displayName = displayName
    self.supportsEffort = supportsEffort
    self.provider = provider
    self.api = api
  }

  /// The key its prices are kept under: the bare id for Anthropic, as every
  /// earlier build keeps them, and the provider and id for any other, since
  /// two providers can serve the same id at different prices.
  public var priceKey: String { PriceTable.key(for: id, provider: provider) }
}

/// The models offered in Settings, for each provider.
///
/// Ids, capabilities and prices were checked against each provider's own
/// documentation on `PriceTable.defaultCheckedOn`: Anthropic's models and
/// pricing pages, OpenAI's Codex model list and API pricing page, and OpenCode
/// Zen's model and pricing tables (opencode.ai/docs/zen).
public enum ModelCatalog {
  // MARK: Anthropic

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
  /// Claude Opus 5.5, the next Opus, priced below Opus 5.
  public static let opus55 = ClaudeModel(
    id: "claude-opus-5-5",
    displayName: "Claude Opus 5.5",
    supportsEffort: true
  )
  /// Claude Fable 5.1, the priciest model in the catalog.
  public static let fable51 = ClaudeModel(
    id: "claude-fable-5-1",
    displayName: "Claude Fable 5.1",
    supportsEffort: true
  )

  /// Every Anthropic model, in the order the price table lists them.
  public static let all: [ClaudeModel] = [haiku45, sonnet5, opus5, opus55, fable51]
  /// Models offered for the triage tier: the cheap default plus every
  /// effort-capable model, so extra-high effort is reachable there too.
  public static let triageChoices: [ClaudeModel] = [haiku45, sonnet5, opus5, opus55, fable51]
  /// Models offered for the mentor tier.
  public static let mentorChoices: [ClaudeModel] = [sonnet5, opus5, opus55, fable51]
  /// Models offered for the understanding refresh.
  ///
  /// Rewriting the record is summarising work, so the cheap model is offered
  /// here as well.
  public static let understandingChoices: [ClaudeModel] = [
    haiku45, sonnet5, opus5, opus55, fable51,
  ]

  // MARK: OpenAI

  /// GPT-6 Luna, OpenAI's most efficient Codex model, the default triage
  /// model on OpenAI.
  public static let gpt6Luna = gpt("gpt-6-luna", "GPT-6 Luna", provider: .openAI)
  /// GPT-6 Sol, the Codex model OpenAI recommends, the default mentor and
  /// understanding model on OpenAI.
  public static let gpt6Sol = gpt("gpt-6-sol", "GPT-6 Sol", provider: .openAI)
  /// GPT-6 Astra, OpenAI's most capable Codex model.
  public static let gpt6Astra = gpt("gpt-6-astra", "GPT-6 Astra", provider: .openAI)

  /// Every OpenAI model, cheapest first.
  public static let openAI: [ClaudeModel] = [gpt6Luna, gpt6Sol, gpt6Astra]

  // MARK: OpenCode Zen

  /// The Claude models OpenCode Zen serves, by Zen's own ids.
  public static let openCodeClaude: [ClaudeModel] = [
    ClaudeModel(
      id: "claude-haiku-4-5",
      displayName: "Claude Haiku 4.5",
      supportsEffort: false,
      provider: .openCode
    ),
    zenClaude("claude-sonnet-5", "Claude Sonnet 5"),
    zenClaude("claude-opus-5", "Claude Opus 5"),
    zenClaude("claude-opus-5-5", "Claude Opus 5.5"),
    zenClaude("claude-fable-5-1", "Claude Fable 5.1"),
  ]
  /// The GPT models OpenCode Zen serves.
  public static let openCodeGPT: [ClaudeModel] = [
    gpt("gpt-6-luna", "GPT-6 Luna", provider: .openCode),
    gpt("gpt-6-sol", "GPT-6 Sol", provider: .openCode),
    gpt("gpt-6-astra", "GPT-6 Astra", provider: .openCode),
  ]
  /// Every OpenCode Zen model Athina offers.
  ///
  /// These are the ones behind the two request shapes Athina speaks; Zen's
  /// other models use shapes Athina does not send.
  public static let openCode: [ClaudeModel] = openCodeClaude + openCodeGPT

  private static func gpt(_ id: String, _ name: String, provider: ModelProvider) -> ClaudeModel {
    ClaudeModel(
      id: id,
      displayName: name,
      supportsEffort: true,
      provider: provider,
      api: .responses
    )
  }

  private static func zenClaude(_ id: String, _ name: String) -> ClaudeModel {
    ClaudeModel(id: id, displayName: name, supportsEffort: true, provider: .openCode)
  }

  // MARK: Lookup

  /// Every model at `provider`.
  public static func models(for provider: ModelProvider) -> [ClaudeModel] {
    switch provider {
    case .anthropic: all
    case .openAI: openAI
    case .openCode: openCode
    }
  }

  /// The models `provider` offers for `tier`.
  ///
  /// Every model triages and refreshes the understanding; the mentor tier,
  /// which judges the whole picture, leaves out each provider's cheapest.
  public static func choices(for tier: ModelTier, provider: ModelProvider) -> [ClaudeModel] {
    switch (provider, tier) {
    case (.anthropic, .triage), (.anthropic, .test): triageChoices
    case (.anthropic, .mentor), (.anthropic, .followUp): mentorChoices
    case (.anthropic, .understanding): understandingChoices
    case (.openAI, .mentor), (.openAI, .followUp): [gpt6Sol, gpt6Astra]
    case (.openCode, .mentor), (.openCode, .followUp):
      Array(openCodeClaude.dropFirst()) + Array(openCodeGPT.dropFirst())
    case (_, .triage), (_, .understanding), (_, .test): models(for: provider)
    }
  }

  /// Returns the catalog model with `id` at `provider`, or nil when the
  /// catalog has none.
  public static func model(id: String, provider: ModelProvider) -> ClaudeModel? {
    models(for: provider).first { $0.id == id }
  }

  /// Returns the catalog model with `id`, at whichever provider lists it
  /// first, or nil when the catalog has none.
  public static func model(id: String) -> ClaudeModel? {
    ModelProvider.allCases.lazy.compactMap { model(id: id, provider: $0) }.first
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
  /// Cache read, 0.1x the base input price (0.05x on Claude Opus 5.5, 0.025x on
  /// Claude Fable 5.1).
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
  /// ISO date on which `defaults` matched each provider's pricing page.
  public static let defaultCheckedOn = "2026-09-28"

  /// The ISO date the prices were checked on, as Settings > Models shows it.
  public var checkedOn: String
  /// Each model's prices, keyed by `key(for:provider:)`.
  public var prices: [String: ModelPrice]

  /// Creates a price table.
  public init(checkedOn: String, prices: [String: ModelPrice]) {
    self.checkedOn = checkedOn
    self.prices = prices
  }

  /// The key a model's prices are kept under: its bare id at Anthropic, as
  /// every earlier build keeps them, and the provider and id elsewhere.
  public static func key(for model: String, provider: ModelProvider) -> String {
    provider == .anthropic ? model : "\(provider.rawValue)/\(model)"
  }

  /// The built-in prices, checked against each provider's pricing page on
  /// `defaultCheckedOn`: the standard rate, below each model's long-context
  /// threshold, with five-minute cache writes.
  ///
  /// Settings > Models can restore them.
  public static let defaults = PriceTable(
    checkedOn: defaultCheckedOn,
    prices: anthropicDefaults.merging(openAIDefaults) { first, _ in first }.merging(
      openCodeDefaults
    ) { first, _ in first }
  )

  private static func price(
    _ input: Double,
    _ output: Double,
    cacheWrite: Double,
    cacheRead: Double
  ) -> ModelPrice {
    ModelPrice(
      inputPerMillion: input,
      outputPerMillion: output,
      cacheWritePerMillion: cacheWrite,
      cacheReadPerMillion: cacheRead
    )
  }

  /// GPT-6 prices, the same at OpenAI and at OpenCode Zen.
  private static let gpt6: [String: ModelPrice] = [
    "gpt-6-luna": price(0.10, 0.50, cacheWrite: 0.125, cacheRead: 0.01),
    "gpt-6-sol": price(2, 10, cacheWrite: 2.50, cacheRead: 0.20),
    "gpt-6-astra": price(10, 50, cacheWrite: 12.50, cacheRead: 1),
  ]

  private static let openAIDefaults: [String: ModelPrice] = Dictionary(
    uniqueKeysWithValues: gpt6.map { (key(for: $0.key, provider: .openAI), $0.value) }
  )

  /// OpenCode Zen's prices for the models Athina offers there.
  private static let openCodeDefaults: [String: ModelPrice] = Dictionary(
    uniqueKeysWithValues: (gpt6.map { ($0.key, $0.value) } + [
      ("claude-haiku-4-5", price(1, 5, cacheWrite: 1.25, cacheRead: 0.10)),
      ("claude-sonnet-5", price(2, 10, cacheWrite: 2.50, cacheRead: 0.20)),
      ("claude-opus-5", price(5, 25, cacheWrite: 6.25, cacheRead: 0.50)),
      ("claude-opus-5-5", price(4, 20, cacheWrite: 5, cacheRead: 0.20)),
      ("claude-fable-5-1", price(10, 50, cacheWrite: 12.50, cacheRead: 0.25)),
    ]).map { (key(for: $0.0, provider: .openCode), $0.1) }
  )

  private static let anthropicDefaults: [String: ModelPrice] = [
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
    ModelCatalog.opus55.id: ModelPrice(
      inputPerMillion: 4,
      outputPerMillion: 20,
      cacheWritePerMillion: 5,
      cacheReadPerMillion: 0.20
    ),
    ModelCatalog.fable51.id: ModelPrice(
      inputPerMillion: 10,
      outputPerMillion: 50,
      cacheWritePerMillion: 12.50,
      cacheReadPerMillion: 0.25
    ),
  ]

  /// Returns the prices for the model id `model`, or nil when it has no row.
  public func price(for model: String) -> ModelPrice? {
    prices[model]
  }

  /// Nil when the model has no price row.
  public func cost(of usage: Usage, model: String) -> Double? {
    price(for: model)?.cost(of: usage)
  }

  /// What `usage` cost on `model` at `provider`; nil when it has no price row.
  public func cost(of usage: Usage, model: String, provider: ModelProvider) -> Double? {
    price(for: PriceTable.key(for: model, provider: provider))?.cost(of: usage)
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
