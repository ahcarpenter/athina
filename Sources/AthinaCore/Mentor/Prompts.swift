import CoreGraphics
import Foundation

/// The system prompts and output schemas for every tier, versioned so a call
/// log entry can be traced to the exact prompt that produced it.
///
/// Bump `version` whenever any prompt or schema changes.
///
/// The app is Athina, but the name these prompts give the model is still
/// Mentor, here and in the history line `PromptBuilder` writes. Changing it
/// is a prompt change: it bumps `version`, which makes every committed
/// fixture stale until they are recorded again live, at the captain's
/// expense. So the model's picture of itself moves in one deliberate
/// re-recording change rather than with the rename (README, "The committed
/// fixtures").
public enum MentorPrompts {
  /// The version of every prompt and schema here, recorded with each model
  /// call, suggestion, and fixture.
  ///
  /// A committed fixture recorded under another version is stale and fails
  /// `swift test`.
  public static let version = 10

  // MARK: Triage

  /// The triage system prompt before any contexts section.
  ///
  /// Sent as it is while the user enforces no mentorship contexts;
  /// `triageSystem(contexts:)` appends the declared ones to it.
  public static let triageBase = """
    You are the triage stage of Mentor, a macOS app that watches what its user is doing and, \
    rarely, \
    offers a live suggestion the way an expert sitting beside them would. You do not write \
    suggestions. \
    You decide whether the stronger mentor model should look at this moment at all.

    You receive one snapshot as text: the frontmost app and window, what the accessibility API \
    says is \
    focused, the screen text recognized by OCR (top to bottom, so layout is lost), a short \
    list of recent \
    events, and, when one exists, a one-paragraph standing understanding of what this user \
    appears to be \
    working toward. The mentor model is expensive and every look costs money, so most \
    snapshots must be a no.

    Answer worth a look only when the snapshot shows a concrete sign that a better approach \
    may exist or \
    that the user may be missing something, for example:
    - repetitive manual work that tools usually automate: retyping, copying between windows, \
    hand-formatting
    - an error, warning, failing build or test, or a confusing state the user seems to be \
    working around \
    instead of fixing
    - a workflow with a well-known faster or more reliable path: a long command sequence that \
    has a \
    shortcut, a manual step that a feature covers
    - a decision point in design or code where common pitfalls apply
    - when a standing understanding is given: the action on screen conflicts with the goal it \
    states. It \
    will not get them there, an available alternative would get them there for less work, or \
    it will get \
    them there and bring a consequence they would not want. Judge against the goal, not \
    against your own \
    preferences, and stay silent when the action is simply a different reasonable path to the \
    same goal.

    Answer not worth a look when:
    - the user is reading, watching, browsing, chatting, or otherwise consuming rather than doing
    - the screen is a transition: loading, a blank document, a login or launch screen, an open menu
    - the content looks personal, financial, medical, or otherwise private
    - the snapshot is routine, competent work with nothing that stands out
    - you are unsure. Silence is the default.

    Reply with JSON only: {"worth_a_look": boolean, "reason": string}. Keep the reason to one \
    short \
    sentence in plain text with plain hyphens, naming the concrete sign you saw, or why you passed.
    """

  /// The extra section appended to the triage system prompt while the user
  /// enforces mentorship contexts.
  ///
  /// It changes only when the declared list changes, so the cached prefix is
  /// rewritten once per edit.
  static func triageContextSection(_ contexts: [MentorshipContext]) -> String {
    let declared = contexts.map { context in
      context.detail.isEmpty ? "- \"\(context.name)\"" : "- \"\(context.name)\": \(context.detail)"
    }.joined(separator: "\n")
    let opening = """
      The user has declared the kinds of work they want mentoring in, and asked to be left alone \
      everywhere else. Place this snapshot in one of them, in the same answer:
      """
    let closing = """
      Set context to the name of the one this snapshot belongs to, exactly as written above, \
      or to null \
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
  /// user is enforcing them.
  ///
  /// One cached block; identical calls hit the cache.
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

  /// The triage output schema.
  ///
  /// While contexts are enforced it also asks which declared context the
  /// snapshot belongs to; the enum of declared names means the model cannot
  /// answer with a context that does not exist.
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
          ]
        ],
      ],
      "required": ["worth_a_look", "reason", "context"],
      "additionalProperties": false,
    ]
  }

  // MARK: Mentor

  /// The mentor tier's system prompt: when to speak, how to write a suggestion,
  /// and how to keep the understanding.
  public static let mentorSystem = """
    You are Mentor, a live mentor for someone working at their Mac. You see a rolling journal \
    of their \
    recent screens as recognized text, and usually the latest screenshot. You also keep a standing \
    understanding of what they are working toward, which you wrote yourself on an earlier call \
    and which \
    is given to you as its own block when it exists. Your one job: notice when there is a \
    genuinely more \
    helpful way to approach what they are doing, or something they appear unaware of or \
    missing, and say \
    so briefly. Otherwise say nothing.

    The bar is high. A suggestion interrupts the user with a small notification. Speak up only \
    when a \
    thoughtful expert looking over their shoulder would actually say something, and would \
    expect thanks \
    for it. Silence is the correct answer for most moments, including ordinary competent work, \
    reading and \
    browsing, transitions between tasks, and anything you cannot see clearly enough to be sure \
    about.

    When you have a standing understanding, look out for them: judge what they are doing now \
    against the \
    goal it states, and speak when one of these is true.
    - wont_achieve_goal: the approach will not get them to that goal. Say what will happen instead.
    - less_efficient: it will get them there, but an alternative they can reach right now gets \
    them there \
    for materially less work. A small difference is not worth an interruption.
    - unwanted_side_effect: it will get them there and also cause something they would not \
    want and \
    probably have not noticed. Name the side effect concretely.
    Only raise one of these when the understanding actually supports it. An inferred goal is a \
    reading, \
    not a fact: when what they are doing simply means your reading was wrong, correct the \
    understanding \
    and stay silent. Never raise one of these three when no understanding was given.

    Never suggest:
    - something the journal shows they already know, already do, or just did
    - generic advice such as adding tests or taking a break that is not tied to what is on screen
    - a restatement or summary of what they are doing
    - anything about content that looks private, financial, medical, or personal, or about \
    other people \
    visible on screen
    - a category the message lists as suppressed for this app

    When you do have a suggestion, write for a busy expert, in plain text with plain hyphens \
    (never an \
    em dash, never markdown):
    - title: under 60 characters, the gist
    - body: one or two sentences, under 220 characters, the concrete recommendation and why it \
    is better here
    - explanation: the full version in a few short paragraphs; include the exact command, \
    shortcut, \
    setting, or code when there is one
    - category: shortcut (a faster way to do the same action), workflow (a better sequence or \
    process), \
    tool (a tool or feature they seem unaware of), approach (a better design or way of solving the \
    problem), correctness (a likely mistake or bug in what they are writing), risk (something \
    that could \
    cause harm, loss, or a security problem), wont_achieve_goal, less_efficient, \
    unwanted_side_effect (the \
    three judged against the standing understanding, above), or other
    - confidence: your probability from 0 to 1 that the user would find this worth the interruption
    - judged_goal: when the category is one of the three judged against the understanding, the \
    goal you \
    judged against, copied from the understanding; otherwise null
    - region: usually null. Fill it only when the suggestion is about one specific spot that \
    is visible \
    in the attached screenshot and pointing at it helps: the exact line, button, field, or \
    panel. Give x, \
    y, width, and height in the pixel coordinates of that screenshot (origin at its top-left \
    corner; the \
    message states its size in pixels), covering just that spot with a little margin, and a \
    note of at \
    most eight words to show beside it, such as "this flag" or "the failing assertion". Leave \
    region null \
    when no screenshot is attached, when the suggestion is about the work as a whole, or when \
    you are not \
    sure exactly where the spot is: a box on the wrong thing is worse than no box.

    Always return updated_understanding, whether or not you have a suggestion. It replaces the \
    standing \
    record wholesale, so carry forward everything still true and write it as if the reader has \
    not seen \
    the old one. Keep it inside the token budget the message states. Leave out anything that looks \
    private, financial, medical, or personal, and anything about other people on screen; a \
    goal you can \
    only state by quoting such content is one to leave out.
    - goals: what they appear to be working toward, most likely first, each with the evidence \
    for it and \
    your confidence from 0 to 1. Prefer the goal behind the task over the task itself: "get \
    the build \
    green before the release" rather than "edit Package.swift". Revise a goal the moment the \
    screens stop \
    supporting it, and keep an alternative reading as a second goal rather than forcing one.
    - timeline: what has happened so far, oldest first, one short sentence each. Merge and \
    shorten old \
    entries as they age rather than dropping the thread.
    - mentor_history: what you have already told them and how they answered, so you never repeat a \
    suggestion or raise one they dismissed.
    - open_concerns: things to watch for that are not worth an interruption yet.

    Reply with JSON only, matching the schema: {"reason": string, "suggestion": null or \
    {title, body, \
    explanation, category, confidence, judged_goal, region}, "updated_understanding": {goals, \
    timeline, \
    mentor_history, open_concerns}}. The reason is one sentence for the log: what you noticed, \
    or why \
    you stayed silent. When you have enough information to decide, decide; do not narrate \
    alternatives.
    """

  /// The mentor tier's output schema: a reason, a suggestion or null, and the
  /// updated understanding.
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
              "judged_goal": ["anyOf": [["type": "null"], ["type": "string"]]],
              "region": regionSchema,
            ],
            "required": [
              "title", "body", "explanation", "category", "confidence", "judged_goal", "region",
            ],
            "additionalProperties": false,
          ],
        ]
      ],
      "updated_understanding": understandingSchema,
    ],
    "required": ["reason", "suggestion", "updated_understanding"],
    "additionalProperties": false,
  ]

  /// The optional spot a suggestion points at, in the pixels of the frame the
  /// model saw.
  ///
  /// Null is the normal answer.
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
    ]
  ]

  // MARK: Understanding

  /// The shape of the understanding itself, shared by the mentor tier's
  /// `updated_understanding` field and the refresh tier's whole reply.
  public static let understandingSchema: JSONValue = [
    "type": "object",
    "properties": [
      "goals": [
        "type": "array",
        "items": [
          "type": "object",
          "properties": [
            "goal": ["type": "string"],
            "evidence": ["type": "string"],
            "confidence": ["type": "number"],
          ],
          "required": ["goal", "evidence", "confidence"],
          "additionalProperties": false,
        ],
      ],
      "timeline": ["type": "array", "items": ["type": "string"]],
      "mentor_history": ["type": "array", "items": ["type": "string"]],
      "open_concerns": ["type": "array", "items": ["type": "string"]],
    ],
    "required": ["goals", "timeline", "mentor_history", "open_concerns"],
    "additionalProperties": false,
  ]

  /// The refresh tier: the same record-keeping the mentor tier does on the way
  /// past, run on its own when a stretch of work produced no mentor call.
  ///
  /// It never writes suggestions, so it can be a cheap model.
  public static let understandingSystem = """
    You keep the standing understanding for Mentor, a macOS app that watches what its user is \
    doing and \
    rarely offers a live suggestion. You do not write suggestions and you never address the \
    user. Your \
    only job is to rewrite the record of what they are working toward and what has happened, \
    so the \
    mentor model can look out for them on later calls.

    You receive the current record, if there is one, the recent suggestions and events, and \
    then the \
    screens since the record was last written. Produce the new record. It replaces the old one \
    wholesale, so carry forward \
    everything still true and write it as if the reader has not seen the old one.

    - goals: what they appear to be working toward, most likely first, each with the evidence \
    for it and \
    your confidence from 0 to 1. Prefer the goal behind the task over the task itself: "get \
    the build \
    green before the release" rather than "edit Package.swift". Revise a goal the moment the \
    screens stop \
    supporting it, and keep an alternative reading as a second goal rather than forcing one. \
    Lower a \
    confidence you can no longer support instead of deleting the goal outright.
    - timeline: what has happened so far, oldest first, one short sentence each. Merge and \
    shorten old \
    entries as they age rather than dropping the thread.
    - mentor_history: what Mentor has already told them and how they answered, so it never \
    repeats a \
    suggestion or raises one they dismissed.
    - open_concerns: things to watch for that are not worth an interruption yet.

    Leave out anything that looks private, financial, medical, or personal, and anything about \
    other \
    people on screen; a goal you can only state by quoting such content is one to leave out. \
    Write plain \
    text with plain hyphens, never an em dash and never markdown. Stay inside the token budget the \
    message states; when you are near it, shorten the oldest timeline entries first.

    Reply with JSON only: {"reason": string, "understanding": {goals, timeline, mentor_history, \
    open_concerns}}. The reason is one sentence for the log saying what changed since the last \
    record.
    """

  /// The refresh tier's output schema: a reason and the rewritten
  /// understanding.
  public static let understandingRefreshSchema: JSONValue = [
    "type": "object",
    "properties": [
      "reason": ["type": "string"],
      "understanding": understandingSchema,
    ],
    "required": ["reason", "understanding"],
    "additionalProperties": false,
  ]

  /// The standing understanding as its own system block after the mentor
  /// prompt, with no cache marker: every mentor call rewrites the record, so
  /// the block changes on every call and could never be read from the cache,
  /// while the prompt before it keeps its own marker and stays cached.
  public static func understandingBlock(_ record: UnderstandingRecord) -> SystemBlock {
    SystemBlock(
      text: """
        Your standing understanding of this user's work, revision \(record.revision), which \
        you wrote \
        yourself and which replaces nothing you see in the messages below.

        \(record.content.promptBlock)
        """,
      cacheControl: nil
    )
  }

  // MARK: Follow-up

  /// The mentor tier answering something the user said about a suggestion while
  /// holding the talk-back key.
  ///
  /// The answer is shown in the toast, so it is short prose, never a list. The
  /// prompt still says it may be read aloud: reading suggestions aloud is
  /// deferred, and changing this text would stale every recorded fixture for
  /// nothing.
  public static let followUpSystem = """
    You are Mentor, a live mentor for someone working at their Mac. A moment ago you made the \
    suggestion \
    described in the message, and the user has now said something about it, transcribed on \
    their Mac while \
    they held a talk-back key. Answer as the same expert who made the suggestion.

    Answer directly, in plain text with plain hyphens (never an em dash, never markdown): two \
    to five short \
    sentences that will be read aloud and shown in a small panel, so no lists, headings, or \
    code fences; \
    give an exact command, shortcut, setting, or line of code inline when one answers the \
    question. The \
    transcript may carry recognition errors; read it charitably and answer the most likely \
    meaning rather \
    than asking for clarification. If the user pushes back, say plainly whether they are \
    right. If they \
    ask about something beyond the suggestion and the screen it was made from, say what you \
    can and admit \
    what you cannot see.

    Reply with JSON only: {"answer": string}.
    """

  /// The follow-up output schema: a single answer string.
  public static let followUpSchema: JSONValue = [
    "type": "object",
    "properties": [
      "answer": ["type": "string"]
    ],
    "required": ["answer"],
    "additionalProperties": false,
  ]
}

/// What the mentor tier returns to a follow-up question.
public struct FollowUpReply: Codable, Equatable, Sendable {
  /// The answer as the model wrote it, before its dashes are made plain.
  public var answer: String

  /// Creates a reply with its answer.
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

/// What the triage tier returns.
///
/// The context field is asked for only while mentorship contexts are enforced,
/// so it is optional: a reply without it names no context, which counts as
/// outside.
public struct TriageVerdict: Codable, Equatable, Sendable {
  /// Whether the mentor tier should look at this moment.
  public var worthALook: Bool
  /// One sentence for the call log saying why.
  public var reason: String
  /// The declared context this snapshot belongs to, or nil for none of them,
  /// which is also how the model says it is unsure.
  public var context: String?

  /// Creates a verdict, naming no context by default.
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
  /// One suggestion as the model wrote it, before the loop checks it against
  /// the confidence threshold and the suppression rules.
  public struct Payload: Codable, Equatable, Sendable {
    /// The spot the suggestion is about, in the pixels of the frame the model
    /// saw.
    ///
    /// Decodes from `"region": null` and from a reply with no region field at
    /// all, so older prompt versions still parse.
    public struct Region: Codable, Equatable, Sendable {
      /// The left edge, in pixels from the left of the frame.
      public var x: Double
      /// The top edge, in pixels down from the top of the frame.
      public var y: Double
      /// The width, in pixels.
      public var width: Double
      /// The height, in pixels.
      public var height: Double
      /// The few words, at most eight, to show beside the spot.
      public var note: String

      /// Creates a region from its rectangle and note.
      public init(x: Double, y: Double, width: Double, height: Double, note: String) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.note = note
      }

      /// The spot as a rectangle in the frame's pixels, origin top-left.
      public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
      }
    }

    /// The gist, asked to stay under 60 characters.
    public var title: String
    /// The concrete recommendation in one or two sentences, asked to stay under
    /// 220 characters.
    public var body: String
    /// The full version, in a few short paragraphs.
    public var explanation: String
    /// The kind of suggestion.
    public var category: SuggestionCategory
    /// The model's probability, 0 to 1, that the user would find this worth the
    /// interruption.
    public var confidence: Double
    /// The inferred goal this was judged against, for the goal categories.
    public var judgedGoal: String?
    /// The spot on screen the suggestion is about, or nil, the usual answer,
    /// for none.
    public var region: Region?

    /// True when the title or the body has no words.
    ///
    /// The schema requires both fields, and a model can still fill them with
    /// empty strings.
    public var isBlank: Bool {
      title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Creates a payload; the goal and the region default to none.
    public init(
      title: String,
      body: String,
      explanation: String,
      category: SuggestionCategory,
      confidence: Double,
      judgedGoal: String? = nil,
      region: Region? = nil
    ) {
      self.title = title
      self.body = body
      self.explanation = explanation
      self.category = category
      self.confidence = confidence
      self.judgedGoal = judgedGoal
      self.region = region
    }

    private enum CodingKeys: String, CodingKey {
      case title, body, explanation, category, confidence, region
      case judgedGoal = "judged_goal"
    }
  }

  /// One sentence for the call log: what the model noticed, or why it stayed
  /// silent.
  public var reason: String
  /// The suggestion, or nil when the model chose silence.
  public var suggestion: Payload?
  /// The rewritten understanding this call carried, so a mentor call refreshes
  /// the record without a call of its own.
  ///
  /// Optional so a reply that omits it still yields its suggestion.
  public var updatedUnderstanding: Understanding?

  private enum CodingKeys: String, CodingKey {
    case reason, suggestion
    case updatedUnderstanding = "updated_understanding"
  }

  /// Creates a verdict, with no updated understanding by default.
  public init(reason: String, suggestion: Payload?, updatedUnderstanding: Understanding? = nil) {
    self.reason = reason
    self.suggestion = suggestion
    self.updatedUnderstanding = updatedUnderstanding
  }

  /// The suggestion is what the user came for, so a bookkeeping field that
  /// does not decode is dropped rather than allowed to fail the whole reply.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    reason = try c.decode(String.self, forKey: .reason)
    suggestion = try c.decodeIfPresent(Payload.self, forKey: .suggestion)
    updatedUnderstanding = try? c.decodeIfPresent(Understanding.self, forKey: .updatedUnderstanding)
  }
}

/// What a periodic understanding refresh returns.
public struct UnderstandingVerdict: Codable, Equatable, Sendable {
  /// One line for the call log: what changed since the last record.
  public var reason: String
  /// The rewritten understanding.
  public var understanding: Understanding

  /// Creates a verdict from its reason and understanding.
  public init(reason: String, understanding: Understanding) {
    self.reason = reason
    self.understanding = understanding
  }
}
