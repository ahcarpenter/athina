import AppKit
import MentorCore
import SwiftUI

/// The Mentor tab: API key, models, cadence, context, delivery, spend, and the
/// learned "never for this" rules.
struct MentorSettingsTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            if state.clientMode.isOffline {
                ReplayConnectionSection()
            } else {
                APIKeySection()
            }

            Section("Models") {
                Toggle("Enable the mentor loop", isOn: $state.settings.mentor.enabled)
                TierRows(
                    tier: "Triage", choices: ModelCatalog.triageChoices,
                    model: $state.settings.mentor.triageModel, effort: $state.settings.mentor.triageEffort
                )
                TierRows(
                    tier: "Mentor", choices: ModelCatalog.mentorChoices,
                    model: $state.settings.mentor.mentorModel, effort: $state.settings.mentor.mentorEffort
                )
                TierRows(
                    tier: "Understanding", choices: ModelCatalog.understandingChoices,
                    model: $state.settings.mentor.understandingModel, effort: $state.settings.mentor.understandingEffort
                )
                Text("Triage runs on change moments and decides whether the mentor model should look. The understanding tier only runs when no mentor call has refreshed the record recently. Effort sets how much the model thinks before answering and is sent only to models that accept it. Every system prompt is cached, so repeated calls pay the cache-read rate for them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            MentorshipContextsSection()

            Section("Cadence") {
                NumberRow(
                    "Triage at most every", value: $state.settings.mentor.triageMinInterval,
                    range: 5...3600, step: 5, unit: "s",
                    help: "Triage runs only on focus changes and settled input, never on floor-cadence frames, and never more often than this."
                )
                NumberRow(
                    "Mentor at most every", value: $state.settings.mentor.mentorMinInterval,
                    range: 10...7200, step: 10, unit: "s",
                    help: "The mentor model runs only when triage says something may be worth saying."
                )
                NumberRow(
                    "Skip triage above similarity", value: $state.settings.mentor.triageSimilarityThreshold,
                    range: 0.5...1, step: 0.05, unit: "",
                    help: "Triage is skipped when at least this fraction of the screen's text lines match the last triaged screen of the same window."
                )
            }

            Section {
                DurationRow("Rolling window", value: $state.settings.mentor.mentorWindowDuration)
                IntRow(
                    "Window text budget", value: $state.settings.mentor.mentorWindowTokenBudget,
                    range: 500...60000, step: 500, unit: "tok",
                    help: "Approximate token budget for recent screens' text sent to the mentor model."
                )
                Toggle(isOn: $state.settings.mentor.sendThumbnail) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send the latest screenshot to the mentor model")
                        Text("When on, the mentor tier receives the latest kept thumbnail as an image. When off, it receives recognized text only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("What the mentor model sees")
            } footer: {
                Text("The triage model always receives text only: app and window, the accessibility summary, the latest screen's recognized text, and a short event summary. Excluded apps and secure fields are never captured, so they never reach either model.")
            }

            UnderstandingSection()

            Section("Delivery") {
                NumberRow(
                    "Minimum confidence", value: $state.settings.mentor.minimumConfidence,
                    range: 0...1, step: 0.05, unit: "",
                    help: "Suggestions the model rates below this are logged but not shown."
                )
                NumberRow(
                    "Toast stays for", value: $state.settings.mentor.toastTimeout,
                    range: 5...600, step: 5, unit: "s"
                )
                DurationRow("Not now snoozes for", value: $state.settings.mentor.notNowSnooze)
                Toggle(isOn: $state.settings.mentor.showCallouts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show callouts on screen")
                        Text("When a suggestion is about one spot on screen, a box and a short note are drawn around it, above the app. It goes away with the toast, and never while the window has moved or lost focus.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VoiceSection()
            SpendSection()
            NeverRulesSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Voice

/// Talking back: the hotkey and what it needs on this Mac.
struct VoiceSection: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    if state.isRunning, state.settings.mentor.pushToTalkHotKey != nil {
                        Label(
                            state.pushToTalkRegistered ? "Active" : "Not registered",
                            systemImage: state.pushToTalkRegistered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(state.pushToTalkRegistered ? Color.green : Color.orange)
                        .help(state.pushToTalkRegistered ? "The hotkey is registered system-wide." : "Another app holds this combination.")
                    }
                    HotKeyRecorder(
                        hotKey: $state.settings.mentor.pushToTalkHotKey,
                        conflicts: [state.settings.pauseHotKey],
                        conflictNote: "That is the pause hotkey."
                    )
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Talk-back hotkey")
                    Text("Hold it to speak; release to send.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("On-device recognition") {
                switch state.speechAvailability {
                case .available(let locale):
                    Label("Available for \(locale)", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                case .unavailable(let reason):
                    Label(reason, systemImage: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Permissions") {
                HStack(spacing: 8) {
                    ForEach(Permission.optional) { permission in
                        HStack(spacing: 4) {
                            Text(permission.title)
                                .font(.callout)
                            StatusPill(granted: state.permissions.isGranted(permission))
                        }
                    }
                    Button("Permissions…") {
                        NSApp.activate()
                        openWindow(id: WindowID.permissions)
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Talking back")
        } footer: {
            Text("Hold the hotkey and speak. \"Tell me more\", \"not now\", and \"never for this\" answer the toast; anything else goes to the mentor model as one follow-up question, on the mentor model and effort above, and the answer comes back in the toast. Audio and transcripts stay on this Mac; only the words you spoke, the suggestion, and the recognized text of the screen it was made from go to the model.")
        }
    }
}

/// A tier's model picker and effort picker. The effort picker is disabled,
/// with a note, when the chosen model rejects the effort parameter.
struct TierRows: View {
    let tier: String
    let choices: [ClaudeModel]
    @Binding var model: String
    @Binding var effort: Effort

    private var supportsEffort: Bool {
        ModelCatalog.model(id: model)?.supportsEffort ?? false
    }

    var body: some View {
        Picker("\(tier) model", selection: $model) {
            ForEach(choices) { choice in
                Text(choice.displayName).tag(choice.id)
            }
        }
        LabeledContent {
            Picker("", selection: $effort) {
                ForEach(Effort.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!supportsEffort)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(tier) effort")
                if !supportsEffort {
                    Text("\(ModelCatalog.displayName(for: model)) does not support effort; none is sent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - API key

private struct APIKeySection: View {
    @Environment(AppState.self) private var state
    @State private var draft = ""
    @State private var testing = false
    @State private var testResult: Result<String, ClaudeClientError>?
    @State private var saveFailed = false

    var body: some View {
        Section {
            LabeledContent("Anthropic API key") {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 8) {
                        SecureField("", text: $draft, prompt: Text("sk-ant-…"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(width: 260)
                            .onSubmit(save)
                        Button("Save", action: save)
                            .disabled(APIKey.normalized(draft) == nil)
                    }
                    HStack(spacing: 8) {
                        if let hint = state.apiKeyHint {
                            Label("Saved key ends in \(hint)", systemImage: "key.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Remove") {
                                state.removeAPIKey()
                                testResult = nil
                            }
                            .controlSize(.small)
                        } else {
                            Label("No key saved", systemImage: "key")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button("Test Connection", action: test)
                    .disabled(!state.hasAPIKey || testing)
                if testing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Contacting api.anthropic.com…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let testResult {
                    switch testResult {
                    case .success(let model):
                        Label("Connected, \(ModelCatalog.displayName(for: model)) answered", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .failure(let error):
                        Label(error.description, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            if saveFailed {
                Text("That does not look like a key: it must be one token with no spaces.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let error = state.apiKeyError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Anthropic")
        } footer: {
            Text("The key is stored in your login keychain and never written to the journal, logs, or the debug panel. Mentor talks only to api.anthropic.com, only when a key is saved, and only from the mentor loop.")
        }
    }

    private func save() {
        saveFailed = !state.saveAPIKey(draft)
        if !saveFailed {
            draft = ""
            testResult = nil
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            let result = await state.testConnection()
            testResult = result
            testing = false
        }
    }
}

/// Stands in for the key section while calls are replayed: there is no key to
/// save, and Test Connection replays a recorded test call.
private struct ReplayConnectionSection: View {
    @Environment(AppState.self) private var state
    @State private var testing = false
    @State private var testResult: Result<String, ClaudeClientError>?

    var body: some View {
        Section {
            LabeledContent("Model calls") {
                Text(state.clientModeLine ?? "Replay mode")
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button("Test Connection", action: test)
                    .disabled(testing)
                if let testResult {
                    switch testResult {
                    case .success(let model):
                        Label("Replayed, \(ModelCatalog.displayName(for: model)) answered when recorded", systemImage: "repeat.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.teal)
                    case .failure(let error):
                        Label(error.description, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
        } header: {
            Text("Anthropic")
        } footer: {
            Text("Mentor was launched to replay recorded calls, so every call is answered from fixture files. No key is read, nothing is sent to api.anthropic.com, and nothing is billed. Launch it without --replay to use the saved key.")
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            testResult = await state.testConnection()
            testing = false
        }
    }
}

// MARK: - Spend

private struct SpendSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Section {
            NumberRow(
                "Hourly spend cap", value: $state.settings.mentor.hourlySpendCap,
                range: 0.05...1000, step: 0.25, unit: "USD",
                help: "Both cadences slow as the hour's estimated spend approaches this, and calls stop at it until the clock hour rolls over."
            )
            LabeledContent("This hour") {
                if state.clientMode.isOffline {
                    Text("Nothing billed: calls are replayed")
                } else {
                    Text("\(Formatting.dollars(state.mentorStatus.spendThisHour)) over \(Plural.count(state.mentorStatus.callsThisHour, "call", "calls")), cadence \(Formatting.multiplier(state.mentorStatus.cadenceMultiplier))")
                        .monospacedDigit()
                }
            }
            PriceTableEditor(table: $state.settings.mentor.prices)
        } header: {
            Text("Spend")
        } footer: {
            Text("Cost is estimated from the token counts each response reports and the prices below (dollars per million tokens). Edit them when Anthropic's pricing changes.")
        }
    }
}

private struct PriceTableEditor: View {
    @Binding var table: PriceTable

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prices checked \(table.checkedOn)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { table = PriceTable.defaults }
                    .controlSize(.small)
            }
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Model").gridColumnAlignment(.leading)
                    Text("Input")
                    Text("Output")
                    Text("Cache write")
                    Text("Cache read")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(ModelCatalog.all) { model in
                    GridRow {
                        Text(model.displayName)
                            .gridColumnAlignment(.leading)
                        priceField(model.id, \.inputPerMillion)
                        priceField(model.id, \.outputPerMillion)
                        priceField(model.id, \.cacheWritePerMillion)
                        priceField(model.id, \.cacheReadPerMillion)
                    }
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
    }

    private func priceField(_ model: String, _ keyPath: WritableKeyPath<ModelPrice, Double>) -> some View {
        TextField("", value: Binding(
            get: { table.prices[model]?[keyPath: keyPath] ?? 0 },
            set: { value in
                var price = table.prices[model] ?? PriceTable.defaults.prices[model]
                    ?? ModelPrice(inputPerMillion: 0, outputPerMillion: 0, cacheWritePerMillion: 0, cacheReadPerMillion: 0)
                price[keyPath: keyPath] = max(0, value)
                table.prices[model] = price
            }
        ), format: .number.precision(.fractionLength(2...4)))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 66)
    }
}

// MARK: - Never rules

private struct NeverRulesSection: View {
    @Environment(AppState.self) private var state
    @State private var selection: String?

    var body: some View {
        @Bindable var state = state
        Section {
            if state.settings.mentor.neverRules.isEmpty {
                Text("None yet. \"Never for this\" on a suggestion adds a rule here.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(state.settings.mentor.neverRules) { rule in
                            HStack(spacing: 8) {
                                Image(systemName: rule.category.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(rule.category.label)
                                Text("in")
                                    .foregroundStyle(.secondary)
                                Text(rule.appName)
                                Spacer()
                                Text(Formatting.dayAndTime(rule.createdAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(rule.id)
                        }
                    }
                    .frame(height: min(200, CGFloat(state.settings.mentor.neverRules.count) * 28 + 12))
                    Divider()
                    HStack(spacing: 0) {
                        Button {
                            if let selection {
                                state.settings.mentor.neverRules.removeAll { $0.id == selection }
                            }
                            selection = nil
                        } label: {
                            Image(systemName: "minus").frame(width: 22, height: 20)
                        }
                        .disabled(selection == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
        } header: {
            Text("Never for this")
        } footer: {
            Text("Categories Mentor must not raise again for an app. Remove a rule to allow that category again.")
        }
    }
}
