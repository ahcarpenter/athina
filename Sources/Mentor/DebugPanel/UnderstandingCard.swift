import MentorCore
import SwiftUI

/// The debug panel's view of the standing understanding: what Mentor currently
/// believes the user is working toward, where that reading came from, what it
/// has cost, and when it will be rewritten next.
struct UnderstandingCard: View {
    /// The understanding's color wherever the debug panel marks it: this card,
    /// its events in the timeline, and its calls in the call log. No other
    /// tier or status uses it.
    static let tint: Color = .brown

    /// Symbols and bullets sit in a column this wide, so every heading, goal,
    /// and item starts at the same edge whatever the symbol's width.
    private static let markWidth: CGFloat = 16

    @Environment(AppState.self) private var state

    private var record: UnderstandingRecord? { state.mentorStatus.understanding }

    var body: some View {
        Card(title: "Understanding") {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let now = state.clock.date
                VStack(alignment: .leading, spacing: 8) {
                    if let record {
                        header(record, now: now)
                    }
                    if state.mentorStatus.inFlight == .understanding {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Refresh call in flight")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let content = record?.content, !content.isEmpty {
                        goals(content)
                        list("Done so far", items: content.timeline, symbol: "list.bullet")
                        list("Said so far", items: content.mentorHistory, symbol: "quote.bubble")
                        list("Open concerns", items: content.openConcerns, symbol: "flag")
                    } else {
                        Text(emptyText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Field(label: "Refresh", value: "every \(Formatting.duration(state.settings.mentor.understandingRefreshInterval)) of active use")
                        Field(label: "Next", value: nextRefresh(now: now), lineLimit: 4)
                        if let record {
                            Field(label: "Size", value: "\(Formatting.tokens(record.content.estimatedTokens)) of \(Formatting.tokens(state.settings.mentor.understandingTokenBudget)) tokens")
                            Field(label: "Cost", value: "\(Formatting.dollars(record.cumulativeCost)) in refresh calls since \(Formatting.clockTime(record.startedAt))", lineLimit: 2)
                        }
                        Field(label: "Last refresh", value: lastRefresh(now: now), lineLimit: 4)
                    }
                }
            }
            // Outside the ticking timeline, so the button and its confirmation
            // keep one identity for VoiceOver while the readout above redraws.
            ResetUnderstandingButton()
                .controlSize(.small)
        }
    }

    // MARK: Pieces

    private func header(_ record: UnderstandingRecord, now: Date) -> some View {
        HStack(spacing: 6) {
            StatusBadge(text: "Revision \(record.revision)", tint: Self.tint)
            Group {
                Text(Formatting.age(record.updatedAt, now: now))
                Text("·").accessibilityHidden(true)
                Text(record.source.label)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyText: String {
        let interval = Formatting.duration(state.settings.mentor.understandingRefreshInterval)
        return "No understanding yet. The next mentor call writes the first one, or a refresh call does after \(interval) of active use without one."
    }

    @ViewBuilder
    private func goals(_ content: Understanding) -> some View {
        if content.goals.isEmpty {
            Text("No goal inferred yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(content.goals) { goal in
                    let confidence = "\(Int((goal.confidence * 100).rounded()))%"
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "target")
                            .font(.caption)
                            .foregroundStyle(Self.tint)
                            .frame(width: Self.markWidth)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(goal.goal)
                                    .font(.callout.weight(.medium))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(confidence)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .help("Confidence")
                                    .accessibilityLabel("\(confidence) confidence")
                            }
                            if !goal.evidence.isEmpty {
                                Text(goal.evidence)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isStaticText)
                }
            }
        }
    }

    @ViewBuilder
    private func list(_ title: String, items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol)
                        .frame(width: Self.markWidth)
                        .accessibilityHidden(true)
                    Text(title)
                        .accessibilityAddTraits(.isHeader)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                            .frame(width: Self.markWidth)
                            .accessibilityHidden(true)
                        Text(item)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Text

    private func nextRefresh(now: Date) -> String {
        switch state.mentorStatus.refreshStanding(mode: state.mode) {
        case .notCounting(let mode):
            return "not counting: \(mode.label.lowercased())"
        case .notStarted:
            return "not counting until the next screen"
        case .counting(let next, let hold):
            var text = Formatting.countdown(to: next, now: now)
            if let hold, repeats(hold.hold) {
                text += ", held \(Formatting.age(hold.at, now: now)): \(hold.hold.label)"
            }
            return text
        }
    }

    /// Whether a hold is worth repeating beside the countdown. A not-due hold
    /// names the time the countdown already shows, and a call in flight is the
    /// progress row above when the call in flight is the refresh itself; a call
    /// in flight for another tier is news, so it is shown.
    private func repeats(_ hold: MentorScheduler.RefreshHold) -> Bool {
        switch hold {
        case .notDue: false
        case .callInFlight: state.mentorStatus.inFlight != .understanding
        default: true
        }
    }

    private func lastRefresh(now: Date) -> String {
        guard let call = state.mentorStatus.lastRefresh else {
            return record == nil ? "none yet" : "none yet, mentor calls have kept it current"
        }
        let model = ModelCatalog.displayName(for: call.model)
        var text = "\(call.outcome.label) \(Formatting.age(call.timestamp, now: now)), \(call.replayed ? "replay of \(model)" : model), "
        text += "\(Formatting.tokens(call.usage.totalInputTokens)) in, \(Formatting.tokens(call.usage.outputTokens)) out, "
        text += "\(call.replayed ? Formatting.unbroken("not billed") : Formatting.dollars(call.cost)), \(Formatting.seconds(call.latency))"
        if let detail = call.detail, !detail.isEmpty { text += "\n\(detail)" }
        return text
    }
}
