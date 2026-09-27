import Darwin
import Foundation

/// The client's end of the control API: one request over a run's socket and
/// the one answer line that comes back, as athina-drive's `api` and the API
/// tier's tests send them (docs/e2e.md "The control API").
public enum ControlConnection {
  /// Why no answer came back.
  public struct Failure: Error, CustomStringConvertible {
    /// What went wrong, for a person to read.
    public let description: String
    /// Creates the failure with its message.
    public init(_ description: String) { self.description = description }
  }

  /// Reads the run's secret from its control directory, without the newline
  /// the harness writes after it.
  ///
  /// - Throws: `Failure` when the directory holds no secret.
  public static func secret(in directory: URL) throws -> String {
    let file = directory.appendingPathComponent(ControlProtocol.secretName)
    guard let secret = try? String(contentsOf: file, encoding: .utf8) else {
      throw Failure("no secret in \(directory.path)")
    }
    return secret.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Sends `request` to the socket in the control directory `directory` and
  /// returns the answer line, without its newline.
  ///
  /// It blocks until the answer arrives: a wait answers when it is over, so
  /// the read allows the request's own `timeout` and 30 seconds more.
  ///
  /// - Throws: `Failure` when nothing is listening there, the connection
  ///   breaks, or no answer comes in that time.
  public static func exchange(_ request: ControlRequest, in directory: URL) throws -> Data {
    let path = directory.appendingPathComponent(ControlProtocol.socketName).path
    let patience = (request.arguments["timeout"]?.number ?? 10) + 30
    do {
      return try exchange(path, request: try request.line(), patience: patience)
    } catch {
      throw Failure("no answer at \(directory.path): \(error)")
    }
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
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
    try request.withUnsafeBytes { buffer in
      var offset = 0
      // The loop runs only while the buffer holds bytes, and a buffer with
      // bytes always has a base address.
      while offset < buffer.count {
        let written = write(
          descriptor,
          buffer.baseAddress!.advanced(by: offset),
          buffer.count - offset
        )
        guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE) }
        offset += written
      }
    }
    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while !received.contains(0x0A) {
      let count = read(descriptor, &chunk, chunk.count)
      guard count > 0 else {
        throw POSIXError(count == 0 ? .ECONNRESET : POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      received.append(contentsOf: chunk[0..<count])
    }
    // The loop above ends only once a newline has arrived.
    return received.prefix(upTo: received.firstIndex(of: 0x0A)!)
  }
}
