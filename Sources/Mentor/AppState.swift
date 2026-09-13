import AppKit
import MentorCore
import Observation
import SwiftUI

/// Main-actor view of everything the pipeline publishes, plus app-level actions.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    static let timelineLimit = 300

    var settings: SensingSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSettingsSave()
            let pipeline = pipeline
            let hotKey = settings.pauseHotKey
            Task { await pipeline?.updateSettings(settings) }
            hotKeys.register(hotKey)
        }
    }

    var mode: SensingMode = .stopped
    var permissions: PermissionStatus
    var focus: FocusContext?
    var latestObservation: ActivityObservation?
    var latestImage: NSImage?
    var cadence = CadenceStatus()
    var timeline: [JournalEntry] = []
    var resources: ProcessResourceUsage?
    var journalStats: JournalStats?
    private(set) var journalError: String?
    private(set) var isPaused = false
    private(set) var isRunning = false

    /// Whether the permissions window should open at launch.
    let needsPermissionsOnboarding: Bool
    let journalURL = Journal.defaultURL()
    let settingsURL = SettingsStore.defaultURL()

    private let store: SettingsStore
    private let hotKeys = HotKeyCenter()
    private var journal: Journal?
    private var pipeline: SensingPipeline?
    private var tracker: FocusTracker?
    private var eventTask: Task<Void, Never>?
    private var resourceTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    private init() {
        store = SettingsStore(url: SettingsStore.defaultURL())
        settings = store.load()
        let status = PermissionProbe.current()
        permissions = status
        needsPermissionsOnboarding = !status.allGranted
    }

    /// A detached state for snapshots and previews: never starts the pipeline.
    init(sampleWithSettings settings: SensingSettings) {
        store = SettingsStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mentor-sample-settings.json"))
        self.settings = settings
        permissions = PermissionStatus(screenRecording: true, accessibility: true)
        needsPermissionsOnboarding = false
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        hotKeys.onPress = { [weak self] in self?.togglePause() }
        hotKeys.register(settings.pauseHotKey)

        let journal: Journal
        do {
            journal = try Journal(url: journalURL)
        } catch {
            journalError = "Could not open the journal at \(journalURL.path): \(error)"
            return
        }
        self.journal = journal
        let tracker = FocusTracker()
        self.tracker = tracker
        let pipeline = SensingPipeline(settings: settings, journal: journal, tracker: tracker)
        self.pipeline = pipeline

        eventTask = Task { [weak self] in
            let stream = await pipeline.events()
            await self?.loadInitialTimeline(from: journal)
            await pipeline.start()
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        resourceTask = Task { [weak self] in
            var previous = ProcessResources.sample()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let current = ProcessResources.sample()
                if let usage = ProcessResourceUsage.between(previous, current) {
                    self?.resources = usage
                }
                previous = current
            }
        }
    }

    func stop() async {
        resourceTask?.cancel()
        saveTask?.cancel()
        try? store.save(settings)
        await pipeline?.stop()
        eventTask?.cancel()
        hotKeys.unregister()
        isRunning = false
    }

    // MARK: Actions

    func togglePause() {
        isPaused.toggle()
        let paused = isPaused
        Task { await pipeline?.setPaused(paused) }
    }

    func captureNow() {
        Task { await pipeline?.captureNow() }
    }

    func refreshPermissions() {
        let fresh = PermissionProbe.current()
        guard fresh != permissions else { return }
        permissions = fresh
        Task { await pipeline?.permissionsMayHaveChanged() }
    }

    func requestPermission(_ permission: Permission) {
        PermissionProbe.request(permission)
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshPermissions()
        }
    }

    func clearJournal() async {
        do {
            try await pipeline?.clearJournal()
            timeline.removeAll()
            latestObservation = nil
            latestImage = nil
            if let journal {
                await loadInitialTimeline(from: journal)
            }
            await refreshJournalStats()
        } catch {
            journalError = "Could not clear the journal: \(error)"
        }
    }

    func refreshJournalStats() async {
        guard let journal else { return }
        journalStats = try? await journal.stats()
    }

    func resetSettingsToDefaults() {
        settings = SensingSettings()
    }

    /// Loads a journaled observation with its thumbnail, for timeline browsing.
    func loadObservation(id: Int64) async -> (ActivityObservation, NSImage?)? {
        guard let journal else { return nil }
        guard let observation = try? await journal.observation(id: id) else { return nil }
        let jpeg = try? await journal.thumbnail(observationID: id)
        return (observation, jpeg.flatMap(NSImage.init(data:)))
    }

    // MARK: Presentation helpers

    var menuBarSymbol: String {
        switch mode {
        case .watching, .screenOnly, .accessibilityOnly: "eye.fill"
        case .idle: "eye"
        case .paused, .stopped: "eye.slash"
        case .excluded: "hand.raised.fill"
        case .waitingForPermissions: "eye.trianglebadge.exclamationmark"
        }
    }

    var statusLine: String {
        switch mode {
        case .watching, .screenOnly, .accessibilityOnly:
            if let focus { return "Watching \(focus.appName)" }
            return "Watching"
        case .idle: return "Idle, waiting for input"
        case .paused: return "Paused"
        case .excluded: return "Not watching \(focus?.appName ?? "excluded app")"
        case .waitingForPermissions: return "Waiting for permissions"
        case .stopped: return journalError == nil ? "Starting…" : "Stopped: journal unavailable"
        }
    }

    // MARK: Private

    private func handle(_ event: SensingEvent) {
        switch event {
        case .observation(let observation):
            latestObservation = observation
            latestImage = observation.frame.jpeg.flatMap(NSImage.init(data:))
            var slim = observation
            slim.frame.jpeg = nil
            prepend(.observation(slim))
        case .focusChanged(let context):
            focus = context
        case .frameDropped:
            break
        case .modeChanged(let newMode):
            mode = newMode
            refreshPermissions()
        case .event(let journalEvent):
            prepend(.event(journalEvent))
        case .cadence(let status):
            cadence = status
        }
    }

    private func prepend(_ entry: JournalEntry) {
        timeline.insert(entry, at: 0)
        if timeline.count > AppState.timelineLimit {
            timeline.removeLast(timeline.count - AppState.timelineLimit)
        }
    }

    private func loadInitialTimeline(from journal: Journal) async {
        if let entries = try? await journal.recentEntries(limit: AppState.timelineLimit) {
            timeline = entries
        }
        journalStats = try? await journal.stats()
    }

    private func scheduleSettingsSave() {
        saveTask?.cancel()
        let store = store
        let settings = settings
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? store.save(settings)
        }
    }
}
