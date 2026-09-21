import AppKit
import AthinaCore
import SwiftUI

/// The General pane: whether Athina offers suggestions and how they are
/// shown, talking back, and the categories turned off with Never for This.
struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Toggle(isOn: $state.settings.mentor.enabled) {
                    Text("Offer suggestions")
                    Text("Athina points out a more helpful way to do what you are doing when it notices one.")
                }
                PercentRow(
                    "Minimum confidence", value: $state.settings.mentor.minimumConfidence,
                    range: 0...1, step: 0.05,
                    help: "Suggestions the model is less sure of are logged but not shown."
                )
                NumberRow(
                    "Show each suggestion for", value: $state.settings.mentor.toastTimeout,
                    range: 5...600, step: 5, unit: .seconds,
                    help: "The time runs out only while the pointer is elsewhere."
                )
                DurationRow(
                    "Not Now pauses a category for", value: $state.settings.mentor.notNowSnooze,
                    help: "Suggestions of that kind stay quiet in that app until then."
                )
                Toggle(isOn: $state.settings.mentor.showCallouts) {
                    Text("Show callouts on screen")
                    Text("When a suggestion is about one spot on screen, a box and a short note mark it. The callout goes away with the suggestion, and whenever its window moves or loses focus.")
                }
            } header: {
                Text("Suggestions")
            }

            VoiceSection()
            NeverRulesSection()
        }
    }
}

// MARK: - Talk back

/// Talking back: the hotkey and what it needs on this Mac.
struct VoiceSection: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        Section {
            LabeledContent {
                HotKeyRecorder(
                    title: "Talk-back shortcut",
                    hotKey: $state.settings.mentor.pushToTalkHotKey,
                    conflicts: [state.settings.pauseHotKey],
                    conflictNote: "That is the pause shortcut."
                )
            } label: {
                Text("Talk-back shortcut")
                if state.isRunning, state.settings.mentor.pushToTalkHotKey != nil, !state.pushToTalkRegistered {
                    StatusLabel("Another app uses this combination. Choose another.", kind: .warning)
                } else {
                    Text("Hold it and speak, then let go to send.")
                }
            }
            LabeledContent("On-device recognition") {
                switch state.speechAvailability {
                case .available(let locale):
                    StatusLabel("Available for \(locale)", kind: .success)
                case .unavailable(let reason):
                    StatusLabel(reason, kind: .warning)
                        .multilineTextAlignment(.trailing)
                }
            }
            ForEach(Permission.optional) { permission in
                LabeledContent(permission.title) {
                    PermissionBadge(granted: state.permissions.isGranted(permission))
                }
            }
            if !state.permissions.voiceGranted {
                HStack {
                    Spacer()
                    Button("Show Permissions…") {
                        NSApp.activate()
                        openWindow(id: WindowID.permissions)
                    }
                }
            }
        } header: {
            Text("Talk back")
        } footer: {
            Text("Hold the shortcut and say \"tell me more,\" \"not now,\" or \"never for this\" to answer a suggestion, or ask a question about it and the answer appears in the suggestion. Audio and transcripts stay on this Mac. Only your question, the suggestion, and the text of the screen it was made from go to the mentor model.")
        }
    }
}

// MARK: - Never for This

/// The categories turned off for an app with Never for This, each removable.
struct NeverRulesSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Section {
            if state.settings.mentor.neverRules.isEmpty {
                Text("None yet. Choose Never for This on a suggestion to stop that kind of suggestion in that app.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.settings.mentor.neverRules) { rule in
                    LabeledContent {
                        RemoveButton(itemName: "\(rule.category.label) in \(rule.appName)") {
                            state.settings.mentor.neverRules.removeAll { $0.id == rule.id }
                        }
                    } label: {
                        Label {
                            Text("\(rule.category.label) in \(rule.appName)")
                            Text("Turned off \(Formatting.dayAndTime(rule.createdAt))")
                        } icon: {
                            Image(systemName: rule.category.symbol)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        } header: {
            Text("Turned off with Never for This")
        } footer: {
            Text("Remove a category to let Athina suggest it in that app again.")
        }
    }
}
