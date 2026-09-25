import AppKit
import AthinaCore
import ScreenCaptureKit
import SnapshotDiff
import SwiftUI

/// Developer aid: `Athina --snapshot <dir>` renders every window with sample
/// data to PNG files (light and dark) and quits.
///
/// It draws the app's own views, so it needs no Screen Recording permission and
/// works in CI.
@MainActor
enum Snapshots {
  static let flag = "--snapshot"

  static var requestedDirectory: URL? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
      return nil
    }
    return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
  }

  static var isActive: Bool { requestedDirectory != nil }

  /// The moment every sample stands still at, so every age, time and date a
  /// render shows is the same on every run: Tuesday 15 September 2026,
  /// 14:32:10 UTC. `scripts/snapshots.sh` renders in UTC and US English, so
  /// the clock times read the same on every machine too.
  static let referenceDate = Date(timeIntervalSince1970: 1_789_482_730)

  /// How every window of this run is captured, decided once.
  ///
  /// The two ways draw glass differently, so a run never mixes them, and says
  /// which it used; renders are compared only with renders made the same way.
  private static let capturesWithScreenCaptureKit = CGPreflightScreenCaptureAccess()

  static func render(to directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    print(
      capturesWithScreenCaptureKit
        ? "snapshot: capturing each window with ScreenCaptureKit"
        : "snapshot: no Screen Recording permission, rendering each window's layer tree"
    )
    let state = AppState.sample()
    let replay = AppState.sampleReplay()
    let empty = AppState.sampleEmpty()
    let atCap = AppState.sampleAtContextCap()
    let noSpeech = AppState.sample(
      speechAvailability: .unavailable(
        reason: "On-device speech recognition is not available for Welsh, so talking back is off."
      )
    )
    let noUnderstanding = AppState.sampleUnderstanding(.none)
    let debugPanelOn = AppState.sample(showDebugPanel: true)
    let pane = CGSize(width: SettingsView.paneWidth, height: 640)
    // The debug panel's Now pane is this wide, so the card wraps as it does there.
    func card(_ height: CGFloat) -> CGSize { CGSize(width: 340, height: height) }
    // Render windows are not held to a display's height, so a pane that
    // scrolls in the Settings window renders whole.
    func whole(_ height: CGFloat) -> CGSize {
      CGSize(width: SettingsView.paneWidth, height: height)
    }
    let specs: [(name: String, size: CGSize, view: AnyView, state: AppState)] = [
      ("permissions", CGSize(width: 580, height: 780), AnyView(PermissionsView()), state),
      ("debug-panel", CGSize(width: 1180, height: 860), AnyView(DebugPanelView()), state),
      (
        "debug-panel-calls",
        CGSize(width: 1180, height: 860),
        AnyView(DebugPanelView(initialSidePage: .calls)),
        state
      ),
      ("debug-panel-empty", CGSize(width: 1180, height: 860), AnyView(DebugPanelView()), empty),
      // The Understanding card whole, in each state it can be in.
      ("understanding-card", card(900), AnyView(SampleUnderstandingCard()), state),
      ("understanding-card-empty", card(360), AnyView(SampleUnderstandingCard()), noUnderstanding),
      (
        "understanding-card-paused",
        card(900),
        AnyView(SampleUnderstandingCard()),
        AppState.sampleUnderstanding(.paused)
      ),
      (
        "understanding-card-refreshing",
        card(900),
        AnyView(SampleUnderstandingCard()),
        AppState.sampleUnderstanding(.refreshing)
      ),
      (
        "understanding-card-failed",
        card(900),
        AnyView(SampleUnderstandingCard()),
        AppState.sampleUnderstanding(.failed)
      ),
      ("settings-general", whole(860), AnyView(GeneralSettings().formStyle(.grouped)), state),
      ("settings-contexts", pane, AnyView(ContextsSettings().formStyle(.grouped)), state),
      (
        "settings-contexts-empty",
        CGSize(width: SettingsView.paneWidth, height: 420),
        AnyView(ContextsSettings().formStyle(.grouped)),
        empty
      ),
      (
        "settings-contexts-at-cap",
        whole(1200),
        AnyView(ContextsSettings().formStyle(.grouped)),
        atCap
      ),
      (
        "settings-context-editor",
        CGSize(width: 520, height: 360),
        AnyView(SampleContextEditor(duplicate: false)),
        state
      ),
      (
        "settings-context-editor-duplicate",
        CGSize(width: 520, height: 360),
        AnyView(SampleContextEditor(duplicate: true)),
        state
      ),
      (
        "settings-status-messages",
        CGSize(width: SettingsView.paneWidth, height: 760),
        AnyView(StatusMessagesPreview()),
        noSpeech
      ),
      ("settings-models", whole(1980), AnyView(ModelSettings().formStyle(.grouped)), state),
      ("settings-models-empty", whole(1980), AnyView(ModelSettings().formStyle(.grouped)), empty),
      // The Understanding section sits below the fold of the Models pane,
      // so it also renders on its own, with a record and without one.
      ("settings-understanding", whole(560), AnyView(SampleUnderstandingSettings()), state),
      (
        "settings-understanding-empty",
        whole(480),
        AnyView(SampleUnderstandingSettings()),
        noUnderstanding
      ),
      ("settings-capture", whole(920), AnyView(CaptureSettings().formStyle(.grouped)), state),
      (
        "settings-journal",
        CGSize(width: SettingsView.paneWidth, height: 500),
        AnyView(JournalSettings().formStyle(.grouped)),
        state
      ),
      ("settings-privacy", pane, AnyView(PrivacySettings().formStyle(.grouped)), state),
      // Off, as every install starts, and enabled, with its button live.
      (
        "settings-advanced",
        CGSize(width: SettingsView.paneWidth, height: 180),
        AnyView(AdvancedSettings().formStyle(.grouped)),
        state
      ),
      (
        "settings-advanced-on",
        CGSize(width: SettingsView.paneWidth, height: 180),
        AnyView(AdvancedSettings().formStyle(.grouped)),
        debugPanelOn
      ),
      // The side-effect suggestion, so the goal it was judged against shows.
      (
        "history", CGSize(width: 860, height: 520), AnyView(HistoryView(initialSelection: 5)), state
      ),
      ("history-empty", CGSize(width: 860, height: 520), AnyView(HistoryView()), empty),
      (
        "toast",
        CGSize(width: ToastController.panelWidth, height: 180),
        AnyView(SampleToast(expanded: false)),
        state
      ),
      (
        "toast-expanded",
        CGSize(width: ToastController.panelWidth, height: 460),
        AnyView(SampleToast(expanded: true)),
        state
      ),
      (
        "toast-listening",
        CGSize(width: ToastController.panelWidth, height: 300),
        AnyView(
          SampleToast(
            expanded: false,
            talkBack: .listening(partial: "does that work with tags as"),
            suggestionID: 4
          )
        ),
        state
      ),
      (
        "toast-thinking",
        CGSize(width: ToastController.panelWidth, height: 300),
        AnyView(
          SampleToast(
            expanded: false,
            talkBack: .thinking(question: "does that work with tags as well"),
            suggestionID: 4
          )
        ),
        state
      ),
      (
        "toast-answered",
        CGSize(width: ToastController.panelWidth, height: 400),
        AnyView(
          SampleToast(
            expanded: false,
            exchange: SampleSuggestions.followUps(now: referenceDate, suggestionID: 4),
            suggestionID: 4
          )
        ),
        state
      ),
      (
        "toast-note",
        CGSize(width: ToastController.panelWidth, height: 120),
        AnyView(SampleToastNote()),
        state
      ),
      ("callout", CGSize(width: 900, height: 620), AnyView(SampleCallout()), state),
      ("menu-bar-marks", SampleMenuBarMarks.wholeSize, AnyView(SampleMenuBarMarks()), state),
      ("debug-panel-replay", CGSize(width: 1180, height: 860), AnyView(DebugPanelView()), replay),
      (
        "debug-panel-calls-replay",
        CGSize(width: 1180, height: 860),
        AnyView(DebugPanelView(initialSidePage: .calls)),
        replay
      ),
      ("settings-models-replay", whole(1980), AnyView(ModelSettings().formStyle(.grouped)), replay),
    ]
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      for spec in specs {
        let suffix = appearance == .aqua ? "light" : "dark"
        let url = directory.appendingPathComponent("\(spec.name)-\(suffix).png")
        try await render(
          spec.view.environment(spec.state),
          size: spec.size,
          appearance: appearance,
          to: url
        )
      }
    }
  }

  /// Renders the view in fresh windows until two in a row give the same
  /// picture, and writes the second.
  ///
  /// AppKit now and then lays a text field out a point off in one window (about
  /// one window in a few hundred on the runner), so a single window cannot be
  /// trusted to give the picture every other run gives. The same picture means
  /// within `SnapshotComparison`'s tolerance, since the window server draws
  /// some glass, a dark switch's knob among it, one of two ways from one window
  /// to the next.
  private static func render(
    _ view: some View,
    size: CGSize,
    appearance: NSAppearance.Name,
    to url: URL
  ) async throws {
    var previous: Bitmap?
    for _ in 0..<5 {
      guard let bitmap = try await renderInWindow(view, size: size, appearance: appearance) else {
        previous = nil
        continue
      }
      if let previous, samePicture(previous, bitmap) {
        try bitmap.writePNG(to: url)
        return
      }
      previous = bitmap
    }
    throw SnapshotError.neverSettled(url.lastPathComponent)
  }

  private static func samePicture(_ a: Bitmap, _ b: Bitmap) -> Bool {
    a.size == b.size
      && PixelDiff.compare(a, b, tolerance: SnapshotComparison.defaultTolerance).matches
  }

  /// The view's settled picture in a new window, or nil when it never settled there.
  private static func renderInWindow(
    _ view: some View,
    size: CGSize,
    appearance: NSAppearance.Name
  ) async throws -> Bitmap? {
    // No SwiftUI animation runs and nothing pulses, so a view shows its
    // final state at once and the same state on every run.
    let still =
      view
      .environment(\.drawsStill, true)
      .transaction { $0.disablesAnimations = true }
    let hosting = NSHostingView(rootView: still)
    hosting.sizingOptions = []
    hosting.wantsLayer = true
    // On a display, so the window server composites glass and control
    // bezels, but below the desktop picture, so nothing appears on a screen
    // someone else is using. ScreenCaptureKit captures a window whatever
    // covers it.
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: 40, y: 80), size: size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.stationary, .ignoresCycle]
    window.hasShadow = false
    window.appearance = NSAppearance(named: appearance)
    // A fixed backdrop: the window is opaque and paints the system window
    // background of its appearance, so glass and materials sample that and
    // never whatever happens to be behind the window. Dark mode's wallpaper
    // tinting still reads the desktop picture, which the CI runner never
    // changes; on another Mac it tints the dark forms a little, one reason
    // baselines come only from the runner.
    window.isOpaque = true
    window.backgroundColor = .windowBackgroundColor
    window.contentView = hosting
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.orderFrontRegardless()
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    // Let SwiftUI finish its layout passes and async tasks, and let a
    // fade such as an app icon's arrive at its end.
    try await Task.sleep(for: .milliseconds(700))
    // Then stop Core Animation's clock in this window at a time before any
    // animation began, so one that repeats, such as a spinner, draws its
    // resting state on every run rather than wherever it was at capture.
    hosting.layer?.speed = 0
    hosting.layer?.timeOffset = 0
    return try await settledCapture(window: window, hosting: hosting)
  }

  /// Captures until two captures in a row are the same picture, so a view that
  /// was still settling (a late layout pass, an image that loads on its own) is
  /// never what gets kept; nil when no two ever are.
  ///
  /// A `Bitmap` is in sRGB, so what is kept does not depend on the colour
  /// profile of the display it was captured on, and every viewer shows the file
  /// the same way.
  private static func settledCapture(window: NSWindow, hosting: NSView) async throws -> Bitmap? {
    var previous: Bitmap?
    for _ in 0..<8 {
      hosting.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      if let image = try await capture(window: window, hosting: hosting) {
        let bitmap = try Bitmap(image)
        if let previous, samePicture(previous, bitmap) { return bitmap }
        previous = bitmap
      }
      try await Task.sleep(for: .milliseconds(150))
    }
    return nil
  }

  /// The window captured the run's one way, or nil when ScreenCaptureKit missed
  /// it this time: its stream occasionally fails to start when many windows are
  /// captured back to back, and a new window can be missing from the shareable
  /// content for a moment.
  ///
  /// A missed capture is taken again, never drawn the other way.
  private static func capture(window: NSWindow, hosting: NSView) async throws -> CGImage? {
    guard capturesWithScreenCaptureKit else { return try renderLayerTree(of: hosting) }
    do {
      if let image = try await captureOwnWindow(window) { return image }
      FileHandle.standardError.write(
        Data("snapshot: window not among the shareable windows yet, capturing again\n".utf8)
      )
    } catch {
      FileHandle.standardError.write(
        Data(
          "snapshot: window capture failed (\(error.localizedDescription)), capturing again\n".utf8
        )
      )
    }
    return nil
  }

  /// ScreenCaptureKit for the app's own window; nil when it is not among the shareable windows.
  private static func captureOwnWindow(_ window: NSWindow) async throws -> CGImage? {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: false
    )
    guard
      let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }
      )
    else { return nil }
    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
    let configuration = SCStreamConfiguration()
    let scale = window.backingScaleFactor
    configuration.width = Int(scWindow.frame.width * scale)
    configuration.height = Int(scWindow.frame.height * scale)
    configuration.showsCursor = false
    return try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: configuration
    )
  }

  /// Renders the backing layer tree at the window's scale factor.
  private static func renderLayerTree(of view: NSView) throws -> CGImage {
    let scale = view.window?.backingScaleFactor ?? 2
    let size = view.bounds.size
    guard let layer = view.layer,
      let context = CGContext(
        data: nil,
        width: Int(size.width * scale),
        height: Int(size.height * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue
      )
    else { throw SnapshotError.noBitmap }
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
    /// No two windows in a row gave the same settled picture of the named
    /// file: something in the view keeps moving, it lays out differently
    /// every time, or ScreenCaptureKit kept missing its windows.
    case neverSettled(String)
  }
}

// MARK: - Sample state

extension AppState {
  /// A process id no app has.
  static let samplePid: Int32 = -1

  /// Realistic data for snapshots and previews, stamped around `now` (the
  /// sample's own clock when nil).
  ///
  /// Nothing here touches the pipeline.
  static func sample(
    at now: Date? = nil,
    speechAvailability: SpeechListener.Availability = .available(locale: "English (US)"),
    showDebugPanel: Bool = false
  ) -> AppState {
    var settings = SensingSettings()
    settings.showDebugPanel = showDebugPanel
    settings.mentor.onlyMentorInsideContexts = true
    settings.mentor.contexts = SampleSuggestions.contexts
    // The oldest sample suggestion was answered Never for This.
    settings.mentor.neverRules = [
      NeverRule(
        bundleID: "com.apple.dt.Xcode",
        appName: "Xcode",
        category: .correctness,
        createdAt: (now ?? Snapshots.referenceDate).addingTimeInterval(-7990)
      )
    ]
    let state = AppState(sampleWithSettings: settings, speechAvailability: speechAvailability)
    let now = now ?? state.clock.date
    let focus = FocusContext(
      timestamp: now,
      // No process has this id, so the Frontmost app card draws its own
      // placeholder: any real pid's icon would be whatever app that pid
      // is, drawn by Icon Services only once it has masked it.
      pid: Self.samplePid,
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
    state.permissions = PermissionStatus(
      screenRecording: true,
      accessibility: false,
      microphone: true,
      speechRecognition: false
    )
    let frame = FrameInfo(
      hash: PerceptualHash(words: [
        0x1234_5678_9abc_def0, 0x0fed_cba9_8765_4321, 0xaaaa_5555_aaaa_5555, 0x0f0f_f0f0_0f0f_f0f0,
      ]),
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
      observationCount: 1284,
      thumbnailCount: 512,
      eventCount: 377,
      usedBytes: 138 * 1024 * 1024,
      oldest: now.addingTimeInterval(-3 * 86400),
      newest: now
    )
    var slim = observation
    slim.frame.jpeg = nil
    var timeline: [JournalEntry] = [
      .observation(slim),
      .event(
        JournalEvent(
          id: 12,
          timestamp: now.addingTimeInterval(-9),
          kind: .windowSwitch,
          bundleID: "com.apple.dt.Xcode",
          appName: "Xcode",
          detail: "SensingPipeline.swift - mentor"
        )
      ),
      .observation(
        ActivityObservation(
          id: 127,
          timestamp: now.addingTimeInterval(-14),
          focus: focus,
          frame: frame,
          textBlocks: [],
          reason: .focusChange
        )
      ),
      .event(
        JournalEvent(
          id: 11,
          timestamp: now.addingTimeInterval(-15),
          kind: .appSwitch,
          bundleID: "com.apple.dt.Xcode",
          appName: "Xcode",
          detail: "from Safari"
        )
      ),
      .observation(
        ActivityObservation(
          id: 126,
          timestamp: now.addingTimeInterval(-31),
          focus: FocusContext(
            timestamp: now.addingTimeInterval(-31),
            pid: 1,
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "ScreenCaptureKit | Apple Developer Documentation"
          ),
          frame: frame,
          textBlocks: Array(sampleFrame.blocks.prefix(4)),
          reason: .floor
        )
      ),
      .event(JournalEvent(id: 10, timestamp: now.addingTimeInterval(-64), kind: .idleEnd)),
      .event(
        JournalEvent(
          id: 9,
          timestamp: now.addingTimeInterval(-420),
          kind: .idleStart,
          detail: "no input for 60s"
        )
      ),
      .event(
        JournalEvent(
          id: 8,
          timestamp: now.addingTimeInterval(-900),
          kind: .excluded,
          bundleID: "com.1password.1password",
          appName: "1Password"
        )
      ),
      .event(JournalEvent(id: 7, timestamp: now.addingTimeInterval(-1300), kind: .resumed)),
      .event(JournalEvent(id: 6, timestamp: now.addingTimeInterval(-1500), kind: .paused)),
      .event(
        JournalEvent(
          id: 5,
          timestamp: now.addingTimeInterval(-3600),
          kind: .retention,
          detail: "removed 40 thumbnails, 0 observations, 0 events"
        )
      ),
      .event(JournalEvent(id: 1, timestamp: now.addingTimeInterval(-7200), kind: .started)),
    ]
    for i in 0..<12 {
      timeline.append(
        .observation(
          ActivityObservation(
            id: Int64(110 - i),
            timestamp: now.addingTimeInterval(-7300 - Double(i) * 47),
            focus: FocusContext(
              timestamp: now.addingTimeInterval(-7300 - Double(i) * 47),
              pid: 2,
              bundleID: "com.github.wez.wezterm",
              appName: "WezTerm",
              windowTitle: "zsh - mentor"
            ),
            frame: frame,
            textBlocks: [],
            reason: i % 3 == 0 ? .focusChange : .floor
          )
        )
      )
    }
    // Yesterday's understanding, forgotten as the day's first session began,
    // so it is the oldest entry and the current record starts after it.
    timeline.append(
      .event(
        JournalEvent(
          id: 2,
          timestamp: now.addingTimeInterval(-7860),
          kind: .understanding,
          detail: "expired after revision 12: a new day started"
        )
      )
    )
    state.timeline = JournalTimeline(limit: AppState.timelineLimit, entries: timeline)

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
    state.followUps =
      SampleSuggestions.followUps(now: now, suggestionID: 3)
      + SampleSuggestions.followUps(now: now, suggestionID: 4)
    state.lastCallout = CalloutRecord(
      at: now.addingTimeInterval(-38),
      suggestionID: 4,
      region: region ?? CalloutRegion(rect: .zero, note: ""),
      placement: region.map {
        CalloutPlacement(
          displayID: 1,
          screenRect: CalloutAnchor.screenRect(for: $0.rect, in: frame) ?? .zero,
          note: $0.note
        )
      },
      status: .shown
    )
    state.lastTranscript = TranscriptRecord(
      at: now.addingTimeInterval(-20),
      text: "does that work with tags as well",
      handling: "asked the mentor"
    )
    state.callLog = SampleSuggestions.calls(now: now)
    state.mentorStatus = MentorStatus(
      availability: .ready,
      lastGate: MentorStatus.GateRecord(
        at: now.addingTimeInterval(-2.4),
        observationID: 128,
        hold: .tooSoon(until: now.addingTimeInterval(13))
      ),
      lastContext: MentorStatus.ContextRecord(
        at: now.addingTimeInterval(-52),
        placement: .inside(
          ContextMatch(
            contextID: SampleSuggestions.contexts[0].id,
            name: SampleSuggestions.contexts[0].name
          )
        ),
        appName: "Xcode"
      ),
      lastTriage: state.callLog.first { $0.tier == .triage },
      lastMentorHold: nil,
      lastMentor: state.callLog.first { $0.tier == .mentor },
      understanding: SampleSuggestions.understanding(now: now),
      lastRefreshHold: MentorStatus.RefreshHoldRecord(
        at: now.addingTimeInterval(-2.4),
        hold: .notDue(until: now.addingTimeInterval(511))
      ),
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
      .appendingPathComponent(
        "workspace/mentor/Tests/AthinaCoreTests/Fixtures/Replay",
        isDirectory: true
      )
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
      directory: directory,
      countsByKind: ["triage": 5, "mentor": 3, "test": 1],
      promptVersion: MentorPrompts.version
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

  enum UnderstandingSample {
    /// Athina is ready but has not written an understanding yet.
    case none
    /// Paused, so no active use counts toward a refresh.
    case paused
    /// A periodic refresh call is in flight.
    case refreshing
    /// The last periodic refresh call failed.
    case failed
  }

  /// The sample with the understanding in another state, for the
  /// Understanding card and settings section.
  static func sampleUnderstanding(_ variant: UnderstandingSample) -> AppState {
    let state = sample()
    let now = state.clock.date
    var status = state.mentorStatus
    switch variant {
    case .none:
      state.callLog.removeAll { $0.tier == .understanding }
      status.understanding = nil
      status.lastRefresh = nil
      status.lastRefreshHold = nil
      status.nextRefreshAt = nil
    case .paused:
      state.mode = .paused
      status.lastRefreshHold = MentorStatus.RefreshHoldRecord(
        at: now.addingTimeInterval(-300),
        hold: .unavailable(.paused)
      )
    case .refreshing:
      status.inFlight = .understanding
      status.lastRefreshHold = MentorStatus.RefreshHoldRecord(
        at: now.addingTimeInterval(-1),
        hold: .callInFlight
      )
      status.nextRefreshAt = now.addingTimeInterval(-1)
    case .failed:
      let failed = ModelCallRecord(
        id: 64,
        timestamp: now.addingTimeInterval(-10),
        tier: .understanding,
        model: "claude-opus-5",
        promptVersion: MentorPrompts.version,
        promptCharacters: 12_010,
        imageBytes: 0,
        usage: Usage(
          inputTokens: 0,
          outputTokens: 0,
          cacheCreationInputTokens: 0,
          cacheReadInputTokens: 0
        ),
        cost: 0,
        latency: 30.2,
        outcome: .error,
        detail: ClaudeClientError.api(status: 529, type: "overloaded_error", message: "Overloaded")
          .description
      )
      state.callLog.insert(failed, at: 0)
      status.lastRefresh = failed
      status.lastRefreshHold = MentorStatus.RefreshHoldRecord(
        at: now.addingTimeInterval(-2.4),
        hold: .notDue(until: now.addingTimeInterval(890))
      )
      status.nextRefreshAt = now.addingTimeInterval(890)
    }
    state.mentorStatus = status
    return state
  }
}

/// The Understanding card as the debug panel's Now pane lays it out.
struct SampleUnderstandingCard: View {
  var body: some View {
    VStack(spacing: 0) {
      UnderstandingCard()
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

/// The Models pane's Understanding section on its own.
struct SampleUnderstandingSettings: View {
  var body: some View {
    Form {
      UnderstandingSection()
    }
    .formStyle(.grouped)
  }
}

/// The context editor sheet's content: editing the first sample context, or
/// adding one whose name another context already uses.
struct SampleContextEditor: View {
  let duplicate: Bool

  var body: some View {
    ContextEditor(
      context: duplicate
        ? MentorshipContext(name: SampleSuggestions.contexts[0].name)
        : SampleSuggestions.contexts[0],
      existing: SampleSuggestions.contexts
    ) { _ in }
  }
}

/// Every inline status message the Settings panes can show, in one form, so
/// the transient ones (a connection test, a refused shortcut, recording a
/// shortcut, recognition unavailable) have renders too.
struct StatusMessagesPreview: View {
  @State private var shortcut: HotKey? = HotKey(
    keyCode: 17,
    modifiers: [.control, .option, .command]
  )

  var body: some View {
    Form {
      Section("Connection") {
        LabeledContent("Testing") { ConnectionResult(testing: true, result: nil, replayed: false) }
        LabeledContent("Connected") {
          ConnectionResult(
            testing: false,
            result: .success("claude-haiku-4-5-20251001"),
            replayed: false
          )
        }
        LabeledContent("Replayed") {
          ConnectionResult(
            testing: false,
            result: .success("claude-haiku-4-5-20251001"),
            replayed: true
          )
        }
        LabeledContent("Failed") {
          ConnectionResult(
            testing: false,
            result: .failure(
              .api(status: 401, type: "authentication_error", message: "invalid x-api-key")
            ),
            replayed: false
          )
        }
        StatusLabel("Paste the whole key. It is one word with no spaces.", kind: .error)
      }
      Section("Shortcuts") {
        LabeledContent("Recording") {
          HotKeyRecorder(title: "Talk-back shortcut", hotKey: $shortcut, previewRecording: true)
        }
        LabeledContent("Refused") {
          HotKeyRecorder(
            title: "Talk-back shortcut",
            hotKey: $shortcut,
            previewRefusal: "That is the pause shortcut."
          )
        }
        StatusLabel(
          "Another app uses this combination, or it lacks Control, Option, or Command. Choose another.",
          kind: .warning
        )
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
              .frame(
                width: Self.markSize.width * Self.enlargement,
                height: Self.markSize.height * Self.enlargement
              )
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
    model.note = "Nothing to reply to yet: Athina has not made a suggestion."
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
    model.suggestion = SampleSuggestions.make(now: Snapshots.referenceDate).first {
      suggestionID == nil || $0.id == suggestionID
    }
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
      let scale = min(
        geometry.size.width / frameSize.width,
        geometry.size.height / frameSize.height
      )
      let fitted = CGSize(
        width: (frameSize.width * scale).rounded(.down),
        height: (frameSize.height * scale).rounded(.down)
      )
      ZStack(alignment: .topLeading) {
        Image(nsImage: sample.image)
          .resizable()
          .interpolation(.high)
          .frame(width: fitted.width, height: fitted.height)
        if let block {
          let spot = block.imageRect.insetBy(dx: -6, dy: -5).applying(
            CGAffineTransform(scaleX: scale, y: scale)
          )
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
      detail:
        "Building the Athina app itself: Swift, SwiftUI, and the tests and build commands around them."
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
            goal: "Get Athina's capture path fast enough to leave running all day",
            evidence:
              "Two hours in SensingPipeline.swift and CaptureScheduler.swift, repeated make measure runs, and a comment about the 250 ms AX timeout.",
            confidence: 0.84
          ),
          Understanding.Goal(
            goal: "Keep the phase-two loop's spend under a dollar an hour",
            evidence:
              "The spend cap was edited twice and the call log is checked after each mentor call.",
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
        id: 5,
        timestamp: now.addingTimeInterval(-12),
        bundleID: "com.github.wez.wezterm",
        appName: "WezTerm",
        windowTitle: "zsh - mentor",
        category: .unwantedSideEffect,
        title: "tccutil reset will drop both grants, not just the stale one",
        body:
          "Resetting ScreenCapture clears the grant for every build of this bundle id, so the app will ask again from scratch and the running copy stops capturing until you re-grant.",
        explanation:
          "tccutil reset ScreenCapture com.ahcarpenter.athina removes the TCC record for that service and bundle identifier outright. That does fix a grant bound to an old code requirement, which is what you are after, but it also means the currently running Athina loses Screen Recording immediately and falls back to accessibility-only mode until you approve it again in System Settings.\n\nIf the goal is only to re-bind the requirement, quit Athina first, run the reset, then launch the freshly signed build so the new grant is made against the bundle-identifier requirement that scripts/bundle.sh writes.",
        confidence: 0.78,
        judgedGoal: "Get Athina's capture path fast enough to leave running all day",
        observationID: 128,
        model: "claude-opus-5",
        promptVersion: MentorPrompts.version
      ),
      Suggestion(
        id: 4,
        timestamp: now.addingTimeInterval(-40),
        bundleID: "com.apple.dt.Xcode",
        appName: "Xcode",
        windowTitle: "SensingPipeline.swift - mentor",
        category: .approach,
        title: "Read focus once per capture, not per step",
        body:
          "performCapture reads the AX context, then re-checks the frontmost app twice more. One read up front plus a pid compare is cheaper and avoids the 250 ms AX timeout on hung apps.",
        explanation:
          "Each AXUIElementCopyAttributeValue call can block up to the messaging timeout you set (250 ms) when the target app is busy, and performCapture currently does that work three times: once in readCurrent() and twice in frontmostIsStill().\n\nNSWorkspace.shared.frontmostApplication is a cheap, non-blocking read, so keep the two late checks but compare only the pid, and drop the bundle-id lookup from the second check since the pid already proves it is the same process.\n\nIf you want to keep the exclusion re-check, look the bundle id up from the pid once and cache it for the duration of the capture.",
        confidence: 0.82,
        observationID: 128,
        model: "claude-fable-5-1",
        promptVersion: MentorPrompts.version
      ),
      Suggestion(
        id: 3,
        timestamp: now.addingTimeInterval(-1500),
        bundleID: "com.github.wez.wezterm",
        appName: "WezTerm",
        windowTitle: "zsh - mentor",
        category: .shortcut,
        title: "swift test --filter runs one suite",
        body:
          "You have run the full test suite four times while editing CaptureSchedulerTests. swift test --filter CaptureSchedulerTests runs just that suite in a few seconds.",
        explanation:
          "SwiftPM accepts a regular expression after --filter and matches it against \"Suite.test\" names, so `swift test --filter CaptureSchedulerTests` runs every test in that suite and `swift test --filter CaptureSchedulerTests/floorFires` runs one test.\n\nWith Swift Testing you can also mark one test with `.tags` and filter on the tag. The full run is still worth doing before you commit.",
        confidence: 0.9,
        observationID: 104,
        model: "claude-fable-5-1",
        promptVersion: MentorPrompts.version,
        feedback: .tellMeMore,
        feedbackAt: now.addingTimeInterval(-1490)
      ),
      Suggestion(
        id: 2,
        timestamp: now.addingTimeInterval(-5400),
        bundleID: "com.apple.Safari",
        appName: "Safari",
        windowTitle: "ScreenCaptureKit | Apple Developer Documentation",
        category: .tool,
        title: "SCScreenshotManager has a captureImage(in:) variant",
        body:
          "The page you are on documents captureImage(contentFilter:configuration:), but the newer captureImage(in: CGRect) skips the filter setup when you only need a display region.",
        explanation:
          "SCScreenshotManager.captureImage(in:) takes a rectangle in screen coordinates and captures whatever is on screen there, without building an SCContentFilter first. It is a good fit for a region capture, and it still respects the Screen Recording grant.\n\nThe filter-based call remains the right one when you need to exclude your own windows, which your pipeline does, so this may not apply to the main capture path.",
        confidence: 0.64,
        observationID: 71,
        model: "claude-fable-5-1",
        promptVersion: MentorPrompts.version,
        feedback: .notNow,
        feedbackAt: now.addingTimeInterval(-5390)
      ),
      Suggestion(
        id: 1,
        timestamp: now.addingTimeInterval(-8000),
        bundleID: "com.apple.dt.Xcode",
        appName: "Xcode",
        windowTitle: "Journal.swift - mentor",
        category: .correctness,
        title: "Retention deletes text before checking the size cap",
        body:
          "applyRetention runs the age deletes and then the size sweep, so a tiny cap can delete today's text while yesterday's thumbnails survive. Consider sweeping thumbnails first in both passes.",
        explanation:
          "The age pass deletes thumbnails older than the thumbnail cutoff, then observations older than the text cutoff. The size pass then deletes the oldest thumbnails, then the oldest observations and events. If the size cap is small enough, the second loop can remove observations from today while thumbnails from earlier today remain, because the thumbnail loop only ran until the target was met.\n\nRunning the thumbnail sweep to exhaustion before touching observations keeps the invariant that text outlives thumbnails.",
        confidence: 0.71,
        observationID: 12,
        model: "claude-opus-5",
        promptVersion: MentorPrompts.version,
        feedback: .never,
        feedbackAt: now.addingTimeInterval(-7990)
      ),
    ]
  }

  /// A short exchange about a suggestion, for the toast and the history.
  static func followUps(now: Date, suggestionID: Int64) -> [FollowUp] {
    switch suggestionID {
    case 4:
      return [
        FollowUp(
          id: 7,
          suggestionID: 4,
          timestamp: now.addingTimeInterval(-20),
          question: "does that work with tags as well",
          answer:
            "Yes. Tag the tests you care about with a Tag you declare once, then run swift test --filter with the tag name in the same way; the suite name filter and the tag filter both narrow the run to seconds.",
          model: "claude-fable-5-1",
          promptVersion: MentorPrompts.version
        )
      ]
    case 3:
      return [
        FollowUp(
          id: 5,
          suggestionID: 3,
          timestamp: now.addingTimeInterval(-1480),
          question: "which file is that in",
          answer:
            "The four full runs were in the terminal window titled zsh - mentor; the suite you were editing is Tests/AthinaCoreTests/CaptureSchedulerTests.swift, so swift test --filter CaptureSchedulerTests is the command.",
          model: "claude-fable-5-1",
          promptVersion: MentorPrompts.version
        ),
        FollowUp(
          id: 6,
          suggestionID: 3,
          timestamp: now.addingTimeInterval(-1470),
          question: "and can I run just one test",
          answer: nil,
          error: "spend cap reached until 15:00",
          model: "claude-fable-5-1",
          promptVersion: MentorPrompts.version
        ),
      ]
    default:
      return []
    }
  }

  static func calls(now: Date) -> [ModelCallRecord] {
    var calls: [ModelCallRecord] = [
      ModelCallRecord(
        id: 63,
        timestamp: now.addingTimeInterval(-20),
        tier: .followUp,
        model: "claude-fable-5-1",
        promptVersion: MentorPrompts.version,
        promptCharacters: 3_960,
        imageBytes: 0,
        usage: Usage(
          inputTokens: 1_240,
          outputTokens: 160,
          cacheCreationInputTokens: 0,
          cacheReadInputTokens: 410
        ),
        cost: 0.0212,
        latency: 4.1,
        outcome: .answered,
        detail:
          "Yes. Tag the tests you care about with a Tag you declare once, then run swift test --filter with the tag name"
      ),
      ModelCallRecord(
        id: 62,
        timestamp: now.addingTimeInterval(-389),
        tier: .understanding,
        model: "claude-opus-5",
        promptVersion: MentorPrompts.version,
        promptCharacters: 11_240,
        imageBytes: 0,
        usage: Usage(
          inputTokens: 2_980,
          outputTokens: 540,
          cacheCreationInputTokens: 0,
          cacheReadInputTokens: 410
        ),
        cost: 0.0303,
        latency: 7.8,
        outcome: .refreshed,
        detail:
          "Second goal about the spend cap weakened; they have not looked at the call log since"
      ),
      ModelCallRecord(
        id: 61,
        timestamp: now.addingTimeInterval(-40),
        tier: .mentor,
        model: "claude-fable-5-1",
        promptVersion: MentorPrompts.version,
        promptCharacters: 14_820,
        imageBytes: 96_400,
        usage: Usage(
          inputTokens: 6_120,
          outputTokens: 610,
          cacheCreationInputTokens: 0,
          cacheReadInputTokens: 730
        ),
        cost: 0.0920,
        latency: 9.4,
        outcome: .suggested,
        detail: "Read focus once per capture, not per step"
      ),
      ModelCallRecord(
        id: 60,
        timestamp: now.addingTimeInterval(-52),
        tier: .triage,
        model: "claude-haiku-4-5-20251001",
        promptVersion: MentorPrompts.version,
        promptCharacters: 3_410,
        imageBytes: 0,
        usage: Usage(
          inputTokens: 1_120,
          outputTokens: 42,
          cacheCreationInputTokens: 0,
          cacheReadInputTokens: 560
        ),
        cost: 0.0014,
        latency: 1.1,
        outcome: .candidate,
        detail: "Three AX reads per capture with a hung-app timeout"
      ),
    ]
    for i in 0..<14 {
      // Every third call is a moment outside the declared contexts, the
      // outcome that keeps the mentor tier out of it.
      let outside = i % 3 == 1
      let quiet = i % 4 != 2
      calls.append(
        ModelCallRecord(
          id: Int64(59 - i),
          timestamp: now.addingTimeInterval(-80 - Double(i) * 47),
          tier: .triage,
          model: "claude-haiku-4-5-20251001",
          promptVersion: MentorPrompts.version,
          promptCharacters: 2_100 + i * 130,
          imageBytes: 0,
          usage: Usage(
            inputTokens: 700 + i * 40,
            outputTokens: 38,
            cacheCreationInputTokens: i == 13 ? 560 : 0,
            cacheReadInputTokens: i == 13 ? 0 : 560
          ),
          cost: 0.0011,
          latency: 0.9 + Double(i % 3) * 0.2,
          outcome: outside ? .outOfContext : (quiet ? .quiet : .candidate),
          detail: outside
            ? "Booking a flight"
            : (quiet ? "Reading documentation, nothing to act on" : "Repeated manual test runs")
        )
      )
    }
    // Newest first, as the journal lists them.
    return calls.sorted { $0.timestamp > $1.timestamp }
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
    let attributes: [NSAttributedString.Key: Any] = [
      .font: mono, .foregroundColor: NSColor(white: 0.9, alpha: 1),
    ]
    var y = size.height - 70
    for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      if !text.trimmingCharacters(in: .whitespaces).isEmpty {
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let bounds = attributed.size()
        let origin = CGPoint(x: 250, y: y)
        attributed.draw(at: origin)
        let imageRect = CGRect(
          x: origin.x,
          y: size.height - origin.y - bounds.height,
          width: bounds.width,
          height: bounds.height
        )
        blocks.append(
          TextBlock(
            text: text.trimmingCharacters(in: .whitespaces),
            confidence: Float.random(in: 0.7...1, using: &generator),
            imageRect: imageRect,
            screenRect: imageRect.applying(
              CGAffineTransform(scaleX: 1512.0 / 1280.0, y: 1512.0 / 1280.0)
            )
          )
        )
      }
      y -= 24
    }
    let sidebarFont = NSFont.systemFont(ofSize: 13)
    let sidebar: [NSAttributedString.Key: Any] = [
      .font: sidebarFont, .foregroundColor: NSColor(white: 0.75, alpha: 1),
    ]
    var sy = size.height - 70
    for name in [
      "AthinaCore",
      "Sensing",
      "SensingPipeline.swift",
      "FocusTracker.swift",
      "ScreenCapturer.swift",
      "TextRecognizer.swift",
      "Journal",
      "Journal.swift",
    ] {
      let attributed = NSAttributedString(string: name, attributes: sidebar)
      let origin = CGPoint(x: 24, y: sy)
      attributed.draw(at: origin)
      let bounds = attributed.size()
      let imageRect = CGRect(
        x: origin.x,
        y: size.height - origin.y - bounds.height,
        width: bounds.width,
        height: bounds.height
      )
      blocks.append(
        TextBlock(text: name, confidence: 0.96, imageRect: imageRect, screenRect: imageRect)
      )
      sy -= 22
    }
    image.unlockFocus()
    return (image, blocks)
  }

  private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state
    }
  }
}
