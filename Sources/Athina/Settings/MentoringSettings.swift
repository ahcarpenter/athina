import AthinaCore
import SwiftUI

/// The Mentoring pane: the kinds of work Athina mentors in, how its
/// suggestions are shown, and the kinds of suggestion turned off with Never
/// for This.
struct MentoringSettings: View {
  var body: some View {
    Form {
      MentorshipContextsSection()
      SuggestionsSection()
      NeverRulesSection()
    }
  }
}

/// Which suggestions are shown, for how long, how long Not Now keeps a kind
/// quiet, and whether a callout marks the spot.
struct SuggestionsSection: View {
  @Environment(AppState.self)
  private var state

  var body: some View {
    @Bindable var state = state
    Section(
      content: {
        PercentRow(
          "Minimum confidence",
          value: $state.settings.mentor.minimumConfidence,
          range: 0...1,
          step: 0.05,
          help: "Suggestions the model is less sure of are logged but not shown."
        )
        NumberRow(
          "Show each suggestion for",
          value: $state.settings.mentor.toastTimeout,
          range: 5...600,
          step: 5,
          unit: .seconds,
          help: "The time runs out only while the pointer is elsewhere."
        )
        DurationRow(
          "Not Now pauses a category for",
          value: $state.settings.mentor.notNowSnooze,
          help: "Suggestions of that kind stay quiet in that app until then."
        )
        Toggle(isOn: $state.settings.mentor.showCallouts) {
          Text("Show callouts on screen")
          Text(
            """
            When a suggestion is about one spot on screen, a callout outlines it and the \
            suggestion says what it outlines. The callout goes away with the suggestion, and \
            whenever its window moves or loses focus.
            """
          )
        }
      },
      header: {
        Text("Suggestions")
      }
    )
  }
}

// MARK: - Never for This

/// The categories turned off for an app with Never for This, each removable,
/// with the tile and name of the kind of note each category is shown as.
struct NeverRulesSection: View {
  @Environment(AppState.self)
  private var state

  var body: some View {
    @Bindable var state = state
    Section(
      content: {
        if state.settings.mentor.neverRules.isEmpty {
          Text(
            """
            None yet. Choose Never for This on a suggestion to stop that kind of suggestion in \
            that app.
            """
          )
          .foregroundStyle(.secondary)
        } else {
          ForEach(state.settings.mentor.neverRules) { rule in
            let kind = NoteKind(rule.category)
            LabeledContent(
              content: {
                RemoveButton(itemName: "\(rule.category.label) in \(rule.appName)") {
                  state.settings.mentor.neverRules.removeAll { $0.id == rule.id }
                }
              },
              label: {
                Label(
                  title: {
                    Text("\(rule.category.label) in \(rule.appName)")
                    Text("\(kind.label) · turned off \(Formatting.dayAndTime(rule.createdAt))")
                  },
                  icon: {
                    KindTile(kind: kind, size: 20)
                  }
                )
              }
            )
          }
        }
      },
      header: {
        Text("Turned off with Never for This")
      },
      footer: {
        Text("Remove a category to let Athina suggest it in that app again.")
      }
    )
  }
}
