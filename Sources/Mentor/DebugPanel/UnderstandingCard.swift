import MentorCore
import SwiftUI

/// The debug panel's view of the standing understanding: what Mentor currently
/// believes the user is working toward, where that reading came from, what it
/// has cost, and when it will be rewritten next.
struct UnderstandingCard: View {
    @Environment(AppState.self) private var state
    @State private var resetting = false

    private var record: UnderstandingRecord? { state.mentorStatus.understanding }

    var body: some View {
        Card(title: "Understanding") {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let now = state.clock.date
                VStack(alignment: .leading, spacing: 8) {
                    header(now: now)
                    if let content = record?.content, !content.isEmpty {
                        goals(content)
                        list("Timeline", items: content.timeline, symbol: "list.bullet")
                        list("Said so far", items: content.mentorHistory, symbol: "quote.bubble")
                        list("Open concerns", items: content.openConcerns, symbol: "eye.trianglebadge.exclamationmark")
                    } else {
                        Text("Nothing yet. The first mentor call writes one, or the periodic refresh does when no mentor call has.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    Field(label: "Refresh", value: refresh(now: now), lineLimit: 6)
                    Field(label: "Last call", value: lastCall(now: now), lineLimit: 4)
                    resetButton
                }
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            if let record {
                Text("Revision \(record.revision)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.teal.opacity(0.15), in: Capsule())
                Text(Formatting.age(record.updatedAt, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(record.source.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("None")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: Capsule())
            }
            Spacer(minLength: 0)
        }
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
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "target")
                                .font(.caption)
                                .foregroundStyle(.teal)
                            Text(goal.goal)
                                .font(.callout.weight(.medium))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(Int((goal.confidence * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if !goal.evidence.isEmpty {
                            Text(goal.evidence)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 19)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func list(_ title: String, items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("- \(item)")
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var resetButton: some View {
        HStack {
            Button("Reset Understanding") {
                resetting = true
                Task {
                    await state.resetUnderstanding()
                    resetting = false
                }
            }
            .controlSize(.small)
            .disabled(record == nil || resetting)
            Spacer()
        }
    }

    // MARK: Text

    private func refresh(now: Date) -> String {
        let mentor = state.settings.mentor
        var parts: [String] = []
        var held: MentorStatus.RefreshHoldRecord?
        switch state.mentorStatus.refreshStanding(mode: state.mode) {
        case .notCounting(let mode):
            parts.append("\(mode.label.lowercased()), so nothing counts and no refresh is due")
        case .notStarted:
            parts.append("no record, the count starts from zero with the next screen")
        case .counting(let next, let hold):
            parts.append("next \(Formatting.countdown(to: next, now: now))")
            held = hold
        }
        parts.append("every \(Formatting.duration(mentor.understandingRefreshInterval)) of active use")
        if let held {
            parts.append("held \(Formatting.age(held.at, now: now)): \(held.hold.label)")
        }
        if let record {
            parts.append("\(record.content.estimatedTokens) of \(state.settings.mentor.understandingTokenBudget) tokens")
            parts.append("\(Formatting.dollars(record.cumulativeCost)) since \(Formatting.clockTime(record.startedAt))")
        }
        return parts.joined(separator: ", ")
    }

    private func lastCall(now: Date) -> String {
        guard let record = state.mentorStatus.lastRefresh else {
            return "no refresh call yet; mentor calls have carried it"
        }
        let model = ModelCatalog.displayName(for: record.model)
        var text = "\(record.outcome.label) \(Formatting.age(record.timestamp, now: now)), \(record.replayed ? "replay of \(model)" : model), "
        text += "\(Formatting.tokens(record.usage.totalInputTokens)) in, \(Formatting.tokens(record.usage.outputTokens)) out, "
        text += "\(record.replayed ? Formatting.unbroken("not billed") : Formatting.dollars(record.cost)), \(Formatting.seconds(record.latency))"
        if let detail = record.detail, !detail.isEmpty { text += "\n\(detail)" }
        return text
    }
}
