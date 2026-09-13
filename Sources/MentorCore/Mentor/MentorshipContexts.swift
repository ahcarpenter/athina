import Foundation

/// One kind of work the user wants mentoring in, in their own words.
public struct MentorshipContext: Codable, Equatable, Sendable, Identifiable {
    public static let maxNameLength = 60
    public static let maxDetailLength = 280

    public var id: UUID
    /// A short name, for example "building web apps". Also the label the triage
    /// model answers with, so it must be unique and readable.
    public var name: String
    /// An optional longer description, sent to the triage model with the name.
    public var detail: String

    public init(id: UUID = UUID(), name: String, detail: String = "") {
        self.id = id
        self.name = name
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

/// Where an activity sits relative to the declared contexts. The mentor gate
/// turns this into a yes or no; the menu and the debug panel show its label.
public enum ContextPlacement: Equatable, Sendable {
    /// "Only mentor inside these contexts" is off, so contexts gate nothing.
    case notEnforced
    case inside(ContextMatch)
    case outside(ContextExclusion)

    public var label: String {
        switch self {
        case .notEnforced: "not enforced"
        case .inside(let match): match.label
        case .outside(let exclusion): "outside every context (\(exclusion.label))"
        }
    }

    /// The declared context this activity was placed in, if any.
    public var contextName: String? {
        switch self {
        case .inside(let match): match.name
        case .notEnforced, .outside: nil
        }
    }

    public var contextID: UUID? {
        switch self {
        case .inside(let match): match.contextID
        case .notEnforced, .outside: nil
        }
    }

    public var isOutside: Bool {
        if case .outside = self { return true }
        return false
    }
}

/// An activity placed inside a declared context.
public struct ContextMatch: Equatable, Sendable {
    public var contextID: UUID
    public var name: String
    /// The triage model's confidence in that placement.
    public var confidence: Double

    public init(contextID: UUID, name: String, confidence: Double) {
        self.contextID = contextID
        self.name = name
        self.confidence = confidence
    }

    public var label: String {
        "inside \"\(name)\" (\(ContextExclusion.percent(confidence)) confident)"
    }
}

/// Why an activity is outside every declared context.
public enum ContextExclusion: Equatable, Sendable {
    /// The switch is on and no context is declared, so nothing is inside.
    case noContextsDeclared
    /// Triage placed the activity in none of the declared contexts.
    case noMatch(reason: String)
    /// Triage named a context but was not sure enough.
    case belowConfidence(name: String, confidence: Double)
    /// Triage did not answer the context question, so enforcement failed closed.
    case unanswered

    public var label: String {
        switch self {
        case .noContextsDeclared: "no context is declared"
        case .noMatch(let reason):
            reason.isEmpty ? "triage matched no declared context" : reason
        case .belowConfidence(let name, let confidence):
            "\"\(name)\" only \(ContextExclusion.percent(confidence)) confident, \(ContextExclusion.percent(ContextRules.confidenceThreshold)) needed"
        case .unanswered: "triage did not name a context"
        }
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Pure normalizing and placement for the declared contexts. Everything here is
/// a function of the settings and one triage answer, so the gate, the prompts,
/// the settings editor, and the tests all see the same answer.
public enum ContextRules {
    public static let maxContexts = 12
    /// Triage's context answer must be at least this confident to count as
    /// inside. Fixed: the user declares where they want mentoring, not how sure
    /// the model has to be about it.
    public static let confidenceThreshold = 0.6

    // MARK: Normalizing

    /// Trims names and details, drops nameless contexts and duplicate names,
    /// and caps the count. The settings editor refuses exactly what this drops,
    /// so nothing the user saves disappears silently.
    public static func normalized(_ contexts: [MentorshipContext]) -> [MentorshipContext] {
        var seen = Set<String>()
        var out: [MentorshipContext] = []
        for context in contexts {
            var normalizedContext = context
            normalizedContext.name = String(
                context.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(MentorshipContext.maxNameLength)
            )
            normalizedContext.detail = String(
                context.detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(MentorshipContext.maxDetailLength)
            )
            guard !normalizedContext.name.isEmpty else { continue }
            guard seen.insert(normalizedContext.name.lowercased()).inserted else { continue }
            out.append(normalizedContext)
            if out.count == maxContexts { break }
        }
        return out
    }

    // MARK: Matching

    public static func context(named name: String, in contexts: [MentorshipContext]) -> MentorshipContext? {
        contexts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether `name` would collide with a context other than `excluding`, which
    /// `normalized` resolves by dropping the later one. The editor asks this
    /// before saving so the user is refused rather than silently ignored.
    public static func isDuplicateName(_ name: String, in contexts: [MentorshipContext], excluding id: UUID?) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return contexts.contains { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    // MARK: Placement

    /// Turns the triage answer into a placement. Anything the model leaves
    /// unanswered is outside: enforcement fails closed.
    public static func placement(triage: TriageVerdict, contexts: [MentorshipContext]) -> ContextPlacement {
        guard !contexts.isEmpty else { return .outside(.noContextsDeclared) }
        guard let name = triage.context, !name.isEmpty else {
            return .outside(triage.contextConfidence == nil ? .unanswered : .noMatch(reason: ""))
        }
        guard let context = context(named: name, in: contexts) else {
            return .outside(.noMatch(reason: "triage answered \"\(name)\", which is not declared"))
        }
        let confidence = triage.contextConfidence ?? 0
        guard confidence >= confidenceThreshold else {
            return .outside(.belowConfidence(name: context.name, confidence: confidence))
        }
        return .inside(ContextMatch(contextID: context.id, name: context.name, confidence: confidence))
    }
}
