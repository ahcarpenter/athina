import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import AthinaCore

@Suite struct SpeechModelCatalogTests {
    /// Every model in the manifest can be fetched exactly as pinned, and
    /// says what it is, what it costs in disk, and whose it is.
    @Test func everyModelIsPinnedAndDescribed() {
        #expect(!SpeechModelCatalog.all.isEmpty)
        #expect(Set(SpeechModelCatalog.all.map(\.id)).count == SpeechModelCatalog.all.count)
        #expect(Set(SpeechModelCatalog.all.map(\.fileName)).count == SpeechModelCatalog.all.count)
        for model in SpeechModelCatalog.all {
            #expect(model.backend.downloadsModels, "\(model.id)")
            #expect(model.sha256.count == 64 && model.sha256.allSatisfy { "0123456789abcdef".contains($0) }, "\(model.id)")
            #expect(model.byteCount > 1_000_000, "\(model.id)")
            #expect(model.url.scheme == "https" && model.url.host() == "huggingface.co", "\(model.id)")
            #expect(model.url.lastPathComponent == model.fileName, "\(model.id)")
            // A commit, not a branch: the bytes behind the checksum never change.
            let revision = model.url.pathComponents.dropLast().last ?? ""
            #expect(revision.count == 40 && revision.allSatisfy(\.isHexDigit), "\(model.id) is not pinned to a commit")
            #expect(model.url.pathComponents.contains("resolve"), "\(model.id)")
            #expect(model.sourcePage.scheme == "https", "\(model.id)")
            #expect(!model.license.isEmpty && !model.credit.isEmpty && !model.languages.isEmpty, "\(model.id)")
            for text in [model.title, model.languages, model.license, model.credit] {
                #expect(!text.contains("\u{2014}"), "\(model.id) has an em dash")
            }
        }
    }

    @Test func eachRecognizerThatDownloadsHasADefaultAmongItsOwnModels() {
        #expect(SpeechModelCatalog.defaultModel(for: .speechAnalyzer) == nil)
        #expect(SpeechBackendID.speechAnalyzer.models.isEmpty)
        for backend in SpeechBackendID.allCases where backend.downloadsModels {
            let model = SpeechModelCatalog.defaultModel(for: backend)
            #expect(model?.backend == backend)
            #expect(backend.models.contains { $0.id == model?.id })
        }
        #expect(SpeechBackendID.whisper.models.count >= 2)
        #expect(SpeechBackendID.parakeet.models.count >= 1)
    }

    @Test func sizesReadInWholeMegabytes() {
        #expect(SpeechModelCatalog.whisperBaseEnglish.sizeText == "148 MB")
        #expect(SpeechModelCatalog.whisperSmallEnglish.sizeText == "488 MB")
        #expect(SpeechModelCatalog.parakeetV3.sizeText == "669 MB")
        #expect(SpeechModel.sizeText(1_255_897_319) == "1.3 GB")
        #expect(SpeechModelCatalog.whisperBaseEnglish.fullName == "OpenAI Whisper Base, English")
    }
}

@Suite struct SpeechSettingsTests {
    @Test func speechAnalyzerIsTheDefault() {
        #expect(SpeechSettings().backend == .speechAnalyzer)
        #expect(SpeechSettings().selectedModel == nil)
        #expect(MentorSettings().speech == SpeechSettings())
    }

    @Test func aSettingsFileWithoutSpeechKeepsTheDefaults() throws {
        let decoded = try JSONDecoder().decode(MentorSettings.self, from: Data(#"{"enabled": true}"#.utf8))
        #expect(decoded.speech == SpeechSettings())
        let partial = try JSONDecoder().decode(SpeechSettings.self, from: Data(#"{"backend": "whisper"}"#.utf8))
        #expect(partial.backend == .whisper)
        #expect(partial.whisperModel == SpeechModelCatalog.whisperBaseEnglish.id)
    }

    /// A recognizer this build does not know is the default recognizer, not
    /// a settings file that cannot be read.
    @Test func anUnknownRecognizerIsTheDefault() throws {
        let decoded = try JSONDecoder().decode(SpeechSettings.self, from: Data(#"{"backend": "somethingElse", "parakeetModel": "x"}"#.utf8))
        #expect(decoded.backend == .speechAnalyzer)
        #expect(decoded.validated().parakeetModel == SpeechModelCatalog.parakeetV3.id)
    }

    @Test func anUnknownModelIsItsRecognizersDefault() {
        var speech = SpeechSettings(backend: .whisper, whisperModel: "whisper-giant", parakeetModel: SpeechModelCatalog.whisperBaseEnglish.id)
        #expect(speech.selectedModel == SpeechModelCatalog.whisperBaseEnglish)
        speech = speech.validated()
        #expect(speech.whisperModel == SpeechModelCatalog.whisperBaseEnglish.id)
        // A model of another recognizer is not this one's.
        #expect(speech.parakeetModel == SpeechModelCatalog.parakeetV3.id)
        #expect(MentorSettings().validated().speech == SpeechSettings())
    }

    @Test func eachRecognizerKeepsItsOwnModel() throws {
        var speech = SpeechSettings()
        speech.setModel(SpeechModelCatalog.whisperLargeTurbo.id, for: .whisper)
        speech.setModel(SpeechModelCatalog.parakeetV3Compact.id, for: .parakeet)
        speech.setModel("ignored", for: .speechAnalyzer)
        speech.backend = .parakeet
        #expect(speech.selectedModel == SpeechModelCatalog.parakeetV3Compact)
        speech.backend = .whisper
        #expect(speech.selectedModel == SpeechModelCatalog.whisperLargeTurbo)
        let round = try JSONDecoder().decode(SpeechSettings.self, from: JSONEncoder().encode(speech))
        #expect(round == speech)
    }

    @Test func originsRoundTripThroughTheJournalColumns() {
        let heard = TranscriptOrigin.heard(backend: .parakeet, model: SpeechModelCatalog.parakeetV3.id)
        #expect(TranscriptOrigin(journalSource: heard.journalSource, model: heard.journalModel) == heard)
        #expect(TranscriptOrigin(journalSource: "typed", model: nil) == .typed)
        #expect(TranscriptOrigin.typed.journalModel == nil)
        #expect(TranscriptOrigin(journalSource: nil, model: nil) == nil)
        #expect(TranscriptOrigin(journalSource: "somethingElse", model: "m") == nil)
    }

    @Test func originsNameTheRecognizerThatHeard() {
        #expect(TranscriptOrigin.typed.label == "Typed")
        #expect(TranscriptOrigin.heard(backend: .whisper, model: SpeechModelCatalog.whisperBaseEnglish.id).label == "OpenAI Whisper Base, English")
        #expect(TranscriptOrigin.heard(backend: .speechAnalyzer, model: "SpeechTranscriber en_US").label == "Apple SpeechAnalyzer, English (US)")
        #expect(TranscriptOrigin.heard(backend: .speechAnalyzer, model: "DictationTranscriber nl_NL").label == "Apple SpeechAnalyzer, Dutch (Netherlands)")
        #expect(TranscriptOrigin.heard(backend: .parakeet, model: "").label == "NVIDIA Parakeet")
    }

    /// The locales SpeechTranscriber listed on the owner's Mac on 2026-09-22.
    static let transcriberLocales = [
        "de_AT", "de_CH", "de_DE", "en_AU", "en_CA", "en_GB", "en_IE", "en_IN", "en_NZ", "en_SG", "en_US", "en_ZA",
        "es_ES", "es_MX", "fr_CA", "fr_FR", "ja_JP", "pt_BR", "zh_CN",
    ].map { Locale(identifier: $0) }

    @Test func theMacsOwnLocaleWinsWhenItIsThere() {
        let choice = SpeechLocaleChoice.best(for: Locale(identifier: "en_GB"), preferredLanguage: "en-US", supported: Self.transcriberLocales)
        #expect(choice?.identifier == "en_GB")
    }

    /// English in a region with no English model of its own is heard as the
    /// English the person prefers, then as the language's usual English,
    /// never a region picked at random.
    @Test func aLanguageWithoutItsRegionFallsBackSensibly() {
        let france = Locale(identifier: "en_FR")
        #expect(SpeechLocaleChoice.best(for: france, preferredLanguage: "en-GB", supported: Self.transcriberLocales)?.identifier == "en_GB")
        #expect(SpeechLocaleChoice.best(for: france, preferredLanguage: nil, supported: Self.transcriberLocales)?.identifier == "en_US")
        #expect(SpeechLocaleChoice.best(for: Locale(identifier: "fr_BE"), preferredLanguage: nil, supported: Self.transcriberLocales)?.identifier == "fr_FR")
        #expect(SpeechLocaleChoice.best(for: Locale(identifier: "pt_PT"), preferredLanguage: nil, supported: Self.transcriberLocales)?.identifier == "pt_BR")
    }

    /// Chinese in Taiwan and Hong Kong is written in Traditional characters,
    /// so SpeechTranscriber's only Chinese, the mainland's in Simplified, is
    /// no match for it, and DictationTranscriber gets to hear it instead.
    @Test func aLanguageIsNeverHeardInAnotherScript() {
        for mac in ["zh_TW", "zh-Hant-TW", "zh_HK", "zh-Hant-HK"] {
            #expect(SpeechLocaleChoice.best(for: Locale(identifier: mac), preferredLanguage: nil, supported: Self.transcriberLocales) == nil, "\(mac)")
        }
        #expect(SpeechLocaleChoice.best(for: Locale(identifier: "zh_TW"), preferredLanguage: "zh-Hans-CN", supported: Self.transcriberLocales)?.identifier == "zh_CN")
        let dictation = ["zh_CN", "zh_HK", "zh_TW"].map { Locale(identifier: $0) }
        #expect(SpeechLocaleChoice.best(for: Locale(identifier: "zh-Hant-TW"), preferredLanguage: nil, supported: dictation)?.identifier == "zh_TW")
        #expect(SpeechLocaleChoice.best(for: Locale(identifier: "zh_MO"), preferredLanguage: nil, supported: dictation)?.identifier == "zh_TW")
        #expect(SpeechLocaleChoice.best(for: Locale(identifier: "zh_CN"), preferredLanguage: nil, supported: Self.transcriberLocales)?.identifier == "zh_CN")
        #expect(SpeechLocaleChoice.best(for: Locale(identifier: "zh_SG"), preferredLanguage: nil, supported: Self.transcriberLocales)?.identifier == "zh_CN")
    }

    @Test func aLanguageNoneOfTheLocalesSpeaksHasNoChoice() {
        #expect(SpeechLocaleChoice.best(for: Locale(identifier: "cy_GB"), preferredLanguage: "cy-GB", supported: Self.transcriberLocales) == nil)
        #expect(SpeechLocaleChoice.best(for: Locale(identifier: "nl_NL"), preferredLanguage: nil, supported: []) == nil)
    }

    @Test func languagesAreNamedInEnglish() {
        #expect(SpeechLanguage.name(of: "en_US") == "English (US)")
        #expect(SpeechLanguage.name(of: "en_GB") == "English (UK)")
        #expect(SpeechLanguage.name(of: "cy_GB") == "Welsh (UK)")
        #expect(SpeechLanguage.name(of: "fr_FR") == "French (France)")
        #expect(SpeechLanguage.name(of: "de") == "German")
    }
}

@Suite struct SpeechReadinessTests {
    @Test func onlyABuiltInOrCheckedModelListens() {
        #expect(SpeechModelState.builtIn.isUsable)
        #expect(SpeechModelState.ready.isUsable)
        for state in [SpeechModelState.notDownloaded, .downloading(fraction: 0.5), .downloading(fraction: nil), .verifying, .failed(reason: "x", canRetry: true)] {
            #expect(!state.isUsable)
        }
        #expect(SpeechModelState.downloading(fraction: 0.2).isBusy && SpeechModelState.verifying.isBusy)
        #expect(!SpeechModelState.ready.isBusy)
    }

    @Test func eachStateOffersItsActions() {
        typealias A = SpeechModelAction
        #expect(A.actions(for: .notDownloaded, backend: .whisper, hasFile: false) == [.download])
        #expect(A.actions(for: .downloading(fraction: 0.4), backend: .whisper, hasFile: false) == [.cancel])
        #expect(A.actions(for: .verifying, backend: .parakeet, hasFile: true).isEmpty)
        #expect(A.actions(for: .ready, backend: .parakeet, hasFile: true) == [.delete])
        #expect(A.actions(for: .failed(reason: "x", canRetry: true), backend: .whisper, hasFile: false) == [.retry])
        #expect(A.actions(for: .failed(reason: "x", canRetry: true), backend: .whisper, hasFile: true) == [.retry, .delete])
        // macOS keeps SpeechAnalyzer's assets: they download from here but
        // are never deleted or stopped from here.
        #expect(A.actions(for: .builtIn, backend: .speechAnalyzer, hasFile: false).isEmpty)
        #expect(A.actions(for: .notDownloaded, backend: .speechAnalyzer, hasFile: false) == [.download])
        #expect(A.actions(for: .downloading(fraction: 0.1), backend: .speechAnalyzer, hasFile: false).isEmpty)
        #expect(A.actions(for: .failed(reason: "unsupported", canRetry: false), backend: .speechAnalyzer, hasFile: false).isEmpty)
        #expect(A.retry.title == "Try Again" && A.delete.title == "Delete")
    }

    /// Every recognizer reports being unusable the same way, and talking
    /// back stays off: nothing falls back to another recognizer.
    @Test func unavailabilityReadsTheSameForEveryRecognizer() {
        let name = SpeechModelCatalog.whisperBaseEnglish.fullName
        #expect(SpeechAvailability.of(backend: .whisper, name: name, state: .ready) == .available(hearing: name))
        #expect(SpeechAvailability.of(backend: .speechAnalyzer, name: "Apple SpeechAnalyzer, English (US)", state: .builtIn).isAvailable)
        guard case .unavailable(let missing, let fixable) = SpeechAvailability.of(backend: .whisper, name: name, state: .notDownloaded) else {
            Issue.record("a missing model must not be available")
            return
        }
        #expect(missing.hasPrefix("\(name) is not downloaded yet, so talking back is off."))
        #expect(fixable)
        guard case .unavailable(let downloading, let fixableWhileDownloading) = SpeechAvailability.of(backend: .parakeet, name: "P", state: .downloading(fraction: 0.425)) else {
            Issue.record("a model still downloading must not be available")
            return
        }
        #expect(downloading.contains("(42%)"))
        #expect(!fixableWhileDownloading)
        guard case .unavailable(let unsupported, let fixableLanguage) = SpeechAvailability.of(
            backend: .speechAnalyzer, name: "Apple SpeechAnalyzer, Welsh (UK)",
            state: .failed(reason: "Apple SpeechAnalyzer cannot hear Welsh (UK) on this Mac.", canRetry: false)
        ) else {
            Issue.record("an unsupported language must not be available")
            return
        }
        #expect(unsupported == "Apple SpeechAnalyzer cannot hear Welsh (UK) on this Mac. Talking back is off. Choose another speech recognizer in Settings > General.")
        #expect(fixableLanguage)
        for state in [SpeechModelState.notDownloaded, .downloading(fraction: nil), .verifying, .failed(reason: "r", canRetry: true)] {
            #expect(!SpeechAvailability.of(backend: .whisper, name: name, state: state).isAvailable)
        }
    }

    @Test func theMenuSaysWhereTalkingBackStands() {
        let name = "OpenAI Whisper Base, English"
        #expect(SpeechAvailability.menuLine(backend: .whisper, name: name, state: .ready) == nil)
        #expect(SpeechAvailability.menuLine(backend: .whisper, name: name, state: .notDownloaded) == "Talk back: \(name) not downloaded")
        #expect(SpeechAvailability.menuLine(backend: .whisper, name: name, state: .downloading(fraction: 0.5)) == "Talk back: downloading \(name), 50%")
        #expect(SpeechAvailability.menuLine(backend: .whisper, name: name, state: .verifying) == "Talk back: checking \(name)")
        #expect(SpeechAvailability.menuLine(backend: .speechAnalyzer, name: "A", state: .failed(reason: "r", canRetry: false)) == "Talk back: A is not available")
    }

    @Test func statesHaveShortLabels() {
        #expect(SpeechModelState.builtIn.label == "Built in")
        #expect(SpeechModelState.downloading(fraction: 0.999).label == "Downloading, 99%")
        #expect(SpeechModelState.downloading(fraction: 1.5).label == "Downloading, 100%")
        #expect(SpeechModelState.failed(reason: "x", canRetry: false).label == "Not available")
        #expect(SpeechModelState.failed(reason: "x", canRetry: true).label == "Failed")
    }
}

/// A small made-up model whose file the tests write themselves.
private func testModel(_ contents: Data, id: String = "whisper-test") -> SpeechModel {
    let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
    return SpeechModel(
        id: id, backend: .whisper, title: "Test", languages: "English", multilingual: false, fileName: "\(id).bin",
        byteCount: Int64(contents.count), sha256: digest,
        url: URL(string: "https://huggingface.co/example/model/resolve/0000000000000000000000000000000000000000/\(id).bin")!,
        sourcePage: URL(string: "https://huggingface.co/example/model")!, license: "MIT", credit: "Tests"
    )
}

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("athina-speech-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct SpeechModelStoreTests {
    let contents = Data((0..<4096).map { UInt8($0 % 251) })

    @Test func aFileIsTrustedOnlyWhileItIsTheOneThatWasChecked() {
        let model = testModel(contents)
        let record = SpeechModelStore.VerifiedRecord(sha256: model.sha256, byteCount: model.byteCount, modified: 100)
        #expect(SpeechModelStore.evaluate(model: model, record: record, size: nil, modified: nil) == .absent)
        #expect(SpeechModelStore.evaluate(model: model, record: record, size: model.byteCount, modified: 100) == .verified)
        #expect(SpeechModelStore.evaluate(model: model, record: nil, size: model.byteCount, modified: 100) == .unchecked)
        #expect(SpeechModelStore.evaluate(model: model, record: record, size: model.byteCount, modified: 101) == .unchecked)
        #expect(SpeechModelStore.evaluate(model: model, record: record, size: 12, modified: 100) == .wrongSize(12))
        var otherChecksum = record
        otherChecksum.sha256 = String(repeating: "0", count: 64)
        #expect(SpeechModelStore.evaluate(model: model, record: otherChecksum, size: model.byteCount, modified: 100) == .unchecked)
    }

    @Test func aDownloadTakesItsPlaceOnlyWhenItMatches() throws {
        let root = try scratchDirectory()
        let store = SpeechModelStore(dataDirectory: root)
        let model = testModel(contents)
        #expect(store.directory.path == root.appendingPathComponent("speech-models").path)
        #expect(store.diskState(of: model) == .absent)

        let wrong = root.appendingPathComponent("wrong.bin")
        var corrupted = contents
        corrupted[10] ^= 0xff
        try corrupted.write(to: wrong)
        #expect(throws: SpeechModelStore.StoreError.checksumMismatch) { try store.install(downloaded: wrong, for: model) }
        #expect(!FileManager.default.fileExists(atPath: wrong.path))
        #expect(store.diskState(of: model) == .absent)

        let short = root.appendingPathComponent("short.bin")
        try contents.prefix(100).write(to: short)
        #expect(throws: SpeechModelStore.StoreError.wrongSize(expected: model.byteCount, got: 100)) { try store.install(downloaded: short, for: model) }
        #expect(store.verifiedFile(for: model) == nil)

        let good = root.appendingPathComponent("good.bin")
        try contents.write(to: good)
        try store.install(downloaded: good, for: model)
        #expect(store.diskState(of: model) == .verified)
        #expect(store.verifiedFile(for: model) == store.fileURL(for: model))
        #expect(store.fileURL(for: model).path.hasSuffix("speech-models/whisper/whisper-test.bin"))
        #expect(try Data(contentsOf: store.fileURL(for: model)) == contents)
    }

    /// A file changed after it was checked is checked again before use, and
    /// kept only when it still matches.
    @Test func aChangedFileIsCheckedAgain() throws {
        let root = try scratchDirectory()
        let store = SpeechModelStore(dataDirectory: root)
        let model = testModel(contents)
        let download = root.appendingPathComponent("download.bin")
        try contents.write(to: download)
        try store.install(downloaded: download, for: model)
        let file = store.fileURL(for: model)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
        #expect(store.diskState(of: model) == .unchecked)
        #expect(try store.verify(model))
        #expect(store.diskState(of: model) == .verified)

        var tampered = contents
        tampered[0] ^= 0x01
        try tampered.write(to: file)
        #expect(store.diskState(of: model) == .unchecked)
        #expect(try !store.verify(model))
        #expect(store.diskState(of: model) == .unchecked)
        #expect(store.verifiedFile(for: model) == nil)
    }

    @Test func deletingRemovesTheFileItsRecordAndAnyPartialDownload() throws {
        let root = try scratchDirectory()
        let store = SpeechModelStore(dataDirectory: root)
        let model = testModel(contents)
        let download = root.appendingPathComponent("download.bin")
        try contents.write(to: download)
        try store.install(downloaded: download, for: model)
        try FileManager.default.createDirectory(at: store.partialURL(for: model).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: store.partialURL(for: model))
        try store.delete(model)
        #expect(store.diskState(of: model) == .absent)
        for url in [store.fileURL(for: model), store.recordURL(for: model), store.partialURL(for: model)] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        // Deleting what is not there is not an error.
        try store.delete(model)
    }

    /// A replay starts with the live models it lacks, copied rather than
    /// moved, and never writes to the live folder.
    @Test func aReplaySeedsItsModelsFromTheLiveOnesWithoutTouchingThem() throws {
        let live = SpeechModelStore(dataDirectory: try scratchDirectory())
        let replay = SpeechModelStore(dataDirectory: try scratchDirectory())
        let checked = testModel(contents)
        let download = live.directory.deletingLastPathComponent().appendingPathComponent("d.bin")
        try contents.write(to: download)
        try live.install(downloaded: download, for: checked)
        let before = try FileManager.default.attributesOfItem(atPath: live.fileURL(for: checked).path)[.modificationDate] as? Date

        #expect(replay.seed(from: live) == [] as [SpeechModel], "only catalog models are seeded")
        // The catalog's own models: one verified live, copied; none other.
        let catalogModel = SpeechModelCatalog.whisperBaseEnglish
        let fake = FakeModelFile(store: live, model: catalogModel)
        try fake.writeVerified()
        #expect(replay.seed(from: live) == [catalogModel])
        #expect(replay.diskState(of: catalogModel) == .verified)
        #expect(live.diskState(of: catalogModel) == .verified)
        #expect(replay.seed(from: live).isEmpty, "a model the replay has is not copied again")
        let after = try FileManager.default.attributesOfItem(atPath: live.fileURL(for: checked).path)[.modificationDate] as? Date
        #expect(before == after)
        #expect(live.seed(from: live).isEmpty)
    }
}

/// Stands a catalog model's file in a store with a record vouching for it,
/// without the hundreds of megabytes: the record is what `diskState` reads,
/// and the file only has to be the right size.
private struct FakeModelFile {
    let store: SpeechModelStore
    let model: SpeechModel

    func writeVerified() throws {
        let url = store.fileURL(for: model)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(model.byteCount))
        try handle.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let record = SpeechModelStore.VerifiedRecord(
            sha256: model.sha256, byteCount: model.byteCount,
            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        )
        try JSONEncoder().encode(record).write(to: store.recordURL(for: model))
    }
}

/// Serves the bytes it was given, in chunks, as a download would arrive.
private struct FakeTransport: ModelFileTransport {
    var contents: Data
    var chunks = 8
    var cancelAfter: Int?

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let size = max(1, contents.count / chunks)
        var written = 0
        var index = 0
        while written < contents.count {
            if let cancelAfter, index == cancelAfter { throw CancellationError() }
            let piece = contents[written..<min(contents.count, written + size)]
            try handle.write(contentsOf: piece)
            written += piece.count
            index += 1
            progress(Int64(written), Int64(contents.count))
        }
    }
}

/// The phases a download reported, in order.
private final class Phases: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [SpeechModelDownloader.Phase] = []
    func append(_ phase: SpeechModelDownloader.Phase) { lock.withLock { seen.append(phase) } }
    var all: [SpeechModelDownloader.Phase] { lock.withLock { seen } }
}

@Suite struct SpeechModelDownloaderTests {
    let contents = Data((0..<8192).map { UInt8(($0 * 7) % 256) })

    @Test func aDownloadReportsProgressThenChecksThenInstalls() async throws {
        let store = SpeechModelStore(dataDirectory: try scratchDirectory())
        let model = testModel(contents)
        let phases = Phases()
        try await SpeechModelDownloader(store: store, transport: FakeTransport(contents: contents)).download(model) { phases.append($0) }
        #expect(phases.all.first == .downloading(nil))
        #expect(phases.all.last == .verifying)
        #expect(phases.all.contains(.downloading(1)))
        #expect(store.diskState(of: model) == .verified)
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(for: model).path))
    }

    @Test func aDownloadThatDoesNotMatchLeavesNothing() async throws {
        let store = SpeechModelStore(dataDirectory: try scratchDirectory())
        var other = contents
        other[0] ^= 0xff
        let model = testModel(contents)
        await #expect(throws: SpeechModelStore.StoreError.checksumMismatch) {
            try await SpeechModelDownloader(store: store, transport: FakeTransport(contents: other)).download(model) { _ in }
        }
        #expect(store.diskState(of: model) == .absent)
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(for: model).path))
    }

    @Test func aCancelledDownloadLeavesNothing() async throws {
        let store = SpeechModelStore(dataDirectory: try scratchDirectory())
        let model = testModel(contents)
        await #expect(throws: CancellationError.self) {
            try await SpeechModelDownloader(store: store, transport: FakeTransport(contents: contents, cancelAfter: 3)).download(model) { _ in }
        }
        #expect(store.diskState(of: model) == .absent)
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(for: model).path))
    }

    /// A connection that fails says which host and why, in a sentence that
    /// reads on its own.
    @Test func aFailedConnectionNamesTheHostAndTheReason() {
        typealias T = URLSessionModelTransport.TransportError
        #expect(T.detail(of: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) == "operation not permitted")
        let offline = T.detail(of: URLError(.notConnectedToInternet))
        #expect(!offline.isEmpty && !offline.hasSuffix(".") && offline.first?.isLowercase == true)
        #expect(T.connection(host: "huggingface.co", detail: "operation not permitted").description == "This Mac could not reach huggingface.co: operation not permitted.")
        #expect(T.status(404).description.hasPrefix("The server answered 404"))
    }

    /// Only a failure to get through to the host says the host could not be
    /// reached, naming the one it was on; any other failure reads as itself.
    @Test func onlyAConnectionThatFailedIsReportedAsOne() {
        typealias T = URLSessionModelTransport.TransportError
        let sandboxed = T.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)), host: "huggingface.co")
        #expect(sandboxed as? T == T.connection(host: "huggingface.co", detail: "operation not permitted"))
        for code in [URLError.Code.cannotConnectToHost, .networkConnectionLost, .timedOut] {
            guard case .connection(let host, _)? = T.classify(URLError(code), host: "cas-bridge.xethub.hf.co") as? T else {
                Issue.record("\(code.rawValue) is a connection that failed")
                continue
            }
            #expect(host == "cas-bridge.xethub.hf.co")
        }
        let fullDisk = T.classify(URLError(.cannotWriteToFile), host: "huggingface.co")
        #expect(fullDisk as? T == nil)
        #expect((fullDisk as? URLError)?.code == .cannotWriteToFile)
        #expect(T.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), host: "huggingface.co") as? T == nil)
    }

    @Test func progressIsReportedAtMostOncePerPercent() {
        let throttle = ProgressThrottle()
        #expect(throttle.advances(to: 0))
        #expect(!throttle.advances(to: 0.004))
        #expect(throttle.advances(to: 0.011))
        #expect(!throttle.advances(to: 0.019))
        #expect(throttle.advances(to: 1))
        #expect(!throttle.advances(to: 1))
    }
}

@Suite struct SpeechAudioTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures/Speech"))
    }

    /// The committed phrases read the way a microphone's audio does: in
    /// short chunks, then converted to the 16 kHz mono whisper.cpp takes.
    @Test func theFixturePhrasesReadAsSpeech() throws {
        for (name, seconds) in [("tell-me-more", 0.92), ("not-now", 0.83), ("which-line", 3.25)] {
            let chunks = try AudioFileChunks(url: try fixture(name))
            #expect(chunks.format.sampleRate == 22_050)
            #expect(abs(chunks.duration - seconds) < 0.05, "\(name)")
            #expect(abs(chunks.chunkDuration - 0.1) < 0.001)
            let samples = try AudioFileChunks.speechSamples(of: try fixture(name))
            #expect(abs(Double(samples.count) / 16_000 - seconds) < 0.05, "\(name)")
            let rms = (samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
            #expect(rms > 0.01, "\(name) is silent")
        }
    }

    @Test func anyInputFormatConvertsToSixteenKilohertzMono() throws {
        let stereo = try #require(AVAudioFormatHelper.stereo48k)
        let buffer = try #require(AVAudioFormatHelper.tone(format: stereo, seconds: 0.5))
        let converter = try #require(PCMConverter(from: stereo))
        var samples = converter.convert(buffer).map(PCMConverter.samples(of:)) ?? []
        samples += converter.flush().map(PCMConverter.samples(of:)) ?? []
        #expect(abs(samples.count - 8000) < 100)
        #expect(converter.outputFormat.channelCount == 1 && converter.outputFormat.sampleRate == 16_000)
    }

    @Test func anUnreadableFileIsAnError() throws {
        let bogus = try scratchDirectory().appendingPathComponent("not-audio.wav")
        try Data("not audio".utf8).write(to: bogus)
        #expect(throws: (any Error).self) { try AudioFileChunks(url: bogus) }
    }
}

private enum AVAudioFormatHelper {
    static let stereo48k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)

    static func tone(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                channels[channel][frame] = 0.3 * sin(Float(frame) * 2 * .pi * 440 / Float(format.sampleRate))
            }
        }
        return buffer
    }
}

@Suite struct TranscriptCleanupTests {
    @Test func soundsThatAreNotSpeechAreDropped() {
        #expect(TranscriptCleanup.clean(" Tell me more.") == "Tell me more.")
        #expect(TranscriptCleanup.clean("[BLANK_AUDIO]") == "")
        #expect(TranscriptCleanup.clean(" (keyboard clicking) Not now. ") == "Not now.")
        #expect(TranscriptCleanup.clean("Which [inaudible] line  do you\nmean?") == "Which line do you mean?")
        #expect(TranscriptCleanup.clean("[nested (sound)] ok") == "ok")
    }

    /// What each recognizer returned for the committed phrases on this Mac
    /// reads as the answer or question it is.
    @Test func theFixturePhrasesMatchWhatTheySay() {
        #expect(TranscriptMatcher.match(TranscriptCleanup.clean(" Tell me more.")) == .answer(.tellMeMore))
        #expect(TranscriptMatcher.match(TranscriptCleanup.clean("Not now.")) == .answer(.notNow))
        let question = "Which line do you mean, and what should I change it to?"
        #expect(TranscriptMatcher.match(TranscriptCleanup.clean(question)) == .question(question))
    }
}

@Suite struct TalkBackRemoteTests {
    @Test func aRequestNamesAnAbsoluteRecording() {
        #expect(TalkBackRemote.file(from: [TalkBackRemote.fileKey: "/tmp/a.wav"]) == .success(URL(fileURLWithPath: "/tmp/a.wav")))
        #expect(TalkBackRemote.file(from: nil) == .failure(ReplayRemote.Refusal(reason: "no file in the request")))
        #expect(TalkBackRemote.file(from: [TalkBackRemote.fileKey: ""]) == .failure(ReplayRemote.Refusal(reason: "no file in the request")))
        #expect(TalkBackRemote.file(from: [TalkBackRemote.fileKey: "a.wav"]) == .failure(ReplayRemote.Refusal(reason: "a.wav is not an absolute path")))
        #expect(TalkBackRemote.replyURL(from: [TalkBackRemote.replyKey: "relative"]) == nil)
        #expect(TalkBackRemote.replyURL(from: [TalkBackRemote.replyKey: "/tmp/r"]) == URL(fileURLWithPath: "/tmp/r"))
    }

    @Test func onlyAReplayListens() {
        #expect(!TalkBackRemote.listens(in: .system))
        #expect(TalkBackRemote.name != ClockRemote.name)
    }

    /// The answer lands only where any replay answer may: a new file in the
    /// temporary directory, outside the live data folder.
    @Test func theAnswerKeepsTheReplayRules() throws {
        let temporary = try scratchDirectory()
        let support = try scratchDirectory()
        let reply = TalkBackRemote.Reply(heard: "Tell me more.", handling: "answered: Tell Me More", backend: "whisper", model: "whisper-base.en", pid: 7)
        let url = temporary.appendingPathComponent("reply.json")
        try ReplayRemote.write(try reply.encoded(), at: url, temporaryDirectory: temporary, supportDirectory: support)
        let decoded = try JSONDecoder().decode(TalkBackRemote.Reply.self, from: Data(contentsOf: url))
        #expect(decoded == reply)
        #expect(throws: ReplayRemote.Refusal.self) {
            try ReplayRemote.write(try reply.encoded(), at: url, temporaryDirectory: temporary, supportDirectory: support)
        }
        #expect(throws: ReplayRemote.Refusal.self) {
            try ReplayRemote.write(try reply.encoded(), at: support.appendingPathComponent("x.json"), temporaryDirectory: temporary, supportDirectory: support)
        }
    }
}

@Suite struct JournalSpeechOriginTests {
    let t0 = Date(timeIntervalSince1970: 1_789_000_000)

    private func suggestion() -> Suggestion {
        Suggestion(
            timestamp: t0, bundleID: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "w", category: .risk,
            title: "t", body: "b", explanation: "e", confidence: 0.9, observationID: nil, model: "m", promptVersion: 10
        )
    }

    /// The recognizer that heard a question, or an answer said aloud, is
    /// journaled with it and read back with it.
    @Test func theRecognizerIsJournaledWithEachExchange() async throws {
        let journal = try Journal.inMemory()
        let stored = try await journal.record(suggestion())
        let whisper = TranscriptOrigin.heard(backend: .whisper, model: SpeechModelCatalog.whisperBaseEnglish.id)
        try await journal.record(FollowUp(suggestionID: stored.id, timestamp: t0, question: "which line", answer: "that one", model: "m", promptVersion: 10, heardBy: whisper))
        try await journal.record(FollowUp(suggestionID: stored.id, timestamp: t0 + 1, question: "typed", answer: "a", model: "m", promptVersion: 10, heardBy: .typed))
        try await journal.record(FollowUp(suggestionID: stored.id, timestamp: t0 + 2, question: "old", answer: "a", model: "m", promptVersion: 10))
        #expect(try await journal.followUps(suggestionID: stored.id).map(\.heardBy) == [whisper, .typed, nil])

        let analyzer = TranscriptOrigin.heard(backend: .speechAnalyzer, model: "SpeechTranscriber en_US")
        let answered = try await journal.updateFeedback(suggestionID: stored.id, feedback: .tellMeMore, at: t0 + 3, heardBy: analyzer)
        #expect(answered?.feedbackHeardBy == analyzer)
        // An answer given with a button carries no recognizer, and clears one.
        let clicked = try await journal.updateFeedback(suggestionID: stored.id, feedback: .notNow, at: t0 + 4)
        #expect(clicked?.feedbackHeardBy == nil)
    }

    /// A journal from before recognizers were journaled gains the columns,
    /// and its rows read back with none.
    @Test func anOlderJournalGainsTheRecognizerColumns() async throws {
        let dir = try scratchDirectory()
        let url = dir.appendingPathComponent("journal.sqlite")
        do {
            let db = try SQLiteConnection(path: url.path)
            try db.execute("""
                CREATE TABLE suggestions (
                    id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, bundle_id TEXT, app_name TEXT NOT NULL, window_title TEXT,
                    category TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, explanation TEXT NOT NULL,
                    confidence REAL NOT NULL, judged_goal TEXT, observation_id INTEGER, model TEXT NOT NULL, prompt_version INTEGER NOT NULL,
                    feedback TEXT, feedback_at REAL, region_json TEXT, callout_shown INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE follow_ups (
                    id INTEGER PRIMARY KEY, suggestion_id INTEGER NOT NULL, timestamp REAL NOT NULL, question TEXT NOT NULL,
                    answer TEXT, error TEXT, model TEXT NOT NULL, prompt_version INTEGER NOT NULL
                );
                INSERT INTO suggestions (timestamp, app_name, category, title, body, explanation, confidence, model, prompt_version, feedback)
                VALUES (1700000000, 'A', 'tool', 'old', 'b', 'e', 0.5, 'm', 9, 'tellMeMore');
                INSERT INTO follow_ups (suggestion_id, timestamp, question, answer, model, prompt_version)
                VALUES (1, 1700000001, 'q', 'a', 'm', 9);
                """)
        }
        let journal = try Journal(url: url)
        #expect(try await journal.recentSuggestions(limit: 5).first?.feedbackHeardBy == nil)
        #expect(try await journal.followUps(suggestionID: 1).first?.heardBy == nil)
        let heard = TranscriptOrigin.heard(backend: .parakeet, model: SpeechModelCatalog.parakeetV3.id)
        try await journal.record(FollowUp(suggestionID: 1, timestamp: t0, question: "new", answer: "a", model: "m", promptVersion: 10, heardBy: heard))
        #expect(try await journal.followUps(suggestionID: 1).last?.heardBy == heard)
    }
}
