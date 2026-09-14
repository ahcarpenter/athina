import AppKit
import MentorCore
import SwiftUI

struct DebugPanelView: View {
    enum SidePage: Hashable {
        case timeline, calls
    }

    @Environment(AppState.self) private var state
    @State private var showOCRBoxes = true
    @State private var selectedEntryID: String?
    @State private var selected: (observation: ActivityObservation, image: NSImage?)?
    @State private var sidePage: SidePage

    init(initialSidePage: SidePage = .timeline) {
        _sidePage = State(initialValue: initialSidePage)
    }

    var body: some View {
        VStack(spacing: 0) {
            DebugStatusBar()
            Divider()
            HStack(spacing: 0) {
                NowPane()
                    .frame(width: 340)
                Divider()
                FramePane(
                    observation: selected?.observation ?? state.latestObservation,
                    image: selected?.image ?? (selected == nil ? state.latestImage : nil),
                    isLive: selected == nil,
                    showBoxes: $showOCRBoxes,
                    onBackToLive: { selected = nil; selectedEntryID = nil }
                )
                .frame(maxWidth: .infinity)
                Divider()
                TimelinePane(selectedID: $selectedEntryID, page: $sidePage)
                    .frame(width: 360)
            }
        }
        .frame(minWidth: 1120, minHeight: 640)
        .task {
            await state.refreshJournalStats()
        }
        .task(id: selectedEntryID) {
            guard let selectedEntryID, selectedEntryID.hasPrefix("o"), let id = Int64(selectedEntryID.dropFirst()) else {
                selected = nil
                return
            }
            if let loaded = await state.loadObservation(id: id) {
                selected = loaded
            }
        }
    }
}

// MARK: - Status bar

private struct DebugStatusBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 14) {
            ModeBadge(mode: state.mode)
            if let badge = ClientModeBadge(mode: state.clientMode, recordingUnavailableReason: state.recordingUnavailableReason) {
                badge
            }
            PermissionChip(title: "Screen", granted: state.permissions.screenRecording)
            PermissionChip(title: "AX", granted: state.permissions.accessibility)
            Divider().frame(height: 16)
            // One tick a second: finer clocks kept the whole window redrawing at ~10% CPU while idle.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 14) {
                    LabeledValue(label: "Last", value: lastCapture(now: context.date))
                    LabeledValue(label: "Next", value: nextCapture(now: context.date))
                    LabeledValue(label: "Input", value: lastInput(now: context.date))
                }
            }
            Spacer(minLength: 8)
            LabeledValue(
                label: "Spend",
                value: state.clientMode.isOffline
                    ? "none, replay mode"
                    : "\(Formatting.dollars(state.mentorStatus.spendThisHour)) / \(Formatting.dollars(state.settings.mentor.hourlySpendCap))"
            )
            if let resources = state.resources {
                LabeledValue(label: "CPU", value: String(format: "%.1f%%", resources.cpuPercent))
                LabeledValue(label: "Mem", value: Formatting.bytes(resources.footprintBytes))
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func lastCapture(now: Date) -> String {
        guard let at = state.cadence.lastCaptureAt else { return "none yet" }
        let reason = state.cadence.lastCaptureReason.map { " (\($0.label))" } ?? ""
        return Formatting.age(at, now: now) + reason
    }

    private func lastInput(now: Date) -> String {
        guard let at = state.cadence.lastInputAt else { return "unknown" }
        return Formatting.age(at, now: now)
    }

    private func nextCapture(now: Date) -> String {
        guard let at = state.cadence.nextDueAt else { return "not scheduled" }
        let reason = state.cadence.nextDueReason.map { " (\($0.label))" } ?? ""
        return Formatting.countdown(to: at, now: now) + reason
    }
}

/// Says that model calls are replayed or recorded; nothing for live calls.
struct ClientModeBadge: View {
    let title: String
    let symbol: String
    let color: Color
    let help: String

    init?(mode: ModelClientMode, recordingUnavailableReason: String?) {
        switch mode {
        case .live:
            return nil
        case .record:
            title = "Recording"
            symbol = "record.circle"
            color = .red
            help = recordingUnavailableReason.map { "Recording is unavailable, so every model call is refused and nothing is sent: \($0)" }
                ?? "Model calls are live and each one is also written to a fixture file"
        case .replay, .invalid:
            title = "Replay"
            symbol = "repeat"
            color = .teal
            help = "Model calls are answered from recordings: nothing reaches the network or is billed"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .imageScale(.small)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(title)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .help(help)
        .fixedSize()
    }
}

struct ModeBadge: View {
    let mode: SensingMode

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(mode.label)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch mode {
        case .watching: .green
        case .screenOnly, .accessibilityOnly: .yellow
        case .idle: .gray
        case .paused, .stopped: .orange
        case .excluded: .purple
        case .waitingForPermissions: .red
        }
    }
}

private struct PermissionChip: View {
    let title: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
            Text(title)
        }
        .help(granted ? "\(title) permission granted" : "\(title) permission missing")
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
        .fixedSize()
    }
}

// MARK: - Now pane

private struct NowPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(title: "Frontmost app") {
                    if let focus = state.focus {
                        HStack(spacing: 10) {
                            AppIcon(pid: focus.pid)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(focus.appName).font(.headline)
                                Text(focus.bundleID ?? "no bundle identifier")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        if focus.isExcluded {
                            Label("Excluded: nothing is read or captured here", systemImage: "hand.raised.fill")
                                .foregroundStyle(.purple)
                                .font(.callout)
                        } else if !focus.accessibilityAvailable {
                            Label("Accessibility unavailable for this app", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                    } else {
                        Text("No frontmost app yet").foregroundStyle(.secondary)
                    }
                }

                Card(title: "Window") {
                    if let focus = state.focus, !focus.isExcluded {
                        Field(label: "Title", value: focus.windowTitle ?? "untitled")
                        if let frame = focus.windowFrame {
                            Field(label: "Frame", value: Formatting.rect(frame))
                        }
                    } else {
                        Text("Not read").foregroundStyle(.secondary)
                    }
                }

                MentorCard()

                Card(title: "Focused element") {
                    if let focus = state.focus, !focus.isExcluded, focus.focusedRole != nil {
                        Field(label: "Role", value: [focus.focusedRole, focus.focusedSubrole].compactMap { $0 }.joined(separator: " / "))
                        if let title = focus.focusedTitle, !title.isEmpty { Field(label: "Title", value: title) }
                        if let description = focus.focusedDescription, !description.isEmpty { Field(label: "Description", value: description) }
                        if let value = focus.focusedValue, !value.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Value · \(Plural.count(focus.focusedValueLength ?? value.count, "char", "chars"))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ScrollView {
                                    Text(value)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 140)
                                .padding(6)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    } else {
                        Text("No focused element").foregroundStyle(.secondary)
                    }
                }

                Card(title: "Cadence") {
                    Field(label: "Floor", value: "every \(Formatting.duration(state.settings.floorInterval))")
                    Field(label: "Settle", value: String(format: "%.2fs after input, %.2fs after focus", state.settings.inputSettleDelay, state.settings.focusSettleDelay))
                    Field(label: "Idle after", value: Formatting.duration(state.settings.idleThreshold))
                    Field(label: "Drop within", value: "\(state.settings.hashDistanceThreshold) bits of \(PerceptualHash.bitCount)")
                    Field(label: "Frames", value: "\(state.cadence.keptCount) kept, \(state.cadence.droppedCount) dropped")
                    if let distance = state.cadence.lastDropDistance {
                        Field(label: "Last drop", value: "distance \(distance)")
                    }
                    if let error = state.cadence.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                Card(title: "Journal") {
                    if let error = state.journalError {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                    if let stats = state.journalStats {
                        Field(label: "Size", value: Formatting.bytes(stats.usedBytes))
                        Field(label: "Rows", value: "\(stats.observationCount) observations, \(stats.thumbnailCount) thumbnails, \(stats.eventCount) events")
                        if let oldest = stats.oldest {
                            Field(label: "Oldest", value: oldest.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    Text(state.journalURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AppIcon: View {
    let pid: Int32

    var body: some View {
        Group {
            if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

private struct Field: View {
    let label: String
    let value: String
    var lineLimit: Int? = nil
    var truncation: Text.TruncationMode = .tail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            Text(value)
                .lineLimit(lineLimit)
                .truncationMode(truncation)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

// MARK: - Frame pane

private struct FramePane: View {
    let observation: ActivityObservation?
    let image: NSImage?
    let isLive: Bool
    @Binding var showBoxes: Bool
    let onBackToLive: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let observation {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isLive ? "Latest frame" : "Observation #\(observation.id)")
                            .font(.headline)
                        Text("\(Formatting.clockTime(observation.timestamp)) · \(observation.reason.label) · \(observation.frame.width)×\(observation.frame.height)")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .lineLimit(1)
                    }
                } else {
                    Text("No frame yet").font(.headline)
                }
                Spacer()
                if !isLive {
                    Button("Back to Live", action: onBackToLive)
                        .controlSize(.small)
                }
                Toggle("OCR boxes", isOn: $showBoxes)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            if let observation {
                FrameImageView(observation: observation, image: image, showBoxes: showBoxes)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                OCRTextList(blocks: observation.textBlocks)
                    .frame(height: 220)
            } else {
                ContentUnavailableView(
                    "Waiting for the first capture",
                    systemImage: "rectangle.dashed",
                    description: Text("Frames appear here once Screen Recording is granted and the user is active.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct FrameImageView: View {
    let observation: ActivityObservation
    let image: NSImage?
    let showBoxes: Bool

    var body: some View {
        GeometryReader { geometry in
            let frameSize = CGSize(width: observation.frame.width, height: observation.frame.height)
            let fitted = fit(frameSize, in: geometry.size)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(width: fitted.width, height: fitted.height)
                        .overlay {
                            Text("Thumbnail no longer stored")
                                .foregroundStyle(.secondary)
                        }
                }
                if showBoxes {
                    Canvas { context, _ in
                        let scale = fitted.width / max(1, frameSize.width)
                        for block in observation.textBlocks {
                            let rect = CGRect(
                                x: block.imageRect.origin.x * scale,
                                y: block.imageRect.origin.y * scale,
                                width: block.imageRect.width * scale,
                                height: block.imageRect.height * scale
                            )
                            let path = Path(roundedRect: rect, cornerRadius: 1.5)
                            context.fill(path, with: .color(.yellow.opacity(0.12)))
                            context.stroke(path, with: .color(.yellow.opacity(0.9)), lineWidth: 1)
                        }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func fit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
    }
}

private struct OCRTextList: View {
    let blocks: [TextBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recognized text")
                    .font(.subheadline.weight(.semibold))
                Text(Plural.count(blocks.count, "block", "blocks"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            if blocks.isEmpty {
                Text("No text recognized in this frame.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(String(format: "%.0f%%", block.confidence * 100))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .trailing)
                                Text(block.text)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

// MARK: - Timeline pane

private struct TimelinePane: View {
    typealias Page = DebugPanelView.SidePage

    @Environment(AppState.self) private var state
    @Binding var selectedID: String?
    @Binding var page: Page

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $page) {
                    Text("Timeline").tag(Page.timeline)
                    Text("Model calls").tag(Page.calls)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 180)
                Text(page == .timeline ? Plural.count(state.timeline.count, "entry", "entries") : Plural.count(state.callLog.count, "call", "calls"))
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            switch page {
            case .timeline:
                List(state.timeline, selection: $selectedID) { entry in
                    TimelineRow(entry: entry)
                        .tag(entry.id)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
                .overlay {
                    if state.timeline.isEmpty {
                        ContentUnavailableView("Nothing journaled yet", systemImage: "clock")
                    }
                }
            case .calls:
                CallLogList(calls: state.callLog)
            }
        }
    }
}

private struct TimelineRow: View {
    let entry: JournalEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Formatting.clockTime(entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(primary)
                    .lineLimit(1)
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var primary: String {
        switch entry {
        case .observation(let o):
            return "\(o.focus.appName) · \(o.reason.label)"
        case .event(let e):
            if let app = e.appName { return "\(e.kind.label) · \(app)" }
            return e.kind.label
        }
    }

    private var secondary: String? {
        switch entry {
        case .observation(let o):
            let title = o.focus.windowTitle.map { "\"\($0)\" · " } ?? ""
            return "\(title)\(o.textBlocks.count) text blocks"
        case .event(let e): return e.detail
        }
    }

    private var symbol: String {
        switch entry {
        case .observation: "camera.viewfinder"
        case .event(let e):
            switch e.kind {
            case .started: "play.circle"
            case .stopped: "stop.circle"
            case .appSwitch: "arrow.left.arrow.right"
            case .windowSwitch: "macwindow"
            case .idleStart: "moon.zzz"
            case .idleEnd: "sun.max"
            case .paused: "pause.circle"
            case .resumed: "play.circle"
            case .excluded: "hand.raised"
            case .permissionsChanged: "lock.shield"
            case .journalCleared: "trash"
            case .retention: "clock.arrow.circlepath"
            case .suggested: "lightbulb.fill"
            case .feedback: "hand.thumbsup"
            case .talkBack: "mic"
            }
        }
    }

    private var tint: Color {
        switch entry {
        case .observation: .accentColor
        case .event(let e):
            switch e.kind {
            case .paused, .excluded: .orange
            case .idleStart: .gray
            case .journalCleared: .red
            case .suggested: .yellow
            case .feedback: .green
            case .talkBack: .teal
            default: .secondary
            }
        }
    }
}

// MARK: - Mentor card

/// The debug panel's Mentor section: gate decisions, the last call of each
/// tier, spend and cadence. The call log lives under the timeline.
private struct MentorCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Card(title: "Mentor loop") {
            HStack(spacing: 8) {
                AvailabilityBadge(availability: state.mentorStatus.availability)
                if let badge = ClientModeBadge(mode: state.clientMode, recordingUnavailableReason: state.recordingUnavailableReason) {
                    badge.font(.caption)
                }
                if let tier = state.mentorStatus.inFlight {
                    ProgressView().controlSize(.mini)
                    Text("\(tier.label) call in flight")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                // Model reasons can run long; four lines keeps spend and cadence in view.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(clientModeFields, id: \.label) { field in
                        Field(label: field.label, value: field.value, lineLimit: field.lineLimit, truncation: field.truncation)
                    }
                    Field(label: "Triage gate", value: triageGate(now: context.date), lineLimit: 4)
                    Field(label: "Context", value: contextVerdict(now: context.date), lineLimit: 4)
                    Field(label: "Last triage", value: describe(state.mentorStatus.lastTriage, now: context.date), lineLimit: 4)
                    Field(label: "Mentor gate", value: mentorGate(now: context.date), lineLimit: 4)
                    Field(label: "Last mentor", value: describe(state.mentorStatus.lastMentor, now: context.date), lineLimit: 4)
                    Field(label: "Spend", value: spend(now: context.date))
                    Field(label: "Cadence", value: cadence(now: context.date))
                    Field(label: "Callout", value: callout(now: context.date), lineLimit: 4)
                    Field(label: "Transcript", value: transcript(now: context.date), lineLimit: 4)
                }
            }
        }
    }

    private struct ModeField {
        var label: String
        var value: String
        var lineLimit: Int? = 1
        var truncation: Text.TruncationMode = .tail
    }

    /// Where calls go when that is not simply live: one short line each, with
    /// a long path cut in the middle so both ends stay readable.
    private var clientModeFields: [ModeField] {
        switch state.clientMode {
        case .live:
            return []
        case .record(let directory):
            if let reason = state.recordingUnavailableReason {
                return [
                    ModeField(label: "Calls", value: "refused, nothing is sent"),
                    ModeField(label: "Why", value: reason, lineLimit: 4),
                ]
            }
            return [
                ModeField(label: "Calls", value: "live, each one also recorded"),
                ModeField(label: "To", value: Formatting.path(directory), truncation: .middle),
            ]
        case .invalid(let reason):
            return [
                ModeField(label: "Calls", value: "refused, nothing is sent"),
                ModeField(label: "Why", value: reason, lineLimit: 4),
            ]
        case .replay(let directory, _):
            guard let summary = state.replaySummary else {
                return [ModeField(label: "Calls", value: "replayed, never sent or billed")]
            }
            if let reason = summary.unavailableReason {
                return [
                    ModeField(label: "Calls", value: "refused, nothing is sent"),
                    ModeField(label: "Why", value: reason, lineLimit: 4),
                ]
            }
            var fixtures = "\(summary.total): \(summary.kindsDescription)"
            if summary.staleCount > 0 {
                let versions = summary.staleVersions.map { "v\($0)" }.joined(separator: ", ")
                fixtures += "\n\(summary.staleCount) stale, from prompt \(versions) (now v\(summary.promptVersion)), \(summary.allowStale ? "served anyway" : "refused")"
            }
            return [
                ModeField(label: "Calls", value: "replayed, never sent or billed"),
                ModeField(label: "Fixtures", value: fixtures, lineLimit: 3),
                ModeField(label: "From", value: Formatting.path(directory), truncation: .middle),
            ]
        }
    }

    /// The last callout decision with both coordinate spaces: the frame
    /// pixels the model answered in and the screen points it mapped to.
    private func callout(now: Date) -> String {
        guard let record = state.lastCallout else { return "none yet" }
        var text = "\(record.outcome) \(Formatting.age(record.at, now: now)), \"\(record.region.note)\"\nframe \(Formatting.rect(record.region.rect)) px"
        if let placement = record.placement {
            text += "\nscreen \(Formatting.rect(placement.screenRect)) pt on display \(placement.displayID)"
        }
        return text
    }

    private func transcript(now: Date) -> String {
        switch state.talkBack {
        case .listening(let partial):
            return partial.isEmpty ? "listening…" : "listening: \"\(partial)\""
        case .thinking(let question):
            return "asking the mentor: \"\(question)\""
        case .idle:
            guard let record = state.lastTranscript else { return "none yet" }
            return "\"\(record.text)\" \(Formatting.age(record.at, now: now)), \(record.handling)"
        }
    }

    private func triageGate(now: Date) -> String {
        guard let gate = state.mentorStatus.lastGate else { return "no observation yet" }
        let when = Formatting.age(gate.at, now: now)
        if let hold = gate.hold {
            return "held \(when): \(hold.label)"
        }
        return "ran \(when) on observation #\(gate.observationID)"
    }

    /// Where the declared contexts put the latest activity, and what settled it.
    /// A verdict is shown only when it was recorded under the enforcement state
    /// in force now and for the app in front now. `lastContext` is not
    /// recomputed when settings or focus change, so any other record describes a
    /// moment that has passed; the menu says "not yet judged" for those and this
    /// says the same rather than presenting a stale verdict as current.
    private func contextVerdict(now: Date) -> String {
        let mentor = state.settings.mentor
        guard mentor.onlyMentorInsideContexts else {
            return "not enforced (\(mentor.contexts.count) declared)"
        }
        var notJudgedYet: String {
            if mentor.contexts.isEmpty { return "enforced with no context declared, so nothing is mentored" }
            let enforcing = "enforcing \(Plural.count(mentor.contexts.count, "context", "contexts"))"
            guard let appName = state.focus?.appName else { return "\(enforcing), not judged yet" }
            return "\(enforcing), not yet judged in \(appName)"
        }
        guard let record = state.mentorStatus.lastContext,
              record.placement != .notEnforced,
              record.appName == state.focus?.appName
        else {
            return notJudgedYet
        }
        return "\(record.placement.label) \(Formatting.age(record.at, now: now)) in \(record.appName)"
    }

    private func mentorGate(now: Date) -> String {
        if let hold = state.mentorStatus.lastMentorHold {
            return "held \(Formatting.age(hold.at, now: now)): \(hold.hold.label)"
        }
        if let last = state.mentorStatus.lastMentor {
            return "ran \(Formatting.age(last.timestamp, now: now))"
        }
        return "not reached yet"
    }

    private func describe(_ record: ModelCallRecord?, now: Date) -> String {
        guard let record else { return "none yet" }
        let model = ModelCatalog.displayName(for: record.model)
        var text = "\(record.outcome.label) \(Formatting.age(record.timestamp, now: now)), \(record.replayed ? "replay of \(model)" : model), "
        text += "\(Formatting.tokens(record.usage.totalInputTokens)) in (\(Formatting.tokens(record.usage.cacheReadInputTokens)) cached), \(Formatting.tokens(record.usage.outputTokens)) out, "
        text += "\(record.replayed ? Formatting.unbroken("not billed") : Formatting.dollars(record.cost)), \(Formatting.seconds(record.latency))"
        if let detail = record.detail, !detail.isEmpty { text += "\n\(detail)" }
        return text
    }

    private func spend(now: Date) -> String {
        guard !state.clientMode.isOffline else { return "nothing billed in replay mode" }
        let status = state.mentorStatus
        let rollover = Formatting.countdown(to: SpendMeter.nextHourStart(after: now), now: now)
        return "\(Formatting.dollars(status.spendThisHour)) of \(Formatting.dollars(state.settings.mentor.hourlySpendCap)) this hour over \(Plural.count(status.callsThisHour, "call", "calls")), hour rolls over \(rollover)"
    }

    private func cadence(now: Date) -> String {
        let status = state.mentorStatus
        var parts = ["\(Formatting.multiplier(status.cadenceMultiplier)) the set intervals"]
        if let next = status.nextTriageAt {
            parts.append("triage allowed \(Formatting.countdown(to: next, now: now))")
        }
        if let next = status.nextMentorAt {
            parts.append("mentor allowed \(Formatting.countdown(to: next, now: now))")
        }
        return parts.joined(separator: ", ")
    }
}

private struct AvailabilityBadge: View {
    let availability: MentorStatus.Availability

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(availability.label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch availability {
        case .ready: .green
        case .disabled: .gray
        case .noAPIKey: .orange
        case .capReached: .red
        }
    }
}

private struct CallLogList: View {
    let calls: [ModelCallRecord]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(calls) { call in
                    CallLogRow(call: call)
                    Divider()
                }
            }
        }
        .overlay {
            if calls.isEmpty {
                ContentUnavailableView(
                    "No model calls yet",
                    systemImage: "sparkles",
                    description: Text("Each call appears here with its prompt size, tokens, cost, and latency.")
                )
            }
        }
    }
}

private struct CallLogRow: View {
    let call: ModelCallRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // A replay is marked under its time, so the outcome and model
            // keep the width they have for a live call.
            VStack(alignment: .leading, spacing: 4) {
                Text(Formatting.clockTime(call.timestamp))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if call.replayed {
                    ReplayTag()
                }
            }
            .frame(width: 60, alignment: .leading)
            Text(call.tier.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tierColor)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(call.outcome.label)
                        .font(.callout.weight(.medium))
                    Text(ModelCatalog.displayName(for: call.model))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(metrics)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = call.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    /// Each number stays on the line with its unit, and "not billed" stays whole,
    /// wherever the narrow column wraps.
    private var metrics: String {
        var line = Formatting.unbroken("\(Formatting.tokens(call.usage.totalInputTokens)) in")
        if call.usage.cacheReadInputTokens > 0 { line += " (" + Formatting.unbroken("\(Formatting.tokens(call.usage.cacheReadInputTokens)) cached") + ")" }
        line += ", " + Formatting.unbroken("\(Formatting.tokens(call.usage.outputTokens)) out")
        line += ", \(call.replayed ? Formatting.unbroken("not billed") : Formatting.dollars(call.cost)), \(Formatting.seconds(call.latency))"
        var prompt = "prompt " + Formatting.unbroken("\(Formatting.tokens(call.promptCharacters)) chars")
        if call.imageBytes > 0 { prompt += " + " + Formatting.unbroken("\(Formatting.bytes(Int64(call.imageBytes))) image") }
        return line + "\n" + prompt
    }

    private var tierColor: Color {
        switch call.tier {
        case .triage: .blue
        case .mentor: .purple
        case .followUp: .teal
        case .test: .secondary
        }
    }
}

/// Marks a call answered from a recording.
private struct ReplayTag: View {
    var body: some View {
        Text("Replay")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.teal)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.teal.opacity(0.15), in: Capsule())
            .fixedSize()
            .help("Answered from a recording: never sent and never billed")
    }
}
