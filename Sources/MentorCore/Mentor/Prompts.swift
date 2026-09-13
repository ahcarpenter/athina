import Foundation

/// The system prompts and output schemas for both tiers, versioned so a call
/// log entry can be traced to the exact prompt that produced it. Bump
/// `version` whenever either prompt or schema changes.
public enum MentorPrompts {
    public static let version = 2

    // MARK: Triage

    public static let triageSystem = """
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
    sentence naming the concrete sign you saw, or why you passed.
    """

    public static let triageSchema: JSONValue = [
        "type": "object",
        "properties": [
            "worth_a_look": ["type": "boolean"],
            "reason": ["type": "string"],
        ],
        "required": ["worth_a_look", "reason"],
        "additionalProperties": false,
    ]

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

    Reply with JSON only, matching the schema: {"reason": string, "suggestion": null or {title, body, \
    explanation, category, confidence}}. The reason is one sentence for the log: what you noticed, or why \
    you stayed silent. When you have enough information to decide, decide; do not narrate alternatives.
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
                        ],
                        "required": ["title", "body", "explanation", "category", "confidence"],
                        "additionalProperties": false,
                    ],
                ],
            ],
        ],
        "required": ["reason", "suggestion"],
        "additionalProperties": false,
    ]
}

/// What the triage tier returns.
public struct TriageVerdict: Codable, Equatable, Sendable {
    public var worthALook: Bool
    public var reason: String

    public init(worthALook: Bool, reason: String) {
        self.worthALook = worthALook
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case worthALook = "worth_a_look"
        case reason
    }
}

/// What the mentor tier returns.
public struct MentorVerdict: Codable, Equatable, Sendable {
    public struct Payload: Codable, Equatable, Sendable {
        public var title: String
        public var body: String
        public var explanation: String
        public var category: SuggestionCategory
        public var confidence: Double

        public init(title: String, body: String, explanation: String, category: SuggestionCategory, confidence: Double) {
            self.title = title
            self.body = body
            self.explanation = explanation
            self.category = category
            self.confidence = confidence
        }
    }

    public var reason: String
    public var suggestion: Payload?

    public init(reason: String, suggestion: Payload?) {
        self.reason = reason
        self.suggestion = suggestion
    }
}
