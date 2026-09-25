import AthinaControlProtocol
import AthinaE2E
import Darwin
import Foundation

/// `athina-drive api`: one request to a replay's control API, and its answer.
///
/// The harness makes the run's control directory, writes the secret into it,
/// and names it in `ATHINA_CONTROL_DIR`; `--control` names another. The answer
/// is printed as the app wrote it, one JSON line, or with `--field <path>` as
/// just that field (`elements.0.enabled`, `refused`), empty when it has none.
/// Exit 0 when the answer is ok, 1 when it is not, 2 when no app answered.
enum ControlClient {
    static func run(_ invocation: DriveInvocation) throws {
        guard let directory = invocation.option("--control") ?? ProcessInfo.processInfo.environment["ATHINA_CONTROL_DIR"],
              !directory.isEmpty else {
            throw DriveUsageError("athina-drive api: no control directory; the harness sets ATHINA_CONTROL_DIR, or pass --control <dir>")
        }
        let command = try invocation.positional(0)
        var arguments: [String: ControlValue] = [:]
        for text in invocation.positionals.dropFirst() {
            guard let (key, value) = ControlValue.argument(text) else {
                throw DriveUsageError("athina-drive api: \"\(text)\" is not key=value")
            }
            arguments[key] = value
        }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        guard let secret = try? String(contentsOf: base.appendingPathComponent(ControlProtocol.secretName), encoding: .utf8) else {
            fail("athina-drive api: no secret in \(directory)", code: 2)
        }
        let request = ControlRequest(
            id: Int(getpid()), secret: secret.trimmingCharacters(in: .whitespacesAndNewlines), command: command, arguments: arguments
        )
        // A wait answers when it is over, so the read allows its timeout and then some.
        let patience = (arguments["timeout"]?.number ?? 10) + 30
        let line: Data
        do {
            line = try exchange(base.appendingPathComponent(ControlProtocol.socketName).path, request: try request.line(), patience: patience)
        } catch {
            fail("athina-drive api: no answer at \(directory): \(error)", code: 2)
        }
        let reply = try ControlReply.decode(line: line)
        if let field = invocation.option("--field") {
            say(reply.json[path: field]?.text ?? "")
        } else {
            say(String(decoding: line, as: UTF8.self))
        }
        exit(reply.ok ? 0 : 1)
    }

    private static func exchange(_ path: String, request: Data, patience: Double) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: Int(patience), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        try request.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE) }
                offset += written
            }
        }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !received.contains(0x0A) {
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { throw POSIXError(count == 0 ? .ECONNRESET : POSIXErrorCode(rawValue: errno) ?? .EIO) }
            received.append(contentsOf: chunk[0..<count])
        }
        return received.prefix(upTo: received.firstIndex(of: 0x0A)!)
    }
}
