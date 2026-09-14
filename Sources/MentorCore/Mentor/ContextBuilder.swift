import Foundation

/// Fixed 24-hour formats for prompts and the app's panels. The locale's own
/// style may be 12-hour without a marker when the marker is omitted, which
/// made every afternoon time read as a morning one.
public enum ClockFormat {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dayAndTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d 'at' HH:mm"
        return formatter
    }()

    /// "15:23:06", in the local time zone.
    public static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// "Sep 14 at 15:23", in the local time zone.
    public static func dayAndTime(_ date: Date) -> String {
        dayAndTimeFormatter.string(from: date)
    }
}

/// A rough token estimate for budgeting prompt text. The API bills the real
/// count; this only decides how much journal fits in the window.
public enum TokenEstimate {
    public static let charactersPerToken = 4

    public static func tokens(in text: String) -> Int {
        (text.utf8.count + charactersPerToken - 1) / charactersPerToken
    }
}

/// The mentor tier's rolling window: recent observations' text, bounded by a
/// time window and a token budget, oldest first.
public enum RollingWindow {
    public struct Entry: Equatable, Sendable {
        public var observationID: Int64
        public var timestamp: Date
        public var appName: String
        public var windowTitle: String?
        public var focusSummary: String
        public var text: String
        public var reason: CaptureReason
        /// True when the text was cut to fit the budget.
        public var truncated: Bool

        public init(observation: ActivityObservation, text: String, truncated: Bool) {
            observationID = observation.id
            timestamp = observation.timestamp
            appName = observation.focus.appName
            windowTitle = observation.focus.windowTitle
            focusSummary = observation.focus.summary
            self.text = text
            reason = observation.reason
            self.truncated = truncated
        }
    }

    /// Consecutive entries from the same window whose text is at least this
    /// similar collapse to the newer one, so a slow edit does not fill the window.
    public static let duplicateSimilarity = 0.95

    /// Builds the window from observations in any order. The newest observation
    /// is always included (truncated to the budget if it alone exceeds it);
    /// older ones are added newest-first until the budget or window runs out.
    public static func build(
        observations: [ActivityObservation],
        now: Date,
        duration: TimeInterval,
        tokenBudget: Int,
        maxEntries: Int = 40
    ) -> [Entry] {
        let cutoff = now.addingTimeInterval(-duration)
        let ordered = observations
            .filter { !$0.focus.isExcluded }
            .sorted { $0.timestamp != $1.timestamp ? $0.timestamp > $1.timestamp : $0.id > $1.id }
        guard let newest = ordered.first else { return [] }

        var remaining = tokenBudget
        var entries: [Entry] = []
        let newestText = newest.ocrText
        let newestTokens = TokenEstimate.tokens(in: newestText)
        if newestTokens > remaining {
            let cut = String(newestText.prefix(max(0, remaining * TokenEstimate.charactersPerToken)))
            entries.append(Entry(observation: newest, text: cut, truncated: true))
            return entries
        }
        entries.append(Entry(observation: newest, text: newestText, truncated: false))
        remaining -= newestTokens

        for observation in ordered.dropFirst() {
            guard observation.timestamp >= cutoff, entries.count < maxEntries else { break }
            let text = observation.ocrText
            if let last = entries.last,
               last.appName == observation.focus.appName, last.windowTitle == observation.focus.windowTitle,
               TextSimilarity.lineJaccard(last.text, text) >= duplicateSimilarity {
                continue
            }
            let tokens = TokenEstimate.tokens(in: text) + 24
            guard tokens <= remaining else { break }
            entries.append(Entry(observation: observation, text: text, truncated: false))
            remaining -= tokens
        }
        return entries.reversed()
    }
}

/// Renders the user messages for both tiers. Only text from the journal is
/// used; the thumbnail is attached separately by the loop when enabled.
public enum PromptBuilder {
    /// OCR text sent to triage is cut here so a dense screen stays cheap.
    public static let triageTextLimit = 6000
    /// Events older than this are left out of both summaries.
    public static let eventWindow: TimeInterval = 600
    public static let eventLimit = 12

    /// Text only: app and window, accessibility summary, the OCR text, and a
    /// compact event summary.
    public static func triageMessage(
        observation: ActivityObservation,
        recentEvents: [JournalEvent],
        now: Date
    ) -> String {
        var lines: [String] = []
        lines.append("Time: \(clock(now))")
        lines.append("App: \(observation.focus.appName)\(observation.focus.bundleID.map { " (\($0))" } ?? "")")
        lines.append("Window: \(observation.focus.windowTitle ?? "untitled")")
        lines.append("Trigger: \(observation.reason.label)")
        lines.append("Accessibility: \(observation.focus.summary)")
        lines.append("")
        lines.append("Recent events:")
        lines.append(eventSummary(recentEvents, now: now))
        lines.append("")
        let text = observation.ocrText
        let cut = text.count > triageTextLimit
        lines.append("Screen text (OCR, top to bottom\(cut ? ", first \(triageTextLimit) characters" : "")):")
        lines.append(cut ? String(text.prefix(triageTextLimit)) : text)
        return lines.joined(separator: "\n")
    }

    /// The rolling window rendered oldest first, with the latest entry marked
    /// and the suppressed categories for the app spelled out.
    public static func mentorMessage(
        window: [RollingWindow.Entry],
        latest: ActivityObservation,
        recentEvents: [JournalEvent],
        suppressed: [SuggestionCategory],
        includesImage: Bool,
        context: MentorshipContext? = nil,
        now: Date
    ) -> String {
        var lines: [String] = []
        lines.append("Time: \(clock(now))")
        lines.append("The user is in \(latest.focus.appName), window \"\(latest.focus.windowTitle ?? "untitled")\".")
        if let context {
            var line = "The user asked to be mentored while \(context.name)"
            if !context.detail.isEmpty { line += " (\(context.detail))" }
            lines.append(line + ", and this moment was placed in that context. Keep the suggestion useful for that work.")
        }
        if suppressed.isEmpty {
            lines.append("Suppressed categories for this app: none.")
        } else {
            lines.append("Suppressed categories for this app (do not raise these): \(suppressed.map(\.rawValue).joined(separator: ", ")).")
        }
        if includesImage {
            lines.append("The attached image is the latest screen, \(latest.frame.width) by \(latest.frame.height) pixels; a region, if you give one, is in those pixels.")
        } else {
            lines.append("No screenshot is attached, so leave region null.")
        }
        lines.append("")
        lines.append("Recent events:")
        lines.append(eventSummary(recentEvents, now: now))
        lines.append("")
        lines.append("Recent screens, oldest first. Each entry: time, app, window, trigger, accessibility focus, then recognized text.")
        for (index, entry) in window.enumerated() {
            let isLatest = index == window.count - 1
            var header = "--- \(clock(entry.timestamp)) | \(entry.appName) | \"\(entry.windowTitle ?? "untitled")\" | \(entry.reason.label)"
            if isLatest { header += " | latest" }
            lines.append("")
            lines.append(header)
            lines.append("focus: \(entry.focusSummary)")
            lines.append("text:")
            lines.append(entry.text.isEmpty ? "(no text recognized)" : entry.text)
            if entry.truncated { lines.append("(text cut to fit the budget)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The follow-up message: the suggestion being discussed, the recognized
    /// text of the screen it was made from when the journal still has it,
    /// the exchange so far, and what the user just said.
    public static func followUpMessage(
        suggestion: Suggestion,
        screenText: String?,
        exchange: [FollowUp],
        question: String,
        now: Date
    ) -> String {
        var lines: [String] = []
        lines.append("Time: \(clock(now))")
        let window = suggestion.windowTitle.map { ", window \"\($0)\"" } ?? ""
        lines.append("Your suggestion, made \(age(suggestion.timestamp, now: now)) in \(suggestion.appName)\(window) (\(suggestion.category.rawValue), confidence \(Int((suggestion.confidence * 100).rounded()))%):")
        lines.append("Title: \(suggestion.title)")
        lines.append("Body: \(suggestion.body)")
        lines.append("Explanation: \(suggestion.explanation)")
        if let region = suggestion.region {
            lines.append("You pointed at a spot on screen with the note \"\(region.note)\".")
        }
        lines.append("")
        if let screenText, !screenText.isEmpty {
            let cut = screenText.count > triageTextLimit
            lines.append("Recognized text of the screen the suggestion was made from (top to bottom\(cut ? ", first \(triageTextLimit) characters" : "")):")
            lines.append(cut ? String(screenText.prefix(triageTextLimit)) : screenText)
        } else {
            lines.append("The screen the suggestion was made from is no longer available.")
        }
        if !exchange.isEmpty {
            lines.append("")
            lines.append("Earlier in this exchange:")
            for entry in exchange {
                lines.append("User: \(entry.question)")
                lines.append("You: \(entry.answer ?? "(no answer: \(entry.error ?? "unknown error"))")")
            }
        }
        lines.append("")
        lines.append("The user now says, spoken and transcribed on their Mac: \"\(question)\"")
        return lines.joined(separator: "\n")
    }

    /// The most recent events inside `eventWindow`, newest last, one per line.
    public static func eventSummary(_ events: [JournalEvent], now: Date) -> String {
        let cutoff = now.addingTimeInterval(-eventWindow)
        let recent = events
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(eventLimit)
        guard !recent.isEmpty else { return "- none in the last \(Int(eventWindow / 60)) minutes" }
        return recent.map { event in
            var line = "- \(age(event.timestamp, now: now)): \(event.kind.label.lowercased())"
            if let app = event.appName { line += " \(app)" }
            if let detail = event.detail, !detail.isEmpty { line += " (\(detail))" }
            return line
        }.joined(separator: "\n")
    }

    /// 24-hour wall-clock time, whatever the locale's preference: "15:23:06"
    /// is unambiguous where "03:23:06" is not.
    static func clock(_ date: Date) -> String {
        ClockFormat.time(date)
    }

    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "\(Int(seconds))s ago" }
        return "\(Int(seconds / 60))m ago"
    }
}
