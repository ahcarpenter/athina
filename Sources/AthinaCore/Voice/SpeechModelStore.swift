import CryptoKit
import Foundation

/// The downloaded speech models on disk: `speech-models` inside a launch's
/// data directory, one folder per recognizer, one file per model. A model
/// reaches its place only after its whole file matched the manifest's
/// SHA-256 (`install`), and each one carries a small record of that check
/// beside it, so a later launch trusts the file without hashing it again for
/// as long as its size and modification date are the ones the check saw, and
/// hashes it again the moment either differs.
///
/// A live launch keeps models in `~/Library/Application Support/athina/speech-models`.
/// A replay keeps its own inside its per-launch directory, and starts with
/// copies of the live ones (`seed`), which on APFS cost no time and no disk:
/// the live folder is only ever read from a replay.
public struct SpeechModelStore: Equatable, Sendable {
    public static let directoryName = "speech-models"

    public let directory: URL

    public init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent(SpeechModelStore.directoryName, isDirectory: true)
    }

    /// Where the model's file lives once it is installed.
    public func fileURL(for model: SpeechModel) -> URL {
        directory
            .appendingPathComponent(model.backend.rawValue, isDirectory: true)
            .appendingPathComponent(model.fileName, isDirectory: false)
    }

    func recordURL(for model: SpeechModel) -> URL {
        fileURL(for: model).appendingPathExtension("verified")
    }

    /// Where a download is assembled before it is checked. Never the file's
    /// own place, so nothing half written or unchecked is ever loaded.
    func partialURL(for model: SpeechModel) -> URL {
        directory.appendingPathComponent(".partial", isDirectory: true).appendingPathComponent(model.fileName)
    }

    // MARK: State on disk

    /// What was proven about a file, kept beside it.
    struct VerifiedRecord: Codable, Equatable {
        var sha256: String
        var byteCount: Int64
        var modified: TimeInterval
    }

    /// What the disk says about a model, without hashing anything.
    public enum DiskState: Equatable, Sendable {
        case absent
        /// Checked, and unchanged since.
        case verified
        /// There, but not proven to be the manifest's file: never checked
        /// here, or changed since it was.
        case unchecked
        /// There and the wrong size, so it cannot be the manifest's file.
        case wrongSize(Int64)
    }

    public func diskState(of model: SpeechModel) -> DiskState {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL(for: model).path)
        let record = (try? Data(contentsOf: recordURL(for: model))).flatMap { try? JSONDecoder().decode(VerifiedRecord.self, from: $0) }
        return SpeechModelStore.evaluate(
            model: model, record: record,
            size: (attributes?[.size] as? NSNumber)?.int64Value,
            modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        )
    }

    /// The rule `diskState` applies: a file is trusted only while it is the
    /// size the manifest says, and the record beside it vouches for the
    /// manifest's checksum at the size and modification date it has now.
    static func evaluate(model: SpeechModel, record: VerifiedRecord?, size: Int64?, modified: TimeInterval?) -> DiskState {
        guard let size else { return .absent }
        guard size == model.byteCount else { return .wrongSize(size) }
        guard let record, let modified,
              record.sha256 == model.sha256, record.byteCount == size, record.modified == modified
        else { return .unchecked }
        return .verified
    }

    /// The file to load, only when it is verified.
    public func verifiedFile(for model: SpeechModel) -> URL? {
        diskState(of: model) == .verified ? fileURL(for: model) : nil
    }

    // MARK: Checking, installing, and deleting

    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case wrongSize(expected: Int64, got: Int64)
        case checksumMismatch
        case missing

        public var description: String {
            switch self {
            case .wrongSize(let expected, let got):
                "The download was \(ByteCountFormatter.string(fromByteCount: got, countStyle: .file)) where \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)) was expected."
            case .checksumMismatch:
                "The download does not match its published checksum, so it was not kept."
            case .missing:
                "The downloaded file is gone."
            }
        }
    }

    /// Hashes the installed file and records the result when it matches the
    /// manifest. False, with nothing recorded, when it does not.
    @discardableResult
    public func verify(_ model: SpeechModel, progress: (@Sendable (Double) -> Void)? = nil) throws -> Bool {
        let url = fileURL(for: model)
        let digest = try SpeechModelStore.sha256(of: url, byteCount: model.byteCount, progress: progress)
        guard digest == model.sha256 else {
            try? FileManager.default.removeItem(at: recordURL(for: model))
            return false
        }
        try writeRecord(for: model)
        return true
    }

    /// Checks a finished download against the manifest and, only when it
    /// matches, moves it into the model's place with its record. A file that
    /// does not match is deleted, never kept.
    public func install(downloaded file: URL, for model: SpeechModel, progress: (@Sendable (Double) -> Void)? = nil) throws {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value else {
            throw StoreError.missing
        }
        guard size == model.byteCount else { throw StoreError.wrongSize(expected: model.byteCount, got: size) }
        guard try SpeechModelStore.sha256(of: file, byteCount: size, progress: progress) == model.sha256 else {
            throw StoreError.checksumMismatch
        }
        let destination = fileURL(for: model)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: recordURL(for: model))
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: destination)
        }
        try writeRecord(for: model)
    }

    /// Removes the model's file, its record, and any download of it left
    /// half done.
    public func delete(_ model: SpeechModel) throws {
        for url in [recordURL(for: model), fileURL(for: model), partialURL(for: model)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func writeRecord(for model: SpeechModel) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL(for: model).path)
        let record = VerifiedRecord(
            sha256: model.sha256,
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        )
        try JSONEncoder().encode(record).write(to: recordURL(for: model), options: .atomic)
    }

    /// Streams the file through SHA-256 without reading it into memory.
    static func sha256(of url: URL, byteCount: Int64, progress: (@Sendable (Double) -> Void)?) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var read: Int64 = 0
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            read += Int64(chunk.count)
            progress?(byteCount > 0 ? Double(read) / Double(byteCount) : 0)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: A replay's copies

    /// Copies every verified model of `source` that this store lacks, records
    /// and all, and never writes to `source`. A replay's store is seeded this
    /// way from the live one, so a model downloaded once serves every replay
    /// after it. On APFS a copy is a clone: no time and no disk. Returns the
    /// models copied.
    @discardableResult
    public func seed(from source: SpeechModelStore) -> [SpeechModel] {
        guard source.directory != directory else { return [] }
        var copied: [SpeechModel] = []
        for model in SpeechModelCatalog.all where diskState(of: model) == .absent && source.diskState(of: model) == .verified {
            let destination = fileURL(for: model)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source.fileURL(for: model), to: destination)
                try FileManager.default.copyItem(at: source.recordURL(for: model), to: recordURL(for: model))
                copied.append(model)
            } catch {
                try? delete(model)
            }
        }
        return copied
    }
}
