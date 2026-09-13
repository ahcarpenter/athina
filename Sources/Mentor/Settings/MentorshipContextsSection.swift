import AppKit
import MentorCore
import SwiftUI

/// Settings > Mentor > Mentorship contexts: the kinds of work the user wants
/// mentoring in, and the switch that makes them a hard boundary.
///
/// The editor works on a local copy and commits on save, because
/// `MentorSettings.validated()` runs on each change and would trim and drop
/// values while they are still being typed. It also refuses exactly what
/// `ContextRules.normalized` would drop - a name past the cap, or one another
/// context already uses - so saved work never disappears silently.
struct MentorshipContextsSection: View {
    @Environment(AppState.self) private var state
    @State private var editing: MentorshipContext?
    @State private var isNew = false

    private var contexts: [MentorshipContext] { state.settings.mentor.contexts }
    private var enforcing: Bool { state.settings.mentor.onlyMentorInsideContexts }
    private var atCap: Bool { contexts.count >= ContextRules.maxContexts }

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
                .disabled(atCap)
                .help(atCap ? "Remove a context to declare another" : "Declare a context")
                Spacer()
            }
            if atCap {
                Text("That is all \(ContextRules.maxContexts) contexts. Remove one to declare another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Mentorship contexts")
        } footer: {
            Text("Triage places each moment in one of your contexts as part of the judgement it already makes, so declaring them costs no extra call. To stop an app being looked at at all, exclude it in Settings > Privacy.")
        }
        .sheet(item: $editing) { context in
            ContextEditor(context: context, isNew: isNew, existing: contexts) { edited in
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

/// One declared context: its name and what it covers.
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

// MARK: - Context editor

/// Edits one context on a local copy: the sheet's Save is what writes it back.
private struct ContextEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MentorshipContext
    private let isNew: Bool
    private let existing: [MentorshipContext]
    private let onSave: (MentorshipContext) -> Void

    init(
        context: MentorshipContext, isNew: Bool, existing: [MentorshipContext],
        onSave: @escaping (MentorshipContext) -> Void
    ) {
        _draft = State(initialValue: context)
        self.isNew = isNew
        self.existing = existing
        self.onSave = onSave
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        ContextRules.isDuplicateName(draft.name, in: existing, excluding: draft.id)
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
                    if isDuplicate {
                        Label("Another context is already called \"\(trimmedName)\". Give this one a different name.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("A short name in your own words, and optionally a sentence saying what counts. Both go to the triage model, which answers with this name when it places you here.")
                    }
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
                    .disabled(trimmedName.isEmpty || isDuplicate)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 300)
    }

    private func save() {
        guard !trimmedName.isEmpty, !isDuplicate else { return }
        var edited = draft
        edited.name = trimmedName
        edited.detail = draft.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(edited)
        dismiss()
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
