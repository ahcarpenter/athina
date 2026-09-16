import AppKit
import MentorCore
import ScreenCaptureKit
import SwiftUI

/// Developer aid: `Mentor --snapshot <dir>` renders every window with sample
/// data to PNG files (light and dark) and quits. It draws the app's own views,
/// so it needs no Screen Recording permission and works in CI.
@MainActor
enum Snapshots {
    static var requestedDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static var isActive: Bool { requestedDirectory != nil }

    static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = AppState.sample()
        let replay = AppState.sampleReplay()
        let empty = AppState.sampleEmpty()
        let atCap = AppState.sampleAtContextCap()
        let noSpeech = AppState.sample(speechAvailability: .unavailable(reason: "On-device speech recognition is not available for Welsh, so talking back is off."))
        let pane = CGSize(width: SettingsView.paneWidth, height: 640)
        // Render windows are not held to a display's height, so a pane that
        // scrolls in the Settings window renders whole.
        func whole(_ height: CGFloat) -> CGSize { CGSize(width: SettingsView.paneWidth, height: height) }
        let specs: [(name: String, size: CGSize, view: AnyView, state: AppState)] = [
            ("permissions", CGSize(width: 580, height: 780), AnyView(PermissionsView()), state),
            ("debug-panel", CGSize(width: 1180, height: 860), AnyView(DebugPanelView()), state),
            ("debug-panel-calls", CGSize(width: 1180, height: 860), AnyView(DebugPanelView(initialSidePage: .calls)), state),
            ("debug-panel-empty", CGSize(width: 1180, height: 860), AnyView(DebugPanelView()), empty),
            ("settings-general", whole(860), AnyView(GeneralSettings().formStyle(.grouped)), state),
            ("settings-contexts", pane, AnyView(ContextsSettings().formStyle(.grouped)), state),
            ("settings-contexts-empty", CGSize(width: SettingsView.paneWidth, height: 420), AnyView(ContextsSettings().formStyle(.grouped)), empty),
            ("settings-contexts-at-cap", whole(1200), AnyView(ContextsSettings().formStyle(.grouped)), atCap),
            ("settings-context-editor", CGSize(width: 520, height: 360), AnyView(SampleContextEditor(duplicate: false)), state),
            ("settings-context-editor-duplicate", CGSize(width: 520, height: 360), AnyView(SampleContextEditor(duplicate: true)), state),
            ("settings-status-messages", CGSize(width: SettingsView.paneWidth, height: 760), AnyView(StatusMessagesPreview()), noSpeech),
            ("settings-models", whole(1980), AnyView(ModelSettings().formStyle(.grouped)), state),
            ("settings-models-empty", whole(1980), AnyView(ModelSettings().formStyle(.grouped)), empty),
            ("settings-capture", whole(920), AnyView(CaptureSettings().formStyle(.grouped)), state),
            ("settings-journal", CGSize(width: SettingsView.paneWidth, height: 500), AnyView(JournalSettings().formStyle(.grouped)), state),
            ("settings-privacy", pane, AnyView(PrivacySettings().formStyle(.grouped)), state),
            // The side-effect suggestion, so the goal it was judged against shows.
            ("history", CGSize(width: 860, height: 520), AnyView(HistoryView(initialSelection: 5)), state),
            ("history-empty", CGSize(width: 860, height: 520), AnyView(HistoryView()), empty),
            ("toast", CGSize(width: ToastController.panelWidth, height: 200), AnyView(SampleToast(expanded: false)), state),
            ("toast-expanded", CGSize(width: ToastController.panelWidth, height: 460), AnyView(SampleToast(expanded: true)), state),
            ("toast-listening", CGSize(width: ToastController.panelWidth, height: 300), AnyView(SampleToast(expanded: false, talkBack: .listening(partial: "does that work with tags as"), suggestionID: 4)), state),
            ("toast-thinking", CGSize(width: ToastController.panelWidth, height: 300), AnyView(SampleToast(expanded: false, talkBack: .thinking(question: "does that work with tags as well"), suggestionID: 4)), state),
            ("toast-answered", CGSize(width: ToastController.panelWidth, height: 400), AnyView(SampleToast(expanded: false, exchange: SampleSuggestions.followUps(now: Date(), suggestionID: 4), suggestionID: 4)), state),
            ("toast-note", CGSize(width: ToastController.panelWidth, height: 120), AnyView(SampleToastNote()), state),
            ("callout", CGSize(width: 900, height: 620), AnyView(SampleCallout()), state),
            ("menu-bar-marks", SampleMenuBarMarks.wholeSize, AnyView(SampleMenuBarMarks()), state),
            ("debug-panel-replay", CGSize(width: 1180, height: 860), AnyView(DebugPanelView()), replay),
            ("debug-panel-calls-replay", CGSize(width: 1180, height: 860), AnyView(DebugPanelView(initialSidePage: .calls)), replay),
            ("settings-models-replay", whole(1980), AnyView(ModelSettings().formStyle(.grouped)), replay),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for spec in specs {
                let suffix = appearance == .aqua ? "light" : "dark"
                let url = directory.appendingPathComponent("\(spec.name)-\(suffix).png")
                try await render(spec.view.environment(spec.state), size: spec.size, appearance: appearance, to: url)
            }
        }
    }

    private static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        // On a display, so the window server composites glass and control
        // bezels, but below the desktop picture, so nothing appears on a screen
        // someone else is using. ScreenCaptureKit captures a window whatever
        // covers it.
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 40, y: 80), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.hasShadow = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI finish its layout passes and async tasks.
        try await Task.sleep(for: .milliseconds(700))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let image = try await captureWithFallback(window: window, hosting: hosting)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.noPNG
        }
        try png.write(to: url)
        window.close()
    }

    /// ScreenCaptureKit gives the truest picture, but its stream occasionally
    /// fails to start when many windows are captured back to back. One retry,
    /// then the layer-tree render, so an unattended run always produces a file.
    private static func captureWithFallback(window: NSWindow, hosting: NSView) async throws -> CGImage {
        for attempt in 0..<2 {
            do {
                if let image = try await captureOwnWindow(window) { return image }
                break
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(400))
                } else {
                    FileHandle.standardError.write(Data("snapshot: window capture failed twice (\(error.localizedDescription)), rendering the layer tree\n".utf8))
                }
            }
        }
        return try renderLayerTree(of: hosting)
    }

    /// ScreenCaptureKit for the app's own window; nil when the permission is missing.
    private static func captureOwnWindow(_ window: NSWindow) async throws -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        configuration.width = Int(scWindow.frame.width * scale)
        configuration.height = Int(scWindow.frame.height * scale)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Renders the backing layer tree at the window's scale factor.
    private static func renderLayerTree(of view: NSView) throws -> CGImage {
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let layer = view.layer, let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw SnapshotError.noBitmap }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        // The window, not the content view, paints the window background, and
        // its dynamic colour must be resolved under the window's appearance.
        let appearance = view.window?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            let background = view.window?.backgroundColor ?? NSColor.windowBackgroundColor
            if let cgColor = background.usingColorSpace(.deviceRGB)?.cgColor {
                context.setFillColor(cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            layer.render(in: context)
        }
        guard let image = context.makeImage() else { throw SnapshotError.noBitmap }
        return image
    }

    enum SnapshotError: Error {
        case noBitmap
        case noPNG
    }
}

// MARK: - Sample state

extension AppState {
    /// Realistic data for snapshots and previews, stamped around `now` (the
    /// sample's own clock when nil). Nothing here touches the pipeline.
    static func sample(
        at now: Date? = nil,
        speechAvailability: SpeechListener.Availability = .available(locale: "English (US)")
    ) -> AppState {
        var settings = SensingSettings()
        settings.mentor.onlyMentorInsideContexts = true
        settings.mentor.contexts = SampleSuggestions.contexts
        // The oldest sample suggestion was answered Never for This.
        settings.mentor.neverRules = [
            NeverRule(bundleID: "com.apple.dt.Xcode", appName: "Xcode", category: .correctness, createdAt: (now ?? Date()).addingTimeInterval(-7990)),
        ]
        let state = AppState(sampleWithSettings: settings, speechAvailability: speechAvailability)
        let now = now ?? state.clock.date
        let focus = FocusContext(
            timestamp: now,
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleID: "com.apple.dt.Xcode",
            appName: "Xcode",
            windowTitle: "SensingPipeline.swift - mentor",
            windowFrame: CGRect(x: 0, y: 38, width: 1512, height: 944),
            focusedRole: "AXTextArea",
            focusedSubrole: nil,
            focusedTitle: nil,
            focusedDescription: "Source editor",
            focusedValue: SampleFrame.code,
            focusedValueLength: SampleFrame.code.count
        )
        let sampleFrame = SampleFrame.render()
        state.permissions = PermissionStatus(screenRecording: true, accessibility: false, microphone: true, speechRecognition: false)
        let frame = FrameInfo(
            hash: PerceptualHash(words: [0x1234_5678_9abc_def0, 0x0fed_cba9_8765_4321, 0xaaaa_5555_aaaa_5555, 0x0f0f_f0f0_0f0f_f0f0]),
            width: Int(sampleFrame.image.size.width),
            height: Int(sampleFrame.image.size.height),
            displayID: 1,
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            jpeg: nil
        )
        let observation = ActivityObservation(
            id: 128,
            timestamp: now.addingTimeInterval(-2.4),
            focus: focus,
            frame: frame,
            textBlocks: sampleFrame.blocks,
            reason: .inputSettled
        )
        state.focus = focus
        state.latestObservation = observation
        state.latestImage = sampleFrame.image
        state.mode = .watching
        state.cadence = CadenceStatus(
            mode: .watching,
            lastCaptureAt: observation.timestamp,
            lastCaptureReason: .inputSettled,
            nextDueAt: now.addingTimeInterval(2.6),
            nextDueReason: .floor,
            lastInputAt: now.addingTimeInterval(-4),
            keptCount: 128,
            droppedCount: 341,
            lastDropDistance: 2
        )
        state.resources = ProcessResourceUsage(cpuPercent: 0.4, footprintBytes: 62 * 1024 * 1024)
        state.journalStats = JournalStats(
            observationCount: 1284, thumbnailCount: 512, eventCount: 377,
            usedBytes: 138 * 1024 * 1024,
            oldest: now.addingTimeInterval(-3 * 86400), newest: now
        )
        var slim = observation
        slim.frame.jpeg = nil
        var timeline: [JournalEntry] = [
            .observation(slim),
            .event(JournalEvent(id: 12, timestamp: now.addingTimeInterval(-9), kind: .windowSwitch, bundleID: "com.apple.dt.Xcode", appName: "Xcode", detail: "SensingPipeline.swift - mentor")),
            .observation(ActivityObservation(id: 127, timestamp: now.addingTimeInterval(-14), focus: focus, frame: frame, textBlocks: [], reason: .focusChange)),
            .event(JournalEvent(id: 11, timestamp: now.addingTimeInterval(-15), kind: .appSwitch, bundleID: "com.apple.dt.Xcode", appName: "Xcode", detail: "from Safari")),
            .observation(ActivityObservation(id: 126, timestamp: now.addingTimeInterval(-31), focus: FocusContext(timestamp: now.addingTimeInterval(-31), pid: 1, bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "ScreenCaptureKit | Apple Developer Documentation"), frame: frame, textBlocks: Array(sampleFrame.blocks.prefix(4)), reason: .floor)),
            .event(JournalEvent(id: 10, timestamp: now.addingTimeInterval(-64), kind: .idleEnd)),
            .event(JournalEvent(id: 9, timestamp: now.addingTimeInterval(-420), kind: .idleStart, detail: "no input for 60s")),
            .event(JournalEvent(id: 8, timestamp: now.addingTimeInterval(-900), kind: .excluded, bundleID: "com.1password.1password", appName: "1Password")),
            .event(JournalEvent(id: 7, timestamp: now.addingTimeInterval(-1300), kind: .resumed)),
            .event(JournalEvent(id: 6, timestamp: now.addingTimeInterval(-1500), kind: .paused)),
            .event(JournalEvent(id: 5, timestamp: now.addingTimeInterval(-3600), kind: .retention, detail: "removed 40 thumbnails, 0 observations, 0 events")),
            .event(JournalEvent(id: 1, timestamp: now.addingTimeInterval(-7200), kind: .started)),
        ]
        for i in 0..<12 {
            timeline.append(.observation(ActivityObservation(
                id: Int64(110 - i), timestamp: now.addingTimeInterval(-7300 - Double(i) * 47),
                focus: FocusContext(timestamp: now.addingTimeInterval(-7300 - Double(i) * 47), pid: 2, bundleID: "com.github.wez.wezterm", appName: "WezTerm", windowTitle: "zsh - mentor"),
                frame: frame, textBlocks: [], reason: i % 3 == 0 ? .focusChange : .floor
            )))
        }
        state.timeline = timeline

        var suggestions = SampleSuggestions.make(now: now)
        // The suggestion about the capture path points at the capture line of the sample frame.
        let region = sampleFrame.blocks.first { $0.text.contains("capturer.capture") }
            .map { CalloutRegion(rect: $0.imageRect.insetBy(dx: -6, dy: -5), note: "this capture call") }
        for index in suggestions.indices where suggestions[index].id == 4 {
            suggestions[index].region = region
            suggestions[index].calloutShown = region != nil
        }
        state.suggestionHistory = suggestions
        state.activeSuggestion = suggestions.first
        state.followUps = SampleSuggestions.followUps(now: now, suggestionID: 3) + SampleSuggestions.followUps(now: now, suggestionID: 4)
        state.lastCallout = CalloutRecord(
            at: now.addingTimeInterval(-38), suggestionID: 4, region: region ?? CalloutRegion(rect: .zero, note: ""),
            placement: region.map { CalloutPlacement(displayID: 1, screenRect: CalloutAnchor.screenRect(for: $0.rect, in: frame) ?? .zero, note: $0.note) },
            status: .shown
        )
        state.lastTranscript = TranscriptRecord(at: now.addingTimeInterval(-20), text: "does that work with tags as well", handling: "asked the mentor")
        state.callLog = SampleSuggestions.calls(now: now)
        state.mentorStatus = MentorStatus(
            availability: .ready,
            lastGate: MentorStatus.GateRecord(at: now.addingTimeInterval(-2.4), observationID: 128, hold: .tooSoon(until: now.addingTimeInterval(13))),
            lastContext: MentorStatus.ContextRecord(
                at: now.addingTimeInterval(-52),
                placement: .inside(ContextMatch(
                    contextID: SampleSuggestions.contexts[0].id, name: SampleSuggestions.contexts[0].name
                )),
                appName: "Xcode"
            ),
            lastTriage: state.callLog.first { $0.tier == .triage },
            lastMentorHold: nil,
            lastMentor: state.callLog.first { $0.tier == .mentor },
            understanding: SampleSuggestions.understanding(now: now),
            lastRefreshHold: MentorStatus.RefreshHoldRecord(at: now.addingTimeInterval(-2.4), hold: .notDue(until: now.addingTimeInterval(511))),
            lastRefresh: state.callLog.first { $0.tier == .understanding },
            nextRefreshAt: now.addingTimeInterval(511),
            spendThisHour: 0.1834,
            hourStart: SpendMeter.hourStart(of: now),
            callsThisHour: 23,
            cadenceMultiplier: 1.22,
            nextTriageAt: now.addingTimeInterval(13),
            nextMentorAt: now.addingTimeInterval(97),
            inFlight: nil
        )
        return state
    }
}

extension AppState {
    /// A state with nothing in it yet: no suggestions, frames, journal
    /// entries, calls, or declared contexts, for the empty states.
    static func sampleEmpty() -> AppState {
        var settings = SensingSettings()
        settings.mentor.onlyMentorInsideContexts = true
        let state = AppState(sampleWithSettings: settings)
        state.mode = .watching
        state.mentorStatus = MentorStatus(availability: .noAPIKey)
        return state
    }

    /// Every context slot declared, for the editor's limit state.
    static func sampleAtContextCap() -> AppState {
        var settings = SensingSettings()
        settings.mentor.onlyMentorInsideContexts = true
        settings.mentor.contexts = (1...ContextRules.maxContexts).map { index in
            index <= SampleSuggestions.contexts.count
                ? SampleSuggestions.contexts[index - 1]
                : MentorshipContext(name: "sample context \(index)")
        }
        return AppState(sampleWithSettings: settings)
    }

    /// The sample in replay mode: every call in the log answered from the
    /// committed fixtures and nothing billed, on a clock running 60 times real
    /// time that was moved ahead a day and two hours, so the clock badge shows.
    static func sampleReplay() -> AppState {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("workspace/mentor/Tests/MentorCoreTests/Fixtures/Replay", isDirectory: true)
        let state = AppState(
            sampleWithSettings: sample().settings,
            clientMode: .replay(directory: directory, allowStale: false),
            clockMode: .replay(scale: 60, ahead: 0)
        )
        state.advanceClock(by: 26 * 3600)
        let live = sample(at: state.clock.date)
        state.focus = live.focus
        state.latestObservation = live.latestObservation
        state.latestImage = live.latestImage
        state.mode = live.mode
        state.permissions = PermissionStatus(screenRecording: true, accessibility: true)
        state.cadence = live.cadence
        state.resources = live.resources
        state.journalStats = live.journalStats
        state.timeline = live.timeline
        state.suggestionHistory = live.suggestionHistory
        state.activeSuggestion = live.activeSuggestion
        state.replaySummary = ReplaySummary(
            directory: directory, countsByKind: ["triage": 5, "mentor": 3, "test": 1], promptVersion: MentorPrompts.version
        )
        state.callLog = live.callLog.map { call in
            var replayed = call
            replayed.replayed = true
            replayed.cost = 0
            return replayed
        }
        var status = live.mentorStatus
        status.lastTriage = state.callLog.first { $0.tier == .triage }
        status.lastMentor = state.callLog.first { $0.tier == .mentor }
        status.spendThisHour = 0
        status.callsThisHour = 0
        status.cadenceMultiplier = 1
        state.mentorStatus = status
        return state
    }
}

/// The context editor sheet's content: editing the first sample context, or
/// adding one whose name another context already uses.
struct SampleContextEditor: View {
    let duplicate: Bool

    var body: some View {
        ContextEditor(
            context: duplicate ? MentorshipContext(name: SampleSuggestions.contexts[0].name) : SampleSuggestions.contexts[0],
            existing: SampleSuggestions.contexts
        ) { _ in }
    }
}

/// Every inline status message the Settings panes can show, in one form, so
/// the transient ones (a connection test, a refused shortcut, recording a
/// shortcut, recognition unavailable) have renders too.
struct StatusMessagesPreview: View {
    @State private var shortcut: HotKey? = HotKey(keyCode: 17, modifiers: [.control, .option, .command])

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Testing") { ConnectionResult(testing: true, result: nil, replayed: false) }
                LabeledContent("Connected") { ConnectionResult(testing: false, result: .success("claude-haiku-4-5-20251001"), replayed: false) }
                LabeledContent("Replayed") { ConnectionResult(testing: false, result: .success("claude-haiku-4-5-20251001"), replayed: true) }
                LabeledContent("Failed") { ConnectionResult(testing: false, result: .failure(.api(status: 401, type: "authentication_error", message: "invalid x-api-key")), replayed: false) }
                StatusLabel("Paste the whole key. It is one word with no spaces.", kind: .error)
            }
            Section("Shortcuts") {
                LabeledContent("Recording") {
                    HotKeyRecorder(title: "Talk-back shortcut", hotKey: $shortcut, previewRecording: true)
                }
                LabeledContent("Refused") {
                    HotKeyRecorder(title: "Talk-back shortcut", hotKey: $shortcut, previewRefusal: "That is the pause shortcut.")
                }
                StatusLabel("Another app uses this combination, or it lacks Control, Option, or Command. Choose another.", kind: .warning)
            }
            VoiceSection()
        }
        .formStyle(.grouped)
    }
}

/// Every variant of the menu bar mark, at the size the menu bar draws it,
/// with the word a replay puts beside it, and enlarged.
///
/// The menu bar itself cannot be rendered into a window, so this is how a
/// change to the mark gets looked at without a person at the screen, and how
/// CI keeps a picture of all six. Each mark is a template image drawn on the
/// window's own background, so it takes the foreground colour the way it does
/// in the bar, in both appearances; the bar's material is not reproduced here.
/// The two labels are drawn in an outline of the width the bar gives them, so
/// the renders show the mark itself never changes width.
struct SampleMenuBarMarks: View {
    private static let enlargement = 4.0
    private static let spacing = 22.0
    private static let padding = 28.0

    /// The mark's own size, read from the asset the menu bar draws, so the
    /// enlargement reserves exactly the room it takes.
    @MainActor private static var markSize: CGSize {
        MenuBarMarkImage.image(for: .watching)?.size ?? CGSize(width: 14, height: 16)
    }

    /// A window tall enough for every variant, so the picture is of all six
    /// rather than of however many a fixed height happened to leave room for.
    @MainActor static var wholeSize: CGSize {
        let rows = Double(MenuBarMark.allCases.count)
        return CGSize(
            width: 480,
            height: padding * 2 + markSize.height * enlargement * rows + spacing * (rows - 1)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(MenuBarMark.allCases, id: \.self) { mark in
                HStack(spacing: 18) {
                    Text(mark.rawValue)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 160, alignment: .leading)
                    // At the size the menu bar draws it, live and in replay.
                    ForEach([nil, "Replay"], id: \.self) { badge in
                        MenuBarLabel(mark: mark, badge: badge, statusLine: mark.rawValue)
                            .font(Font(NSFont.menuBarFont(ofSize: 0)))
                            .fixedSize()
                            .border(.separator)
                    }
                    Divider().frame(height: 26)
                    // And enlarged, so the drawing can be looked at closely:
                    // the same template PDF drawn at that size, so the curves
                    // and the eyes are the vector rather than the small render
                    // magnified.
                    if let image = MenuBarMarkImage.image(for: mark) {
                        Image(nsImage: image)
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: Self.markSize.width * Self.enlargement,
                                   height: Self.markSize.height * Self.enlargement)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}

/// The note the toast shows on its own, for a talk-back press with nothing to reply to.
struct SampleToastNote: View {
    var body: some View {
        let model = ToastModel()
        model.note = "Nothing to reply to yet: Mentor has not made a suggestion."
        return VStack(spacing: 0) {
            ToastView(model: model, onAction: { _ in })
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// A toast rendered on its own, for snapshots.
struct SampleToast: View {
    let expanded: Bool
    var talkBack: TalkBackState = .idle
    var exchange: [FollowUp] = []
    /// The sample suggestion to show; the newest when nil.
    var suggestionID: Int64?

    var body: some View {
        let model = ToastModel()
        model.suggestion = SampleSuggestions.make(now: Date()).first { suggestionID == nil || $0.id == suggestionID }
        model.expanded = expanded
        model.talkBack = talkBack
        model.exchange = exchange
        model.talkBackKey = "⌃⌥⌘T"
        // The panel sizes itself to the toast's ideal height; a fixed-size
        // snapshot gets the same by letting the toast hug its content.
        return VStack(spacing: 0) {
            ToastView(model: model, onAction: { _ in })
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// The sample frame with a callout drawn over the line the newest sample
/// suggestion points at, scaled the way the frame is.
struct SampleCallout: View {
    var body: some View {
        let sample = SampleFrame.render()
        let block = sample.blocks.first { $0.text.contains("capturer.capture") }
        GeometryReader { geometry in
            let frameSize = sample.image.size
            let scale = min(geometry.size.width / frameSize.width, geometry.size.height / frameSize.height)
            let fitted = CGSize(width: (frameSize.width * scale).rounded(.down), height: (frameSize.height * scale).rounded(.down))
            ZStack(alignment: .topLeading) {
                Image(nsImage: sample.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                if let block {
                    let spot = block.imageRect.insetBy(dx: -6, dy: -5).applying(CGAffineTransform(scaleX: scale, y: scale))
                    let layout = CalloutLayout(screenRect: spot, display: CGRect(origin: .zero, size: fitted))
                    CalloutView(layout: layout, note: "this capture call")
                        .offset(x: layout.windowRect.minX, y: layout.windowRect.minY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

enum SampleSuggestions {
    /// Two declared contexts, so the settings section and the context readouts
    /// have something real to show.
    static let contexts = [
        MentorshipContext(
            name: "writing Swift",
            detail: "Building the Mentor app itself: Swift, SwiftUI, and the tests and build commands around them."
        ),
        MentorshipContext(
            name: "reading API documentation",
            detail: "Working out how an Apple or third-party framework behaves before using it."
        ),
    ]

    static func understanding(now: Date) -> UnderstandingRecord {
        UnderstandingRecord(
            id: 9,
            updatedAt: now.addingTimeInterval(-40),
            startedAt: now.addingTimeInterval(-7300),
            revision: 7,
            promptVersion: MentorPrompts.version,
            model: "claude-opus-5",
            source: .mentorCall,
            cost: 0,
            cumulativeCost: 0.0412,
            content: Understanding(
                goals: [
                    Understanding.Goal(
                        goal: "Get the mentor app's capture path fast enough to leave running all day",
                        evidence: "Two hours in SensingPipeline.swift and CaptureScheduler.swift, repeated make measure runs, and a comment about the 250 ms AX timeout.",
                        confidence: 0.84
                    ),
                    Understanding.Goal(
                        goal: "Keep the phase-two loop's spend under a dollar an hour",
                        evidence: "The spend cap was edited twice and the call log is checked after each mentor call.",
                        confidence: 0.51
                    ),
                ],
                timeline: [
                    "Read the ScreenCaptureKit documentation in Safari, looking at SCScreenshotManager.",
                    "Moved to Xcode and rewrote performCapture to re-check the frontmost app after OCR.",
                    "Ran make measure twice; CPU sat near 0.4% and memory near 62 MB.",
                    "Went back to the AX reads in performCapture after the second measure run.",
                ],
                mentorHistory: [
                    "Suggested swift test --filter to run one suite; they read the full explanation.",
                    "Suggested SCScreenshotManager.captureImage(in:); they answered Not now.",
                    "Suggested reading focus once per capture; still on screen, no answer yet.",
                ],
                openConcerns: [
                    "The size-cap sweep can delete today's text while older thumbnails survive.",
                    "No measurement yet of what the OCR step costs on a dense screen.",
                ]
            )
        )
    }

    static func make(now: Date) -> [Suggestion] {
        [
            Suggestion(
                id: 5, timestamp: now.addingTimeInterval(-12), bundleID: "com.github.wez.wezterm", appName: "WezTerm",
                windowTitle: "zsh - mentor", category: .unwantedSideEffect,
                title: "tccutil reset will drop both grants, not just the stale one",
                body: "Resetting ScreenCapture clears the grant for every build of this bundle id, so the app will ask again from scratch and the running copy stops capturing until you re-grant.",
                explanation: "tccutil reset ScreenCapture com.ahcarpenter.mentor removes the TCC record for that service and bundle identifier outright. That does fix a grant bound to an old code requirement, which is what you are after, but it also means the currently running Mentor loses Screen Recording immediately and falls back to accessibility-only mode until you approve it again in System Settings.\n\nIf the goal is only to re-bind the requirement, quit Mentor first, run the reset, then launch the freshly signed build so the new grant is made against the bundle-identifier requirement that scripts/bundle.sh writes.",
                confidence: 0.78,
                judgedGoal: "Get the mentor app's capture path fast enough to leave running all day",
                observationID: 128, model: "claude-opus-5", promptVersion: MentorPrompts.version
            ),
            Suggestion(
                id: 4, timestamp: now.addingTimeInterval(-40), bundleID: "com.apple.dt.Xcode", appName: "Xcode",
                windowTitle: "SensingPipeline.swift - mentor", category: .approach,
                title: "Read focus once per capture, not per step",
                body: "performCapture reads the AX context, then re-checks the frontmost app twice more. One read up front plus a pid compare is cheaper and avoids the 250 ms AX timeout on hung apps.",
                explanation: "Each AXUIElementCopyAttributeValue call can block up to the messaging timeout you set (250 ms) when the target app is busy, and performCapture currently does that work three times: once in readCurrent() and twice in frontmostIsStill().\n\nNSWorkspace.shared.frontmostApplication is a cheap, non-blocking read, so keep the two late checks but compare only the pid, and drop the bundle-id lookup from the second check since the pid already proves it is the same process.\n\nIf you want to keep the exclusion re-check, look the bundle id up from the pid once and cache it for the duration of the capture.",
                confidence: 0.82, observationID: 128, model: "claude-fable-5-1", promptVersion: MentorPrompts.version
            ),
            Suggestion(
                id: 3, timestamp: now.addingTimeInterval(-1500), bundleID: "com.github.wez.wezterm", appName: "WezTerm",
                windowTitle: "zsh - mentor", category: .shortcut,
                title: "swift test --filter runs one suite",
                body: "You have run the full test suite four times while editing CaptureSchedulerTests. swift test --filter CaptureSchedulerTests runs just that suite in a few seconds.",
                explanation: "SwiftPM accepts a regular expression after --filter and matches it against \"Suite.test\" names, so `swift test --filter CaptureSchedulerTests` runs every test in that suite and `swift test --filter CaptureSchedulerTests/floorFires` runs one test.\n\nWith Swift Testing you can also mark one test with `.tags` and filter on the tag. The full run is still worth doing before you commit.",
                confidence: 0.9, observationID: 104, model: "claude-fable-5-1", promptVersion: MentorPrompts.version,
                feedback: .tellMeMore, feedbackAt: now.addingTimeInterval(-1490)
            ),
            Suggestion(
                id: 2, timestamp: now.addingTimeInterval(-5400), bundleID: "com.apple.Safari", appName: "Safari",
                windowTitle: "ScreenCaptureKit | Apple Developer Documentation", category: .tool,
                title: "SCScreenshotManager has a captureImage(in:) variant",
                body: "The page you are on documents captureImage(contentFilter:configuration:), but the newer captureImage(in: CGRect) skips the filter setup when you only need a display region.",
                explanation: "SCScreenshotManager.captureImage(in:) takes a rectangle in screen coordinates and captures whatever is on screen there, without building an SCContentFilter first. It is a good fit for a region capture, and it still respects the Screen Recording grant.\n\nThe filter-based call remains the right one when you need to exclude your own windows, which your pipeline does, so this may not apply to the main capture path.",
                confidence: 0.64, observationID: 71, model: "claude-fable-5-1", promptVersion: MentorPrompts.version,
                feedback: .notNow, feedbackAt: now.addingTimeInterval(-5390)
            ),
            Suggestion(
                id: 1, timestamp: now.addingTimeInterval(-8000), bundleID: "com.apple.dt.Xcode", appName: "Xcode",
                windowTitle: "Journal.swift - mentor", category: .correctness,
                title: "Retention deletes text before checking the size cap",
                body: "applyRetention runs the age deletes and then the size sweep, so a tiny cap can delete today's text while yesterday's thumbnails survive. Consider sweeping thumbnails first in both passes.",
                explanation: "The age pass deletes thumbnails older than the thumbnail cutoff, then observations older than the text cutoff. The size pass then deletes the oldest thumbnails, then the oldest observations and events. If the size cap is small enough, the second loop can remove observations from today while thumbnails from earlier today remain, because the thumbnail loop only ran until the target was met.\n\nRunning the thumbnail sweep to exhaustion before touching observations keeps the invariant that text outlives thumbnails.",
                confidence: 0.71, observationID: 12, model: "claude-opus-5", promptVersion: MentorPrompts.version,
                feedback: .never, feedbackAt: now.addingTimeInterval(-7990)
            ),
        ]
    }

    /// A short exchange about a suggestion, for the toast and the history.
    static func followUps(now: Date, suggestionID: Int64) -> [FollowUp] {
        switch suggestionID {
        case 4:
            return [
                FollowUp(
                    id: 7, suggestionID: 4, timestamp: now.addingTimeInterval(-20),
                    question: "does that work with tags as well",
                    answer: "Yes. Tag the tests you care about with a Tag you declare once, then run swift test --filter with the tag name in the same way; the suite name filter and the tag filter both narrow the run to seconds.",
                    model: "claude-fable-5-1", promptVersion: MentorPrompts.version
                ),
            ]
        case 3:
            return [
                FollowUp(
                    id: 5, suggestionID: 3, timestamp: now.addingTimeInterval(-1480),
                    question: "which file is that in",
                    answer: "The four full runs were in the terminal window titled zsh - mentor; the suite you were editing is Tests/MentorCoreTests/CaptureSchedulerTests.swift, so swift test --filter CaptureSchedulerTests is the command.",
                    model: "claude-fable-5-1", promptVersion: MentorPrompts.version
                ),
                FollowUp(
                    id: 6, suggestionID: 3, timestamp: now.addingTimeInterval(-1470),
                    question: "and can I run just one test",
                    answer: nil, error: "spend cap reached until 15:00",
                    model: "claude-fable-5-1", promptVersion: MentorPrompts.version
                ),
            ]
        default:
            return []
        }
    }

    static func calls(now: Date) -> [ModelCallRecord] {
        var calls: [ModelCallRecord] = [
            ModelCallRecord(
                id: 63, timestamp: now.addingTimeInterval(-20), tier: .followUp, model: "claude-fable-5-1",
                promptVersion: MentorPrompts.version, promptCharacters: 3_960, imageBytes: 0,
                usage: Usage(inputTokens: 1_240, outputTokens: 160, cacheCreationInputTokens: 0, cacheReadInputTokens: 410),
                cost: 0.0212, latency: 4.1, outcome: .answered, detail: "Yes. Tag the tests you care about with a Tag you declare once, then run swift test --filter with the tag name"
            ),
            ModelCallRecord(
                id: 62, timestamp: now.addingTimeInterval(-389), tier: .understanding, model: "claude-opus-5",
                promptVersion: MentorPrompts.version, promptCharacters: 11_240, imageBytes: 0,
                usage: Usage(inputTokens: 2_980, outputTokens: 540, cacheCreationInputTokens: 0, cacheReadInputTokens: 410),
                cost: 0.0303, latency: 7.8, outcome: .refreshed,
                detail: "Second goal about the spend cap weakened; they have not looked at the call log since"
            ),
            ModelCallRecord(
                id: 61, timestamp: now.addingTimeInterval(-40), tier: .mentor, model: "claude-fable-5-1",
                promptVersion: MentorPrompts.version, promptCharacters: 14_820, imageBytes: 96_400,
                usage: Usage(inputTokens: 6_120, outputTokens: 610, cacheCreationInputTokens: 0, cacheReadInputTokens: 730),
                cost: 0.0920, latency: 9.4, outcome: .suggested, detail: "Read focus once per capture, not per step"
            ),
            ModelCallRecord(
                id: 60, timestamp: now.addingTimeInterval(-52), tier: .triage, model: "claude-haiku-4-5-20251001",
                promptVersion: MentorPrompts.version, promptCharacters: 3_410, imageBytes: 0,
                usage: Usage(inputTokens: 1_120, outputTokens: 42, cacheCreationInputTokens: 0, cacheReadInputTokens: 560),
                cost: 0.0014, latency: 1.1, outcome: .candidate, detail: "Three AX reads per capture with a hung-app timeout"
            ),
        ]
        for i in 0..<14 {
            // Every third call is a moment outside the declared contexts, the
            // outcome that keeps the mentor tier out of it.
            let outside = i % 3 == 1
            let quiet = i % 4 != 2
            calls.append(ModelCallRecord(
                id: Int64(59 - i), timestamp: now.addingTimeInterval(-80 - Double(i) * 47), tier: .triage, model: "claude-haiku-4-5-20251001",
                promptVersion: MentorPrompts.version, promptCharacters: 2_100 + i * 130, imageBytes: 0,
                usage: Usage(inputTokens: 700 + i * 40, outputTokens: 38, cacheCreationInputTokens: i == 13 ? 560 : 0, cacheReadInputTokens: i == 13 ? 0 : 560),
                cost: 0.0011, latency: 0.9 + Double(i % 3) * 0.2,
                outcome: outside ? .outOfContext : (quiet ? .quiet : .candidate),
                detail: outside ? "Booking a flight" : (quiet ? "Reading documentation, nothing to act on" : "Repeated manual test runs")
            ))
        }
        return calls
    }
}

/// A synthetic "screen" with real text, so OCR boxes have something to frame.
private enum SampleFrame {
    static let code = """
    private func performCapture(reason: CaptureReason) async {
        let startedAt = Date()
        defer { scheduler.noteCaptureFinished(at: Date()) }

        guard let focus = await tracker.readCurrent() else { return }
        guard !focus.isExcluded else { return }
        let frame = try await capturer.capture(windowFrame: focus.windowFrame)
    }
    """

    static func render() -> (image: NSImage, blocks: [TextBlock]) {
        var generator = SeededGenerator(seed: 7)
        let size = CGSize(width: 1280, height: 831)
        let image = NSImage(size: size)
        var blocks: [TextBlock] = []
        image.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        NSColor(white: 0.18, alpha: 1).setFill()
        CGRect(x: 0, y: size.height - 36, width: size.width, height: 36).fill()
        CGRect(x: 0, y: 0, width: 230, height: size.height - 36).fill()

        let mono = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor(white: 0.9, alpha: 1)]
        var y = size.height - 70
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let attributed = NSAttributedString(string: text, attributes: attributes)
                let bounds = attributed.size()
                let origin = CGPoint(x: 250, y: y)
                attributed.draw(at: origin)
                let imageRect = CGRect(x: origin.x, y: size.height - origin.y - bounds.height, width: bounds.width, height: bounds.height)
                blocks.append(TextBlock(
                    text: text.trimmingCharacters(in: .whitespaces),
                    confidence: Float.random(in: 0.7...1, using: &generator),
                    imageRect: imageRect,
                    screenRect: imageRect.applying(CGAffineTransform(scaleX: 1512.0 / 1280.0, y: 1512.0 / 1280.0))
                ))
            }
            y -= 24
        }
        let sidebarFont = NSFont.systemFont(ofSize: 13)
        let sidebar: [NSAttributedString.Key: Any] = [.font: sidebarFont, .foregroundColor: NSColor(white: 0.75, alpha: 1)]
        var sy = size.height - 70
        for name in ["MentorCore", "Sensing", "SensingPipeline.swift", "FocusTracker.swift", "ScreenCapturer.swift", "TextRecognizer.swift", "Journal", "Journal.swift"] {
            let attributed = NSAttributedString(string: name, attributes: sidebar)
            let origin = CGPoint(x: 24, y: sy)
            attributed.draw(at: origin)
            let bounds = attributed.size()
            let imageRect = CGRect(x: origin.x, y: size.height - origin.y - bounds.height, width: bounds.width, height: bounds.height)
            blocks.append(TextBlock(text: name, confidence: 0.96, imageRect: imageRect, screenRect: imageRect))
            sy -= 22
        }
        image.unlockFocus()
        return (image, blocks)
    }


    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
}
