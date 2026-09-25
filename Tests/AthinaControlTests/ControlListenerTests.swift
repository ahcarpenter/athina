import AthinaCore
import Darwin
import Foundation
import Testing
@testable import AthinaControl
@testable import AthinaControlProtocol

/// The socket itself: a real listener in a directory of its own, a stand-in
/// for the app's commands, and a client talking to it as athina-drive does.
@Suite struct ControlListenerTests {
    let secret = String(repeating: "c0", count: 32)

    @MainActor final class Seen {
        var commands: [String] = []
    }

    @Test func onlyARequestCarryingTheSecretReachesTheApp() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = ControlChannel(directory: directory, secret: secret)
        let seen = Seen()
        let listener = try ControlListener(channel: channel) { request in
            seen.commands.append(request.command)
            return .ok(["command": .string(request.command)])
        }
        listener.run()
        defer { listener.stop() }

        var socketInfo = stat()
        #expect(lstat(channel.socketPath, &socketInfo) == 0)
        #expect(socketInfo.st_mode & 0o777 == 0o600, "only this user may connect")

        let secret = self.secret
        let answers = try await Task.detached {
            try exchange(channel.socketPath, lines: [
                try ControlRequest(id: 1, secret: secret, command: "ping").line(),
                try ControlRequest(id: 2, secret: "wrong", command: "click").line(),
                try ControlRequest(id: 3, secret: "", command: "click").line(),
                Data("not a request\n".utf8),
                try ControlRequest(id: 4, secret: secret, command: "windows").line(),
            ])
        }.value

        #expect(answers.count == 5)
        #expect(answers[0].ok && answers[0]["id"] == .number(1) && answers[0]["command"] == .string("ping"))
        #expect(!answers[1].ok && answers[1]["error"] == .string("wrong or missing secret"))
        #expect(!answers[2].ok && answers[2]["error"] == .string("wrong or missing secret"))
        #expect(!answers[3].ok && answers[3]["id"] == nil)
        #expect(answers[4].ok && answers[4]["id"] == .number(4))
        #expect(await seen.commands == ["ping", "windows"], "nothing without the secret reached the app")
        for answer in answers {
            let text = String(decoding: answer.line(), as: UTF8.self)
            #expect(!text.contains(secret), "an answer never carries the secret")
        }
    }

    @Test func anEndlessLineIsCutOff() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = ControlChannel(directory: directory, secret: secret)
        let listener = try ControlListener(channel: channel) { _ in .ok() }
        listener.run()
        defer { listener.stop() }
        let answers = try await Task.detached {
            try exchange(channel.socketPath, lines: [Data(repeating: 0x61, count: ControlProtocol.maximumLineLength + 70_000)])
        }.value
        #expect(answers.count == 1)
        #expect(answers.first?["error"]?.string?.contains("at most") == true)
    }

    @Test func aSocketLeftByAnEarlierLaunchIsReplacedAndAnyOtherFileIsNot() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = ControlChannel(directory: directory, secret: secret)
        let first = try ControlListener(channel: channel) { _ in .ok() }
        first.stop()
        let second = try ControlListener(channel: channel) { _ in .ok() }
        second.stop()

        try FileManager.default.removeItem(atPath: channel.socketPath)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: channel.socketPath))
        #expect(throws: ControlListenerError.self) { _ = try ControlListener(channel: channel) { _ in .ok() } }
        #expect(try String(contentsOfFile: channel.socketPath, encoding: .utf8) == "keep")
    }

    /// A 0700 directory short enough for a socket, as the harness makes one.
    func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ctl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
}

/// Connects, writes every line, and reads one answer per line until the app
/// closes the connection or has answered them all.
private func exchange(_ path: String, lines: [Data]) throws -> [ControlReply] {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var one: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
    let payload = lines.reduce(Data(), +)
    payload.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if written <= 0 { break }
            offset += written
        }
    }
    var answers: [ControlReply] = []
    var pending = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while answers.count < lines.count {
        while let newline = pending.firstIndex(of: 0x0A) {
            answers.append(try ControlReply.decode(line: pending[pending.startIndex..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
        }
        if answers.count >= lines.count { break }
        let count = read(descriptor, &chunk, chunk.count)
        if count <= 0 { break }
        pending.append(contentsOf: chunk[0..<count])
    }
    return answers
}
