import AthinaCore
import SwiftUI

/// The Models pane: which provider answers and its key, and what it may spend
/// first, as the two things a person must set, then each model and its effort,
/// how often they are called, what the mentor model sees, and the understanding.
struct ModelSettings: View {
  @Environment(AppState.self)
  private var state

  var body: some View {
    @Bindable var state = state
    let provider = state.settings.mentor.provider
    Form {
      ProviderSection()
      SpendSection()

      Section(
        content: {
          TierRows(
            tier: "Triage",
            choices: ModelCatalog.choices(for: .triage, provider: provider),
            provider: provider,
            model: $state.settings.mentor.tierModels.triage,
            effort: $state.settings.mentor.tierModels.triageEffort
          )
          TierRows(
            tier: "Mentor",
            choices: ModelCatalog.choices(for: .mentor, provider: provider),
            provider: provider,
            model: $state.settings.mentor.tierModels.mentor,
            effort: $state.settings.mentor.tierModels.mentorEffort
          )
          TierRows(
            tier: "Understanding",
            choices: ModelCatalog.choices(for: .understanding, provider: provider),
            provider: provider,
            model: $state.settings.mentor.tierModels.understanding,
            effort: $state.settings.mentor.tierModels.understandingEffort
          )
        },
        header: {
          Text("Models")
        },
        footer: {
          Text(
            """
            The triage model takes a quick look whenever what you are doing changes and \
            decides whether the mentor model should look closer. The understanding model \
            rewrites what Athina believes you are working toward, only when no mentor call has \
            done so recently. Effort sets how much a model thinks before answering and is sent \
            only to models that accept it. Each provider keeps its own choices.
            """
          )
        }
      )

      Section(
        content: {
          NumberRow(
            "Triage at most every",
            value: $state.settings.mentor.triageMinInterval,
            range: 5...3600,
            step: 5,
            unit: .seconds,
            help:
              """
              Triage runs when you switch windows or pause after typing, never more often \
              than this.
              """
          )
          NumberRow(
            "Mentor at most every",
            value: $state.settings.mentor.mentorMinInterval,
            range: 10...7200,
            step: 10,
            unit: .seconds,
            help: "The mentor model runs only when triage finds something that may be worth saying."
          )
          PercentRow(
            "Skip triage when the screen matches",
            value: $state.settings.mentor.triageSimilarityThreshold,
            range: 0.5...1,
            step: 0.05,
            help:
              """
              Triage is skipped when this much of a window's text matches the last time it was \
              triaged.
              """
          )
        },
        header: {
          Text("How often")
        }
      )

      Section(
        content: {
          DurationRow(
            "Look back over",
            value: $state.settings.mentor.mentorWindowDuration,
            help: "Recent screens from this long are sent as text."
          )
          IntRow(
            "Limit that text to",
            value: $state.settings.mentor.mentorWindowTokenBudget,
            range: 500...60000,
            step: 500,
            unit: .tokens
          )
          Toggle(isOn: $state.settings.mentor.sendThumbnail) {
            Text("Send the latest screenshot")
            Text("The mentor model also receives the most recent screenshot as an image.")
          }
        },
        header: {
          Text("What the mentor model sees")
        },
        footer: {
          Text(
            """
            The triage model receives text only: the app and window, the focused element, the \
            latest screen's recognized text, and a short summary of recent events. Excluded \
            apps and secure text fields are never captured, so they never reach either model.
            """
          )
        }
      )

      UnderstandingSection()
    }
  }
}

/// Which provider answers, as a pop-up button with each provider's mark,
/// then the chosen provider's key or, while calls are replayed, what they are
/// replayed from.
///
/// The picker stays in a replay, since the provider still decides the models,
/// the consent page and the menu; only the key has nothing to do there. The
/// Setup window's model page shows it too (`ModelPage`).
struct ProviderSection: View {
  @Environment(AppState.self)
  private var state

  var body: some View {
    @Bindable var state = state
    let picker = Picker("Provider", selection: $state.settings.mentor.provider) {
      ForEach(ModelProvider.allCases) { choice in
        Label {
          Text(choice.name)
        } icon: {
          Image(nsImage: ProviderMark.image(for: choice))
        }
        .tag(choice)
      }
    }
    .accessibilityIdentifier("models.provider")
    if state.clientMode.isOffline {
      ReplayConnectionSection(header: "Model provider") { picker }
    } else {
      APIKeySection(provider: state.settings.mentor.provider, header: "Model provider") {
        picker
      }
    }
  }
}

/// A tier's model picker and effort picker.
///
/// The effort picker is disabled, with a note, when the chosen model does not
/// accept the effort parameter.
private struct TierRows: View {
  let tier: String
  let choices: [ClaudeModel]
  let provider: ModelProvider
  @Binding var model: String
  @Binding var effort: Effort

  private var supportsEffort: Bool {
    ModelCatalog.model(id: model, provider: provider)?.supportsEffort ?? false
  }

  var body: some View {
    Picker("\(tier) model", selection: $model) {
      ForEach(choices) { choice in
        Text(choice.displayName).tag(choice.id)
      }
    }
    Picker(
      selection: $effort,
      content: {
        ForEach(Effort.allCases) { level in
          Text(level.label.capitalized).tag(level)
        }
      },
      label: {
        Text("\(tier) effort")
        if !supportsEffort {
          Text(
            """
            \(ModelCatalog.displayName(for: model)) does not accept an effort setting, so none \
            is sent.
            """
          )
        }
      }
    )
    .pickerStyle(.segmented)
    .disabled(!supportsEffort)
  }
}

/// What the key section says when a pasted key cannot be used.
enum APIKeyEntry {
  static let saveFailure = "Paste the whole key. It is one word with no spaces."
}

/// The provider in force's key: pasted here, kept in the login keychain, and
/// tested with one tiny call, with `leading` first when the layout keeps the
/// picker in this section.
private struct APIKeySection<Leading: View>: View {
  @Environment(AppState.self)
  private var state

  let provider: ModelProvider
  let header: String
  let leading: Leading

  @State private var draft = ""
  @State private var testing = false
  @State private var testResult: Result<String, ClaudeClientError>?
  @State private var saveFailed = false
  @State private var confirmRemove = false

  init(provider: ModelProvider, header: String, @ViewBuilder leading: () -> Leading) {
    self.provider = provider
    self.header = header
    self.leading = leading()
  }

  var body: some View {
    Section(
      content: {
        leading
        LabeledContent("API key") {
          HStack(spacing: 8) {
            SecureField("API key", text: $draft, prompt: Text(provider.keyPlaceholder))
              .labelsHidden()
              .onSubmit(save)
              // The complaint is about the key that was saved; a new one being
              // typed has not been judged yet.
              .onChange(of: draft) { _, _ in saveFailed = false }
            Button("Save", action: save)
              .disabled(APIKey.normalized(draft) == nil)
          }
        }
        if saveFailed {
          StatusLabel(APIKeyEntry.saveFailure, kind: .error)
        }
        if let error = state.apiKeyError {
          StatusLabel(error, kind: .error)
        }
        LabeledContent("Saved key") {
          if let hint = state.apiKeyHint {
            HStack(spacing: 8) {
              Text("Ends in \(hint)")
                .monospacedDigit()
              Button("Remove…", role: .destructive) {
                confirmRemove = true
              }
              .accessibilityLabel("Remove saved key")
              .accessibilityIdentifier("models.removeKey")
            }
          } else {
            Text("None")
              .foregroundStyle(.secondary)
          }
        }
        LabeledContent(
          content: {
            Button("Test Connection", action: test)
              .disabled(!state.hasAPIKey || testing)
          },
          label: {
            Text("Connection")
            ConnectionResult(
              testing: testing,
              result: testResult,
              replayed: false,
              provider: provider
            )
          }
        )
      },
      header: {
        Text(header)
      },
      footer: {
        Text(footer)
      }
    )
    // A key typed for one provider is never saved as another's.
    .onChange(of: provider) {
      draft = ""
      testResult = nil
      saveFailed = false
    }
    // Only a new key from the provider's account brings it back, so it asks
    // first; the confirming button is plain, since it is what the person chose.
    .confirmationDialog(
      "Remove the saved \(provider.name) API key?",
      isPresented: $confirmRemove,
      titleVisibility: .visible,
      actions: {
        Button("Remove Key") {
          state.removeAPIKey()
          testResult = nil
        }
        Button("Cancel", role: .cancel) {}
      },
      message: {
        Text(
          """
          Athina stops asking \(provider.name) until you paste a key again, and a removed key \
          can only be copied again from your \(provider.name) account.
          """
        )
      }
    )
  }

  private var footer: String {
    var text =
      """
      Calls are billed to your own account with \(provider.name), with the key you add here, \
      and choosing a provider that sends to another company asks for your consent again. The \
      key stays in your login keychain and is never written to the journal, the logs, or the \
      debug panel. Athina connects only to \(provider.host), and only while a key is saved.
      """
    if provider == .openCode {
      text += " OpenCode passes each call to Anthropic or OpenAI, whichever makes the model."
    }
    return text
  }

  private func save() {
    saveFailed = !state.saveAPIKey(draft)
    if saveFailed {
      Announce.post(APIKeyEntry.saveFailure)
    } else {
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
      ConnectionResult.announce(result, replayed: false, provider: provider)
    }
  }
}

/// Stands in for the key section while calls are replayed: there is no key to
/// save, and Test Connection replays a recorded test call.
private struct ReplayConnectionSection<Leading: View>: View {
  @Environment(AppState.self)
  private var state

  let header: String
  let leading: Leading

  @State private var testing = false
  @State private var testResult: Result<String, ClaudeClientError>?

  init(header: String, @ViewBuilder leading: () -> Leading) {
    self.header = header
    self.leading = leading()
  }

  var body: some View {
    Section(
      content: {
        leading
        LabeledContent("Model calls") {
          Text(state.clientModeLine ?? "Replay mode")
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        LabeledContent(
          content: {
            Button("Test Connection", action: test)
              .disabled(testing)
          },
          label: {
            Text("Connection")
            ConnectionResult(
              testing: testing,
              result: testResult,
              replayed: true,
              provider: state.settings.mentor.provider
            )
          }
        )
      },
      header: {
        Text(header)
      },
      footer: {
        Text(
          """
          Athina was launched to replay recorded calls, so every call is answered from fixture \
          files, whichever provider is chosen. No key is read, nothing is sent to any provider, \
          and nothing is billed. Launch Athina without --replay to use your saved keys.
          """
        )
      }
    )
  }

  private func test() {
    testing = true
    testResult = nil
    Task {
      let result = await state.testConnection()
      testResult = result
      testing = false
      ConnectionResult.announce(
        result,
        replayed: true,
        provider: state.settings.mentor.provider
      )
    }
  }
}

/// What the last Test Connection found, under the Connection label.
///
/// A failure says what it means in Athina's words (`UserFacing`), with the
/// API's own text as the tooltip.
struct ConnectionResult: View {
  let testing: Bool
  let result: Result<String, ClaudeClientError>?
  let replayed: Bool
  /// Whose API the test goes to, which a live wait and a failure name.
  let provider: ModelProvider

  var body: some View {
    if testing {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
          .accessibilityHidden(true)
        Text(replayed ? "Replaying the recorded test call…" : "Contacting \(provider.host)…")
      }
    } else if let result {
      switch result {
      case .success:
        StatusLabel(
          Self.sentence(for: result, replayed: replayed, provider: provider),
          kind: .success
        )
      case .failure(let error):
        StatusLabel(
          Self.sentence(for: result, replayed: replayed, provider: provider),
          kind: .error
        )
        .textSelection(.enabled)
        .help(error.description)
      }
    }
  }

  static func sentence(
    for result: Result<String, ClaudeClientError>,
    replayed: Bool,
    provider: ModelProvider
  ) -> String {
    switch result {
    case .success(let model):
      replayed
        ? "Replayed: \(ModelCatalog.displayName(for: model)) answered when it was recorded."
        : "Connected: \(ModelCatalog.displayName(for: model)) answered."
    case .failure(let error):
      UserFacing.sentence(for: error, provider: provider)
    }
  }

  /// Tells VoiceOver what the test found, since it comes after the button
  /// that asked, in a line the person is not on.
  @MainActor
  static func announce(
    _ result: Result<String, ClaudeClientError>,
    replayed: Bool,
    provider: ModelProvider
  ) {
    Announce.post(sentence(for: result, replayed: replayed, provider: provider))
  }
}

// MARK: - Spend

/// What the provider may spend each hour, and what this hour has spent; the
/// Setup window's model page shows only the limit (`ModelPage`).
struct SpendSection: View {
  @Environment(AppState.self)
  private var state

  /// Only the limit, for the Setup window: what this hour spent and the price
  /// table are for a person tuning Athina, not one setting it up.
  var limitOnly = false

  var body: some View {
    @Bindable var state = state
    Section(
      content: {
        DollarRow(
          "Spend at most",
          value: $state.settings.mentor.hourlySpendCap,
          range: 0.05...1000,
          step: 0.25,
          help:
            """
            Calls slow down as the hour's estimated spend nears this amount and stop at it \
            until the next hour begins.
            """,
          identifier: "models.spendCap"
        )
        if !limitOnly {
          SpendDetailRows()
        }
      },
      header: {
        Text("Spend per hour")
      },
      footer: {
        if !limitOnly {
          Text(
            """
            Cost is estimated from the tokens each response reports and these prices, in \
            dollars per million tokens, across every provider. Update them when \
            \(state.settings.mentor.provider.name)'s pricing changes.
            """
          )
        }
      }
    )
  }
}

/// What this hour has spent, and the prices it is estimated from.
private struct SpendDetailRows: View {
  @Environment(AppState.self)
  private var state

  var body: some View {
    @Bindable var state = state
    Group {
      LabeledContent("This hour") {
        if state.clientMode.isOffline {
          Text("Nothing billed, calls are replayed")
        } else {
          let status = state.mentorStatus
          let spend =
            """
            \(Formatting.dollars(status.spendThisHour)) over \
            \(Plural.count(status.callsThisHour, "call", "calls"))
            """
          Text(
            status.isCadenceSlowed
              ? "\(spend), calls slowed \(Formatting.multiplier(status.cadenceMultiplier))"
              : spend
          )
          .monospacedDigit()
        }
      }
      // Twenty prices a person rarely changes, folded away until wanted.
      DisclosureGroup("Prices per million tokens") {
        PriceTableEditor(
          table: $state.settings.mentor.prices,
          models: ModelCatalog.models(for: state.settings.mentor.provider)
        )
      }
      .accessibilityIdentifier("models.prices")
    }
  }
}

/// The prices of the provider in force's models, and the button that puts
/// every provider's back.
private struct PriceTableEditor: View {
  @Binding var table: PriceTable
  let models: [ClaudeModel]

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
        ForEach(models) { model in
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

  private func priceField(
    _ model: ClaudeModel,
    _ column: String,
    _ keyPath: WritableKeyPath<ModelPrice, Double>
  ) -> some View {
    TextField(
      "\(model.displayName) \(column) price",
      value: Binding(
        get: { table.prices[model.priceKey]?[keyPath: keyPath] ?? 0 },
        set: { value in
          var price =
            table.prices[model.priceKey] ?? PriceTable.defaults.prices[model.priceKey]
            ?? ModelPrice(
              inputPerMillion: 0,
              outputPerMillion: 0,
              cacheWritePerMillion: 0,
              cacheReadPerMillion: 0
            )
          price[keyPath: keyPath] = max(0, value)
          table.prices[model.priceKey] = price
        }
      ),
      format: .number.precision(.fractionLength(2...4))
    )
    .labelsHidden()
    .multilineTextAlignment(.trailing)
    .frame(width: 66)
  }
}
