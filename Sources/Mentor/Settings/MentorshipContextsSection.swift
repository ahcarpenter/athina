import AppKit
import MentorCore
import SwiftUI

/// Settings > Mentor > Mentorship contexts: the kinds of work the user wants
/// mentoring in, the switch that makes them a hard boundary, and the apps and
/// sites that are always inside one or always outside all of them.
///
/// Every editor works on a local copy and commits on save, because
/// `MentorSettings.validated()` runs on each change and would trim and drop
/// values while they are still being typed.
struct MentorshipContextsSection: View {
    @Environment(AppState.self) private var state
    @State private var editing: MentorshipContext?
    @State private var isNew = false

    private var contexts: [MentorshipContext] { state.settings.mentor.contexts }
    private var enforcing: Bool { state.settings.mentor.onlyMentorInsideContexts }

    var body: some View {
        @Bindable var state = state
        Section {
            Toggle(isOn: $state.settings.mentor.onlyMentorInsideContexts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Only mentor inside these contexts")
                    Text("When off, Mentor may speak up about anything it is watching. When on, it stays silent everywhere it cannot place you in one of the contexts below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if enforcing, contexts.isEmpty {
                Label(
                    "No context is declared, so Mentor will not mentor anywhere. Add one below, or turn this off.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            BorderedList {
                if contexts.isEmpty {
                    EmptyListNote("None yet. Add a context to say what you want mentoring in.")
                } else {
                    ForEach(contexts) { context in
                        ContextRow(context: context) { edit(context) }
                        if context.id != contexts.last?.id { Divider() }
                    }
                }
            } toolbar: {
                Button {
                    editing = MentorshipContext(name: "")
                    isNew = true
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20)
                }
                .help("Declare a context")
                Spacer()
            }
            NumberRow(
                "Least confidence to count as inside", value: $state.settings.mentor.contextConfidence,
                range: 0...1, step: 0.05, unit: "",
                help: "Triage names the context it thinks you are in and how sure it is. Below this, the moment counts as out of context and nothing is said."
            )
            .disabled(!enforcing)
        } header: {
            Text("Mentorship contexts")
        } footer: {
            Text("Triage places each moment in one of your contexts as part of the judgement it already makes, so declaring them costs no extra call. An app or site listed inside a context skips that question; one on the always-outside list below is never sent anywhere at all.")
        }
        .sheet(item: $editing) { context in
            ContextEditor(context: context, isNew: isNew) { edited in
                commit(edited)
            }
        }
    }

    private func edit(_ context: MentorshipContext) {
        isNew = false
        editing = context
    }

    private func commit(_ edited: MentorshipContext) {
        var all = state.settings.mentor.contexts
        if let index = all.firstIndex(where: { $0.id == edited.id }) {
            all[index] = edited
        } else {
            all.append(edited)
        }
        state.settings.mentor.contexts = all
    }
}

/// One declared context: its name, what it covers, and its always-inside rules.
private struct ContextRow: View {
    @Environment(AppState.self) private var state
    let context: MentorshipContext
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "target")
                .foregroundStyle(.tint)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.name)
                    .fontWeight(.medium)
                if !context.detail.isEmpty {
                    Text(context.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !context.alwaysInside.isEmpty {
                    Text("Always inside: " + context.alwaysInside.map(\.value).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Edit", action: onEdit)
                .controlSize(.small)
            Button {
                state.settings.mentor.contexts.removeAll { $0.id == context.id }
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Remove this context")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// The always-outside list: apps and sites Mentor never looks at.
struct AlwaysOutsideSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Section {
            ContextRuleEditor(
                rules: $state.settings.mentor.alwaysOutside,
                addLabel: "Never mentor in"
            )
        } header: {
            Text("Always outside")
        } footer: {
            Text("Mentor never triages these, whether or not the switch above is on, so no text from them ever leaves this Mac. Apps match the bundle identifier or the app name; sites match a domain in the window title. This is separate from Settings > Privacy, where an excluded app is not even sensed.")
        }
    }
}

// MARK: - Context editor

/// Edits one context on a local copy: the sheet's Save is what writes it back.
private struct ContextEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MentorshipContext
    private let isNew: Bool
    private let onSave: (MentorshipContext) -> Void

    init(context: MentorshipContext, isNew: Bool, onSave: @escaping (MentorshipContext) -> Void) {
        _draft = State(initialValue: context)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Declare a context" : "Edit context")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("building web apps"))
                        .onSubmit(save)
                    TextField(
                        "What it covers", text: $draft.detail, prompt: Text("Optional. React and TypeScript work in the editor and the browser."),
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                } footer: {
                    Text("A short name in your own words, and optionally a sentence saying what counts. Both go to the triage model, which answers with this name when it places you here.")
                }
                Section {
                    ContextRuleEditor(rules: $draft.alwaysInside, addLabel: "Always inside")
                } header: {
                    Text("Always inside this context")
                } footer: {
                    Text("Mentor treats these as inside without asking the model. Everything else in this context is judged from what is on screen.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 470)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        var edited = draft
        edited.name = trimmedName
        edited.detail = draft.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(edited)
        dismiss()
    }
}

// MARK: - Rule editing

/// A bordered list of app and site rules with an add row underneath. New rules
/// are typed into local state and appended on Add, so nothing is normalized
/// away mid-word.
private struct ContextRuleEditor: View {
    @Binding var rules: [ContextRule]
    let addLabel: String

    @State private var kind: ContextRule.Kind = .app
    @State private var value = ""

    private var trimmed: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        let normalized = ContextRules.normalized(trimmed, kind: kind).lowercased()
        return rules.contains { $0.kind == kind && $0.value.lowercased() == normalized }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BorderedList {
                if rules.isEmpty {
                    EmptyListNote("No app or site listed.")
                } else {
                    ForEach(rules) { rule in
                        RuleRow(rule: rule) {
                            rules.removeAll { $0.id == rule.id }
                        }
                        if rule.id != rules.last?.id { Divider() }
                    }
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $kind) {
                    ForEach(ContextRule.Kind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(addLabel)
                if kind == .app {
                    RunningAppMenu(existing: rules) { value = $0 }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                // Without labelsHidden a Form lays an empty-label field out in
                // its trailing column, which leaves it half the width.
                TextField("", text: $value, prompt: Text(kind.placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(trimmed.isEmpty || isDuplicate)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func add() {
        guard !trimmed.isEmpty, !isDuplicate else { return }
        rules.append(ContextRule(kind: kind, value: ContextRules.normalized(trimmed, kind: kind)))
        value = ""
    }
}

private struct RuleRow: View {
    let rule: ContextRule
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if rule.kind == .app {
                AppRuleIcon(value: rule.value)
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            Text(rule.value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(rule.kind.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// The app's icon when the value is a bundle identifier of an installed app.
private struct AppRuleIcon: View {
    let value: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 18, height: 18)
    }
}

private struct RunningAppMenu: View {
    let existing: [ContextRule]
    let onPick: (String) -> Void

    private var runningApps: [(name: String, id: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier,
                      !existing.contains(where: { $0.kind == .app && $0.value.caseInsensitiveCompare(id) == .orderedSame })
                else { return nil }
                return (app.localizedName ?? id, id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Menu {
            ForEach(runningApps, id: \.id) { app in
                Button(app.name) { onPick(app.id) }
            }
        } label: {
            Label("Choose a running app", systemImage: "macwindow.on.rectangle")
        }
        .fixedSize()
        .help("Fill in the bundle identifier of an app that is running now")
    }
}

// MARK: - Shared chrome

/// The bordered, rounded container the settings lists share.
struct BorderedList<Content: View, Toolbar: View>: View {
    private let content: Content
    private let toolbar: Toolbar
    private let hasToolbar: Bool

    init(@ViewBuilder content: () -> Content, @ViewBuilder toolbar: () -> Toolbar) {
        self.content = content()
        self.toolbar = toolbar()
        hasToolbar = true
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) { content }
            if hasToolbar {
                Divider()
                HStack(spacing: 0) { toolbar }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }
}

extension BorderedList where Toolbar == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
        toolbar = EmptyView()
        hasToolbar = false
    }
}

struct EmptyListNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
