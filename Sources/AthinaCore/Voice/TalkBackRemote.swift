import Foundation

/// Plays a recording into a running replay's listener from a script, as if
/// the talk-back key were held for its length: the audio goes through the
/// chosen recognizer, the partial transcript into the toast, and the final
/// one into `TranscriptMatcher` and, for a question, a replayed follow-up.
/// `scripts/talk-back.sh` sends it; it is how the end-to-end harness checks
/// every recognizer on a Mac with no microphone and no permission for one.
///
/// Only a replay listens, and only for its own pid (`ReplayRemote`), so no
/// live Athina ever hears a recording it was not asked for by the person at
/// the Mac, and nothing a replay hears leaves it: its model calls are
/// answered from fixtures.
public enum TalkBackRemote {
    public static let name = "com.ahcarpenter.athina.talk-back"
    public static let fileKey = "file"
    public static let replyKey = "replyTo"

    public static func listens(in mode: ClockMode) -> Bool {
        ClockRemote.listens(in: mode)
    }

    /// The recording a request names, or why it is refused.
    public static func file(from userInfo: [AnyHashable: Any]?) -> Result<URL, ReplayRemote.Refusal> {
        guard let path = userInfo?[fileKey] as? String, !path.isEmpty else {
            return .failure(ReplayRemote.Refusal(reason: "no \(fileKey) in the request"))
        }
        guard path.hasPrefix("/") else {
            return .failure(ReplayRemote.Refusal(reason: "\(path) is not an absolute path"))
        }
        return .success(URL(fileURLWithPath: path))
    }

    public static func replyURL(from userInfo: [AnyHashable: Any]?) -> URL? {
        ReplayRemote.replyURL(from: userInfo, key: replyKey)
    }

    /// What a replay answers once the recording has been heard and handled.
    public struct Reply: Codable, Equatable, Sendable {
        /// The final transcript, nil when nothing was heard.
        public var heard: String?
        /// What was done with it, as the debug panel's Mentor card says:
        /// "answered: Tell Me More", "asked the mentor", "nothing heard", or
        /// why the recording was not played at all.
        public var handling: String
        /// The recognizer and model that heard it, as the journal stores them.
        public var backend: String?
        public var model: String?
        /// The answer the toast shows, for a question.
        public var answer: String?
        public var pid: Int32

        public init(heard: String?, handling: String, backend: String? = nil, model: String? = nil, answer: String? = nil, pid: Int32 = getpid()) {
            self.heard = heard
            self.handling = handling
            self.backend = backend
            self.model = model
            self.answer = answer
            self.pid = pid
        }

        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }
    }
}
