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
      // The answers, from the keyboard and the pointer alike: a Suggestions
      // window has no menu bar of its own to carry them.
      .contextMenu(forSelectionType: Int64.self) { ids in
        if let id = ids.first, ids.count == 1,
          let suggestion = state.suggestionHistory.first(where: { $0.id == id })
        {
          SuggestionActions(suggestion: suggestion)
        }
      }
      .overlay {
        if state.suggestionHistory.isEmpty {
          EmptyHistory()
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

/// The empty list, saying why nothing is here yet and offering what would
/// change that.
private struct EmptyHistory: View {
  @Environment(AppState.self)
  private var state

  var body: some View {
    switch state.mentorStatus.availability {
    case .ready:
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
    case .noConsent:
      unavailable(
        "Athina Is Not Watching",
        "Athina makes no suggestions until you allow it to watch the screen.",
        action: "Allow Watching…",
        command: .openConsent
      )
    case .disabled:
      unavailable(
        "Suggestions Are Off",
        "Offer suggestions is turned off in General settings.",
        action: "Open General Settings…",
        command: .openSettings(pane: SettingsPane.general.rawValue)
      )
    case .noAPIKey:
      unavailable(
        "Athina Needs an API Key",
        "Athina makes suggestions once an \(state.settings.mentor.provider.name) API key is saved in Models settings.",
        action: "Add API Key…",
        command: .openSettings(pane: SettingsPane.models.rawValue)
      )
    case .capReached(let until):
      unavailable(
        "Spend Limit Reached",
        """
        This hour's spend limit is reached, so Athina makes no suggestions until \
        \(until.formatted(date: .omitted, time: .shortened)).
        """,
        action: "Open Models Settings…",
        command: .openSettings(pane: SettingsPane.models.rawValue)
      )
    }
  }

  private func unavailable(
    _ title: String,
    _ description: String,
    action: String,
    command: MenuModel.Command
  ) -> some View {
    ContentUnavailableView(
      label: {
        Label(title, systemImage: "lightbulb.slash")
      },
      description: {
        Text(description)
      },
      actions: {
        Button(action) { state.perform(command) }
          .accessibilityIdentifier("history.emptyAction")
      }
    )
  }
}

/// Not Now, Never for This and Copy Suggestion for one suggestion, in the
/// list's context menu.
private struct SuggestionActions: View {
  @Environment(AppState.self)
  private var state

  let suggestion: Suggestion

  private var answerable: Bool { SuggestionDetail.isAnswerable(suggestion) }

  var body: some View {
    Button("Not Now") { state.respond(to: suggestion.id, with: .notNow) }
      .disabled(!answerable)
    Button("Never for This") { state.respond(to: suggestion.id, with: .never) }
      .disabled(!answerable)
    Divider()
    Button("Copy Suggestion") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(
        [suggestion.title, suggestion.body, suggestion.explanation].joined(separator: "\n\n"),
        forType: .string
      )
    }
  }
}

private struct HistoryRow: View {
  @Environment(AppState.self)
  private var state

  let suggestion: Suggestion

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: suggestion.category.symbol)
        .foregroundStyle(suggestion.category.tint)
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
/// An answer is the person's own choice, not a fault, so every answer shares
/// the neutral tint and its word says which it was. A suggestion with neither
/// gets no pill.
struct FeedbackPill: View {
  let feedback: SuggestionFeedback?
  let isShowing: Bool

  var body: some View {
    if let feedback {
      StatusBadge(text: feedback.label, status: .neutral)
    } else if isShowing {
      StatusBadge(text: "Showing", tint: .accentColor)
    }
  }
}

extension SuggestionCategory {
  /// The color the category's symbol is drawn in: a warning in the attention
  /// tint, a tip in the accent.
  var tint: Color {
    isWarning ? StatusTint.attention.color : .accentColor
  }
}

struct SuggestionDetail: View {
  @Environment(AppState.self)
  private var state

  let suggestion: Suggestion

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Label(
              title: {
                Text(suggestion.category.label)
                  .foregroundStyle(.secondary)
              },
              icon: {
                Image(systemName: suggestion.category.symbol)
                  .foregroundStyle(suggestion.category.tint)
              }
            )
            .font(.callout.weight(.semibold))
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
            // Athina's reading of the person's goal, which they must be able
            // to read to judge the suggestion: primary and callout, not a
            // caption hint.
            Label("Judged against: \(goal)", systemImage: "target")
              .font(.callout)
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
            // One grid, so the speaker column is as wide as its widest word.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
              ForEach(exchange) { entry in
                exchangeLine("You", entry.question, at: entry.timestamp)
                if let answer = entry.answer {
                  exchangeLine("Athina", answer, at: nil)
                } else {
                  exchangeLine(
                    "Athina",
                    ExchangeEntry.failure(entry, provider: state.settings.mentor.provider),
                    at: nil
                  )
                  .help(entry.error ?? "")
                }
              }
            }
          }
        }
        if SuggestionDetail.isAnswerable(suggestion) {
          HStack(spacing: 8) {
            Button("Not Now") { state.respond(to: suggestion.id, with: .notNow) }
              .help(notNowConsequence)
              .accessibilityHint(notNowConsequence)
              .accessibilityIdentifier("history.notNow")
            Button("Never for This") { state.respond(to: suggestion.id, with: .never) }
              .help(neverConsequence)
              .accessibilityHint(neverConsequence)
              .accessibilityIdentifier("history.never")
          }
        } else if let feedback = suggestion.feedback,
          let line = state.consequence(of: feedback, for: suggestion)
        {
          // What the answer did, in words rather than only in a tooltip.
          StatusLabel(line, kind: .success)
            .accessibilityIdentifier("history.consequence")
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Whether the detail still offers Not Now and Never for This: while
  /// nothing but Tell Me More or a non-answer is recorded.
  static func isAnswerable(_ suggestion: Suggestion) -> Bool {
    suggestion.feedback == nil || suggestion.feedback?.isNonAnswer == true
      || suggestion.feedback == .tellMeMore
  }

  private var notNowConsequence: String {
    """
    Hides \(suggestion.category.label.lowercased()) suggestions in \(suggestion.appName) \
    for a while
    """
  }

  private var neverConsequence: String {
    "Stops \(suggestion.category.label.lowercased()) suggestions in \(suggestion.appName)"
  }

  /// A speaker and what they said, as a row of the exchange's grid.
  private func exchangeLine(_ speaker: String, _ text: String, at time: Date?) -> some View {
    GridRow {
      Text(speaker)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
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
