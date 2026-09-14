import AppKit
import MentorCore
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable {
        case mentor, cadence, frames, journal, privacy
    }

    @Environment(AppState.self) private var state
    @State private var tab: Tab

    init(initialTab: Tab = .mentor) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            MentorSettingsTab()
                .tabItem { Label("Mentor", systemImage: "lightbulb") }
                .tag(Tab.mentor)
            CadenceSettings()
                .tabItem { Label("Cadence", systemImage: "timer") }
                .tag(Tab.cadence)
            FrameSettings()
                .tabItem { Label("Frames", systemImage: "photo.on.rectangle") }
                .tag(Tab.frames)
            JournalSettings()
                .tabItem { Label("Journal", systemImage: "book.closed") }
                .tag(Tab.journal)
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(Tab.privacy)
        }
        .tabViewStyle(.grouped)
        .frame(minWidth: 600, minHeight: 560)
    }
}

// MARK: - Cadence

private struct CadenceSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Triggers") {
                NumberRow(
                    "Settle after focus change", value: $state.settings.focusSettleDelay,
                    range: 0...5, step: 0.05, unit: "s",
                    help: "Delay after an app or window switch so the new window has finished drawing."
                )
                NumberRow(
                    "Settle after input", value: $state.settings.inputSettleDelay,
                    range: 0.1...30, step: 0.1, unit: "s",
                    help: "Quiet time after typing or mouse activity before capturing."
                )
                NumberRow(
                    "Floor cadence", value: $state.settings.floorInterval,
                    range: 1...600, step: 1, unit: "s",
                    help: "Slow, steady capture interval while you are active."
                )
                NumberRow(
                    "Minimum between captures", value: $state.settings.minCaptureInterval,
                    range: 0.1...60, step: 0.05, unit: "s",
                    help: "Hard lower bound between two captures, whatever triggered them."
                )
            }
            Section("Idle") {
                NumberRow(
                    "Idle after", value: $state.settings.idleThreshold,
                    range: 5...3600, step: 5, unit: "s",
                    help: "Sensing stops after this long without keyboard, mouse, or trackpad input."
                )
                NumberRow(
                    "Poll input while active", value: $state.settings.inputPollInterval,
                    range: 0.1...5, step: 0.1, unit: "s"
                )
                NumberRow(
                    "Poll input while idle", value: $state.settings.idlePollInterval,
                    range: 0.5...30, step: 0.5, unit: "s"
                )
            }
            Section {
                Button("Restore Defaults") {
                    let defaults = SensingSettings()
                    var restored = state.settings
                    restored.focusSettleDelay = defaults.focusSettleDelay
                    restored.inputSettleDelay = defaults.inputSettleDelay
                    restored.floorInterval = defaults.floorInterval
                    restored.minCaptureInterval = defaults.minCaptureInterval
                    restored.idleThreshold = defaults.idleThreshold
                    restored.inputPollInterval = defaults.inputPollInterval
                    restored.idlePollInterval = defaults.idlePollInterval
                    state.settings = restored
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Frames

private struct FrameSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Capture") {
                IntRow(
                    "Longest edge", value: $state.settings.maxFrameDimension,
                    range: 320...4096, step: 64, unit: "px",
                    help: "Frames are downscaled so their longest edge is at most this. Smaller is cheaper to hash, OCR, and store."
                )
                IntRow(
                    "Drop within", value: $state.settings.hashDistanceThreshold,
                    range: 0...PerceptualHash.bitCount, step: 1, unit: "bits",
                    help: "Frames whose 256-bit perceptual hash is within this Hamming distance of the previous kept frame are dropped, unless the window or focused text changed."
                )
            }
            Section("Recognition and storage") {
                Picker("OCR level", selection: $state.settings.ocrLevel) {
                    ForEach(OCRLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text("Accurate costs a few hundred milliseconds per kept frame. Fast is much cheaper but finds no text in dark interfaces such as terminals.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NumberRow(
                    "Thumbnail JPEG quality", value: $state.settings.thumbnailJPEGQuality,
                    range: 0.1...1, step: 0.05, unit: ""
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Journal

private struct JournalSettings: View {
    @Environment(AppState.self) private var state
    @State private var confirmClear = false
    @State private var confirmClearRecordings = false
    @State private var sizeCapMB: Double = 0

    /// Recordings are a developer tool: the section appears only once there
    /// are some, or while the app is recording into its own directory.
    private var showsRecordings: Bool {
        if state.recordingStats != nil { return true }
        if case .record(let directory) = state.clientMode { return directory.standardizedFileURL == state.recordingsURL.standardizedFileURL }
        return false
    }

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Retention") {
                DurationRow("Keep thumbnails for", value: $state.settings.thumbnailRetention)
                DurationRow("Keep text and events for", value: $state.settings.textRetention)
                Text("Text and events are kept at least as long as thumbnails.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("Size cap") {
                    HStack(spacing: 6) {
                        TextField("", value: $sizeCapMB, format: .number.grouping(.never).precision(.fractionLength(0)))
                            .labelsHidden()
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(applySizeCap)
                        Stepper("", value: $sizeCapMB, in: 10...100_000, step: 50, onEditingChanged: { _ in applySizeCap() })
                            .labelsHidden()
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
                NumberRow(
                    "Run retention every", value: $state.settings.retentionInterval,
                    range: 30...86400, step: 30, unit: "s"
                )
            }
            Section("On disk") {
                LabeledContent("Location") {
                    Text(state.journalURL.path)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                if let stats = state.journalStats {
                    LabeledContent("Size", value: Formatting.bytes(stats.usedBytes))
                    LabeledContent("Contents", value: "\(stats.observationCount) observations, \(stats.thumbnailCount) thumbnails, \(stats.eventCount) events")
                }
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([state.journalURL])
                    }
                    Spacer()
                    Button("Clear Journal…", role: .destructive) {
                        confirmClear = true
                    }
                }
            }
            if showsRecordings {
                Section {
                    LabeledContent("Location") {
                        Text(state.recordingsURL.path)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Contents") {
                        if let stats = state.recordingStats {
                            Text("\(Plural.count(stats.count, "recorded call", "recorded calls")), \(Formatting.bytes(stats.bytes))")
                                .monospacedDigit()
                        } else {
                            Text("None yet")
                        }
                    }
                    if let error = state.recordingsError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([state.recordingsURL])
                        }
                        .disabled(state.recordingStats == nil)
                        Spacer()
                        Button("Clear Recordings…", role: .destructive) {
                            confirmClearRecordings = true
                        }
                        .disabled(state.recordingStats == nil)
                    }
                } header: {
                    Text("Recorded model calls")
                } footer: {
                    Text("Written by Mentor --record. Each file holds a whole request, including the screen text and screenshot it sent, and the answer. They stay on this Mac and are not part of the journal.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Clear the recorded model calls?",
            isPresented: $confirmClearRecordings,
            titleVisibility: .visible
        ) {
            Button("Clear Recordings", role: .destructive) {
                state.clearRecordings()
            }
        } message: {
            Text("\(Plural.count(state.recordingStats?.count ?? 0, "recorded call is", "recorded calls are")) deleted from this Mac. This cannot be undone.")
        }
        .confirmationDialog(
            "Clear the activity journal?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear Journal", role: .destructive) {
                Task { await state.clearJournal() }
            }
        } message: {
            Text("Every observation, thumbnail, and event is deleted. This cannot be undone.")
        }
        .task {
            sizeCapMB = Double(state.settings.journalSizeCapBytes / (1024 * 1024))
            await state.refreshJournalStats()
            state.refreshRecordingStats()
        }
    }

    private func applySizeCap() {
        let clamped = min(max(sizeCapMB, 10), 100_000)
        sizeCapMB = clamped
        state.settings.journalSizeCapBytes = Int64(clamped) * 1024 * 1024
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @Environment(AppState.self) private var state
    @State private var selection: String?
    @State private var newBundleID = ""
    @State private var showAdd = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                LabeledContent("Pause hotkey") {
                    HStack(spacing: 10) {
                        if state.isRunning {
                            Label(
                                state.hotKeyRegistered ? "Active" : "Not registered",
                                systemImage: state.hotKeyRegistered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(state.hotKeyRegistered ? Color.green : Color.orange)
                            .help(state.hotKeyRegistered ? "The hotkey is registered system-wide." : "Another app holds this combination, or it needs a Control, Option, or Command modifier.")
                        }
                        HotKeyRecorder(hotKey: $state.settings.pauseHotKey)
                    }
                }
            } footer: {
                Text("Toggles watching from any app. The menu bar icon shows an eye while watching and a crossed eye while paused.")
            }
            Section {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(state.settings.excludedBundleIDs, id: \.self) { id in
                            HStack(spacing: 8) {
                                ExcludedAppIcon(bundleID: id)
                                Text(id)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                            }
                            .tag(id)
                        }
                    }
                    .frame(height: 190)
                    Divider()
                    HStack(spacing: 0) {
                        Button {
                            showAdd = true
                        } label: {
                            Image(systemName: "plus").frame(width: 22, height: 20)
                        }
                        .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                            AddExcludedAppPopover(existing: state.settings.excludedBundleIDs) { id in
                                state.settings.excludedBundleIDs.append(id)
                            }
                        }
                        Divider().frame(height: 16)
                        Button {
                            if let selection {
                                state.settings.excludedBundleIDs.removeAll { $0 == selection }
                            }
                            selection = nil
                        } label: {
                            Image(systemName: "minus").frame(width: 22, height: 20)
                        }
                        .disabled(selection == nil)
                        Spacer()
                        Button("Restore Defaults") {
                            state.settings.excludedBundleIDs = ExcludedApps.defaults
                        }
                        .controlSize(.small)
                        .padding(.trailing, 6)
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("While one of these apps is frontmost, Mentor captures nothing, reads no window or element, and journals only that the app was excluded.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExcludedAppIcon: View {
    let bundleID: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 18, height: 18)
    }
}

private struct AddExcludedAppPopover: View {
    let existing: [String]
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bundleID = ""

    private var runningApps: [(name: String, id: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, !existing.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return nil }
                return (app.localizedName ?? id, id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exclude an app").font(.headline)
            Menu("Choose a running app…") {
                ForEach(runningApps, id: \.id) { app in
                    Button(app.name) { bundleID = app.id }
                }
            }
            TextField("Bundle identifier, e.g. com.example.App", text: $bundleID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(add)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(bundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func add() {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        onAdd(id)
        dismiss()
    }
}

// MARK: - Rows

struct NumberRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var help: String? = nil

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String, help: String? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.help = help
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { value = value.clamped(to: range) }
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct IntRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    var help: String? = nil

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String, help: String? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.help = help
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { value = value.clamped(to: range) }
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A duration picker with a unit menu, for retention periods.
struct DurationRow: View {
    let title: String
    @Binding var value: TimeInterval

    private enum Unit: String, CaseIterable, Identifiable {
        case minutes, hours, days
        var id: String { rawValue }
        var seconds: Double {
            switch self {
            case .minutes: 60
            case .hours: 3600
            case .days: 86400
            }
        }
    }

    @State private var amount: Double = 1
    @State private var unit: Unit = .hours

    init(_ title: String, value: Binding<TimeInterval>) {
        self.title = title
        _value = value
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $amount, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(push)
                Stepper("", value: $amount, in: 1...10_000, step: 1, onEditingChanged: { _ in push() })
                    .labelsHidden()
                Picker("", selection: $unit) {
                    ForEach(Unit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                .onChange(of: unit) { _, _ in push() }
            }
        }
        .onAppear(perform: pull)
        .onChange(of: value) { _, newValue in
            if newValue != amount * unit.seconds { pull() }
        }
    }

    private func pull() {
        let seconds = value
        let chosen: Unit
        if seconds >= 86400, seconds.truncatingRemainder(dividingBy: 86400) == 0 {
            chosen = .days
        } else if seconds >= 3600 {
            chosen = .hours
        } else {
            chosen = .minutes
        }
        unit = chosen
        amount = (seconds / chosen.seconds * 10).rounded() / 10
    }

    private func push() {
        value = max(60, amount * unit.seconds)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
