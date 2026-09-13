import CoreGraphics
import Foundation

/// Orchestrates focus tracking, input polling, screen capture, frame diffing,
/// OCR, and journaling, and publishes `SensingEvent`s to subscribers.
public actor SensingPipeline {
    public private(set) var settings: SensingSettings
    private let journal: Journal
    private let tracker: FocusTracker
    private let capturer = ScreenCapturer()
    private let recognizer = TextRecognizer()
    private let broadcaster = EventBroadcaster<SensingEvent>()
    private let signal = AsyncSignal()

    private var scheduler: CaptureScheduler
    private var loopTask: Task<Void, Never>?
    private var userPaused = false
    private var isIdle = false
    private var permissions = PermissionStatus(screenRecording: false, accessibility: false)
    private var permissionsCheckedAt: Date = .distantPast
    private var retentionRanAt: Date = .distantPast
    private var mode: SensingMode = .stopped
    private var cadence = CadenceStatus()
    private var lastFocus: FocusContext?
    private var lastKept: (hash: PerceptualHash, windowSignature: String, textSignature: String)?
    private var lastPublishedCadence: Date = .distantPast

    public init(settings: SensingSettings, journal: Journal, tracker: FocusTracker) {
        self.settings = settings
        self.journal = journal
        self.tracker = tracker
        self.scheduler = CaptureScheduler(settings: settings)
    }

    // MARK: Subscription

    /// Every subscriber gets every event from the moment it subscribes.
    public func events() async -> AsyncStream<SensingEvent> {
        await broadcaster.subscribe()
    }

    public var currentMode: SensingMode { mode }
    public var currentCadence: CadenceStatus { cadence }
    public var currentFocus: FocusContext? { lastFocus }
    public var isPaused: Bool { userPaused }

    // MARK: Control

    public func start() async {
        guard loopTask == nil else { return }
        await tracker.updateExcluded(settings.excludedBundleIDSet)
        await tracker.setOnChange { [weak self] change in
            guard let self else { return }
            Task { await self.focusDidChange(change) }
        }
        await tracker.start()
        await journalEvent(JournalEvent(kind: .started))
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
        await tracker.stop()
        await tracker.setOnChange(nil)
        await journalEvent(JournalEvent(kind: .stopped))
        setMode(.stopped)
        await broadcaster.finish()
    }

    public func setPaused(_ paused: Bool) async {
        guard paused != userPaused else { return }
        userPaused = paused
        await journalEvent(JournalEvent(kind: paused ? .paused : .resumed))
        await signal.signal()
    }

    public func updateSettings(_ newSettings: SensingSettings) async {
        let validated = newSettings.validated()
        settings = validated
        scheduler.settings = validated
        await tracker.updateExcluded(validated.excludedBundleIDSet)
        await signal.signal()
    }

    /// Captures as soon as the loop wakes, regardless of cadence.
    public func captureNow() async {
        scheduler.requestManualCapture()
        await signal.signal()
    }

    /// Call when the permissions window sees a change so the loop reacts at once.
    public func permissionsMayHaveChanged() async {
        permissionsCheckedAt = .distantPast
        await signal.signal()
    }

    public func clearJournal() async throws {
        try await journal.clear()
        lastKept = nil
        if let cleared = try? await journal.recentEvents(limit: 1).first {
            await broadcaster.send(.event(cleared))
        }
    }

    // MARK: Focus

    private func focusDidChange(_ change: FocusChange) async {
        let previous = lastFocus
        lastFocus = change.context
        await broadcaster.send(.focusChanged(change.context))

        switch change.kind {
        case .application:
            if previous?.bundleID != change.context.bundleID || previous?.pid != change.context.pid {
                await journalEvent(JournalEvent(
                    kind: .appSwitch,
                    bundleID: change.context.bundleID,
                    appName: change.context.appName,
                    detail: previous.map { "from \($0.appName)" }
                ))
            }
            if change.context.isExcluded, previous?.isExcluded != true {
                await journalEvent(JournalEvent(
                    kind: .excluded, bundleID: change.context.bundleID, appName: change.context.appName
                ))
            }
            scheduler.noteFocusChange(at: Date())
            await signal.signal()
        case .window:
            if previous?.windowSignature != change.context.windowSignature {
                await journalEvent(JournalEvent(
                    kind: .windowSwitch,
                    bundleID: change.context.bundleID,
                    appName: change.context.appName,
                    detail: change.context.windowTitle
                ))
                scheduler.noteFocusChange(at: Date())
                await signal.signal()
            }
        case .element:
            break
        }
    }

    // MARK: Loop

    private func runLoop() async {
        while !Task.isCancelled {
            let now = Date()
            refreshPermissionsIfDue(now: now)
            await runRetentionIfDue(now: now)

            let secondsSinceInput = InputActivity.secondsSinceLastInput()
            cadence.secondsSinceInput = secondsSinceInput
            if secondsSinceInput < settings.inputPollInterval * 1.5 {
                scheduler.noteInput(at: now.addingTimeInterval(-secondsSinceInput))
            }
            await updateIdle(secondsSinceInput: secondsSinceInput)

            let newMode = computeMode()
            setMode(newMode)
            scheduler.setActive(newMode.capturesFrames, at: now)

            var waitFor = newMode == .idle ? settings.idlePollInterval : settings.inputPollInterval
            switch scheduler.evaluate(now: now) {
            case .capture(let reason):
                await performCapture(reason: reason)
                waitFor = min(waitFor, settings.minCaptureInterval)
            case .wait(let until):
                if let until {
                    waitFor = min(waitFor, max(0.01, until.timeIntervalSince(now)))
                }
            }
            publishCadence(now: now)
            await signal.wait(for: .seconds(waitFor))
        }
    }

    private func refreshPermissionsIfDue(now: Date) {
        guard now.timeIntervalSince(permissionsCheckedAt) >= 2 else { return }
        permissionsCheckedAt = now
        let fresh = PermissionProbe.current()
        if fresh != permissions {
            let hadAny = permissions.anyGranted
            permissions = fresh
            if hadAny || fresh.anyGranted {
                Task { await journalEvent(JournalEvent(
                    kind: .permissionsChanged,
                    detail: "screen \(fresh.screenRecording ? "granted" : "denied"), accessibility \(fresh.accessibility ? "granted" : "denied")"
                )) }
            }
        }
    }

    private func runRetentionIfDue(now: Date) async {
        guard now.timeIntervalSince(retentionRanAt) >= settings.retentionInterval else { return }
        retentionRanAt = now
        do {
            let result = try await journal.applyRetention(RetentionPolicy(settings: settings), now: now)
            if result.deletedAnything {
                await journalEvent(JournalEvent(
                    kind: .retention,
                    detail: "removed \(result.thumbnailsDeleted) thumbnails, \(result.observationsDeleted) observations, \(result.eventsDeleted) events"
                ))
            }
        } catch {
            cadence.lastError = "retention: \(error)"
        }
    }

    private func updateIdle(secondsSinceInput: TimeInterval) async {
        let nowIdle = secondsSinceInput >= settings.idleThreshold
        guard nowIdle != isIdle else { return }
        isIdle = nowIdle
        await journalEvent(JournalEvent(
            kind: nowIdle ? .idleStart : .idleEnd,
            detail: nowIdle ? "no input for \(Int(secondsSinceInput))s" : nil
        ))
    }

    private func computeMode() -> SensingMode {
        if userPaused { return .paused }
        if !permissions.anyGranted { return .waitingForPermissions }
        if let lastFocus, lastFocus.isExcluded { return .excluded }
        if isIdle { return .idle }
        if !permissions.screenRecording { return .accessibilityOnly }
        if !permissions.accessibility { return .screenOnly }
        return .watching
    }

    private func setMode(_ newMode: SensingMode) {
        guard newMode != mode else { return }
        mode = newMode
        cadence.mode = newMode
        Task { await broadcaster.send(.modeChanged(newMode)) }
    }

    private func publishCadence(now: Date) {
        let next = scheduler.nextDue(now: now)
        cadence.nextDueAt = next?.at
        cadence.nextDueReason = next?.reason
        cadence.lastCaptureAt = scheduler.lastCaptureAt
        guard now.timeIntervalSince(lastPublishedCadence) >= 0.2 else { return }
        lastPublishedCadence = now
        let snapshot = cadence
        Task { await broadcaster.send(.cadence(snapshot)) }
    }

    // MARK: Capture

    private func performCapture(reason: CaptureReason) async {
        let startedAt = Date()
        defer { scheduler.noteCaptureFinished(at: Date()) }

        let focus: FocusContext
        if let fresh = await tracker.readCurrent() {
            focus = fresh
            lastFocus = fresh
        } else if let lastFocus {
            focus = lastFocus
        } else {
            return
        }
        guard !focus.isExcluded else { return }

        let frame: CapturedFrame
        do {
            frame = try await capturer.capture(windowFrame: focus.windowFrame, maxDimension: settings.maxFrameDimension)
            cadence.lastError = nil
        } catch {
            cadence.lastError = "capture: \(error)"
            permissionsCheckedAt = .distantPast
            return
        }

        guard let hash = FrameImaging.perceptualHash(of: frame.image) else {
            cadence.lastError = "capture: could not hash frame"
            return
        }
        let verdict = FrameKeepPolicy.decide(
            distance: lastKept.map { $0.hash.distance(to: hash) },
            threshold: settings.hashDistanceThreshold,
            windowChanged: lastKept.map { $0.windowSignature != focus.windowSignature } ?? true,
            textChanged: lastKept.map { $0.textSignature != focus.textSignature } ?? true
        )
        guard verdict.keep else {
            cadence.droppedCount += 1
            cadence.lastDropDistance = verdict.distance
            await broadcaster.send(.frameDropped(distance: verdict.distance ?? 0, at: startedAt))
            return
        }

        var blocks: [TextBlock] = []
        do {
            blocks = try await recognizer.recognize(frame, level: settings.ocrLevel)
        } catch {
            cadence.lastError = "ocr: \(error)"
        }
        let jpeg = FrameImaging.jpegData(from: frame.image, quality: settings.thumbnailJPEGQuality)
        let info = FrameInfo(
            hash: hash,
            width: frame.image.width,
            height: frame.image.height,
            displayID: frame.displayID,
            screenRect: frame.screenRect,
            jpeg: jpeg
        )
        var observation = ActivityObservation(timestamp: startedAt, focus: focus, frame: info, textBlocks: blocks, reason: reason)
        do {
            observation = try await journal.record(observation)
        } catch {
            cadence.lastError = "journal: \(error)"
        }
        lastKept = (hash, focus.windowSignature, focus.textSignature)
        cadence.keptCount += 1
        cadence.lastCaptureAt = startedAt
        cadence.lastCaptureReason = reason
        await broadcaster.send(.observation(observation))
    }

    private func journalEvent(_ event: JournalEvent) async {
        var stored = event
        do {
            stored = try await journal.record(event)
        } catch {
            cadence.lastError = "journal: \(error)"
        }
        await broadcaster.send(.event(stored))
    }
}
