import CoreGraphics
import Foundation

/// The system prompts and output schemas for both tiers, versioned so a call
/// log entry can be traced to the exact prompt that produced it. Bump
/// `version` whenever either prompt or schema changes.
public enum MentorPrompts {
    public static let version = 5

    // MARK: Triage

    public static let triageBase = """
    You are the triage stage of Mentor, a macOS app that watches what its user is doing and, rarely, \
    offers a live suggestion the way an expert sitting beside them would. You do not write suggestions. \
    You decide whether the stronger mentor model should look at this moment at all.

    You receive one snapshot as text: the frontmost app and window, what the accessibility API says is \
    focused, the screen text recognized by OCR (top to bottom, so layout is lost), and a short list of \
    recent events. The mentor model is expensive and every look costs money, so most snapshots must be a no.

    Answer worth a look only when the snapshot shows a concrete sign that a better approach may exist or \
    that the user may be missing something, for example:
    - repetitive manual work that tools usually automate: retyping, copying between windows, hand-formatting
    - an error, warning, failing build or test, or a confusing state the user seems to be working around \
    instead of fixing
    - a workflow with a well-known faster or more reliable path: a long command sequence that has a \
    shortcut, a manual step that a feature covers
    - a decision point in design or code where common pitfalls apply

    Answer not worth a look when:
    - the user is reading, watching, browsing, chatting, or otherwise consuming rather than doing
    - the screen is a transition: loading, a blank document, a login or launch screen, an open menu
    - the content looks personal, financial, medical, or otherwise private
    - the snapshot is routine, competent work with nothing that stands out
    - you are unsure. Silence is the default.

    Reply with JSON only: {"worth_a_look": boolean, "reason": string}. Keep the reason to one short \
    sentence in plain text with plain hyphens, naming the concrete sign you saw, or why you passed.
    """

    /// The extra section appended to the triage system prompt while the user
    /// enforces mentorship contexts. It changes only when the declared list
    /// changes, so the cached prefix is rewritten once per edit.
    static func triageContextSection(_ contexts: [MentorshipContext]) -> String {
        let declared = contexts.map { context in
            context.detail.isEmpty ? "- \"\(context.name)\"" : "- \"\(context.name)\": \(context.detail)"
        }.joined(separator: "\n")
        let opening = """
        The user has declared the kinds of work they want mentoring in, and asked to be left alone \
        everywhere else. Place this snapshot in one of them, in the same answer:
        """
        let closing = """
        Set context to the name of the one this snapshot belongs to, exactly as written above, or to null \
        when it belongs to none of them. Judge the work, not the app: the same app can be inside one \
        moment and outside the next. A snapshot outside every context is never shown to the user, so \
        answer null whenever you are unsure rather than guessing, and answer worth_a_look on its own \
        merits either way.

        This replaces the reply shape above: reply with JSON only, \
        {"worth_a_look": boolean, "reason": string, "context": string or null}.
        """
        return "\n\n" + opening + "\n\n" + declared + "\n\n" + closing
    }

    /// The triage system prompt, with the declared contexts appended when the
    /// user is enforcing them. One cached block; identical calls hit the cache.
    public static func triageSystem(contexts: [MentorshipContext]) -> String {
        guard !contexts.isEmpty else { return triageBase }
        return triageBase + triageContextSection(contexts)
    }

    static let triageBaseSchema: JSONValue = [
        "type": "object",
        "properties": [
            "worth_a_look": ["type": "boolean"],
            "reason": ["type": "string"],
        ],
        "required": ["worth_a_look", "reason"],
        "additionalProperties": false,
    ]

    /// The triage output schema. While contexts are enforced it also asks which
    /// declared context the snapshot belongs to; the enum of declared names
    /// means the model cannot answer with a context that does not exist.
    public static func triageSchema(contexts: [MentorshipContext]) -> JSONValue {
        guard !contexts.isEmpty else { return triageBaseSchema }
        return [
            "type": "object",
            "properties": [
                "worth_a_look": ["type": "boolean"],
                "reason": ["type": "string"],
                "context": [
                    "anyOf": [
                        ["type": "null"],
                        ["type": "string", "enum": .array(contexts.map { .string($0.name) })],
                    ],
                ],
            ],
            "required": ["worth_a_look", "reason", "context"],
            "additionalProperties": false,
        ]
    }

    // MARK: Mentor

    public static let mentorSystem = """
    You are Mentor, a live mentor for someone working at their Mac. You see a rolling journal of their \
    recent screens as recognized text, and usually the latest screenshot. Your one job: notice when there \
    is a genuinely more helpful way to approach what they are doing, or something they appear unaware of \
    or missing, and say so briefly. Otherwise say nothing.

    The bar is high. A suggestion interrupts the user with a small notification. Speak up only when a \
    thoughtful expert looking over their shoulder would actually say something, and would expect thanks \
    for it. Silence is the correct answer for most moments, including ordinary competent work, reading and \
    browsing, transitions between tasks, and anything you cannot see clearly enough to be sure about.

    Never suggest:
    - something the journal shows they already know, already do, or just did
    - generic advice such as adding tests or taking a break that is not tied to what is on screen
    - a restatement or summary of what they are doing
    - anything about content that looks private, financial, medical, or personal, or about other people \
    visible on screen
    - a category the message lists as suppressed for this app

    When you do have a suggestion, write for a busy expert, in plain text with plain hyphens (never an \
    em dash, never markdown):
    - title: under 60 characters, the gist
    - body: one or two sentences, under 220 characters, the concrete recommendation and why it is better here
    - explanation: the full version in a few short paragraphs; include the exact command, shortcut, \
    setting, or code when there is one
    - category: shortcut (a faster way to do the same action), workflow (a better sequence or process), \
    tool (a tool or feature they seem unaware of), approach (a better design or way of solving the \
    problem), correctness (a likely mistake or bug in what they are writing), risk (something that could \
    cause harm, loss, or a security problem), or other
    - confidence: your probability from 0 to 1 that the user would find this worth the interruption
    - region: usually null. Fill it only when the suggestion is about one specific spot that is visible \
    in the attached screenshot and pointing at it helps: the exact line, button, field, or panel. Give x, \
    y, width, and height in the pixel coordinates of that screenshot (origin at its top-left corner; the \
    message states its size in pixels), covering just that spot with a little margin, and a note of at \
    most eight words to show beside it, such as "this flag" or "the failing assertion". Leave region null \
    when no screenshot is attached, when the suggestion is about the work as a whole, or when you are not \
    sure exactly where the spot is: a box on the wrong thing is worse than no box.

    Reply with JSON only, matching the schema: {"reason": string, "suggestion": null or {title, body, \
    explanation, category, confidence, region}}. The reason is one sentence for the log: what you noticed, \
    or why you stayed silent. When you have enough information to decide, decide; do not narrate alternatives.
    """

    public static let mentorSchema: JSONValue = [
        "type": "object",
        "properties": [
            "reason": ["type": "string"],
            "suggestion": [
                "anyOf": [
                    ["type": "null"],
                    [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "body": ["type": "string"],
                            "explanation": ["type": "string"],
                            "category": [
                                "type": "string",
                                "enum": .array(SuggestionCategory.allCases.map { .string($0.rawValue) }),
                            ],
                            "confidence": ["type": "number"],
                            "region": regionSchema,
                        ],
                        "required": ["title", "body", "explanation", "category", "confidence", "region"],
                        "additionalProperties": false,
                    ],
                ],
            ],
        ],
        "required": ["reason", "suggestion"],
        "additionalProperties": false,
    ]

    /// The optional spot a suggestion points at, in the pixels of the frame
    /// the model saw. Null is the normal answer.
    static let regionSchema: JSONValue = [
        "anyOf": [
            ["type": "null"],
            [
                "type": "object",
                "properties": [
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "width": ["type": "number"],
                    "height": ["type": "number"],
                    "note": ["type": "string"],
                ],
                "required": ["x", "y", "width", "height", "note"],
                "additionalProperties": false,
            ],
        ],
    ]

    // MARK: Follow-up

    /// The mentor tier answering something the user said about a suggestion
    /// while holding the talk-back key. The answer is read aloud and shown in
    /// the toast, so it is short prose, never a list.
    public static let followUpSystem = """
    You are Mentor, a live mentor for someone working at their Mac. A moment ago you made the suggestion \
    described in the message, and the user has now said something about it, transcribed on their Mac while \
    they held a talk-back key. Answer as the same expert who made the suggestion.

    Answer directly, in plain text with plain hyphens (never an em dash, never markdown): two to five short \
    sentences that will be read aloud and shown in a small panel, so no lists, headings, or code fences; \
    give an exact command, shortcut, setting, or line of code inline when one answers the question. The \
    transcript may carry recognition errors; read it charitably and answer the most likely meaning rather \
    than asking for clarification. If the user pushes back, say plainly whether they are right. If they \
    ask about something beyond the suggestion and the screen it was made from, say what you can and admit \
    what you cannot see.

    Reply with JSON only: {"answer": string}.
    """

    public static let followUpSchema: JSONValue = [
        "type": "object",
        "properties": [
            "answer": ["type": "string"],
        ],
        "required": ["answer"],
        "additionalProperties": false,
    ]
}

/// What the mentor tier returns to a follow-up question.
public struct FollowUpReply: Codable, Equatable, Sendable {
    public var answer: String

    public init(answer: String) {
        self.answer = answer
    }
}

extension String {
    /// Model text with em and en dashes replaced by a plain dash, so nothing
    /// the app shows or stores carries one whatever the model does.
    public var withPlainDashes: String {
        guard contains("\u{2014}") || contains("\u{2013}") else { return self }
        return replacingOccurrences(of: " \u{2014} ", with: " - ")
            .replacingOccurrences(of: "\u{2014}", with: " - ")
            .replacingOccurrences(of: "\u{2013}", with: "-")
    }
}

/// What the triage tier returns. The context field is asked for only while
/// mentorship contexts are enforced, so it is optional: a reply without it
/// names no context, which counts as outside.
public struct TriageVerdict: Codable, Equatable, Sendable {
    public var worthALook: Bool
    public var reason: String
    /// The declared context this snapshot belongs to, or nil for none of them,
    /// which is also how the model says it is unsure.
    public var context: String?

    public init(worthALook: Bool, reason: String, context: String? = nil) {
        self.worthALook = worthALook
        self.reason = reason
        self.context = context
    }

    private enum CodingKeys: String, CodingKey {
        case worthALook = "worth_a_look"
        case reason
        case context
    }
}

/// What the mentor tier returns.
public struct MentorVerdict: Codable, Equatable, Sendable {
    public struct Payload: Codable, Equatable, Sendable {
        /// The spot the suggestion is about, in the pixels of the frame the
        /// model saw. Decodes from `"region": null` and from a reply with no
        /// region field at all, so older prompt versions still parse.
        public struct Region: Codable, Equatable, Sendable {
            public var x: Double
            public var y: Double
            public var width: Double
            public var height: Double
            public var note: String

            public init(x: Double, y: Double, width: Double, height: Double, note: String) {
                self.x = x
                self.y = y
                self.width = width
                self.height = height
                self.note = note
            }

            public var rect: CGRect {
                CGRect(x: x, y: y, width: width, height: height)
            }
        }

        public var title: String
        public var body: String
        public var explanation: String
        public var category: SuggestionCategory
        public var confidence: Double
        public var region: Region?

        public init(title: String, body: String, explanation: String, category: SuggestionCategory, confidence: Double, region: Region? = nil) {
            self.title = title
            self.body = body
            self.explanation = explanation
            self.category = category
            self.confidence = confidence
            self.region = region
        }
    }

    public var reason: String
    public var suggestion: Payload?

    public init(reason: String, suggestion: Payload?) {
        self.reason = reason
        self.suggestion = suggestion
    }
}
