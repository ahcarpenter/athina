import AppKit
import MentorCore
import SwiftUI

/// The Contexts pane: the kinds of work the user wants mentoring in, and the
/// switch that makes them a hard boundary.
struct ContextsSettings: View {
    var body: some View {
        Form {
            MentorshipContextsSection()
        }
    }
}

/// The declared contexts, as a section of its own so snapshots can render it.
///
/// The editor works on a local copy and commits on save, because
/// `MentorSettings.validated()` runs on each change and would trim and drop
/// values while they are still being typed. It also refuses exactly what
/// `ContextRules.normalized` would drop - a name past the cap, or one another
/// context already uses - so saved work never disappears silently.
struct MentorshipContextsSection: View {
    @Environment(AppState.self) private var state
    @State private var editing: MentorshipContext?

    private var contexts: [MentorshipContext] { state.settings.mentor.contexts }
    private var enforcing: Bool { state.settings.mentor.onlyMentorInsideContexts }
    private var atCap: Bool { contexts.count >= ContextRules.maxContexts }

    var body: some View {
        @Bindable var state = state
        Section {
            Toggle(isOn: $state.settings.mentor.onlyMentorInsideContexts) {
                Text("Only mentor inside these contexts")
                Text("Mentor stays silent unless it can place what you are doing in one of the contexts below.")
            }
            if enforcing, contexts.isEmpty {
                StatusLabel("No context is declared, so Mentor mentors nowhere. Add a context, or turn this off.", kind: .warning)
            }
            if contexts.isEmpty {
                Text("None yet. Add a context to say what you want mentoring in.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(contexts) { context in
                    ContextRow(context: context) { editing = context }
                }
            }
            LabeledContent {
                Button("Add Context…") {
                    editing = MentorshipContext(name: "")
                }
                .disabled(atCap)
            } label: {
                if atCap {
                    Text("That is all \(ContextRules.maxContexts) contexts. Remove one to add another.")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Mentorship contexts")
        } footer: {
            // The link opens the Privacy pane in place rather than describing where it is.
            Text("Triage places each moment in one of your contexts as part of the judgment it already makes, so contexts cost no extra call. To keep an app from being looked at at all, exclude it in [Privacy settings](mentor-settings:privacy).")
                .settingsPaneLinks()
        }
        .sheet(item: $editing) { context in
            ContextEditor(context: context, existing: contexts) { edited in
                commit(edited)
            }
        }
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

/// One declared context: its name and what it covers, with Edit and Remove.
private struct ContextRow: View {
    @Environment(AppState.self) private var state
    let context: MentorshipContext
    let onEdit: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button("Edit…", action: onEdit)
                    .accessibilityLabel("Edit \(context.name)")
                RemoveButton(itemName: context.name) {
                    state.settings.mentor.contexts.removeAll { $0.id == context.id }
                }
            }
        } label: {
            Label {
                Text(context.name)
                if !context.detail.isEmpty {
                    Text(context.detail)
                }
            } icon: {
                Image(systemName: "target")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Context editor

/// Edits one context on a local copy: the sheet's Save is what writes it back.
/// A context is new when the declared list does not hold its id yet, so the
/// sheet's copy comes from the same data it validates against rather than a
/// flag set beside the presented item.
struct ContextEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MentorshipContext
    private let existing: [MentorshipContext]
    private let onSave: (MentorshipContext) -> Void

    init(
        context: MentorshipContext, existing: [MentorshipContext],
        onSave: @escaping (MentorshipContext) -> Void
    ) {
        _draft = State(initialValue: context)
        self.existing = existing
        self.onSave = onSave
    }

    private var isNew: Bool { !existing.contains { $0.id == draft.id } }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        ContextRules.isDuplicateName(draft.name, in: existing, excluding: draft.id)
    }

    private var nameAtLimit: Bool { trimmedName.count >= MentorshipContext.maxNameLength }

    private var detailAtLimit: Bool {
        draft.detail.trimmingCharacters(in: .whitespacesAndNewlines).count >= MentorshipContext.maxDetailLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("building web apps"))
                        .onSubmit(save)
                        .onChange(of: draft.name) { _, typed in
                            draft.name = ContextRules.capped(typed, to: MentorshipContext.maxNameLength)
                        }
                    if isDuplicate {
                        StatusLabel("Another context is already called \"\(trimmedName)\". Choose a different name.", kind: .warning)
                    } else if nameAtLimit {
                        Text("A name can be at most \(MentorshipContext.maxNameLength) characters.")
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "What it covers", text: $draft.detail, prompt: Text("Optional. React and TypeScript work in the editor and the browser."),
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .onChange(of: draft.detail) { _, typed in
                        draft.detail = ContextRules.capped(typed, to: MentorshipContext.maxDetailLength)
                    }
                    if detailAtLimit {
                        Text("A description can be at most \(MentorshipContext.maxDetailLength) characters.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(isNew ? "New Context" : "Edit Context")
                        .font(.headline)
                        .foregroundStyle(.primary)
                } footer: {
                    Text("A short name in your own words, and optionally a sentence saying what counts. Both go to the triage model, which answers with this name when it places you here.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || isDuplicate)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
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
