import Foundation
import OSLog

/// Wraps any `ClaudeClient` and writes every call it passes through as one
/// fixture file, success or error, then hands back exactly what the wrapped
/// client returned or threw. Behind `Mentor --record`.
///
/// The key is used only to redact itself from the file. A fixture that cannot
/// be written is logged and the call goes on: recording never changes what the
/// loop sees.
public actor RecordingClaudeClient: ClaudeClient {
    private static let log = Logger(subsystem: "com.ahcarpenter.mentor", category: "recording")

    public nonisolated let directory: URL
    private let inner: any ClaudeClient
    private let prices: PriceTable
    /// The files written so far this run, oldest first.
    public private(set) var written: [URL] = []

    public init(wrapping inner: any ClaudeClient, directory: URL, prices: PriceTable) {
        self.inner = inner
        self.directory = directory
        self.prices = prices
    }

    public func send(_ request: MessagesRequest, call: CallIdentity, apiKey: String, timeout: TimeInterval) async throws -> MessagesResponse {
        let started = Date()
        let clock = ContinuousClock.now
        var thrown: (any Error)?
        let result: Result<MessagesResponse, ClaudeClientError>
        do {
            result = .success(try await inner.send(request, call: call, apiKey: apiKey, timeout: timeout))
        } catch let error as ClaudeClientError {
            thrown = error
            result = .failure(error)
        } catch {
            thrown = error
            result = .failure(.transport(error.localizedDescription))
        }
        let elapsed = ContinuousClock.now - clock
        let usage = (try? result.get().usage) ?? Usage()
        let fixture = CallFixture(
            identity: call,
            recordedAt: started,
            request: request,
            result: result,
            latency: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            cost: prices.cost(of: usage, model: request.model) ?? 0
        )
        do {
            let url = try CallFixtureFiles.write(fixture, to: directory, redacting: apiKey)
            written.append(url)
            RecordingClaudeClient.log.notice("recorded \(call.kind, privacy: .public) call to \(url.lastPathComponent, privacy: .public)")
        } catch {
            RecordingClaudeClient.log.error("recording not written: \(String(describing: error), privacy: .public)")
        }
        if let thrown { throw thrown }
        return try result.get()
    }
}

/// Sends nothing and refuses every call with one reason, for a recording whose
/// directory cannot be written. It is not a replay: the loop reads the key as
/// for any live launch, and each refused call is journaled as a live error
/// that cost nothing.
public struct RefusingClaudeClient: ClaudeClient {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func send(_ request: MessagesRequest, call: CallIdentity, apiKey: String, timeout: TimeInterval) async throws -> MessagesResponse {
        throw ClaudeClientError.notSent(reason)
    }
}
