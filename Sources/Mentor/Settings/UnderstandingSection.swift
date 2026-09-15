import MentorCore
import SwiftUI

/// Settings for the standing understanding: how often it is rewritten by a call
/// of its own, how large it may grow, how long it survives, and how to forget it.
struct UnderstandingSection: View {
    @Environment(AppState.self) private var state
    @State private var resetting = false

    var body: some View {
        @Bindable var state = state
        Section {
            if let record = state.mentorStatus.understanding, let goal = record.content.primaryGoal {
                LabeledContent("Currently") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(goal.goal)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("revision \(record.revision), \(record.content.estimatedTokens) tokens, \(Formatting.dollars(record.cumulativeCost)) so far")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("Currently") {
                    Text("nothing worked out yet")
                        .foregroundStyle(.secondary)
                }
            }
            NumberRow(
                "Refresh at most every", value: $state.settings.mentor.understandingRefreshInterval,
                range: MentorSettings.refreshIntervalRange, step: 300, unit: "s",
                help: "Every mentor call rewrites the understanding on the way past, for free. This is how long it may go unrefreshed, counting only time you are active, before a call of its own is made."
            )
            IntRow(
                "Size limit", value: $state.settings.mentor.understandingTokenBudget,
                range: MentorSettings.understandingTokenBudgetRange, step: 100, unit: "tok",
                help: "The record is trimmed to fit, oldest timeline entries first, so it can never grow without bound."
            )
            DurationRow("Forget after no activity for", value: $state.settings.mentor.understandingIdleGap)
            HStack {
                Button("Reset Understanding") {
                    resetting = true
                    Task {
                        await state.resetUnderstanding()
                        resetting = false
                    }
                }
                .disabled(state.mentorStatus.understanding == nil || resetting)
                Spacer()
            }
        } header: {
            Text("Understanding")
        } footer: {
            Text("Mentor keeps a short written record of what you appear to be working toward and what has happened, so it can judge what you are doing against your goal instead of the last ten minutes alone. It is written by the model, kept in the journal, cleared by Clear Journal, and always forgotten at a new day.")
        }
    }
}
