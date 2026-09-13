import AppKit
import MentorCore
import SwiftUI

struct DebugPanelView: View {
    @Environment(AppState.self) private var state
    @State private var showOCRBoxes = true
    @State private var selectedEntryID: String?
    @State private var selected: (observation: ActivityObservation, image: NSImage?)?

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
                TimelinePane(selectedID: $selectedEntryID)
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
            PermissionChip(title: "Screen", granted: state.permissions.screenRecording)
            PermissionChip(title: "AX", granted: state.permissions.accessibility)
            Divider().frame(height: 16)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                HStack(spacing: 14) {
                    LabeledValue(label: "Last", value: lastCapture(now: context.date))
                    LabeledValue(label: "Next", value: nextCapture(now: context.date))
                    LabeledValue(label: "Input", value: String(format: "%.1fs ago", state.cadence.secondsSinceInput))
                }
            }
            Spacer(minLength: 8)
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

    private func nextCapture(now: Date) -> String {
        guard let at = state.cadence.nextDueAt else { return "not scheduled" }
        let reason = state.cadence.nextDueReason.map { " (\($0.label))" } ?? ""
        return Formatting.countdown(to: at, now: now) + reason
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

                Card(title: "Focused element") {
                    if let focus = state.focus, !focus.isExcluded, focus.focusedRole != nil {
                        Field(label: "Role", value: [focus.focusedRole, focus.focusedSubrole].compactMap { $0 }.joined(separator: " / "))
                        if let title = focus.focusedTitle, !title.isEmpty { Field(label: "Title", value: title) }
                        if let description = focus.focusedDescription, !description.isEmpty { Field(label: "Description", value: description) }
                        if let value = focus.focusedValue, !value.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Value · \(focus.focusedValueLength ?? value.count) chars")
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            Text(value)
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
            HStack(spacing: 12) {
                if let observation {
                    Text(isLive ? "Latest frame" : "ActivityObservation #\(observation.id)")
                        .font(.headline)
                    Text("\(Formatting.clockTime(observation.timestamp)) · \(observation.reason.label) · \(observation.frame.width)×\(observation.frame.height)")
                        .foregroundStyle(.secondary)
                        .font(.callout)
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
                Text("\(blocks.count) blocks")
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
    @Environment(AppState.self) private var state
    @Binding var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Timeline")
                    .font(.headline)
                Text("\(state.timeline.count) entries")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
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
            default: .secondary
            }
        }
    }
}
