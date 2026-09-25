import AthinaControlProtocol
import AthinaCore
import Darwin
import Foundation

/// The control API's Unix socket: one thread accepting, one per connection,
/// each reading one JSON request per line and writing one answer per line.
///
/// A connection is served only for this user (`getpeereid`), and a request only
/// with the run's secret, compared in constant time; nothing else is read from
/// a request without it. Commands run on the main actor, one at a time.
final class ControlListener: @unchecked Sendable {
  typealias Handler = @MainActor @Sendable (ControlRequest) async -> ControlReply

  private let descriptor: Int32
  private let secret: String
  private let handle: Handler

  init(channel: ControlChannel, handle: @escaping Handler) throws {
    secret = channel.secret
    self.handle = handle
    let path = channel.socketPath
    // A socket left by an earlier launch in the same directory goes; any
    // other file there is left alone, and bind then fails naming it.
    var existing = stat()
    if lstat(path, &existing) == 0, existing.st_mode & S_IFMT == S_IFSOCK { unlink(path) }

    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw ControlListenerError("socket: \(String(cString: strerror(errno)))")
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(descriptor)
      throw ControlListenerError("\(path) is too long for a socket")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else {
      let reason = String(cString: strerror(errno))
      close(descriptor)
      throw ControlListenerError("could not listen at \(path): \(reason)")
    }
    chmod(path, 0o600)
    guard listen(descriptor, 16) == 0 else {
      let reason = String(cString: strerror(errno))
      close(descriptor)
      throw ControlListenerError("could not listen at \(path): \(reason)")
    }
  }

  /// Stops accepting connections; the app never does, and tests do.
  func stop() {
    shutdown(descriptor, SHUT_RDWR)
    close(descriptor)
  }

  func run() {
    let thread = Thread { [self] in
      while true {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else {
          if errno == EINTR || errno == ECONNABORTED { continue }
          return
        }
        let connection = Thread { [self] in serve(client) }
        connection.name = "athina-control-connection"
        connection.start()
      }
    }
    thread.name = "athina-control"
    thread.start()
  }

  private func serve(_ client: Int32) {
    defer { close(client) }
    // A client that goes away mid-answer must end this connection, never
    // the app, which SIGPIPE would.
    var one: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
    var pending = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = pending[pending.startIndex..<newline]
        pending.removeSubrange(pending.startIndex...newline)
        guard write(answer(Data(line)).line(), to: client) else { return }
      }
      guard pending.count <= ControlProtocol.maximumLineLength else {
        _ = write(
          ControlReply.error("a request is at most \(ControlProtocol.maximumLineLength) bytes")
            .line(),
          to: client
        )
        return
      }
      let count = read(client, &chunk, chunk.count)
      if count <= 0 { return }
      pending.append(contentsOf: chunk[0..<count])
    }
  }

  private func answer(_ line: Data) -> ControlReply {
    guard let request = try? ControlRequest.decode(line: line) else {
      return ControlReply.error(
        "not a request: one JSON object with id, secret, command, and arguments"
      )
    }
    guard ControlSecret.matches(request.secret, secret) else {
      return ControlReply.error("wrong or missing secret", ["id": .number(Double(request.id))])
    }
    let reply = ReplyBox()
    let done = DispatchSemaphore(value: 0)
    let handle = self.handle
    Task { @MainActor in
      reply.value = await handle(request)
      done.signal()
    }
    done.wait()
    var answer = reply.value
    answer["id"] = .number(Double(request.id))
    return answer
  }

  private func write(_ data: Data, to client: Int32) -> Bool {
    data.withUnsafeBytes { buffer in
      var offset = 0
      // The loop runs only while the buffer holds bytes, and a buffer with
      // bytes always has a base address.
      while offset < buffer.count {
        let written = Darwin.write(
          client,
          buffer.baseAddress!.advanced(by: offset),
          buffer.count - offset
        )
        if written <= 0 { return false }
        offset += written
      }
      return true
    }
  }
}

private final class ReplyBox: @unchecked Sendable {
  var value = ControlReply.error("no answer")
}

struct ControlListenerError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
