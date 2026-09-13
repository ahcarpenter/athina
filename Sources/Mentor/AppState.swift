import AppKit
import MentorCore
import Observation
import OSLog
import SwiftUI

/// Main-actor view of everything the pipeline and the mentor loop publish,
/// plus app-level actions.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    static let timelineLimit = 300
    static let callLogLimit = 200
    static let historyLimit = 500
    static let log = Logger(subsystem: "com.ahcarpenter.mentor", category: "app")

    var settings: SensingSettings {
        didSet {
            guard settings != oldValue else { return }
            let validated = settings.validated()
            if settings != validated {
                settings = validated
                return
            }
            scheduleSettingsSave()
            let pipeline = pipeline
            let mentor = mentor
            let settings = settings
            let hotKey = settings.pauseHotKey
            Task {
                await pipeline?.updateSettings(settings)
                await mentor?.updateSettings(settings.mentor)
            }
            if hotKey != oldValue.pauseHotKey {
                hotKeyRegistered = hotKeys.register(hotKey)
                AppState.log.notice("pause hotkey \(hotKey.displayString, privacy: .public) registered: \(self.hotKeyRegistered)")
            }
        }
    }

    /// False when the pause hotkey could not be registered (unusable or taken by another app).
    private(set) var hotKeyRegistered = false

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

    // MARK: Mentor loop state

    var mentorStatus = MentorStatus()
    /// Newest first.
    var callLog: [ModelCallRecord] = []
    /// Newest first.
    var suggestionHistory: [Suggestion] = []
    /// The suggestion currently shown as a toast, if any.
    var activeSuggestion: Suggestion?
    /// Last four characters of the saved key, or nil when there is none.
    private(set) var apiKeyHint: String?
    private(set) var apiKeyError: String?

    /// Whether the permissions window should open at launch.
    let needsPermissionsOnboarding: Bool
    let journalURL = Journal.defaultURL()
    let settingsURL = SettingsStore.defaultURL()

    private let store: SettingsStore
    private let keyStore: any KeyStore
    private let isSample: Bool
    private let hotKeys = HotKeyCenter()
    private var journal: Journal?
    private var pipeline: SensingPipeline?
    private var tracker: FocusTracker?
    private var mentor: MentorLoop?
    private var eventTask: Task<Void, Never>?
    private var mentorTask: Task<Void, Never>?
    private var resourceTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var toastDeadline: Date?
    private var toastRemaining: TimeInterval?
    private let toast = ToastController()

    private init() {
        store = SettingsStore(url: SettingsStore.defaultURL())
        keyStore = KeychainKeyStore()
        isSample = false
        settings = store.load()
        let status = PermissionProbe.current()
        permissions = status
        needsPermissionsOnboarding = !status.allGranted
        reloadKeyHint()
    }

    /// A detached state for snapshots and previews: never starts the pipeline.
    init(sampleWithSettings settings: SensingSettings) {
        store = SettingsStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mentor-sample-settings.json"))
        keyStore = InMemoryKeyStore(key: "sk-ant-sample-key-0000-7Q2x")
        isSample = true
        self.settings = settings
        permissions = PermissionStatus(screenRecording: true, accessibility: true)
        needsPermissionsOnboarding = false
        reloadKeyHint()
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        hotKeys.onPress = { [weak self] in self?.togglePause() }
        hotKeyRegistered = hotKeys.register(settings.pauseHotKey)
        AppState.log.notice("pause hotkey \(self.settings.pauseHotKey.displayString, privacy: .public) registered: \(self.hotKeyRegistered)")

        let journal: Journal
        do {
            journal = try Journal(url: journalURL)
        } catch {
            journalError = "Could not open the journal at \(journalURL.path): \(error)"
            AppState.log.error("journal unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        AppState.log.notice("journal open at \(self.journalURL.path, privacy: .public)")
        self.journal = journal
        let tracker = FocusTracker()
        self.tracker = tracker
        let pipeline = SensingPipeline(settings: settings, journal: journal, tracker: tracker)
        self.pipeline = pipeline
        let mentorSettings = settings.mentor
        let keyStore = keyStore
        toast.onAction = { [weak self] id, feedback in
            self?.respond(to: id, with: feedback)
        }
        toast.onHover = { [weak self] hovering in
            self?.toastHoverChanged(hovering)
        }

        eventTask = Task { [weak self] in
            let stream = await pipeline.events()
            let mentorStream = await pipeline.events()
            let mentor = MentorLoop(
                settings: mentorSettings, journal: journal, client: AnthropicClient(), keyStore: keyStore, events: mentorStream
            )
            await self?.attach(mentor: mentor, journal: journal)
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

    private func attach(mentor: MentorLoop, journal: Journal) async {
        self.mentor = mentor
        let mentorEvents = await mentor.events()
        await mentor.start()
        mentorTask = Task { [weak self] in
            for await event in mentorEvents {
                guard let self else { return }
                self.handle(event)
            }
        }
        callLog = (try? await journal.recentModelCalls(limit: AppState.callLogLimit)) ?? []
        suggestionHistory = (try? await journal.recentSuggestions(limit: AppState.historyLimit)) ?? []
    }

    func stop() async {
        resourceTask?.cancel()
        saveTask?.cancel()
        if let active = activeSuggestion {
            await respond(to: active.id, with: .expired)?.value
        }
        try? store.save(settings)
        await mentor?.stop()
        mentorTask?.cancel()
        await pipeline?.stop()
        eventTask?.cancel()
        hotKeys.unregister()
        isRunning = false
    }

    // MARK: Actions

    func togglePause() {
        isPaused.toggle()
        let paused = isPaused
        AppState.log.notice("pause toggled: \(paused)")
        Task { await pipeline?.setPaused(paused) }
    }

    func captureNow() {
        Task { await pipeline?.captureNow() }
    }

    func refreshPermissions() {
        guard !isSample else { return }
        let fresh = PermissionProbe.current()
        guard fresh != permissions else { return }
        permissions = fresh
        Task { await pipeline?.permissionsMayHaveChanged() }
    }

    func requestPermission(_ permission: Permission) {
        guard !isSample else { return }
        AppState.log.notice("requesting permission \(permission.rawValue, privacy: .public)")
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
            callLog.removeAll()
            suggestionHistory.removeAll()
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

    /// Loads a journaled observation with its thumbnail, for timeline browsing.
    func loadObservation(id: Int64) async -> (ActivityObservation, NSImage?)? {
        guard let journal else { return nil }
        guard let observation = try? await journal.observation(id: id) else { return nil }
        let jpeg = try? await journal.thumbnail(observationID: id)
        return (observation, jpeg.flatMap(NSImage.init(data:)))
    }

    // MARK: API key

    var hasAPIKey: Bool { apiKeyHint != nil }

    /// Saves a new key to the Keychain. Returns false when the text is not usable as a key.
    @discardableResult
    func saveAPIKey(_ raw: String) -> Bool {
        guard let key = APIKey.normalized(raw) else { return false }
        do {
            try keyStore.save(key)
            apiKeyError = nil
            AppState.log.notice("api key saved (ends in \(APIKey.lastFour(key), privacy: .public))")
        } catch {
            apiKeyError = "Could not save the key: \(error)"
            AppState.log.error("api key save failed: \(String(describing: error), privacy: .public)")
        }
        reloadKeyHint()
        Task { await mentor?.apiKeyChanged() }
        return apiKeyError == nil
    }

    func removeAPIKey() {
        do {
            try keyStore.delete()
            apiKeyError = nil
            AppState.log.notice("api key removed")
        } catch {
            apiKeyError = "Could not remove the key: \(error)"
        }
        reloadKeyHint()
        Task { await mentor?.apiKeyChanged() }
    }

    /// One tiny request; the result is the answering model's id or the API's error text.
    func testConnection() async -> Result<String, ClaudeClientError> {
        guard let mentor else { return .failure(.transport("the mentor loop is not running")) }
        return await mentor.testConnection()
    }

    private func reloadKeyHint() {
        do {
            apiKeyHint = try keyStore.load().map(APIKey.lastFour)
        } catch {
            apiKeyHint = nil
            apiKeyError = "Could not read the key: \(error)"
        }
    }

    // MARK: Suggestions

    /// Records feedback for a suggestion, whether it came from the toast or the
    /// history window. A non-answer (expiry or closing the toast) is recorded
    /// once and never overwrites anything: closing a re-shown toast just closes it.
    /// Tell me more is recorded once too; re-expanding a folded toast is only a
    /// view change. Returns the task that journals the feedback, or nil when
    /// nothing was recorded.
    @discardableResult
    func respond(to suggestionID: Int64, with feedback: SuggestionFeedback) -> Task<Void, Never>? {
        let existing = suggestionHistory.first { $0.id == suggestionID }?.feedback
        if activeSuggestion?.id == suggestionID {
            cancelToastExpiry()
            if feedback != .tellMeMore {
                toast.dismiss()
                activeSuggestion = nil
            }
        }
        if feedback.isNonAnswer, existing != nil { return nil }
        if feedback == .tellMeMore, existing == .tellMeMore { return nil }
        if let index = suggestionHistory.firstIndex(where: { $0.id == suggestionID }) {
            suggestionHistory[index].feedback = feedback
            suggestionHistory[index].feedbackAt = Date()
        }
        let suggestion = suggestionHistory.first { $0.id == suggestionID }
        switch feedback {
        case .notNow:
            if let suggestion {
                let snooze = Snooze(
                    bundleID: suggestion.bundleID, appName: suggestion.appName,
                    category: suggestion.category, until: Date().addingTimeInterval(settings.mentor.notNowSnooze)
                )
                settings.mentor.snoozes = SuppressionRules.adding(snooze, to: settings.mentor.snoozes, now: Date())
            }
        case .never:
            if let suggestion {
                let rule = NeverRule(
                    bundleID: suggestion.bundleID, appName: suggestion.appName,
                    category: suggestion.category, createdAt: Date()
                )
                settings.mentor.neverRules = SuppressionRules.adding(rule, to: settings.mentor.neverRules)
            }
        case .tellMeMore, .expired, .dismissed:
            break
        }
        AppState.log.notice("suggestion \(suggestionID) feedback \(feedback.rawValue, privacy: .public)")
        return Task { await mentor?.recordFeedback(suggestionID: suggestionID, feedback: feedback) }
    }

    /// Brings the most recent suggestion back as a toast, for one that was
    /// missed. A toast the user asked for stays until answered or closed.
    func showLastSuggestion() {
        guard let latest = suggestionHistory.first else { return }
        show(latest, autoExpires: false)
    }

    private func present(_ suggestion: Suggestion) {
        suggestionHistory.insert(suggestion, at: 0)
        if suggestionHistory.count > AppState.historyLimit {
            suggestionHistory.removeLast(suggestionHistory.count - AppState.historyLimit)
        }
        show(suggestion, autoExpires: true)
    }

    private func show(_ suggestion: Suggestion, autoExpires: Bool) {
        if let active = activeSuggestion, active.id != suggestion.id {
            respond(to: active.id, with: .expired)
        }
        cancelToastExpiry()
        activeSuggestion = suggestion
        toast.show(suggestion, expanded: false)
        if autoExpires {
            scheduleToastExpiry(for: suggestion.id, after: settings.mentor.toastTimeout)
        }
    }

    /// The countdown pauses while the pointer is over the toast and resumes
    /// with the remaining time when it leaves.
    private func toastHoverChanged(_ hovering: Bool) {
        guard let active = activeSuggestion else { return }
        if hovering {
            // cancelToastExpiry clears toastRemaining, so record the remainder after it.
            guard let deadline = toastDeadline else { return }
            let remaining = max(2, deadline.timeIntervalSinceNow)
            cancelToastExpiry()
            toastRemaining = remaining
        } else if let remaining = toastRemaining {
            toastRemaining = nil
            scheduleToastExpiry(for: active.id, after: remaining)
        }
    }

    private func scheduleToastExpiry(for suggestionID: Int64, after timeout: TimeInterval) {
        toastTask?.cancel()
        toastDeadline = Date().addingTimeInterval(timeout)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.activeSuggestion?.id == suggestionID else { return }
            self.respond(to: suggestionID, with: .expired)
        }
    }

    private func cancelToastExpiry() {
        toastTask?.cancel()
        toastTask = nil
        toastDeadline = nil
        toastRemaining = nil
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

    /// One line for the menu: spend this hour against the cap, or why the loop is off.
    var mentorLine: String {
        switch mentorStatus.availability {
        case .ready, .capReached:
            let spend = Formatting.dollars(mentorStatus.spendThisHour)
            let cap = Formatting.dollars(settings.mentor.hourlySpendCap)
            if case .capReached = mentorStatus.availability {
                return "Mentor: \(spend) of \(cap) this hour, cap reached"
            }
            if mentorStatus.cadenceMultiplier > 1.05 {
                return "Mentor: \(spend) of \(cap) this hour, slowed \(Formatting.multiplier(mentorStatus.cadenceMultiplier))"
            }
            return "Mentor: \(spend) of \(cap) this hour"
        case .disabled: return "Mentor: off"
        case .noAPIKey: return "Mentor: add an API key in Settings"
        }
    }

    /// One line for the menu saying where the declared contexts put the
    /// current activity, or nil when contexts have nothing to say: they are
    /// not being enforced. A verdict is only shown while it is still about the
    /// frontmost app, because it is rewritten only when triage runs and most
    /// observations hold before that.
    var mentorContextLine: String? {
        let mentor = settings.mentor
        guard mentor.onlyMentorInsideContexts else { return nil }
        guard let record = mentorStatus.lastContext, record.appName == focus?.appName else {
            if mentor.contexts.isEmpty { return "Context: none declared, so nothing is mentored" }
            guard let appName = focus?.appName else { return "Context: not judged yet" }
            return "Context: not yet judged in \(appName)"
        }
        switch record.placement {
        case .notEnforced:
            return nil
        case .inside(let match):
            return "Context: \(match.label)"
        case .outside(let exclusion):
            return "Context: out, \(exclusion.label)"
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
        case .modeChanged(let newMode):
            mode = newMode
            AppState.log.notice("mode: \(newMode.rawValue, privacy: .public)")
            refreshPermissions()
        case .event(let journalEvent):
            prepend(.event(journalEvent))
        case .cadence(let status):
            if status != cadence { cadence = status }
        }
    }

    private func handle(_ event: MentorEvent) {
        switch event {
        case .status(let status):
            if status != mentorStatus { mentorStatus = status }
        case .suggestion(let suggestion):
            present(suggestion)
        case .feedback(let suggestion):
            if let index = suggestionHistory.firstIndex(where: { $0.id == suggestion.id }) {
                suggestionHistory[index] = suggestion
            }
        case .call(let record):
            callLog.insert(record, at: 0)
            if callLog.count > AppState.callLogLimit {
                callLog.removeLast(callLog.count - AppState.callLogLimit)
            }
        case .event(let journalEvent):
            prepend(.event(journalEvent))
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
