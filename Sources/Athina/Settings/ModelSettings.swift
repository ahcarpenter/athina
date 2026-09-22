import AppKit
import AthinaCore
import SwiftUI

/// The Models pane: the Anthropic connection, each model and its effort,
/// how often they are called, what the mentor model sees, and spend.
struct ModelSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            if state.clientMode.isOffline {
                ReplayConnectionSection()
            } else {
                APIKeySection()
            }

            Section {
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
            } header: {
                Text("Models")
            } footer: {
                Text("The triage model takes a quick look whenever what you are doing changes and decides whether the mentor model should look closer. The understanding model rewrites what Athina believes you are working toward, only when no mentor call has done so recently. Effort sets how much a model thinks before answering and is sent only to models that accept it.")
            }

            Section {
                NumberRow(
                    "Triage at most every", value: $state.settings.mentor.triageMinInterval,
                    range: 5...3600, step: 5, unit: .seconds,
                    help: "Triage runs when you switch windows or pause after typing, never more often than this."
                )
                NumberRow(
                    "Mentor at most every", value: $state.settings.mentor.mentorMinInterval,
                    range: 10...7200, step: 10, unit: .seconds,
                    help: "The mentor model runs only when triage finds something that may be worth saying."
                )
                PercentRow(
                    "Skip triage when the screen matches", value: $state.settings.mentor.triageSimilarityThreshold,
                    range: 0.5...1, step: 0.05,
                    help: "Triage is skipped when this much of a window's text matches the last time it was triaged."
                )
            } header: {
                Text("How often")
            }

            Section {
                DurationRow(
                    "Look back over", value: $state.settings.mentor.mentorWindowDuration,
                    help: "Recent screens from this long are sent as text."
                )
                IntRow(
                    "Limit that text to", value: $state.settings.mentor.mentorWindowTokenBudget,
                    range: 500...60000, step: 500, unit: .tokens
                )
                Toggle(isOn: $state.settings.mentor.sendThumbnail) {
                    Text("Send the latest screenshot")
                    Text("The mentor model also receives the most recent screenshot as an image.")
                }
            } header: {
                Text("What the mentor model sees")
            } footer: {
                Text("The triage model receives text only: the app and window, the focused element, the latest screen's recognized text, and a short summary of recent events. Excluded apps and secure text fields are never captured, so they never reach either model.")
            }

            UnderstandingSection()
            SpendSection()
        }
    }
}

/// A tier's model picker and effort picker. The effort picker is disabled,
/// with a note, when the chosen model does not accept the effort parameter.
private struct TierRows: View {
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
        Picker(selection: $effort) {
            ForEach(Effort.allCases) { level in
                Text(level.label.capitalized).tag(level)
            }
        } label: {
            Text("\(tier) effort")
            if !supportsEffort {
                Text("\(ModelCatalog.displayName(for: model)) does not accept an effort setting, so none is sent.")
            }
        }
        .pickerStyle(.segmented)
        .disabled(!supportsEffort)
    }
}

// MARK: - Anthropic

private struct APIKeySection: View {
    @Environment(AppState.self) private var state
    @State private var draft = ""
    @State private var testing = false
    @State private var testResult: Result<String, ClaudeClientError>?
    @State private var saveFailed = false

    var body: some View {
        Section {
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    SecureField("API key", text: $draft, prompt: Text("Paste a key, sk-ant-…"))
                        .labelsHidden()
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(APIKey.normalized(draft) == nil)
                }
            }
            if saveFailed {
                StatusLabel("Paste the whole key. It is one word with no spaces.", kind: .error)
            }
            if let error = state.apiKeyError {
                StatusLabel(error, kind: .error)
            }
            LabeledContent("Saved key") {
                if let hint = state.apiKeyHint {
                    HStack(spacing: 8) {
                        Text("Ends in \(hint)")
                            .monospacedDigit()
                        Button("Remove") {
                            state.removeAPIKey()
                            testResult = nil
                        }
                        .accessibilityLabel("Remove saved key")
                    }
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent {
                Button("Test Connection", action: test)
                    .disabled(!state.hasAPIKey || testing)
            } label: {
                Text("Connection")
                ConnectionResult(testing: testing, result: testResult, replayed: false)
            }
        } header: {
            Text("Anthropic")
        } footer: {
            Text("The key stays in your login keychain and is never written to the journal, the logs, or the debug panel. The mentor's model calls go only to api.anthropic.com, and only while a key is saved.")
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
            testResult = await state.testConnection()
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
            LabeledContent {
                Button("Test Connection", action: test)
                    .disabled(testing)
            } label: {
                Text("Connection")
                ConnectionResult(testing: testing, result: testResult, replayed: true)
            }
        } header: {
            Text("Anthropic")
        } footer: {
            Text("Athina was launched to replay recorded calls, so every call is answered from fixture files. No key is read, nothing is sent to api.anthropic.com, and nothing is billed. Launch Athina without --replay to use the saved key.")
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

/// What the last Test Connection found, under the Connection label.
struct ConnectionResult: View {
    let testing: Bool
    let result: Result<String, ClaudeClientError>?
    let replayed: Bool

    var body: some View {
        if testing {
            Text(replayed ? "Replaying the recorded test call…" : "Contacting api.anthropic.com…")
        } else {
            switch result {
            case nil:
                EmptyView()
            case .success(let model):
                StatusLabel(
                    replayed
                        ? "Replayed: \(ModelCatalog.displayName(for: model)) answered when it was recorded."
                        : "Connected: \(ModelCatalog.displayName(for: model)) answered.",
                    kind: .success
                )
            case .failure(let error):
                StatusLabel(error.description, kind: .error)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Spend

private struct SpendSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Section {
            DollarRow(
                "Spend at most", value: $state.settings.mentor.hourlySpendCap,
                range: 0.05...1000, step: 0.25,
                help: "Calls slow down as the hour's estimated spend nears this amount and stop at it until the next hour begins."
            )
            LabeledContent("This hour") {
                if state.clientMode.isOffline {
                    Text("Nothing billed, calls are replayed")
                } else {
                    let status = state.mentorStatus
                    let spend = "\(Formatting.dollars(status.spendThisHour)) over \(Plural.count(status.callsThisHour, "call", "calls"))"
                    Text(status.isCadenceSlowed ? "\(spend), calls slowed \(Formatting.multiplier(status.cadenceMultiplier))" : spend)
                        .monospacedDigit()
                }
            }
            PriceTableEditor(table: $state.settings.mentor.prices)
        } header: {
            Text("Spend per hour")
        } footer: {
            Text("Cost is estimated from the tokens each response reports and these prices, in dollars per million tokens. Update them when Anthropic's pricing changes.")
        }
    }
}

private struct PriceTableEditor: View {
    @Binding var table: PriceTable

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Model").gridColumnAlignment(.leading)
                    Text("Input")
                    Text("Output")
                    Text("Cache Write")
                    Text("Cache Read")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                ForEach(ModelCatalog.all) { model in
                    GridRow {
                        Text(model.displayName)
                            .gridColumnAlignment(.leading)
                        priceField(model, "input", \.inputPerMillion)
                        priceField(model, "output", \.outputPerMillion)
                        priceField(model, "cache write", \.cacheWritePerMillion)
                        priceField(model, "cache read", \.cacheReadPerMillion)
                    }
                }
            }
            HStack {
                Text("Prices checked \(table.checkedOn)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Default Prices") { table = PriceTable.defaults }
                    .disabled(table == PriceTable.defaults)
            }
        }
    }

    private func priceField(_ model: ClaudeModel, _ column: String, _ keyPath: WritableKeyPath<ModelPrice, Double>) -> some View {
        TextField("\(model.displayName) \(column) price", value: Binding(
            get: { table.prices[model.id]?[keyPath: keyPath] ?? 0 },
            set: { value in
                var price = table.prices[model.id] ?? PriceTable.defaults.prices[model.id]
                    ?? ModelPrice(inputPerMillion: 0, outputPerMillion: 0, cacheWritePerMillion: 0, cacheReadPerMillion: 0)
                price[keyPath: keyPath] = max(0, value)
                table.prices[model.id] = price
            }
        ), format: .number.precision(.fractionLength(2...4)))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 66)
    }
}
