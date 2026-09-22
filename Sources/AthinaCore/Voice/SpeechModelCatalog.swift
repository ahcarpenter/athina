import Foundation

/// The recognizers talking back can use. Every one runs on this Mac and none
/// sends audio anywhere; they differ in where their model comes from.
/// SpeechAnalyzer is Apple's own, built into macOS, and the default. Whisper
/// and Parakeet are free open models that Athina downloads on request and
/// runs with whisper.cpp.
///
/// The raw values are what the settings file and the journal store, so a
/// rename is a migration.
public enum SpeechBackendID: String, Codable, CaseIterable, Sendable, Identifiable {
    case speechAnalyzer
    case whisper
    case parakeet

    public var id: String { rawValue }

    /// The name the picker and the history show.
    public var title: String {
        switch self {
        case .speechAnalyzer: "Apple SpeechAnalyzer"
        case .whisper: "OpenAI Whisper"
        case .parakeet: "NVIDIA Parakeet"
        }
    }

    /// The model choices, for a recognizer whose model Athina downloads;
    /// empty for SpeechAnalyzer, whose language assets macOS manages.
    public var models: [SpeechModel] { SpeechModelCatalog.models(for: self) }

    /// Whether Athina downloads and keeps this recognizer's model itself.
    public var downloadsModels: Bool { !models.isEmpty }
}

/// One downloadable model: a single file, fetched from a pinned revision and
/// checked against its SHA-256 before it is ever loaded (`SpeechModelStore`).
public struct SpeechModel: Equatable, Hashable, Sendable, Identifiable {
    /// Stable, and stored in the settings and the journal.
    public var id: String
    public var backend: SpeechBackendID
    /// "Base, English": the model's own name and what it hears.
    public var title: String
    /// Every language it transcribes, for the settings row.
    public var languages: String
    /// Whether it hears languages other than English, so the recognizer is
    /// told which language to expect.
    public var multilingual: Bool
    public var fileName: String
    public var byteCount: Int64
    /// Lowercase hex SHA-256 of the whole file, the value Hugging Face
    /// publishes for it, which a download must match before it is used.
    public var sha256: String
    /// The file at one commit of its repository, so the bytes behind the
    /// checksum never change under it.
    public var url: URL
    /// The model card.
    public var sourcePage: URL
    public var license: String
    /// Who made the weights and who converted them.
    public var credit: String

    public init(
        id: String, backend: SpeechBackendID, title: String, languages: String, multilingual: Bool, fileName: String,
        byteCount: Int64, sha256: String, url: URL, sourcePage: URL, license: String, credit: String
    ) {
        self.id = id
        self.backend = backend
        self.title = title
        self.languages = languages
        self.multilingual = multilingual
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.url = url
        self.sourcePage = sourcePage
        self.license = license
        self.credit = credit
    }

    /// "OpenAI Whisper Base, English".
    public var fullName: String { "\(backend.title) \(title)" }

    /// "148 MB", in the decimal units Finder counts in, to the nearest
    /// megabyte so every row reads alike.
    public var sizeText: String {
        SpeechModel.sizeText(byteCount)
    }

    public static func sizeText(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1000 {
            return (megabytes / 1000).formatted(.number.precision(.fractionLength(1))) + " GB"
        }
        return megabytes.formatted(.number.precision(.fractionLength(0))) + " MB"
    }
}

/// The manifest of every model talking back can download: size, source,
/// license, and checksum, each pinned to one revision of its repository.
/// The sizes and checksums were read from the Hugging Face API for those
/// revisions on `checkedOn`, and every file was downloaded and hashed on that
/// day; `SpeechModelCatalogTests` holds the table to its rules. Weights are
/// never committed to the repository.
public enum SpeechModelCatalog {
    public static let checkedOn = "2026-09-22"

    /// ggerganov/whisper.cpp, the conversions of OpenAI's weights the
    /// whisper.cpp project publishes.
    static let whisperRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    /// ggml-org/parakeet-GGUF, the whisper.cpp project's conversions of
    /// NVIDIA's Parakeet TDT 0.6B v3.
    static let parakeetRevision = "35156454d1a39de06863303dd209fd2bed6ee079"

    static let whisperCredit = "Weights by OpenAI, converted to ggml by the whisper.cpp project"
    static let parakeetCredit = "Weights by NVIDIA (CC BY 4.0), converted to ggml by the whisper.cpp project"
    static let parakeetLanguages = "25 European languages, English included"

    private static func whisper(_ name: String, id: String, title: String, languages: String, multilingual: Bool, bytes: Int64, sha256: String) -> SpeechModel {
        SpeechModel(
            id: id, backend: .whisper, title: title, languages: languages, multilingual: multilingual,
            fileName: "ggml-\(name).bin", byteCount: bytes, sha256: sha256,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(whisperRevision)/ggml-\(name).bin")!,
            sourcePage: URL(string: "https://huggingface.co/ggerganov/whisper.cpp")!,
            license: "MIT", credit: whisperCredit
        )
    }

    private static func parakeet(_ quantization: String, id: String, title: String, bytes: Int64, sha256: String) -> SpeechModel {
        SpeechModel(
            id: id, backend: .parakeet, title: title, languages: parakeetLanguages, multilingual: true,
            fileName: "ggml-parakeet-tdt-0.6b-v3-\(quantization).bin", byteCount: bytes, sha256: sha256,
            url: URL(string: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/\(parakeetRevision)/ggml-parakeet-tdt-0.6b-v3-\(quantization).bin")!,
            sourcePage: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!,
            license: "CC BY 4.0", credit: parakeetCredit
        )
    }

    public static let whisperBaseEnglish = whisper(
        "base.en", id: "whisper-base.en", title: "Base, English", languages: "English", multilingual: false,
        bytes: 147_964_211, sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
    )
    public static let whisperSmallEnglish = whisper(
        "small.en", id: "whisper-small.en", title: "Small, English", languages: "English", multilingual: false,
        bytes: 487_614_201, sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
    )
    public static let whisperLargeTurbo = whisper(
        "large-v3-turbo-q5_0", id: "whisper-large-v3-turbo-q5_0", title: "Large v3 Turbo, 99 languages",
        languages: "99 languages, English included", multilingual: true,
        bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    )
    public static let parakeetV3 = parakeet(
        "q8_0", id: "parakeet-tdt-0.6b-v3-q8_0", title: "TDT 0.6B v3",
        bytes: 668_757_119, sha256: "4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e"
    )
    public static let parakeetV3Compact = parakeet(
        "q4_k", id: "parakeet-tdt-0.6b-v3-q4_k", title: "TDT 0.6B v3, compact",
        bytes: 415_611_879, sha256: "8b205b8b39c6535e153de6fb11c51db46125d45c4f16ba496fe41a0fe71b885e"
    )

    public static let all: [SpeechModel] = [
        whisperBaseEnglish, whisperSmallEnglish, whisperLargeTurbo, parakeetV3, parakeetV3Compact,
    ]

    public static func models(for backend: SpeechBackendID) -> [SpeechModel] {
        all.filter { $0.backend == backend }
    }

    public static func model(id: String) -> SpeechModel? {
        all.first { $0.id == id }
    }

    /// The model a recognizer starts with: the smallest that hears English
    /// well, since a talk-back phrase is a few words.
    public static func defaultModel(for backend: SpeechBackendID) -> SpeechModel? {
        switch backend {
        case .speechAnalyzer: nil
        case .whisper: whisperBaseEnglish
        case .parakeet: parakeetV3
        }
    }
}
