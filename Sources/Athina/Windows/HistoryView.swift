import AppKit
import AthinaCore
import Foundation
import SwiftUI

/// Past suggestions with their feedback, and the full text of the selected one.
struct HistoryView: View {
  @Environment(AppState.self)
  private var state

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
      List(state.suggestionHistory, selection: $selectedID) { suggestion in
        HistoryRow(suggestion: suggestion)
          .tag(suggestion.id)
      }
      .listStyle(.inset)
      .accessibilityLabel("Suggestions")
      .overlay {
        if state.suggestionHistory.isEmpty {
          ContentUnavailableView(
            "No Suggestions Yet",
            systemImage: "lightbulb",
            description: Text(
              """
              When Athina notices a more helpful way to do something, the suggestion appears \
              here with your answer to it.
              """
            )
          )
        }
      }
      .frame(minWidth: 320, idealWidth: 360)
      Group {
        if let selected {
          SuggestionDetail(suggestion: selected)
        } else {
          ContentUnavailableView("No Suggestion Selected", systemImage: "text.alignleft")
        }
      }
      .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 760, minHeight: 440)
    .navigationSubtitle(Plural.count(state.suggestionHistory.count, "suggestion", "suggestions"))
  }
}

private struct HistoryRow: View {
  @Environment(AppState.self)
  private var state

  let suggestion: Suggestion

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: suggestion.category.symbol)
        .foregroundStyle(.tint)
        .frame(width: 18)
        .padding(.top, 2)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(suggestion.title)
          .lineLimit(2)
        HStack(spacing: 6) {
          Text(Formatting.dayAndTime(suggestion.timestamp))
            .monospacedDigit()
          Text("·").accessibilityHidden(true)
          Text(suggestion.appName)
            .lineLimit(1)
          Text("·").accessibilityHidden(true)
          Text(suggestion.category.label)
          DeliveryMarks(
            suggestion: suggestion,
            talkedBack: state.followUps.contains { $0.suggestionID == suggestion.id }
          )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      FeedbackPill(
        feedback: suggestion.feedback,
        isShowing: state.activeSuggestion?.id == suggestion.id
      )
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
  }
}

/// Small marks for how a suggestion was delivered: a callout drawn, talked
/// back to.
private struct DeliveryMarks: View {
  let suggestion: Suggestion
  let talkedBack: Bool

  var body: some View {
    if suggestion.calloutShown || talkedBack {
      HStack(spacing: 5) {
        if suggestion.calloutShown {
          Image(systemName: "rectangle.dashed")
            .help("A callout was drawn on screen")
            .accessibilityLabel("Callout shown")
        }
        if talkedBack {
          Image(systemName: "mic")
            .help("Talked back to")
            .accessibilityLabel("Talked back to")
        }
      }
      .foregroundStyle(.secondary)
    }
  }
}

/// The feedback recorded for a suggestion, or "Showing" while its toast is up
/// and nothing has been recorded yet.
///
/// A suggestion with neither gets no pill.
struct FeedbackPill: View {
  let feedback: SuggestionFeedback?
  let isShowing: Bool

  var body: some View {
    if let label = feedback?.label ?? (isShowing ? "Showing" : nil) {
      StatusBadge(text: label, tint: color)
    }
  }

  private var color: Color {
    switch feedback {
    case .tellMeMore: .green
    case .notNow: .orange
    case .never: .red
    case .expired, .expiredUnseen, .dismissed: .gray
    case nil: .accentColor
    }
  }
}

private struct SuggestionDetail: View {
  @Environment(AppState.self)
  private var state

  let suggestion: Suggestion

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Label(suggestion.category.label, systemImage: suggestion.category.symbol)
              .font(.callout.weight(.semibold))
              .foregroundStyle(.secondary)
            FeedbackPill(
              feedback: suggestion.feedback,
              isShowing: state.activeSuggestion?.id == suggestion.id
            )
            Spacer()
          }
          Text(suggestion.title)
            .font(.title2.weight(.semibold))
            .textSelection(.enabled)
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
          Text(suggestion.body)
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          if let goal = suggestion.judgedGoal, !goal.isEmpty {
            Label("Judged against: \(goal)", systemImage: "target")
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 2)
          }
        }
        Divider()
        Text(suggestion.explanation)
          .font(.body)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Divider()
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
          detailRow("When", Formatting.dayAndTime(suggestion.timestamp))
          detailRow(
            "App",
            suggestion.bundleID.map { "\(suggestion.appName) (\($0))" } ?? suggestion.appName
          )
          if let title = suggestion.windowTitle, !title.isEmpty {
            detailRow("Window", title)
          }
          detailRow("Confidence", String(format: "%.0f%%", suggestion.confidence * 100))
          detailRow(
            "Model",
            """
            \(ModelCatalog.displayName(for: suggestion.model)), prompt \
            v\(suggestion.promptVersion)
            """
          )
          if let feedback = suggestion.feedback {
            detailRow(
              "Feedback",
              feedback.label
                + (suggestion.feedbackAt.map { " at \(Formatting.dayAndTime($0))" } ?? "")
            )
          }
          if let region = suggestion.region {
            detailRow(
              "Callout",
              """
              \(suggestion.calloutShown ? "Shown" : "Not shown"): \"\(region.note)\" at \
              \(Formatting.rect(region.rect)) px of the frame
              """
            )
          } else {
            detailRow("Callout", "None: the suggestion did not point at one spot")
          }
        }
        .font(.callout)
        let exchange = state.exchange(for: suggestion.id)
        if !exchange.isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 10) {
            Text("Talk back")
              .font(.headline)
              .accessibilityAddTraits(.isHeader)
            ForEach(exchange) { entry in
              VStack(alignment: .leading, spacing: 4) {
                exchangeLine("You", entry.question, at: entry.timestamp)
                if let answer = entry.answer {
                  exchangeLine("Athina", answer, at: nil)
                } else {
                  exchangeLine("Athina", "No answer: \(entry.error ?? "unknown error").", at: nil)
                }
              }
            }
          }
        }
        if suggestion.feedback == nil || suggestion.feedback?.isNonAnswer == true
          || suggestion.feedback == .tellMeMore
        {
          HStack(spacing: 8) {
            Button("Not Now") { state.respond(to: suggestion.id, with: .notNow) }
              .help(
                """
                Hide \(suggestion.category.label.lowercased()) suggestions in \
                \(suggestion.appName) for a while
                """
              )
            Button("Never for This") { state.respond(to: suggestion.id, with: .never) }
              .help(
                """
                Stop \(suggestion.category.label.lowercased()) suggestions in \
                \(suggestion.appName)
                """
              )
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func exchangeLine(_ speaker: String, _ text: String, at time: Date?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(speaker)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 48, alignment: .trailing)
      Text(text)
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      if let time {
        Spacer(minLength: 8)
        Text(Formatting.dayAndTime(time))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
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
