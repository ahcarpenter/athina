import AthinaControlProtocol
import AthinaE2E
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
  static func run(_ invocation: DriveInvocation) throws {
    guard let directory = ProcessInfo.processInfo.environment["ATHINA_CONTROL_DIR"],
      !directory.isEmpty
    else {
      throw DriveUsageError(
        "athina-drive api: no control directory; the harness sets ATHINA_CONTROL_DIR"
      )
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
    let line: Data
    do {
      let request = ControlRequest(
        id: Int(getpid()),
        secret: try ControlConnection.secret(in: base),
        command: command,
        arguments: arguments
      )
      line = try ControlConnection.exchange(request, in: base)
    } catch {
      fail("athina-drive api: \(error)", code: 2)
    }
    let reply = try ControlReply.decode(line: line)
    if let field = invocation.option("--field") {
      say(reply.json[path: field]?.text ?? "")
    } else {
      say(String(decoding: line, as: UTF8.self))
    }
    exit(reply.ok ? 0 : 1)
  }
}
