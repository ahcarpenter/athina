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
        let specs: [(name: String, size: CGSize, view: AnyView)] = [
            ("permissions", CGSize(width: 560, height: 520), AnyView(PermissionsView())),
            ("debug-panel", CGSize(width: 1180, height: 760), AnyView(DebugPanelView())),
            ("debug-panel-calls", CGSize(width: 1180, height: 760), AnyView(DebugPanelView(initialSidePage: .calls))),
            // The Mentor tab is longer than any window macOS will open, so it
            // renders as tall as a screen allows and its contexts sections get
            // a render of their own.
            ("settings-mentor", CGSize(width: 600, height: 1040), AnyView(SettingsView(initialTab: .mentor))),
            ("settings-mentor-contexts", CGSize(width: 600, height: 800), AnyView(MentorshipContextsPreview())),
            ("settings-cadence", CGSize(width: 600, height: 560), AnyView(SettingsView(initialTab: .cadence))),
            ("settings-frames", CGSize(width: 600, height: 560), AnyView(SettingsView(initialTab: .frames))),
            ("settings-journal", CGSize(width: 600, height: 560), AnyView(SettingsView(initialTab: .journal))),
            ("settings-privacy", CGSize(width: 600, height: 560), AnyView(SettingsView(initialTab: .privacy))),
            ("history", CGSize(width: 860, height: 520), AnyView(HistoryView(initialSelection: 3))),
            ("toast", CGSize(width: ToastController.width + 2, height: 170), AnyView(SampleToast(expanded: false))),
            ("toast-expanded", CGSize(width: ToastController.width + 2, height: 420), AnyView(SampleToast(expanded: true))),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for spec in specs {
                let suffix = appearance == .aqua ? "light" : "dark"
                let url = directory.appendingPathComponent("\(spec.name)-\(suffix).png")
                try await render(spec.view.environment(state), size: spec.size, appearance: appearance, to: url)
            }
        }
    }

    private static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 40, y: 80), size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
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
    /// Realistic data for snapshots and previews. Nothing here touches the pipeline.
    static func sample() -> AppState {
        var settings = SensingSettings()
        settings.mentor.onlyMentorInsideContexts = true
        settings.mentor.contexts = SampleSuggestions.contexts
        let state = AppState(sampleWithSettings: settings)
        let now = Date()
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
        state.permissions = PermissionStatus(screenRecording: true, accessibility: false)
        state.cadence = CadenceStatus(
            mode: .watching,
            lastCaptureAt: observation.timestamp,
            lastCaptureReason: .inputSettled,
            nextDueAt: now.addingTimeInterval(2.6),
            nextDueReason: .floor,
            lastInputAt: Date().addingTimeInterval(-4),
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
            .observation(ActivityObservation(id: 126, timestamp: now.addingTimeInterval(-31), focus: FocusContext(pid: 1, bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "ScreenCaptureKit | Apple Developer Documentation"), frame: frame, textBlocks: Array(sampleFrame.blocks.prefix(4)), reason: .floor)),
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
                focus: FocusContext(pid: 2, bundleID: "com.github.wez.wezterm", appName: "WezTerm", windowTitle: "zsh - mentor"),
                frame: frame, textBlocks: [], reason: i % 3 == 0 ? .focusChange : .floor
            )))
        }
        state.timeline = timeline

        let suggestions = SampleSuggestions.make(now: now)
        state.suggestionHistory = suggestions
        state.activeSuggestion = suggestions.first
        state.callLog = SampleSuggestions.calls(now: now)
        state.mentorStatus = MentorStatus(
            availability: .ready,
            lastGate: MentorStatus.GateRecord(at: now.addingTimeInterval(-2.4), observationID: 128, hold: .tooSoon(until: now.addingTimeInterval(13))),
            lastContext: MentorStatus.ContextRecord(
                at: now.addingTimeInterval(-52),
                placement: .inside(ContextMatch(
                    contextID: SampleSuggestions.contexts[0].id, name: SampleSuggestions.contexts[0].name, confidence: 0.88
                )),
                appName: "Xcode"
            ),
            lastTriage: state.callLog.first { $0.tier == .triage },
            lastMentorHold: nil,
            lastMentor: state.callLog.first { $0.tier == .mentor },
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

/// The mentorship contexts section on its own, because the Mentor tab is
/// taller than any window it would otherwise be rendered in.
struct MentorshipContextsPreview: View {
    var body: some View {
        Form {
            MentorshipContextsSection()
        }
        .formStyle(.grouped)
    }
}

/// A toast rendered on its own, for snapshots.
struct SampleToast: View {
    let expanded: Bool

    var body: some View {
        let model = ToastModel()
        model.suggestion = SampleSuggestions.make(now: Date()).first
        model.expanded = expanded
        return ToastView(model: model, onAction: { _ in })
            .padding(0)
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

    static func make(now: Date) -> [Suggestion] {
        [
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

    static func calls(now: Date) -> [ModelCallRecord] {
        var calls: [ModelCallRecord] = [
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
