import Foundation

/// Whose API answers Athina's model calls, with the person's own key for it.
///
/// Chosen in Settings > Models. Anthropic is the default. Each provider's key
/// is kept in the login keychain under its own account (`KeychainKeyStore`),
/// and each provider needs its own Allow in the consent window, since each
/// sends to a different company (`SensingSettings.hasConsent`).
public enum ModelProvider: String, Codable, Sendable, CaseIterable, Identifiable {
  /// The Anthropic Messages API at api.anthropic.com.
  case anthropic
  /// The OpenAI Responses API at api.openai.com, where the Codex models run.
  case openAI = "openai"
  /// OpenCode, through its Zen API gateway at opencode.ai, which serves
  /// Claude and GPT models behind one key.
  case openCode = "opencode"

  /// The raw value, which is also what settings.json stores.
  public var id: String { rawValue }

  /// Decodes a provider, reading one this build does not know, which a later
  /// build wrote, as Anthropic, so the rest of the settings still load.
  ///
  /// Anthropic's consent is kept apart from every other provider's
  /// (`SensingSettings.consent(for:)`), so nothing is sent under an Allow
  /// given to another provider.
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = ModelProvider(rawValue: raw) ?? .anthropic
  }

  /// The provider's name in Settings, the menu and the call log.
  public var name: String {
    switch self {
    case .anthropic: "Anthropic"
    case .openAI: "OpenAI"
    case .openCode: "OpenCode"
    }
  }

  /// The only host a call to this provider goes to.
  public var host: String {
    switch self {
    case .anthropic: "api.anthropic.com"
    case .openAI: "api.openai.com"
    case .openCode: "opencode.ai"
    }
  }

  /// The account the provider's key is saved under in the keychain, within
  /// the service `AppPaths` names.
  public var keychainAccount: String {
    switch self {
    case .anthropic: "anthropic-api-key"
    case .openAI: "openai-api-key"
    case .openCode: "opencode-api-key"
    }
  }

  /// The placeholder in the key field, showing how the provider's keys begin
  /// where they share a prefix.
  public var keyPlaceholder: String {
    switch self {
    case .anthropic: "Paste a key, sk-ant-…"
    case .openAI: "Paste a key, sk-…"
    case .openCode: "Paste a key"
    }
  }
}

/// How one call reaches its model: the provider, and the person's key for it.
///
/// The loop builds it for every call from the provider in force; recording
/// and replay pass it through untouched.
public struct CallRoute: Equatable, Sendable {
  /// Whose API the call goes to.
  public var provider: ModelProvider
  /// The person's key for that API, never stored by the route.
  public var key: String

  /// A route to `provider` with `key`.
  public init(_ provider: ModelProvider, key: String) {
    self.provider = provider
    self.key = key
  }
}
