import Foundation

/// An app or a site that settles, on its own, whether an activity belongs to a
/// mentorship context. Apps match the bundle identifier or the app name; sites
/// match a domain in the window title.
public struct ContextRule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
        case app
        case site

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .app: "App"
            case .site: "Site"
            }
        }

        public var symbol: String {
            switch self {
            case .app: "app.dashed"
            case .site: "globe"
            }
        }

        public var placeholder: String {
            switch self {
            case .app: "Bundle identifier or app name"
            case .site: "Domain, such as github.com"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// A bundle identifier or an app name for `.app`, a domain for `.site`.
    public var value: String

    public init(id: UUID = UUID(), kind: Kind, value: String) {
        self.id = id
        self.kind = kind
        self.value = value
    }

    /// "App Xcode" or "Site github.com", for logs and the settings list.
    public var label: String { "\(kind.label) \(value)" }
}

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
    /// Apps and sites that are always inside this context, with no model judgement.
    public var alwaysInside: [ContextRule]

    public init(id: UUID = UUID(), name: String, detail: String = "", alwaysInside: [ContextRule] = []) {
        self.id = id
        self.name = name
        self.detail = detail
        self.alwaysInside = alwaysInside
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, detail, alwaysInside
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        alwaysInside = try c.decodeIfPresent([ContextRule].self, forKey: .alwaysInside) ?? []
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
    /// The triage model's confidence, or nil when a rule settled it and no
    /// model judgement was involved.
    public var confidence: Double?
    /// The always-inside rule that settled it, when one did.
    public var rule: ContextRule?

    public init(contextID: UUID, name: String, confidence: Double? = nil, rule: ContextRule? = nil) {
        self.contextID = contextID
        self.name = name
        self.confidence = confidence
        self.rule = rule
    }

    public var label: String {
        if let rule {
            return "inside \"\(name)\" (\(rule.label.lowercased()) is always inside it)"
        }
        if let confidence {
            return "inside \"\(name)\" (\(ContextExclusion.percent(confidence)) confident)"
        }
        return "inside \"\(name)\""
    }
}

/// Why an activity is outside every declared context.
public enum ContextExclusion: Equatable, Sendable {
    /// An always-outside rule matched, so triage never ran and nothing was sent.
    case alwaysOutside(rule: ContextRule)
    /// The switch is on and no context is declared, so nothing is inside.
    case noContextsDeclared
    /// Triage placed the activity in none of the declared contexts.
    case noMatch(reason: String)
    /// Triage named a context but was not sure enough.
    case belowConfidence(name: String, confidence: Double, threshold: Double)
    /// Triage did not answer the context question, so enforcement failed closed.
    case unanswered

    public var label: String {
        switch self {
        case .alwaysOutside(let rule): "\(rule.label.lowercased()) is always outside"
        case .noContextsDeclared: "no context is declared"
        case .noMatch(let reason):
            reason.isEmpty ? "triage matched no declared context" : reason
        case .belowConfidence(let name, let confidence, let threshold):
            "\"\(name)\" only \(ContextExclusion.percent(confidence)) confident, \(ContextExclusion.percent(threshold)) needed"
        case .unanswered: "triage did not name a context"
        }
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Pure matching and placement for the declared contexts. Everything here is a
/// function of the settings and one observation's focus, so the gate, the
/// prompts, and the tests all see the same answer.
public enum ContextRules {
    public static let maxContexts = 12
    public static let maxRulesPerList = 30

    // MARK: Normalizing

    /// Trims an app rule; strips a site rule's scheme, leading "www.", any
    /// path, and lowercases it, so "https://www.GitHub.com/x" is "github.com".
    public static func normalized(_ raw: String, kind: ContextRule.Kind) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == .site else { return value }
        value = value.lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if let at = value.lastIndex(of: "@") { value = String(value[value.index(after: at)...]) }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// Trims, normalizes, drops empties and duplicates, and caps the count.
    public static func normalized(_ rules: [ContextRule]) -> [ContextRule] {
        var seen = Set<String>()
        var out: [ContextRule] = []
        for rule in rules {
            var normalizedRule = rule
            normalizedRule.value = normalized(rule.value, kind: rule.kind)
            guard !normalizedRule.value.isEmpty else { continue }
            guard seen.insert("\(rule.kind.rawValue)|\(normalizedRule.value.lowercased())").inserted else { continue }
            out.append(normalizedRule)
            if out.count == maxRulesPerList { break }
        }
        return out
    }

    /// Trims names and details, drops nameless contexts and duplicate names,
    /// normalizes every rule, and caps the count.
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
            normalizedContext.alwaysInside = normalized(context.alwaysInside)
            guard !normalizedContext.name.isEmpty else { continue }
            guard seen.insert(normalizedContext.name.lowercased()).inserted else { continue }
            out.append(normalizedContext)
            if out.count == maxContexts { break }
        }
        return out
    }

    // MARK: Matching

    /// An app rule matches the bundle identifier or the app name, either way
    /// case-insensitively. A site rule matches its domain in the window title.
    public static func matches(_ rule: ContextRule, focus: FocusContext) -> Bool {
        switch rule.kind {
        case .app:
            if let bundleID = focus.bundleID, bundleID.caseInsensitiveCompare(rule.value) == .orderedSame { return true }
            return focus.appName.caseInsensitiveCompare(rule.value) == .orderedSame
        case .site:
            return titleContainsDomain(rule.value, title: focus.windowTitle)
        }
    }

    /// True when the title contains the domain at a domain boundary, so
    /// "hub.com" does not match "github.com" and "docs.swift.org" matches
    /// a rule for "swift.org".
    public static func titleContainsDomain(_ domain: String, title: String?) -> Bool {
        let needle = normalized(domain, kind: .site)
        guard !needle.isEmpty, let title, !title.isEmpty else { return false }
        let haystack = title.lowercased()
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == haystack.startIndex {
                beforeOK = true
            } else {
                // A dot before the domain is a subdomain, which is still the site.
                let before = haystack[haystack.index(before: range.lowerBound)]
                beforeOK = before == "." || !isDomainCharacter(before)
            }
            let afterOK: Bool
            if range.upperBound == haystack.endIndex {
                afterOK = true
            } else {
                let after = haystack[range.upperBound]
                afterOK = !isDomainCharacter(after) && after != "."
            }
            if beforeOK, afterOK { return true }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    private static func isDomainCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    /// The first always-outside rule that matches, if any.
    public static func alwaysOutsideRule(matching focus: FocusContext, rules: [ContextRule]) -> ContextRule? {
        rules.first { matches($0, focus: focus) }
    }

    /// The first declared context whose always-inside rules match, with the
    /// rule that matched.
    public static func pinnedContext(
        for focus: FocusContext, contexts: [MentorshipContext]
    ) -> (context: MentorshipContext, rule: ContextRule)? {
        for context in contexts {
            if let rule = context.alwaysInside.first(where: { matches($0, focus: focus) }) {
                return (context, rule)
            }
        }
        return nil
    }

    public static func context(named name: String, in contexts: [MentorshipContext]) -> MentorshipContext? {
        contexts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Placement

    /// Turns the triage answer into a placement. `pinned` is the always-inside
    /// rule's context when one matched, in which case the model's answer is
    /// ignored. Anything the model leaves unanswered is outside: enforcement
    /// fails closed.
    public static func placement(
        triage: TriageVerdict,
        pinned: (context: MentorshipContext, rule: ContextRule)?,
        contexts: [MentorshipContext],
        confidenceThreshold: Double
    ) -> ContextPlacement {
        if let pinned {
            return .inside(ContextMatch(contextID: pinned.context.id, name: pinned.context.name, rule: pinned.rule))
        }
        guard !contexts.isEmpty else { return .outside(.noContextsDeclared) }
        guard let name = triage.context, !name.isEmpty else {
            return .outside(triage.contextConfidence == nil ? .unanswered : .noMatch(reason: ""))
        }
        guard let context = context(named: name, in: contexts) else {
            return .outside(.noMatch(reason: "triage answered \"\(name)\", which is not declared"))
        }
        let confidence = triage.contextConfidence ?? 0
        guard confidence >= confidenceThreshold else {
            return .outside(.belowConfidence(name: context.name, confidence: confidence, threshold: confidenceThreshold))
        }
        return .inside(ContextMatch(contextID: context.id, name: context.name, confidence: confidence))
    }
}
