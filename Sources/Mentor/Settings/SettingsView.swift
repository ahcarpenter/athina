import AppKit
import MentorCore
import SwiftUI

/// A pane of the Settings window. The last pane viewed is remembered, and
/// `--open settings:<pane>` or a link inside another pane can choose it.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, contexts, models, capture, journal, privacy

    static let storageKey = "SettingsPane"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .contexts: "Contexts"
        case .models: "Models"
        case .capture: "Capture"
        case .journal: "Journal"
        case .privacy: "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .contexts: "target"
        case .models: "sparkles"
        case .capture: "camera.viewfinder"
        case .journal: "book.closed"
        case .privacy: "hand.raised"
        }
    }

    /// Makes this the pane the Settings window shows, now or when it next opens.
    func select() {
        UserDefaults.standard.set(rawValue, forKey: SettingsPane.storageKey)
    }
}

/// The Settings window: a standard toolbar of panes. The window takes its
/// title from the pane, and each pane is a grouped form of a fixed size that
/// scrolls when its settings run longer.
struct SettingsView: View {
    static let paneWidth: CGFloat = 600

    @AppStorage(SettingsPane.storageKey) private var pane = SettingsPane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab(SettingsPane.general.title, systemImage: SettingsPane.general.symbol, value: .general) {
                GeneralSettings().settingsPane(height: 640)
            }
            Tab(SettingsPane.contexts.title, systemImage: SettingsPane.contexts.symbol, value: .contexts) {
                ContextsSettings().settingsPane(height: 520)
            }
            Tab(SettingsPane.models.title, systemImage: SettingsPane.models.symbol, value: .models) {
                ModelSettings().settingsPane(height: 640)
            }
            Tab(SettingsPane.capture.title, systemImage: SettingsPane.capture.symbol, value: .capture) {
                CaptureSettings().settingsPane(height: 640)
            }
            Tab(SettingsPane.journal.title, systemImage: SettingsPane.journal.symbol, value: .journal) {
                JournalSettings().settingsPane(height: 500)
            }
            Tab(SettingsPane.privacy.title, systemImage: SettingsPane.privacy.symbol, value: .privacy) {
                PrivacySettings().settingsPane(height: 560)
            }
        }
    }
}

extension View {
    /// A Settings pane: a grouped form at the pane's size.
    func settingsPane(height: CGFloat) -> some View {
        formStyle(.grouped)
            .frame(width: SettingsView.paneWidth, height: height)
    }

    /// Opens a `mentor-settings:<pane>` link in this text as that Settings
    /// pane, so text names a place elsewhere in Settings by linking to it.
    func settingsPaneLinks() -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "mentor-settings", let pane = SettingsPane(rawValue: url.absoluteString.replacingOccurrences(of: "mentor-settings:", with: "")) else {
                return .systemAction
            }
            pane.select()
            return .handled
        })
    }
}

// MARK: - Capture

struct CaptureSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                NumberRow(
                    "Wait after switching windows", value: $state.settings.focusSettleDelay,
                    range: 0...5, step: 0.05, unit: .seconds,
                    help: "Gives the new window time to finish drawing before it is captured."
                )
                NumberRow(
                    "Wait after typing or clicking", value: $state.settings.inputSettleDelay,
                    range: 0.1...30, step: 0.1, unit: .seconds,
                    help: "Quiet time after keyboard, mouse, or trackpad input before a capture."
                )
                NumberRow(
                    "Capture at least every", value: $state.settings.floorInterval,
                    range: 1...600, step: 1, unit: .seconds,
                    help: "A slow, steady capture while you are active, even when nothing triggers one."
                )
                NumberRow(
                    "Capture at most every", value: $state.settings.minCaptureInterval,
                    range: 0.1...60, step: 0.05, unit: .seconds,
                    help: "The shortest time between two captures, whatever triggered them."
                )
            } header: {
                Text("When to capture")
            }
            Section {
                NumberRow(
                    "Idle after", value: $state.settings.idleThreshold,
                    range: 5...3600, step: 5, unit: .seconds,
                    help: "Sensing stops after this long without keyboard, mouse, or trackpad input."
                )
                NumberRow(
                    "Check for input while active every", value: $state.settings.inputPollInterval,
                    range: 0.1...5, step: 0.1, unit: .seconds
                )
                NumberRow(
                    "Check for input while idle every", value: $state.settings.idlePollInterval,
                    range: 0.5...30, step: 0.5, unit: .seconds
                )
                HStack {
                    Spacer()
                    Button("Restore Default Timing") {
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
            } header: {
                Text("Idle")
            }
            Section {
                IntRow(
                    "Longest frame edge", value: $state.settings.maxFrameDimension,
                    range: 320...4096, step: 64, unit: .pixels,
                    help: "Frames are scaled down to this size. Smaller frames are cheaper to compare, read, and store."
                )
                IntRow(
                    "Treat frames as unchanged within", value: $state.settings.hashDistanceThreshold,
                    range: 0...PerceptualHash.bitCount, step: 1, unit: .bits,
                    help: "A frame this close to the previous one, out of \(PerceptualHash.bitCount) bits of its fingerprint, is dropped unless the window or the focused text changed."
                )
            } header: {
                Text("Frames")
            }
            Section {
                Picker(selection: $state.settings.ocrLevel) {
                    ForEach(OCRLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                } label: {
                    Text("Text recognition")
                    Text("Accurate takes a few hundred milliseconds per frame. Fast is much quicker but finds no text in dark interfaces such as terminals.")
                }
                .pickerStyle(.segmented)
                PercentRow("Thumbnail quality", value: $state.settings.thumbnailJPEGQuality, range: 0.1...1, step: 0.05)
            } header: {
                Text("Recognition and storage")
            }
        }
    }
}

// MARK: - Journal

struct JournalSettings: View {
    @Environment(AppState.self) private var state
    @State private var confirmClear = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                DurationRow("Keep thumbnails for", value: $state.settings.thumbnailRetention)
                DurationRow(
                    "Keep text and events for", value: $state.settings.textRetention,
                    help: "Always at least as long as thumbnails."
                )
                NumberRow(
                    "Limit the journal to", value: Binding(
                        get: { Double(state.settings.journalSizeCapBytes / (1024 * 1024)) },
                        set: { state.settings.journalSizeCapBytes = Int64($0.clamped(to: 10...100_000)) * 1024 * 1024 }
                    ),
                    range: 10...100_000, step: 50, unit: .megabytes,
                    help: "The oldest thumbnails, then the oldest text and events, are removed to stay under this size."
                )
                NumberRow(
                    "Clean up every", value: $state.settings.retentionInterval,
                    range: 30...86400, step: 30, unit: .seconds
                )
            } header: {
                Text("Retention")
            }
            Section {
                LabeledContent("Location") {
                    Text(Formatting.path(state.journalURL))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let stats = state.journalStats {
                    LabeledContent("Size", value: Formatting.bytes(stats.usedBytes))
                    LabeledContent("Contents") {
                        Text("\(Plural.count(stats.observationCount, "observation", "observations")), \(Plural.count(stats.thumbnailCount, "thumbnail", "thumbnails")), \(Plural.count(stats.eventCount, "event", "events"))")
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            } header: {
                Text("On disk")
            }
        }
        // Clearing is what the person just chose, so the confirming button
        // is the plain default and Cancel stays available.
        .confirmationDialog(
            "Clear the journal?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear Journal") {
                Task { await state.clearJournal() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every observation, thumbnail, event, suggestion, follow-up question, and model call record is deleted, along with Mentor's understanding of what you are working toward. You can't undo this action.")
        }
        .task {
            await state.refreshJournalStats()
        }
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    @Environment(AppState.self) private var state
    @State private var showAdd = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                LabeledContent {
                    HotKeyRecorder(
                        title: "Pause shortcut",
                        hotKey: $state.settings.pauseHotKey,
                        conflicts: [state.settings.mentor.pushToTalkHotKey].compactMap { $0 },
                        conflictNote: "That is the talk-back shortcut."
                    )
                } label: {
                    Text("Pause shortcut")
                    if state.isRunning, !state.hotKeyRegistered {
                        StatusLabel("Another app uses this combination, or it lacks Control, Option, or Command. Choose another.", kind: .warning)
                    }
                }
            } footer: {
                Text("Pauses and resumes watching from any app. The menu bar icon shows an eye while watching and a crossed-out eye while paused.")
            }
            Section {
                ForEach(state.settings.excludedBundleIDs, id: \.self) { id in
                    ExcludedAppRow(bundleID: id) {
                        state.settings.excludedBundleIDs.removeAll { $0 == id }
                    }
                }
                HStack {
                    Button("Add App…") { showAdd = true }
                        .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                            AddExcludedAppPopover(existing: state.settings.excludedBundleIDs) { id in
                                state.settings.excludedBundleIDs.append(id)
                            }
                        }
                    Spacer()
                    Button("Restore Defaults") {
                        state.settings.excludedBundleIDs = ExcludedApps.defaults
                    }
                    .disabled(state.settings.excludedBundleIDs == ExcludedApps.defaults)
                }
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("While one of these apps is frontmost, Mentor captures nothing, reads no window or element, and journals only that the app was excluded.")
            }
        }
    }
}

/// An excluded app: its icon and name when it is installed, its bundle
/// identifier always, and a button that removes it.
private struct ExcludedAppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    var body: some View {
        let url = appURL
        LabeledContent {
            RemoveButton(itemName: url.map(appName) ?? bundleID, action: onRemove)
        } label: {
            Label {
                Text(url.map(appName) ?? bundleID)
                Text(url == nil ? "Not installed" : bundleID)
            } icon: {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "app.dashed")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// An icon-only button that removes one item from a list, labeled for
/// VoiceOver and the pointer with what it removes.
struct RemoveButton: View {
    let itemName: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label("Remove \(itemName)", systemImage: "minus.circle")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Remove \(itemName)")
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Exclude an App")
                .font(.headline)
            Menu("Choose a Running App") {
                ForEach(runningApps, id: \.id) { app in
                    Button(app.name) { bundleID = app.id }
                }
            }
            .fixedSize()
            TextField("Bundle identifier", text: $bundleID, prompt: Text("com.example.App"))
                .textFieldStyle(.roundedBorder)
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
        .padding()
        .frame(width: 340)
    }

    private func add() {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        onAdd(id)
        dismiss()
    }
}

// MARK: - Rows

/// The unit a number row counts in, written out for the row and for VoiceOver.
enum SettingsUnit {
    case seconds, pixels, bits, tokens, megabytes

    func label(for value: Double) -> String {
        let one = value == 1
        switch self {
        case .seconds: return one ? "second" : "seconds"
        case .pixels: return one ? "pixel" : "pixels"
        case .bits: return one ? "bit" : "bits"
        case .tokens: return one ? "token" : "tokens"
        case .megabytes: return "MB"
        }
    }
}

/// A number with a field for typing it, a stepper for nudging it, and its unit.
/// The label can carry a line of help underneath, styled by the form.
struct NumberRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: SettingsUnit
    var help: String?

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: SettingsUnit, help: String? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.help = help
    }

    private var spokenTitle: String { "\(title), in \(unit.label(for: value))" }

    var body: some View {
        LabeledContent {
            NumberControls(
                unitLabel: unit.label(for: value),
                field: TextField(spokenTitle, value: $value, format: .number.precision(.fractionLength(0...2)))
                    .onSubmit { value = value.clamped(to: range) },
                stepper: Stepper(title, value: $value, in: range, step: step)
            )
        } label: {
            Text(title)
            if let help { Text(help) }
        }
    }
}

struct IntRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: SettingsUnit
    var help: String?

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: SettingsUnit, help: String? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.help = help
    }

    private var spokenTitle: String { "\(title), in \(unit.label(for: Double(value)))" }

    var body: some View {
        LabeledContent {
            NumberControls(
                unitLabel: unit.label(for: Double(value)),
                field: TextField(spokenTitle, value: $value, format: .number.grouping(.never))
                    .onSubmit { value = value.clamped(to: range) },
                stepper: Stepper(title, value: $value, in: range, step: step)
            )
        } label: {
            Text(title)
            if let help { Text(help) }
        }
    }
}

/// An amount of money, typed and shown in dollars.
struct DollarRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var help: String?

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, help: String? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.help = help
    }

    var body: some View {
        LabeledContent {
            NumberControls(
                unitLabel: nil,
                field: TextField(title, value: $value, format: .currency(code: "USD"))
                    .onSubmit { value = value.clamped(to: range) },
                stepper: Stepper(title, value: $value, in: range, step: step)
            )
        } label: {
            Text(title)
            if let help { Text(help) }
        }
    }
}

/// A fraction from 0 to 1, typed and shown as a percentage.
struct PercentRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var help: String?

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, help: String? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.help = help
    }

    var body: some View {
        LabeledContent {
            NumberControls(
                unitLabel: nil,
                field: TextField(title, value: $value, format: .percent.precision(.fractionLength(0)))
                    .onSubmit { value = value.clamped(to: range) },
                stepper: Stepper(title, value: $value, in: range, step: step)
            )
        } label: {
            Text(title)
            if let help { Text(help) }
        }
    }
}

/// The trailing controls of a number row. The field and stepper are titled
/// with the row's title, the field's with its unit too, which VoiceOver reads
/// once; a separate accessibility label would be read beside that title.
private struct NumberControls<Field: View, StepperView: View>: View {
    let unitLabel: String?
    let field: Field
    let stepper: StepperView

    var body: some View {
        HStack(spacing: 6) {
            field
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            stepper
                .labelsHidden()
            if let unitLabel {
                Text(unitLabel)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A duration with a field, a stepper, and a unit menu, for retention periods.
struct DurationRow: View {
    let title: String
    @Binding var value: TimeInterval
    /// The seconds the setting itself accepts, where it bounds them. A unit is
    /// offered only where the range holds a whole amount of it, and the stepper
    /// and a typed amount are held inside it, so the row cannot offer a
    /// duration `MentorSettings.validated()` would clamp away.
    let range: ClosedRange<TimeInterval>?
    var help: String?

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

    /// The width the unit pop-up reserves. A menu-style Picker sizes to the
    /// unit it is showing, not to the widest in its menu, and a form's rows are
    /// trailing aligned, so a row showing "minutes" puts its field and stepper
    /// 12 pt left of a row showing "hours". Reserving what a pop-up needs for
    /// the widest unit word holds every duration row on one x whatever unit
    /// each is showing, and measuring it rather than naming a number keeps that
    /// true whatever font the control draws in.
    @MainActor private static let unitWidth: CGFloat = {
        let sizing = NSPopUpButton(frame: .zero, pullsDown: false)
        sizing.addItems(withTitles: Unit.allCases.map(\.rawValue))
        return sizing.intrinsicContentSize.width
    }()

    @State private var amount: Double = 1
    @State private var unit: Unit = .hours
    @FocusState private var editing: Bool

    init(_ title: String, value: Binding<TimeInterval>, range: ClosedRange<TimeInterval>? = nil, help: String? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.help = help
    }

    /// The whole amounts of `unit` the range allows, or the unbounded row's
    /// own 1...10_000 where the setting has no range. Nil where the range holds
    /// no whole amount of the unit, which is how that unit is left out.
    private func amounts(in unit: Unit) -> ClosedRange<Double>? {
        guard let range else { return 1...10_000 }
        let low = max(1, (range.lowerBound / unit.seconds).rounded(.up))
        let high = (range.upperBound / unit.seconds).rounded(.down)
        return low <= high ? low...high : nil
    }

    private var units: [Unit] { Unit.allCases.filter { amounts(in: $0) != nil } }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("\(title), in \(unit.rawValue)", value: $amount, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .focused($editing)
                    .onSubmit(push)
                    // A field writes the setting when its editing ends, however
                    // it ends, not only when Return commits it.
                    .onChange(of: editing) { _, focused in
                        if !focused { push() }
                    }
                Stepper(title, value: $amount, in: amounts(in: unit) ?? 1...10_000, step: 1, onEditingChanged: { _ in push() })
                    .labelsHidden()
                Picker("Unit", selection: $unit) {
                    ForEach(units) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .labelsHidden()
                // A minimum rather than a width, so a unit word wider than the
                // measurement grows the control instead of clipping, and
                // trailing so the pop-up keeps the form's edge and the slack a
                // shorter word leaves falls between it and the stepper.
                .frame(minWidth: Self.unitWidth, alignment: .trailing)
                .onChange(of: unit) { _, _ in push() }
            }
        } label: {
            Text(title)
            if let help { Text(help) }
        }
        .onAppear(perform: pull)
        .onChange(of: value) { _, newValue in
            if newValue != amount * unit.seconds { pull() }
        }
    }

    private func pull() {
        let seconds = value
        let offered = units
        let chosen: Unit
        if offered.contains(.days), seconds >= 86400, seconds.truncatingRemainder(dividingBy: 86400) == 0 {
            chosen = .days
        } else if offered.contains(.hours), seconds >= 3600 {
            chosen = .hours
        } else {
            chosen = offered.first ?? .minutes
        }
        unit = chosen
        amount = (seconds / chosen.seconds * 10).rounded() / 10
    }

    private func push() {
        let seconds = amount * unit.seconds
        let bounded = range.map { seconds.clamped(to: $0) } ?? max(60, seconds)
        value = bounded
        amount = (bounded / unit.seconds * 10).rounded() / 10
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
