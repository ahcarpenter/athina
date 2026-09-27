#if E2EAPI
  import Foundation
  import Synchronization

  /// A file of the run's evidence that lines are added to, from any task.
  final class LogFile: Sendable {
    let url: URL
    private let handle: Mutex<FileHandle?>

    init(_ url: URL) {
      self.url = url
      FileManager.default.createFile(atPath: url.path, contents: nil)
      handle = Mutex(try? FileHandle(forWritingTo: url))
    }

    /// Adds `line` and a newline to the end of the file.
    func append(_ line: String) {
      handle.withLock { handle in
        guard let handle else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
      }
    }

    /// Closes the file; later lines are dropped.
    func close() {
      handle.withLock { handle in
        try? handle?.close()
        handle = nil
      }
    }

    /// The time of day to the second, as every log line starts.
    static func stamp(_ date: Date = Date()) -> String {
      let time = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
      return String(format: "%02d:%02d:%02d", time.hour ?? 0, time.minute ?? 0, time.second ?? 0)
    }
  }
#endif
