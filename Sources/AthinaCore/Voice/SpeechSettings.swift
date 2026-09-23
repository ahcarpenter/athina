import Foundation

/// Which recognizer hears the talk-back key, and which model each
/// downloadable recognizer uses. Kept in the `mentor` section of the settings
/// file under `speech`.
public struct SpeechSettings: Codable, Equatable, Sendable {
    /// Apple's SpeechAnalyzer unless the person chose another.
    public var backend: SpeechBackendID = .speechAnalyzer
    /// Remembered for each recognizer, so switching back finds the model
    /// that was chosen, already downloaded.
    public var whisperModel = SpeechModelCatalog.defaultModel(for: .whisper)!.id
    public var parakeetModel = SpeechModelCatalog.defaultModel(for: .parakeet)!.id

    public init() {}

    public init(backend: SpeechBackendID, whisperModel: String? = nil, parakeetModel: String? = nil) {
        self.backend = backend
        if let whisperModel { self.whisperModel = whisperModel }
        if let parakeetModel { self.parakeetModel = parakeetModel }
    }

    private enum CodingKeys: String, CodingKey {
        case backend, whisperModel, parakeetModel
    }

    /// Missing or unknown keys fall back to the defaults, as the rest of the
    /// file does; an unknown recognizer name is the default recognizer rather
    /// than a file that cannot be read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpeechSettings()
        backend = (try? c.decodeIfPresent(SpeechBackendID.self, forKey: .backend)) ?? d.backend
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        parakeetModel = try c.decodeIfPresent(String.self, forKey: .parakeetModel) ?? d.parakeetModel
    }

    /// A model id that is not one of its recognizer's is that recognizer's default.
    public func validated() -> SpeechSettings {
        var s = self
        for backend in SpeechBackendID.allCases where backend.downloadsModels {
            let id = s.modelID(for: backend)
            if !backend.models.contains(where: { $0.id == id }), let fallback = SpeechModelCatalog.defaultModel(for: backend) {
                s.setModel(fallback.id, for: backend)
            }
        }
        return s
    }

    /// The model chosen for a recognizer that downloads one; nil for SpeechAnalyzer.
    public func model(for backend: SpeechBackendID) -> SpeechModel? {
        guard backend.downloadsModels else { return nil }
        return SpeechModelCatalog.model(id: modelID(for: backend)).flatMap { $0.backend == backend ? $0 : nil }
            ?? SpeechModelCatalog.defaultModel(for: backend)
    }

    /// The chosen recognizer's model, nil for SpeechAnalyzer.
    public var selectedModel: SpeechModel? { model(for: backend) }

    public func modelID(for backend: SpeechBackendID) -> String {
        switch backend {
        case .speechAnalyzer: ""
        case .whisper: whisperModel
        case .parakeet: parakeetModel
        }
    }

    public mutating func setModel(_ id: String, for backend: SpeechBackendID) {
        switch backend {
        case .speechAnalyzer: break
        case .whisper: whisperModel = id
        case .parakeet: parakeetModel = id
        }
    }
}

/// Where a transcript came from, journaled with the exchange it started so
/// the history can say which recognizer heard the question.
public enum TranscriptOrigin: Codable, Equatable, Sendable {
    /// Typed into the debug panel's Talk back field.
    case typed
    /// Heard by a recognizer: which one, and the model or language it used
    /// (a catalog id for a downloaded model, "SpeechTranscriber en_US" for
    /// SpeechAnalyzer).
    case heard(backend: SpeechBackendID, model: String)

    /// The journal's `heard_by` column.
    public var journalSource: String {
        switch self {
        case .typed: "typed"
        case .heard(let backend, _): backend.rawValue
        }
    }

    /// The journal's `heard_by_model` column.
    public var journalModel: String? {
        switch self {
        case .typed: nil
        case .heard(_, let model): model
        }
    }

    /// Reads the two columns back; nil for a row journaled before they
    /// existed, or one this build does not know.
    public init?(journalSource: String?, model: String?) {
        guard let journalSource else { return nil }
        if journalSource == "typed" {
            self = .typed
        } else if let backend = SpeechBackendID(rawValue: journalSource) {
            self = .heard(backend: backend, model: model ?? "")
        } else {
            return nil
        }
    }

    /// "OpenAI Whisper Base, English", "Apple SpeechAnalyzer, English (US)",
    /// or "Typed".
    public var label: String {
        switch self {
        case .typed:
            return "Typed"
        case .heard(let backend, let model):
            if let known = SpeechModelCatalog.model(id: model), known.backend == backend {
                return known.fullName
            }
            if backend == .speechAnalyzer, let locale = model.split(separator: " ").last.map(String.init), !locale.isEmpty {
                return "\(backend.title), \(SpeechLanguage.name(of: locale))"
            }
            return model.isEmpty ? backend.title : "\(backend.title) \(model)"
        }
    }
}

/// Language names as the interface shows them. Athina's interface is in
/// English, so a language is named in English whatever the Mac's own
/// language is.
public enum SpeechLanguage {
    static let displayLocale = Locale(identifier: "en_US")

    /// "English (US)" for `en_US`.
    public static func name(of identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        guard let language = locale.language.languageCode.flatMap({ displayLocale.localizedString(forLanguageCode: $0.identifier) }) else {
            return identifier
        }
        guard let region = locale.region?.identifier else { return language }
        let regionName = shortRegionNames[region] ?? displayLocale.localizedString(forRegionCode: region) ?? region
        return "\(language) (\(regionName))"
    }

    /// The two regions macOS itself names by their short form in its language lists.
    static let shortRegionNames = ["US": "US", "GB": "UK"]
}

/// Which of a transcriber's locales should hear the Mac's language. Apple's
/// own equivalence (`supportedLocale(equivalentTo:)`) maps a language to a
/// region of its choosing, English in France to South Africa, so it is the
/// last resort: first the language in the Mac's region (`spoken`), then in
/// the region the person gave it in their preferred languages, then in its
/// usual region (English to the US, French to France), then any region of the
/// same language. A language is always matched in the script it is written
/// in, so Chinese in Taiwan or Hong Kong is never heard as mainland Chinese
/// in Simplified characters.
public enum SpeechLocaleChoice {
    /// The language the person speaks, in the Mac's region. An app runs in a
    /// language it is localized in, only English for Athina, so
    /// `Locale.current` reads English in the Mac's region whatever the Mac's
    /// language; the language is the first the person prefers, in its script.
    /// `current` itself when they prefer none.
    public static func spoken(preferredLanguage: String?, current: Locale) -> Locale {
        guard let preferredLanguage else { return current }
        let preferred = Locale.Language(identifier: Locale.Language(identifier: preferredLanguage).maximalIdentifier)
        let language = Locale.Language(languageCode: preferred.languageCode, script: preferred.script, region: current.region)
        return Locale(identifier: language.maximalIdentifier)
    }

    /// Nil when `supported` has nothing in the language and script at all.
    public static func best(for current: Locale, preferredLanguage: String?, supported: [Locale]) -> Locale? {
        let byKey = Dictionary(supported.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var candidates = [key(current)]
        if let preferredLanguage { candidates.append(key(Locale(identifier: preferredLanguage))) }
        let language = written(current)
        if let language {
            candidates.append(key(Locale(identifier: Locale.Language(identifier: language).maximalIdentifier)))
        }
        for candidate in candidates {
            if let match = byKey[candidate] { return match }
        }
        guard let language else { return nil }
        return supported
            .filter { written($0) == language }
            .min { $0.identifier < $1.identifier }
    }

    /// Language, script, and region, which is what tells two locales apart here.
    static func key(_ locale: Locale) -> String {
        [written(locale) ?? locale.identifier, locale.region?.identifier].compactMap { $0 }.joined(separator: "-")
    }

    /// The language and the script it is written in, `zh-Hant` for Taiwan
    /// and `zh-Hans` for the mainland, with the script a region implies
    /// filled in; nil for a locale without a language.
    static func written(_ locale: Locale) -> String? {
        guard let language = locale.language.languageCode?.identifier else { return nil }
        let script = Locale.Language(identifier: locale.language.maximalIdentifier).script?.identifier
        return [language, script].compactMap { $0 }.joined(separator: "-")
    }
}
