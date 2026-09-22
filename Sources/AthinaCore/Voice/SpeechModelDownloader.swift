import Foundation

/// Fetches one model file. The only network use in Athina besides the model
/// tiers' calls to Anthropic, and only when the person presses Download: it
/// sends the file's address and nothing else.
public protocol ModelFileTransport: Sendable {
    /// Downloads `url` into a file at `destination`, reporting the bytes
    /// written so far and the total when the server says it. Throws
    /// `CancellationError` when the calling task is cancelled.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
}

/// Downloads, checks, and installs speech models: the file goes to a
/// partial path, is checked against the manifest's size and SHA-256, and only
/// then takes the model's place (`SpeechModelStore.install`). A cancelled or
/// failed download leaves nothing behind.
public struct SpeechModelDownloader: Sendable {
    public enum Phase: Equatable, Sendable {
        /// Bytes arriving; the fraction of the file, nil until its size is known.
        case downloading(Double?)
        /// The whole file is here and being hashed.
        case verifying
    }

    let store: SpeechModelStore
    let transport: any ModelFileTransport

    public init(store: SpeechModelStore, transport: any ModelFileTransport = URLSessionModelTransport()) {
        self.store = store
        self.transport = transport
    }

    public func download(_ model: SpeechModel, phase: @escaping @Sendable (Phase) -> Void) async throws {
        let partial = store.partialURL(for: model)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        do {
            phase(.downloading(nil))
            let reported = ProgressThrottle()
            try await transport.download(model.url, to: partial) { written, total in
                let expected = total ?? model.byteCount
                guard expected > 0 else { return }
                let fraction = min(1, Double(written) / Double(expected))
                if reported.advances(to: fraction) { phase(.downloading(fraction)) }
            }
            try Task.checkCancellation()
            phase(.verifying)
            try store.install(downloaded: partial, for: model)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}

/// Lets a report through only when it has moved on by a whole percent, the
/// step the row shows, so a file's tens of thousands of network writes
/// become a hundred updates of the Settings window rather than a redraw on
/// every one.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func advances(to fraction: Double) -> Bool {
        let step = Int(fraction * 100)
        lock.lock()
        defer { lock.unlock() }
        guard step > last else { return false }
        last = step
        return true
    }
}

/// `ModelFileTransport` over URLSession: an ephemeral session, so no cookie,
/// cache, or credential is kept or sent, following the redirect Hugging Face
/// answers a file request with to its content delivery network.
public struct URLSessionModelTransport: ModelFileTransport {
    public init() {}

    public enum TransportError: Error, Equatable, CustomStringConvertible {
        case status(Int)
        /// No answer came from the host at all: offline, a proxy, a firewall.
        case connection(host: String, detail: String)

        public var description: String {
            switch self {
            case .status(let code): "The server answered \(code) (\(HTTPURLResponse.localizedString(forStatusCode: code)))."
            case .connection(let host, let detail): "This Mac could not reach \(host) (\(detail))."
            }
        }
    }

    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        let delegate = DownloadDelegate(destination: destination, host: url.host() ?? url.absoluteString, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.begin(session.downloadTask(with: url), continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Bridges one download task's delegate callbacks to the async call above.
/// URLSession calls it on its own queue; the lock keeps the task and the
/// continuation consistent between those callbacks and a cancellation.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let host: String
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var moveError: Error?

    init(destination: URL, host: String, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.host = host
        self.progress = progress
    }

    func begin(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let alreadyCancelled = cancelled
        self.task = task
        self.continuation = continuation
        lock.unlock()
        if alreadyCancelled {
            resume(with: .failure(CancellationError()))
        } else {
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is removed as soon as this returns, so it is
        // moved here, on the delegate's queue.
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            moveError = URLSessionModelTransport.TransportError.status(response.statusCode)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled {
            resume(with: .failure(CancellationError()))
        } else if let error {
            // A failure of the transfer itself, whatever layer reported it,
            // is a host that could not be reached; its own words say how.
            resume(with: .failure(URLSessionModelTransport.TransportError.connection(host: host, detail: error.localizedDescription)))
        } else if let moveError {
            resume(with: .failure(moveError))
        } else {
            resume(with: .success(()))
        }
    }

    private func resume(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
