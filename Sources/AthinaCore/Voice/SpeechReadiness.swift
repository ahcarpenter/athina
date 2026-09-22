import Foundation

/// Where a recognizer's model stands on this Mac: the one state model the
/// Settings picker, the menu, and a press of the talk-back key all read, for
/// every recognizer alike.
public enum SpeechModelState: Equatable, Sendable {
    /// Part of macOS and installed: SpeechAnalyzer for a language whose
    /// assets are on this Mac.
    case builtIn
    /// Not on this Mac yet: a downloadable model, or SpeechAnalyzer's assets
    /// for a language macOS supports but has not installed.
    case notDownloaded
    /// On its way; the fraction done, nil until the size is known.
    case downloading(fraction: Double?)
    /// Downloaded, and being checked against its published checksum before
    /// it is used.
    case verifying
    /// Downloaded and checked.
    case ready
    /// Cannot be used, and why, in a sentence; `canRetry` when doing it
    /// again could help (a download that broke off), not when it cannot (a
    /// language SpeechAnalyzer does not support).
    case failed(reason: String, canRetry: Bool)

    /// Whether talking back can use the recognizer in this state.
    public var isUsable: Bool {
        switch self {
        case .builtIn, .ready: true
        case .notDownloaded, .downloading, .verifying, .failed: false
        }
    }

    /// A download is running, or its file is being checked.
    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying: true
        case .builtIn, .notDownloaded, .ready, .failed: false
        }
    }

    /// The short word or phrase a row shows beside the model's name.
    public var label: String {
        switch self {
        case .builtIn: "Built in"
        case .notDownloaded: "Not downloaded"
        case .downloading(let fraction?): "Downloading, \(SpeechModelState.percent(fraction))"
        case .downloading(nil): "Downloading"
        case .verifying: "Checking the download"
        case .ready: "Ready"
        case .failed(_, let canRetry): canRetry ? "Failed" : "Not available"
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction.clamped(to: 0...1) * 100).rounded(.down)))%"
    }
}

/// What a row in Settings offers for a model in a given state. Pure, so the
/// rule that a model is never deleted mid-download, and that macOS's own
/// language assets are never deleted from here, is tested rather than
/// scattered through the view.
public enum SpeechModelAction: Equatable, Sendable {
    case download
    /// A failed download or check, tried again.
    case retry
    case cancel
    case delete

    public var title: String {
        switch self {
        case .download: "Download"
        case .retry: "Try Again"
        case .cancel: "Cancel"
        case .delete: "Delete"
        }
    }

    /// `hasFile` is whether a file is on disk for the model, which a failed
    /// check leaves behind; macOS manages SpeechAnalyzer's assets itself, so
    /// nothing here deletes them.
    public static func actions(for state: SpeechModelState, backend: SpeechBackendID, hasFile: Bool) -> [SpeechModelAction] {
        switch state {
        case .builtIn, .verifying:
            return []
        case .notDownloaded:
            return [.download]
        case .downloading:
            // SpeechAnalyzer's assets download in the system, which offers
            // no way to stop one from outside.
            return backend.downloadsModels ? [.cancel] : []
        case .ready:
            return backend.downloadsModels ? [.delete] : []
        case .failed(_, let canRetry):
            return (canRetry ? [.retry] : []) + (backend.downloadsModels && hasFile ? [.delete] : [])
        }
    }
}

/// Whether talking back can listen right now with the chosen recognizer, and
/// if not, why: the same report for every recognizer, so a model that is not
/// downloaded reads exactly like a language SpeechAnalyzer does not support.
/// Talking back is then off; nothing falls back to another recognizer.
public enum SpeechAvailability: Equatable, Sendable {
    /// Ready, with what will hear the person: "OpenAI Whisper Base, English".
    case available(hearing: String)
    /// Off, with the sentence Settings and a key press show, and whether a
    /// change in Settings would fix it (so the menu offers Set Up Talk Back).
    case unavailable(reason: String, fixable: Bool)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// For the chosen recognizer in `state`. `name` is what the person chose:
    /// the model's full name, or SpeechAnalyzer with its language.
    public static func of(backend: SpeechBackendID, name: String, state: SpeechModelState) -> SpeechAvailability {
        switch state {
        case .builtIn, .ready:
            return .available(hearing: name)
        case .notDownloaded:
            return .unavailable(
                reason: "\(name) is not downloaded yet, so talking back is off. Download it in Settings > General, or choose another speech recognizer there.",
                fixable: true
            )
        case .downloading(let fraction):
            let progress = fraction.map { " (\(SpeechModelState.percent($0)))" } ?? ""
            return .unavailable(reason: "\(name) is still downloading\(progress), so talking back is off until it finishes.", fixable: false)
        case .verifying:
            return .unavailable(reason: "\(name) is being checked against its published checksum, so talking back is off until that finishes.", fixable: false)
        case .failed(let reason, _):
            let fix = backend.downloadsModels
                ? "Try the download again in Settings > General, or choose another speech recognizer there."
                : "Choose another speech recognizer in Settings > General."
            return .unavailable(reason: "\(reason) Talking back is off. \(fix)", fixable: true)
        }
    }

    /// The menu's one line: how talking back stands, in a few words.
    public static func menuLine(backend: SpeechBackendID, name: String, state: SpeechModelState) -> String? {
        switch state {
        case .builtIn, .ready: nil
        case .notDownloaded: "Talk back: \(name) not downloaded"
        case .downloading(let fraction?): "Talk back: downloading \(name), \(SpeechModelState.percent(fraction))"
        case .downloading(nil): "Talk back: downloading \(name)"
        case .verifying: "Talk back: checking \(name)"
        case .failed: backend.downloadsModels ? "Talk back: \(name) cannot be used" : "Talk back: \(name) is not available"
        }
    }
}
