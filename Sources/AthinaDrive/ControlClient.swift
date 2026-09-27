import ArgumentParser
import AthinaControlProtocol
import Darwin
import Foundation

/// `athina-drive api`: one request to a replay's control API, and its answer.
///
/// The harness makes the run's control directory, writes the secret into it,
/// and names it in `ATHINA_CONTROL_DIR`. Each `key=value` is sent as its
/// parameter takes it (`ControlValue.argument`), text as written. The answer
/// is printed as the app wrote it, one JSON line, or with `--field <path>` as
/// just that field (`elements.0.enabled`, `refused`), empty when it has none.
/// Exit 0 when the answer is ok, 1 when it is not, 2 when no app answered.
enum ControlClient {
  /// One request, checked before it is sent.
  struct Request {
    /// The run's control directory, from `ATHINA_CONTROL_DIR`.
    let directory: URL
    /// The control API command.
    let command: String
    /// Its parameters, each as its parameter takes it.
    let arguments: [String: ControlValue]
  }

  /// `command` with its `key=value` words, sent to the directory the harness
  /// named.
  ///
  /// - Throws: `ValidationError` when there is no control directory or a
  ///   word is not `key=value`.
  static func request(_ command: String, _ words: [String]) throws -> Request {
    guard let directory = ProcessInfo.processInfo.environment["ATHINA_CONTROL_DIR"],
      !directory.isEmpty
    else {
      throw ValidationError("no control directory; the harness sets ATHINA_CONTROL_DIR")
    }
    var arguments: [String: ControlValue] = [:]
    for text in words {
      guard let (key, value) = ControlValue.argument(text) else {
        throw ValidationError("\"\(text)\" is not key=value")
      }
      arguments[key] = value
    }
    return Request(
      directory: URL(fileURLWithPath: directory, isDirectory: true),
      command: command,
      arguments: arguments
    )
  }

  /// Sends `request`, prints the answer or its `field`, and exits.
  static func run(_ request: Request, field: String?) throws -> Never {
    let line: Data
    do {
      let message = ControlRequest(
        id: Int(getpid()),
        secret: try ControlConnection.secret(in: request.directory),
        command: request.command,
        arguments: request.arguments
      )
      line = try ControlConnection.exchange(message, in: request.directory)
    } catch {
      fail("athina-drive api: \(error)", code: 2)
    }
    let reply = try ControlReply.decode(line: line)
    if let field {
      say(reply.json[path: field]?.text ?? "")
    } else {
      say(String(decoding: line, as: UTF8.self))
    }
    exit(reply.ok ? 0 : 1)
  }
}
