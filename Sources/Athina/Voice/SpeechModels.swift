import AthinaCore
import Foundation
import Observation
import OSLog
import Speech

/// Every recognizer's state on this Mac, for the Settings picker, the menu,
/// and a press of the talk-back key: SpeechAnalyzer's language assets, which
/// macOS keeps, and each downloadable model, which Athina keeps in its own
/// data directory (`SpeechModelStore`). Downloads, checks, and deletes run
/// from here, one at a time per model.
@MainActor
@Observable
final class SpeechModels {
    private static let log = Logger(subsystem: "com.ahcarpenter.athina", category: "voice")

    let store: SpeechModelStore
    /// Each downloadable model's state, by id.
    private(set) var states: [String: SpeechModelState] = [:] {
        didSet { if states != oldValue { onChange?() } }
    }
    /// The language SpeechAnalyzer hears the Mac's language in, nil until
    /// macOS has said, or when it has none.
    private(set) var analyzerLanguage: AnalyzerLanguage?
    /// SpeechAnalyzer's state for that language; nil until macOS has said.
    private(set) var analyzerState: SpeechModelState? {
        didSet { if analyzerState != oldValue { onChange?() } }
    }
    /// Called whenever a state changes, so what depends on talking back
    /// being usable can follow.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Where downloads fetch from; a test or a render never fetches.
    @ObservationIgnored private let downloader: SpeechModelDownloader
    @ObservationIgnored private var work: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let isSample: Bool
    /// The Mac's language, which SpeechAnalyzer and a multilingual Whisper
    /// are asked to hear.
    @ObservationIgnored private let macLanguage: Locale
    private static let analyzerKey = "speechAnalyzer"

    init(store: SpeechModelStore) {
        self.store = store
        downloader = SpeechModelDownloader(store: store)
        isSample = false
        macLanguage = SpeechLocaleChoice.spoken(preferredLanguage: Locale.preferredLanguages.first, current: .current)
        for model in SpeechModelCatalog.all {
            states[model.id] = .notDownloaded
        }
    }

    /// A still picture for snapshots: the states given, nothing on disk read
    /// and nothing ever fetched.
    /// A language SpeechAnalyzer does not hear is given with `analyzer`
    /// failed, and then has no module.
    init(sampleStates: [String: SpeechModelState], analyzer: SpeechModelState = .builtIn, language: String = "en_US") {
        store = SpeechModelStore(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("athina-sample-speech"))
        downloader = SpeechModelDownloader(store: store)
        isSample = true
        macLanguage = Locale(identifier: language)
        for model in SpeechModelCatalog.all {
            states[model.id] = sampleStates[model.id] ?? .notDownloaded
        }
        if case .failed(_, canRetry: false) = analyzer {
            analyzerLanguage = nil
        } else {
            analyzerLanguage = AnalyzerLanguage(module: .transcriber, locale: Locale(identifier: language))
        }
        analyzerState = analyzer
    }

    // MARK: Reading

    func state(of model: SpeechModel) -> SpeechModelState {
        states[model.id] ?? .notDownloaded
    }

    /// What `settings` chose, in its current state.
    func state(for settings: SpeechSettings) -> SpeechModelState {
        if let model = settings.selectedModel { return state(of: model) }
        return analyzerState ?? .verifying
    }

    /// "OpenAI Whisper Base, English", or "Apple SpeechAnalyzer, English (US)".
    func name(for settings: SpeechSettings) -> String {
        if let model = settings.selectedModel { return model.fullName }
        return "\(SpeechBackendID.speechAnalyzer.title), \(analyzerLanguageName)"
    }

    /// The language SpeechAnalyzer hears in: the closest one it has to the
    /// Mac's language, or the Mac's own when it has none.
    var analyzerLanguageName: String {
        analyzerLanguage?.languageName ?? SpeechLanguage.name(of: macLanguage.identifier)
    }

    func availability(for settings: SpeechSettings) -> SpeechAvailability {
        if settings.backend == .speechAnalyzer, analyzerState == nil {
            return .unavailable(reason: "Athina is still asking macOS which languages Apple SpeechAnalyzer hears on this Mac.", fixable: false)
        }
        return SpeechAvailability.of(backend: settings.backend, name: name(for: settings), state: state(for: settings))
    }

    func menuLine(for settings: SpeechSettings) -> String? {
        SpeechAvailability.menuLine(backend: settings.backend, name: name(for: settings), state: state(for: settings))
    }

    /// Whether a file for the model is on disk, checked or not.
    func hasFile(_ model: SpeechModel) -> Bool {
        !isSample && FileManager.default.fileExists(atPath: store.fileURL(for: model).path)
    }

    /// The recognizer `settings` chose, ready to listen; nil when it cannot.
    func backend(for settings: SpeechSettings) -> (any SpeechBackend)? {
        guard !isSample else { return nil }
        if let model = settings.selectedModel {
            guard state(of: model) == .ready, let file = store.verifiedFile(for: model) else {
                // Changed on disk since it was checked: check it again.
                refresh(model)
                return nil
            }
            return WhisperCppBackend(model: model, file: file, language: macLanguage)
        }
        guard analyzerState == .builtIn, let analyzerLanguage else { return nil }
        return SpeechAnalyzerBackend(language: analyzerLanguage)
    }

    // MARK: Refreshing

    /// Reads every model's state from disk, checking any file that has not
    /// been checked, and asks macOS about SpeechAnalyzer.
    func refresh() {
        guard !isSample else { return }
        for model in SpeechModelCatalog.all {
            refresh(model)
        }
        refreshAnalyzer()
    }

    private func refresh(_ model: SpeechModel) {
        guard work[model.id] == nil else { return }
        switch store.diskState(of: model) {
        case .absent:
            states[model.id] = .notDownloaded
        case .verified:
            states[model.id] = .ready
        case .wrongSize:
            states[model.id] = .failed(reason: "The file on this Mac is not the size its manifest gives.", canRetry: true)
        case .unchecked:
            verify(model)
        }
    }

    func refreshAnalyzer() {
        guard !isSample, work[SpeechModels.analyzerKey] == nil else { return }
        Task {
            let language = await AnalyzerLanguage.resolve(for: macLanguage)
            let state: SpeechModelState = if let language {
                await language.assetState()
            } else {
                .failed(reason: SpeechModels.unsupported(macLanguage), canRetry: false)
            }
            guard work[SpeechModels.analyzerKey] == nil else { return }
            analyzerLanguage = language
            analyzerState = state
        }
    }

    // MARK: Acting

    func perform(_ action: SpeechModelAction, on model: SpeechModel) {
        switch action {
        case .download, .retry: download(model)
        case .cancel: cancel(model)
        case .delete: delete(model)
        }
    }

    func download(_ model: SpeechModel) {
        guard !isSample, work[model.id] == nil else { return }
        SpeechModels.log.notice("downloading \(model.id, privacy: .public) from \(model.url.host() ?? "", privacy: .public)")
        states[model.id] = .downloading(fraction: nil)
        let downloader = downloader
        let started = Date()
        work[model.id] = Task { [weak self] in
            // The downloader reports from URLSession's queue. Its reports
            // come here through one stream, in the order they were made, so
            // a late one never puts back a state already passed.
            let (phases, sink) = AsyncStream.makeStream(of: SpeechModelDownloader.Phase.self)
            let transfer = Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                defer { sink.finish() }
                do {
                    try await downloader.download(model) { sink.yield($0) }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            for await phase in phases {
                guard let self, self.work[model.id] != nil else { break }
                switch phase {
                case .downloading(let fraction): self.states[model.id] = .downloading(fraction: fraction)
                case .verifying: self.states[model.id] = .verifying
                }
            }
            let result = await withTaskCancellationHandler {
                await transfer.value
            } onCancel: {
                transfer.cancel()
            }
            let outcome: SpeechModelState
            switch result {
            case .success:
                outcome = .ready
                SpeechModels.log.notice("downloaded and checked \(model.id, privacy: .public) (\(model.byteCount) bytes) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            case .failure(let error) where error is CancellationError || (error as? URLError)?.code == .cancelled:
                outcome = .notDownloaded
                SpeechModels.log.notice("download of \(model.id, privacy: .public) cancelled")
            case .failure(let error):
                outcome = .failed(reason: SpeechModels.describe(error), canRetry: true)
                SpeechModels.log.error("download of \(model.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            guard let self else { return }
            self.work[model.id] = nil
            self.states[model.id] = outcome
        }
    }

    func cancel(_ model: SpeechModel) {
        work[model.id]?.cancel()
    }

    func delete(_ model: SpeechModel) {
        guard !isSample, work[model.id] == nil else { return }
        do {
            try store.delete(model)
            states[model.id] = .notDownloaded
            SpeechModels.log.notice("deleted \(model.id, privacy: .public)")
        } catch {
            states[model.id] = .failed(reason: "The file could not be deleted: \(error.localizedDescription)", canRetry: false)
        }
    }

    /// Hashes a file that has not been checked here, on a background thread.
    private func verify(_ model: SpeechModel) {
        guard work[model.id] == nil else { return }
        states[model.id] = .verifying
        let store = store
        work[model.id] = Task { [weak self] in
            let matches = await Task.detached(priority: .utility) { (try? store.verify(model)) ?? false }.value
            guard let self else { return }
            self.work[model.id] = nil
            self.states[model.id] = matches
                ? .ready
                : .failed(reason: "The file on this Mac does not match its published checksum.", canRetry: true)
        }
    }

    /// Has macOS download SpeechAnalyzer's assets for the Mac's language,
    /// showing the progress the system reports.
    func downloadAnalyzerAssets() {
        guard !isSample, work[SpeechModels.analyzerKey] == nil, let language = analyzerLanguage else { return }
        analyzerState = .downloading(fraction: nil)
        work[SpeechModels.analyzerKey] = Task { [weak self] in
            var outcome: SpeechModelState
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [language.makeModule()]) {
                    let progress = request.progress
                    // The system reports progress on its own; this reads it
                    // for the row while the download runs.
                    let poll = Task { [weak self] in
                        while !Task.isCancelled {
                            self?.analyzerState = .downloading(fraction: progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                    defer { poll.cancel() }
                    try await request.downloadAndInstall()
                }
                outcome = await language.assetState()
            } catch {
                outcome = .failed(reason: "macOS could not download Apple SpeechAnalyzer for \(language.languageName): \(error.localizedDescription)", canRetry: true)
            }
            guard let self else { return }
            self.work[SpeechModels.analyzerKey] = nil
            self.analyzerState = outcome
        }
    }

    /// Why SpeechAnalyzer cannot serve a language.
    static func unsupported(_ language: Locale) -> String {
        "Apple SpeechAnalyzer cannot hear \(SpeechLanguage.name(of: language.identifier)) on this Mac."
    }

    /// A failed download, in a sentence for the row.
    private static func describe(_ error: Error) -> String {
        if let error = error as? SpeechModelStore.StoreError { return error.description }
        if let error = error as? URLSessionModelTransport.TransportError { return "The download failed. \(error.description)" }
        return "The download failed: \(error.localizedDescription)"
    }
}
