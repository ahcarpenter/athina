import AthinaCore
import SwiftUI

// MARK: - Choosing a recognizer

/// The talk-back section's recognizer rows: which recognizer hears the
/// shortcut, its model or language, and where that stands on this Mac, with
/// the action that moves it on.
struct SpeechRecognizerRows: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let speech = state.settings.mentor.speech
        Picker(selection: $state.settings.mentor.speech.backend) {
            ForEach(SpeechBackendID.allCases) { backend in
                Text(backend.title).tag(backend)
            }
        } label: {
            Text("Speech recognizer")
            Text("Recognition runs on this Mac, and audio never leaves it.")
        }
        // Named for VoiceOver and the keyboard: a picker with a two-line label
        // otherwise reaches accessibility with its value and no name.
        .accessibilityLabel("Speech recognizer")
        if speech.backend.downloadsModels {
            Picker("Model", selection: modelBinding(for: speech.backend)) {
                ForEach(speech.backend.models) { model in
                    Text("\(model.title) (\(model.sizeText))").tag(model.id)
                }
            }
            .accessibilityLabel("\(speech.backend.title) model")
        } else {
            LabeledContent {
                Text(state.speechModels.analyzerLanguageName)
            } label: {
                Text("Language")
                Text("The Mac's own language, from Language & Region in System Settings.")
            }
        }
        let current = state.speechModels.state(for: speech)
        LabeledContent {
            if let model = speech.selectedModel {
                SpeechModelStatus(state: current, backend: speech.backend, hasFile: state.speechModels.hasFile(model), subject: model.fullName) { action in
                    state.speechModels.perform(action, on: model)
                }
            } else {
                SpeechModelStatus(state: current, backend: .speechAnalyzer, hasFile: false, subject: state.speechModels.name(for: speech)) { _ in
                    state.speechModels.downloadAnalyzerAssets()
                }
            }
        } label: {
            Text("Status")
            if case .failed(let reason, let canRetry) = current {
                StatusLabel(reason, kind: canRetry ? .error : .warning)
            }
        }
    }

    /// The model picker edits the chosen recognizer's own model, so each
    /// recognizer keeps the one picked for it.
    private func modelBinding(for backend: SpeechBackendID) -> Binding<String> {
        Binding {
            state.settings.mentor.speech.modelID(for: backend)
        } set: { id in
            state.settings.mentor.speech.setModel(id, for: backend)
        }
    }
}

/// Where one recognizer's model stands, and the one or two actions that
/// state offers (`SpeechModelAction`): a status label for a settled state, a
/// progress bar while downloading, and a badge when it cannot be used, whose
/// reason the row shows under its name.
struct SpeechModelStatus: View {
    let state: SpeechModelState
    let backend: SpeechBackendID
    let hasFile: Bool
    /// The model's name, for the buttons' accessibility labels.
    let subject: String
    /// Compact rows show the state as a badge; the status row says it in words.
    var compact = false
    let perform: (SpeechModelAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            indicator
            ForEach(SpeechModelAction.actions(for: state, backend: backend, hasFile: hasFile), id: \.title) { action in
                Button(role: action == .delete ? .destructive : nil) {
                    perform(action)
                } label: {
                    Text(action.title)
                }
                .accessibilityLabel("\(action.title) \(subject)")
            }
        }
    }

    @ViewBuilder private var indicator: some View {
        switch state {
        case .builtIn:
            if compact {
                StatusBadge(text: "Built in", tint: .green)
            } else {
                StatusLabel("Built into macOS", kind: .success)
            }
        case .ready:
            if compact {
                StatusBadge(text: "Ready", tint: .green)
            } else {
                StatusLabel("Downloaded and checked", kind: .success)
            }
        case .notDownloaded:
            Text("Not downloaded")
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            if let fraction {
                ProgressView(value: fraction)
                    .frame(width: compact ? 80 : 120)
                    .accessibilityLabel("Downloading \(subject)")
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Downloading \(subject)")
                Text("Starting")
                    .foregroundStyle(.secondary)
            }
        case .verifying:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Checking \(subject)")
            Text("Checking")
                .foregroundStyle(.secondary)
        case .failed(let reason, let canRetry):
            // The reason is spelled out beside the row's name, where there is
            // room for a sentence; the badge says which kind of trouble.
            StatusBadge(text: canRetry ? "Failed" : "Not available", tint: canRetry ? .red : .orange)
                .help(reason)
        }
    }
}

// MARK: - Managing the models

/// Every recognizer and model, each with its state and what can be done
/// with it: a download to start, one to stop, or a model to delete. Models
/// download from a fixed revision of their repository and are checked
/// against their published SHA-256 before they are used.
struct SpeechModelsSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Section {
            let analyzer = SpeechSettings(backend: .speechAnalyzer)
            LabeledContent {
                SpeechModelStatus(
                    state: state.speechModels.state(for: analyzer), backend: .speechAnalyzer, hasFile: false,
                    subject: state.speechModels.name(for: analyzer), compact: true
                ) { _ in
                    state.speechModels.downloadAnalyzerAssets()
                }
            } label: {
                Text(state.speechModels.name(for: analyzer))
                Text("Managed by macOS and shared with other apps")
                if case .failed(let reason, let canRetry) = state.speechModels.state(for: analyzer) {
                    StatusLabel(reason, kind: canRetry ? .error : .warning)
                }
            }
            ForEach(SpeechModelCatalog.all) { model in
                LabeledContent {
                    SpeechModelStatus(
                        state: state.speechModels.state(of: model), backend: model.backend,
                        hasFile: state.speechModels.hasFile(model), subject: model.fullName, compact: true
                    ) { action in
                        state.speechModels.perform(action, on: model)
                    }
                } label: {
                    Text(model.fullName)
                    Text("\(model.sizeText), \(model.languages), \(model.license)")
                    if case .failed(let reason, let canRetry) = state.speechModels.state(of: model) {
                        StatusLabel(reason, kind: canRetry ? .error : .warning)
                    }
                }
            }
        } header: {
            Text("Speech models")
        } footer: {
            Text("Whisper and Parakeet download from Hugging Face, at a fixed revision, into Athina's own data folder, and each file is checked against its published checksum before it is used. A download is the only thing Athina fetches besides the mentor's model calls, and it sends nothing about you. Whisper's weights are OpenAI's, under the MIT license; Parakeet's are NVIDIA's, under CC BY 4.0.")
        }
    }
}
