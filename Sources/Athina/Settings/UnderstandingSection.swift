import AthinaCore
import SwiftUI

/// Settings for the standing understanding: how often it is rewritten by a call
/// of its own, how large it may grow, how long it survives, and how to forget it.
struct UnderstandingSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Section {
            // A goal is a sentence, so it reads as the row's subtitle, leading
            // and wrapping, rather than as a ragged value against the trailing edge.
            if let record = state.mentorStatus.understanding, let goal = record.content.primaryGoal {
                LabeledContent {
                    Text("Revision \(record.revision)")
                } label: {
                    Text("Current goal")
                    Text(goal.goal)
                    Text("\(Formatting.tokens(record.content.estimatedTokens)) tokens, \(Formatting.dollars(record.cumulativeCost)) in refresh calls")
                }
                .accessibilityElement(children: .combine)
            } else {
                LabeledContent("Current goal") {
                    Text("Not worked out yet")
                }
                .accessibilityElement(children: .combine)
            }
            DurationRow(
                "Refresh at most every", value: $state.settings.mentor.understandingRefreshInterval,
                range: MentorSettings.refreshIntervalRange,
                help: "Every mentor call also rewrites the understanding, at no extra cost. After at least this much active use with no mentor call, Athina makes a refresh call of its own."
            )
            IntRow(
                "Size limit", value: $state.settings.mentor.understandingTokenBudget,
                range: MentorSettings.understandingTokenBudgetRange, step: 100, unit: .tokens,
                help: "When the understanding grows past this, its oldest entries are dropped first and its strongest goal is always kept."
            )
            DurationRow(
                "Forget after no activity for", value: $state.settings.mentor.understandingIdleGap,
                range: MentorSettings.idleGapRange,
                help: "It is also forgotten when a new day starts."
            )
            HStack {
                Spacer()
                ResetUnderstandingButton()
            }
        } header: {
            Text("Understanding")
        } footer: {
            // The link opens the Journal pane in place rather than describing where it is.
            Text("Athina keeps a short written record of what you appear to be working toward and what has happened so far, so it can judge what you do against that goal rather than recent screens alone. The model writes it, and once it is forgotten Athina starts a fresh one. Its revisions stay in the journal on this Mac until they are reset here, or age out or are cleared with the rest of the journal in [Journal settings](athina-settings:journal).")
                .settingsPaneLinks()
        }
    }
}

/// Reset Understanding, in Settings and in the debug panel. It forgets every
/// revision at once and nothing brings them back, so it asks first.
struct ResetUnderstandingButton: View {
    @Environment(AppState.self) private var state
    @State private var confirming = false
    @State private var resetting = false

    var body: some View {
        Button("Reset Understanding…", role: .destructive) {
            confirming = true
        }
        .disabled(state.mentorStatus.understanding == nil || resetting)
        // Resetting is what the person just chose, so the confirming button
        // is the plain default and Cancel stays available, as for Clear Journal.
        .confirmationDialog(
            "Reset the understanding?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Reset Understanding") {
                resetting = true
                Task {
                    await state.resetUnderstanding()
                    resetting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Athina forgets the goals, history, and concerns it has worked out, and starts a new understanding from what you do next. You can't undo this action.")
        }
    }
}
