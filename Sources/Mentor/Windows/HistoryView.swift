import AppKit
import MentorCore
import SwiftUI

/// Past suggestions with their feedback, and the full text of the selected one.
struct HistoryView: View {
    @Environment(AppState.self) private var state
    @State private var selectedID: Int64?

    init(initialSelection: Int64? = nil) {
        _selectedID = State(initialValue: initialSelection)
    }

    private var selected: Suggestion? {
        guard let selectedID else { return nil }
        return state.suggestionHistory.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Suggestions")
                        .font(.headline)
                    Text("\(state.suggestionHistory.count)")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
                List(state.suggestionHistory, selection: $selectedID) { suggestion in
                    HistoryRow(suggestion: suggestion)
                        .tag(suggestion.id)
                }
                .listStyle(.inset)
                .overlay {
                    if state.suggestionHistory.isEmpty {
                        ContentUnavailableView(
                            "No suggestions yet",
                            systemImage: "lightbulb",
                            description: Text("Suggestions appear here as Mentor makes them.")
                        )
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 360)
            Group {
                if let selected {
                    SuggestionDetail(suggestion: selected)
                } else {
                    ContentUnavailableView("Select a suggestion", systemImage: "text.alignleft")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 440)
    }
}

private struct HistoryRow: View {
    @Environment(AppState.self) private var state
    let suggestion: Suggestion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: suggestion.category.symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(Formatting.dayAndTime(suggestion.timestamp))
                        .monospacedDigit()
                    Text("·")
                    Text(suggestion.appName)
                        .lineLimit(1)
                    Text("·")
                    Text(suggestion.category.label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            FeedbackPill(feedback: suggestion.feedback, isShowing: state.activeSuggestion?.id == suggestion.id)
        }
        .padding(.vertical, 3)
    }
}

/// The feedback recorded for a suggestion, or "Showing" while its toast is up
/// and nothing has been recorded yet. A suggestion with neither gets no pill.
struct FeedbackPill: View {
    let feedback: SuggestionFeedback?
    let isShowing: Bool

    var body: some View {
        if let label = feedback?.label ?? (isShowing ? "Showing" : nil) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(color.opacity(0.16), in: Capsule())
                .foregroundStyle(color)
                .fixedSize()
        }
    }

    private var color: Color {
        switch feedback {
        case .tellMeMore: .green
        case .notNow: .orange
        case .never: .red
        case .expired, .dismissed: .gray
        case nil: .accentColor
        }
    }
}

private struct SuggestionDetail: View {
    @Environment(AppState.self) private var state
    let suggestion: Suggestion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label(suggestion.category.label, systemImage: suggestion.category.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        FeedbackPill(feedback: suggestion.feedback, isShowing: state.activeSuggestion?.id == suggestion.id)
                        Spacer()
                    }
                    Text(suggestion.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(suggestion.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text(suggestion.explanation)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    detailRow("When", Formatting.dayAndTime(suggestion.timestamp))
                    detailRow("App", suggestion.bundleID.map { "\(suggestion.appName) (\($0))" } ?? suggestion.appName)
                    if let title = suggestion.windowTitle, !title.isEmpty {
                        detailRow("Window", title)
                    }
                    detailRow("Confidence", String(format: "%.0f%%", suggestion.confidence * 100))
                    detailRow("Model", "\(ModelCatalog.displayName(for: suggestion.model)), prompt v\(suggestion.promptVersion)")
                    if let feedback = suggestion.feedback {
                        detailRow("Feedback", feedback.label + (suggestion.feedbackAt.map { " at \(Formatting.dayAndTime($0))" } ?? ""))
                    }
                }
                .font(.callout)
                if suggestion.feedback == nil || suggestion.feedback?.isNonAnswer == true || suggestion.feedback == .tellMeMore {
                    HStack(spacing: 8) {
                        Button("Not now") { state.respond(to: suggestion.id, with: .notNow) }
                        Button("Never for this") { state.respond(to: suggestion.id, with: .never) }
                            .help("Stop \(suggestion.category.label.lowercased()) suggestions in \(suggestion.appName)")
                    }
                    .controlSize(.small)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
