import AppKit
import AthinaCore
import Foundation
import OSLog
import Observation

/// The last callout decision, for the debug panel.
struct CalloutRecord: Equatable {
  enum Status: String {
    case shown
    case notShown = "not shown"
    case takenDown = "taken down"
  }

  var at: Date
  var suggestionID: Int64
  var region: CalloutRegion
  /// Where it was drawn, or nil when it was not.
  var placement: CalloutPlacement?
  var status: Status
  /// Why it was not shown or was taken down.
  var reason: String?

  /// "taken down: window moved", for the log.
  var summary: String {
    reason.map { "\(status.rawValue): \($0)" } ?? status.rawValue
  }
}

/// The last thing heard over push-to-talk, for the debug panel.
struct TranscriptRecord: Equatable {
  var at: Date
  var text: String
  var handling: String
}

/// Main-actor view of everything the pipeline and the mentor loop publish,
/// plus app-level actions.
@MainActor
@Observable
final class AppState {
  static let shared = AppState()

  static let timelineLimit = 300
  static let callLogLimit = 200
  static let historyLimit = 500
  static let followUpLimit = 2000
  static let log = Logger(subsystem: "com.ahcarpenter.athina", category: "app")

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
      Task {
        await pipeline?.updateSettings(settings)
        await mentor?.updateSettings(settings.mentor)
      }
      if settings.pauseHotKey != oldValue.pauseHotKey {
        registerPauseHotKey()
      }
      if settings.mentor.pushToTalkHotKey != oldValue.mentor.pushToTalkHotKey {
        registerPushToTalkHotKey()
      }
      toast.setTalkBackKey(talkBackKey)
    }
  }

  /// False when the pause hotkey could not be registered (unusable or taken by another app).
  private(set) var hotKeyRegistered = false
  /// False when no talk-back hotkey is set or it could not be registered.
  private(set) var pushToTalkRegistered = false

  var mode: SensingMode = .stopped
  var permissions: PermissionStatus
  /// Permissions the system has never asked about, so asking shows its alert.
  private(set) var undeterminedPermissions: Set<Permission>
  var focus: FocusContext?
  var latestObservation: ActivityObservation?
  var latestImage: NSImage?
  var cadence = CadenceStatus()
  var timeline = JournalTimeline(limit: AppState.timelineLimit)
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
  /// Newest first, across every suggestion.
  var followUps: [FollowUp] = []
  /// The suggestion currently shown as a toast, if any.
  var activeSuggestion: Suggestion?
  /// Last four characters of the saved key, or nil when there is none.
  private(set) var apiKeyHint: String?
  private(set) var apiKeyError: String?

  // MARK: Callouts and voice state

  private(set) var talkBack: TalkBackState = .idle
  var lastCallout: CalloutRecord?
  var lastTranscript: TranscriptRecord?
  /// Whether the system recognizer can transcribe the current locale on this Mac.
  let speechAvailability: SpeechListener.Availability

  /// Whether the permissions window should open at launch.
  let needsPermissionsOnboarding: Bool
  /// The live files, or a replay's own (`LaunchFiles`).
  let journalURL: URL
  let settingsURL: URL
  /// Where this launch keeps its files, the settings it started from, and
  /// any flag that was refused.
  let launchFiles: LaunchFiles
  /// Keeps a replay's data directory its own while the app runs.
  private let dataDirectoryLock: DataDirectoryLock?
  /// Why this launch must not start: a replay was given a `--settings` file
  /// that is not settings or could not hold its data directory, or the files
  /// the app kept as Mentor could not be moved
  /// (`DataMigration.Outcome.stopsLaunch`).
  ///
  /// The app says so and exits rather than running on settings nobody asked
  /// for, or on an empty journal in place of the owner's.
  let startupRefusal: String?
  /// What this launch found and did about the files the app kept when it was
  /// called Mentor (`DataMigration`).
  ///
  /// Shown in Settings and the debug panel, because a move that was refused is
  /// the owner's to settle; one that could not be finished stops the launch
  /// (`startupRefusal`).
  let dataMigration: DataMigration.Outcome
  /// Why this live launch moves nothing from Mentor at all, for the log:
  /// it runs in the App Sandbox (`DataMigration.skipReason`).
  private let migrationSkipReason: String?
  /// Whether this launch copies the API key saved under the old name
  /// (`KeyMigration`).
  ///
  /// Only a launch that reads the keychain at all does: never a replay, and
  /// never a snapshot render.
  private let copyKeyFromMentor: Bool

  // MARK: Model client mode

  /// Live, recording, or replaying, from the launch arguments.
  let clientMode: ModelClientMode
  /// What a replay is serving from, once the loop has started.
  var replaySummary: ReplaySummary?
  /// Why a recording cannot be written, once the loop has started; every
  /// call is refused while it is set.
  var recordingUnavailableReason: String?
  /// How long a replayed call takes, from the launch arguments.
  private let replayLatency: ReplayLatencyMode

  // MARK: Clock

  /// Real time, or a replay's clock, from the launch arguments.
  let clockMode: ClockMode
  /// The one time source everything in the app reads.
  let clock: any AthinaClock
  /// Moves a replay's clock ahead.
  ///
  /// Nil outside a replay, so nothing else can.
  let clockControl: AdjustableClock?
  /// How far a replay's clock has been moved ahead, for the menu and the
  /// debug panel; the clock itself is not observable.
  private(set) var clockMovedAhead: TimeInterval = 0

  // MARK: Control API

  /// Whether this launch serves the end-to-end harness's control API, from
  /// `--control` (`ControlMode`).
  let controlMode: ControlMode
  /// Why the control API could not start listening although it was allowed,
  /// set once at launch.
  var controlFailure: String?

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
  private var toastCountdown = ToastCountdown()
  /// Whether the pointer is over the toast, kept through an exchange so a
  /// countdown given back afterwards does not run under it.
  private var toastHovered = false
  /// The toast the user has talked to: a transcript was matched to an answer or
  /// a question was asked.
  ///
  /// A press that heard nothing does not count.
  private var talkedToSuggestionID: Int64?
  private let toast: ToastController
  private let callouts = CalloutController()
  private var calloutTask: Task<Void, Never>?
  /// What says the screen under the callout is unchanged, and since when.
  private var calloutWitness: CalloutWitness?
  /// The pipeline's dropped-capture count when last seen, to notice new near duplicates.
  private var lastDroppedCount = 0
  /// When the pipeline last dropped a capture as a near duplicate of the
  /// newest kept frame; nil once a newer frame is kept.
  private var lastNearDuplicateAt: Date?
  private var screenObserver: (any NSObjectProtocol)?
  /// Listens for another process moving a replay's clock (`ClockRemote`).
  private var clockRemoteObserver: (any NSObjectProtocol)?
  private let listener: SpeechListener
  private var listeningLimitTask: Task<Void, Never>?
  /// Finishes the transcript after the key comes up; cancelled with the exchange.
  private var transcriptTask: Task<Void, Never>?

  private init() {
    clientMode = ModelClientMode(arguments: CommandLine.arguments)
    clockMode = ClockMode(arguments: CommandLine.arguments, clientMode: clientMode)
    replayLatency = ReplayLatencyMode(arguments: CommandLine.arguments, clientMode: clientMode)
    controlMode = ControlMode(
      arguments: CommandLine.arguments,
      clientMode: clientMode,
      environment: .current,
      compiledIn: ControlAvailability.compiledIn
    )
    (clock, clockControl) = clockMode.makeClock()
    // A hermetic run listens to no click outside its own windows and to
    // no microphone; the control API stands in for both.
    toast = ToastController(clock: clock, watchesOtherApps: !controlMode.isHermetic)
    listener = SpeechListener(clock: clock, hears: controlMode.isHermetic ? .script : .microphone)
    // Before anything reads the live files: the journal, settings,
    // recordings and understanding the app kept while it was called
    // Mentor move to the folder it keeps them in now. A replay's files
    // are its own and never the live ones, and a snapshot render reads
    // neither, so neither moves anything. A sandboxed build can reach
    // nothing Mentor kept, and says so once as it starts.
    migrationSkipReason =
      clientMode.isOffline || Snapshots.isActive ? nil : DataMigration.skipReason(in: .current)
    let movesFromMentor =
      !(clientMode.isOffline || Snapshots.isActive || migrationSkipReason != nil)
    let dataMigration: DataMigration.Outcome =
      movesFromMentor ? DataMigration.run() : .nothingToMove
    self.dataMigration = dataMigration
    // The preferences follow the files, so a launch that stops here
    // leaves both for the next one.
    let copiesFromMentor = movesFromMentor && !dataMigration.stopsLaunch
    if copiesFromMentor { PreferencesMigration.run() }
    var files = LaunchFiles(arguments: CommandLine.arguments, clientMode: clientMode)
    // The settings first, so that a --settings file that is there but is
    // not settings is one of the reasons `claim` refuses the launch.
    let launchSettings = files.loadSettings()
    switch files.claim(clientMode: clientMode) {
    case .notNeeded:
      dataDirectoryLock = nil
      startupRefusal = dataMigration.stopsLaunch ? dataMigration.note : nil
    case .held(let lock):
      dataDirectoryLock = lock
      startupRefusal = nil
    case .refusedToStart(let reason):
      dataDirectoryLock = nil
      startupRefusal = reason
    }
    launchFiles = files
    journalURL = Journal.defaultURL(in: files.dataDirectory)
    store = files.store
    settingsURL = files.store.url
    // Neither a replay nor a snapshot render needs a key, so neither reads
    // the keychain, and its per-build access prompt never blocks them.
    keyStore = clientMode.isOffline || Snapshots.isActive ? InMemoryKeyStore() : KeychainKeyStore()
    copyKeyFromMentor = copiesFromMentor
    isSample = false
    settings = launchSettings
    // A hermetic run asks macOS about no permission, since even asking
    // leaves a record for an app it has not seen; it has them all, as a
    // person's copy normally does, and senses nothing with them.
    let status = controlMode.isHermetic ? AppState.hermeticPermissions : PermissionProbe.current()
    permissions = status
    undeterminedPermissions =
      controlMode.isHermetic
      ? [] : Set(Permission.allCases.filter(PermissionProbe.isUndetermined))
    needsPermissionsOnboarding = !status.allGranted
    speechAvailability = SpeechListener.availability()
  }

  /// A detached state for snapshots and previews: never starts the pipeline.
  init(
    sampleWithSettings settings: SensingSettings,
    clientMode: ModelClientMode = .live,
    clockMode: ClockMode = .system,
    speechAvailability: SpeechListener.Availability = .available(locale: "English (US)")
  ) {
    store = SettingsStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        "athina-sample-settings.json"
      )
    )
    self.clientMode = clientMode
    self.clockMode = clockMode
    replayLatency = ReplayLatencyMode()
    controlMode = .off
    // A sample's time stands still at one fixed moment, so a render reads
    // the same however long it takes and whenever it runs.
    (clock, clockControl) = clockMode.makeClock(
      base: AdjustableClock(startingAt: Snapshots.referenceDate)
    )
    toast = ToastController(clock: clock)
    listener = SpeechListener(clock: clock)
    // A fixed per-launch name, so a replay render reads the same every time.
    launchFiles = LaunchFiles(
      arguments: [],
      clientMode: clientMode,
      launchName: "launch-4242-5a1e0c9d"
    )
    dataMigration = .nothingToMove
    migrationSkipReason = nil
    dataDirectoryLock = nil
    startupRefusal = nil
    journalURL = Journal.defaultURL(in: launchFiles.dataDirectory)
    settingsURL = launchFiles.store.url
    keyStore =
      clientMode.isOffline
      ? InMemoryKeyStore() : InMemoryKeyStore(key: "sk-ant-sample-key-0000-7Q2x")
    copyKeyFromMentor = false
    isSample = true
    self.settings = settings
    permissions = PermissionStatus(screenRecording: true, accessibility: true)
    undeterminedPermissions = Set(Permission.optional)
    needsPermissionsOnboarding = false
    self.speechAvailability = speechAvailability
    reloadKeyHint()
  }

  // MARK: Lifecycle

  func start() {
    guard !isRunning else { return }
    isRunning = true
    // First of all, and before the journal or the fixtures: a distributed
    // notification reaches only the observers registered when it is
    // posted, so anything slow ahead of this would drop a clock request
    // that arrived in the meantime rather than queue it. A journal that
    // will not open returns below, and the channel stays live even then.
    if ClockRemote.listens(in: clockMode) {
      clockRemoteObserver = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name(ClockRemote.name),
        object: ClockRemote.object(for: getpid()),
        queue: .main
      ) { [weak self] notification in
        let request = ClockRemote.seconds(from: notification.userInfo)
        let replyURL = ClockRemote.replyURL(from: notification.userInfo)
        MainActor.assumeIsolated { self?.advanceClock(onRequest: request, answeringAt: replyURL) }
      }
    }
    // The keychain may put up its prompt on the first read after a
    // rebuild; off the main thread it never freezes the app behind it.
    reloadKeyHint()
    hotKeys.onPress = { [weak self] slot in self?.hotKeyPressed(slot) }
    hotKeys.onRelease = { [weak self] slot in self?.hotKeyReleased(slot) }
    registerPauseHotKey()
    registerPushToTalkHotKey()

    // What became of the files the app kept under its old name, before
    // the journal below opens in the folder they moved to.
    if let migrationSkipReason {
      AppState.log.notice("from Mentor: \(migrationSkipReason, privacy: .public)")
    }
    if let note = dataMigration.note {
      if dataMigration.needsAttention {
        AppState.log.error("data from Mentor: \(note, privacy: .public)")
      } else {
        AppState.log.notice("data from Mentor: \(note, privacy: .public)")
      }
    }

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
    let clock = clock
    let tracker = FocusTracker(clock: clock)
    self.tracker = tracker
    let pipeline = SensingPipeline(
      settings: settings,
      journal: journal,
      tracker: tracker,
      clock: clock,
      source: controlMode.isHermetic ? .hermetic : .system
    )
    self.pipeline = pipeline
    let mentorSettings = settings.mentor
    let keyStore = keyStore
    let clientSetup = clientMode.makeClient(
      prices: settings.mentor.prices,
      clock: clock,
      latency: replayLatency.latency
    )
    replaySummary = clientSetup.replay
    recordingUnavailableReason = clientSetup.recordingUnavailableReason
    AppState.log.notice("model calls: \(self.clientModeLog, privacy: .public)")
    AppState.log.notice("clock: \(self.clockLog, privacy: .public)")
    AppState.log.notice("files: \(self.launchFilesLog, privacy: .public)")
    if let refusal = controlMode.refusal {
      AppState.log.error("control API refused: \(refusal, privacy: .public)")
    }
    toast.onAction = { [weak self] id, feedback in
      self?.respond(to: id, with: feedback)
    }
    toast.onHover = { [weak self] hovering in
      self?.toastHoverChanged(hovering)
    }
    toast.setTalkBackKey(talkBackKey)
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.displayConfigurationChanged() }
    }
    // Where a replay's clock starts, before anything runs on it and before
    // the line that says this lane is up.
    startReplayClock()
    eventTask = Task { [weak self] in
      let stream = await pipeline.events()
      let mentorStream = await pipeline.events()
      let mentor = MentorLoop(
        settings: mentorSettings,
        journal: journal,
        client: clientSetup.client,
        keyStore: keyStore,
        events: mentorStream,
        clock: clock
      )
      // The timeline is read before anything this launch journals, which
      // arrives on the streams instead, so no entry is listed twice.
      await self?.loadInitialTimeline(from: journal)
      // Sensing starts before the loop attaches: the loop's first key
      // read can wait on the keychain prompt, and its stream buffers.
      await pipeline.start()
      await self?.attach(mentor: mentor, journal: journal)
      await self?.refreshJournalStats()
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

  private func startReplayClock() {
    guard let clockControl else { return }
    clockMode.startReplay(clockControl)
    clockMovedAhead = clockControl.movedAhead.timeInterval
    AppState.log.notice("clock: \(self.clockLog, privacy: .public)")
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
    followUps = (try? await journal.recentFollowUps(limit: AppState.followUpLimit)) ?? []
  }

  func stop() async {
    resourceTask?.cancel()
    saveTask?.cancel()
    cancelTalkBack()
    if let active = activeSuggestion {
      await respond(to: active.id, with: .expired)?.value
    }
    callouts.dismiss()
    stopCalloutWatch()
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
    if let clockRemoteObserver {
      DistributedNotificationCenter.default().removeObserver(clockRemoteObserver)
    }
    try? store.save(settings)
    await mentor?.stop()
    mentorTask?.cancel()
    await pipeline?.stop()
    eventTask?.cancel()
    hotKeys.unregisterAll()
    isRunning = false
  }

  /// A hermetic run registers no hot key with the system, where it would
  /// take the combination from every other app; the control API's `hotkey`
  /// presses it instead (`hotKeyPressed`), so it counts as registered.
  private func registerPauseHotKey() {
    hotKeyRegistered =
      controlMode.isHermetic
      ? settings.pauseHotKey.isUsable : hotKeys.register(settings.pauseHotKey, for: .pause)
    AppState.log.notice(
      """
      pause hotkey \(self.settings.pauseHotKey.displayString, privacy: .public) registered: \
      \(self.hotKeyRegistered)
      """
    )
  }

  private func registerPushToTalkHotKey() {
    let key = settings.mentor.pushToTalkHotKey
    pushToTalkRegistered =
      controlMode.isHermetic
      ? key?.isUsable == true : hotKeys.register(key, for: .pushToTalk)
    AppState.log.notice(
      """
      talk-back hotkey \(key?.displayString ?? "unset", privacy: .public) registered: \
      \(self.pushToTalkRegistered)
      """
    )
  }

  /// What a hermetic run has instead of asking macOS: every permission.
  static let hermeticPermissions = PermissionStatus(
    screenRecording: true,
    accessibility: true,
    microphone: true,
    speechRecognition: true
  )

  // MARK: Actions

  /// A hot key went down: from Carbon, or in a hermetic run from the control
  /// API's `hotkey`, which takes the same path.
  func hotKeyPressed(_ slot: HotKeyCenter.Slot) {
    switch slot {
    case .pause: togglePause()
    case .pushToTalk: pushToTalkPressed()
    }
  }

  /// A hot key came up, as `hotKeyPressed` has it.
  func hotKeyReleased(_ slot: HotKeyCenter.Slot) {
    if slot == .pushToTalk { pushToTalkReleased() }
  }

  /// A click outside Athina's windows, at a point on screen, handed to the
  /// suggestion toast as its global monitor would hand it one; false when no
  /// toast was up.
  ///
  /// How a hermetic run, which has no such monitor, is clicked outside of (the
  /// control API's `outside-click`).
  func clickOutside(at location: CGPoint) -> Bool {
    toast.outsideClick(at: location)
  }

  /// What talking back hears while its key is down in a hermetic run,
  /// which opens no microphone; false when it is not listening.
  func hear(_ words: String) -> Bool {
    listener.hear(words)
  }

  func togglePause() {
    isPaused.toggle()
    let paused = isPaused
    AppState.log.notice("pause toggled: \(paused)")
    cancelTalkBack()
    Task { await pipeline?.setPaused(paused) }
  }

  func captureNow() {
    Task { await pipeline?.captureNow() }
  }

  func refreshPermissions() {
    guard !isSample, !controlMode.isHermetic else { return }
    let undetermined = Set(Permission.allCases.filter(PermissionProbe.isUndetermined))
    if undetermined != undeterminedPermissions { undeterminedPermissions = undetermined }
    let fresh = PermissionProbe.current()
    guard fresh != permissions else { return }
    permissions = fresh
    toast.setTalkBackKey(talkBackKey)
    Task { await pipeline?.permissionsMayHaveChanged() }
  }

  func requestPermission(_ permission: Permission) {
    guard !isSample, !controlMode.isHermetic else { return }
    AppState.log.notice("requesting permission \(permission.rawValue, privacy: .public)")
    PermissionProbe.request(permission)
    Task {
      try? await Task.sleep(for: .seconds(1))
      refreshPermissions()
    }
  }

  /// What the Permissions window offers for a permission right now.
  func permissionAction(for permission: Permission) -> PermissionAction {
    PermissionAction.for(
      permission,
      granted: permissions.isGranted(permission),
      undetermined: undeterminedPermissions.contains(permission)
    )
  }

  /// The Permissions window's button: the system's request when it has not
  /// asked yet, otherwise the matching System Settings pane.
  ///
  /// For the two permissions granted there, Athina is registered in the pane's
  /// list first, so it is there to switch on; the system may also show its own
  /// note pointing at the same pane.
  func perform(_ action: PermissionAction, for permission: Permission) {
    guard !isSample, !controlMode.isHermetic else { return }
    switch action {
    case .none:
      return
    case .request:
      requestPermission(permission)
    case .openSystemSettings:
      AppState.log.notice("opening System Settings for \(permission.rawValue, privacy: .public)")
      if permission.isGrantedInSystemSettings {
        PermissionProbe.request(permission)
      }
      PermissionProbe.openSystemSettings(for: permission)
      Task {
        try? await Task.sleep(for: .seconds(1))
        refreshPermissions()
      }
    }
  }

  func clearJournal() async {
    do {
      await mentor?.resetUnderstanding()
      try await pipeline?.clearJournal()
      timeline.removeAll()
      latestObservation = nil
      latestImage = nil
      callLog.removeAll()
      suggestionHistory.removeAll()
      followUps.removeAll()
      if let journal {
        await loadInitialTimeline(from: journal)
      }
      await refreshJournalStats()
    } catch {
      journalError = "Could not clear the journal: \(error)"
    }
  }

  /// Forgets what Athina has worked out so far.
  ///
  /// The next call starts a new understanding from what is actually happening.
  func resetUnderstanding() async {
    await mentor?.resetUnderstanding()
    AppState.log.notice("understanding reset")
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

  /// Saves a new key to the Keychain.
  ///
  /// Returns false when the text is not usable as a key, or when the
  /// Keychain save fails, which `apiKeyError` then says.
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

  /// Reads the key's last four characters off the main thread: the keychain
  /// can block on its own prompt, and the rest of the app must not wait.
  private func reloadKeyHint() {
    let keyStore = keyStore
    let copyKeyFromMentor = copyKeyFromMentor
    Task { [weak self] in
      // The key saved while the app was called Mentor is copied to the
      // item Athina saves, here rather than at launch, because a
      // keychain read can wait on the system's access prompt for as
      // long as the owner takes to answer it.
      if copyKeyFromMentor {
        let outcome = await Task.detached(priority: .userInitiated) { KeyMigration.run() }.value
        if let note = outcome.note {
          AppState.log.notice("key from Mentor: \(note, privacy: .public)")
        }
        // The loop reads the key once as it attaches, which can be
        // before the owner has answered the keychain prompt this
        // copy waited on. A loop attached later reads the copy itself.
        if outcome == .copied { await self?.mentor?.apiKeyChanged() }
      }
      let outcome: Result<String?, Error>
      do {
        outcome = .success(try await keyStore.loadInBackground().map(APIKey.lastFour))
      } catch {
        outcome = .failure(error)
      }
      guard let self else { return }
      switch outcome {
      case .success(let hint):
        self.apiKeyHint = hint
      case .failure(let error):
        self.apiKeyHint = nil
        self.apiKeyError = "Could not read the key: \(error)"
      }
    }
  }

  // MARK: Suggestions

  /// Records feedback for a suggestion, whether it came from the toast, the
  /// history window, or a transcript.
  ///
  /// A non-answer (expiry or closing the toast) is recorded once and never
  /// overwrites anything: closing a re-shown toast just closes it. Tell me more
  /// is recorded once too; re-expanding a folded toast is only a view change.
  /// Returns the task that journals the feedback, or nil when nothing was
  /// recorded.
  @discardableResult
  func respond(to suggestionID: Int64, with feedback: SuggestionFeedback) -> Task<Void, Never>? {
    let existing = suggestionHistory.first { $0.id == suggestionID }?.feedback
    if activeSuggestion?.id == suggestionID {
      cancelToastExpiry()
      if feedback != .tellMeMore {
        takeDown()
      }
    }
    if feedback.isNonAnswer, existing != nil { return nil }
    if feedback == .tellMeMore, existing == .tellMeMore { return nil }
    if let index = suggestionHistory.firstIndex(where: { $0.id == suggestionID }) {
      suggestionHistory[index].feedback = feedback
      suggestionHistory[index].feedbackAt = clock.date
    }
    let suggestion = suggestionHistory.first { $0.id == suggestionID }
    switch feedback {
    case .notNow:
      if let suggestion {
        let snooze = Snooze(
          bundleID: suggestion.bundleID,
          appName: suggestion.appName,
          category: suggestion.category,
          until: clock.date.addingTimeInterval(settings.mentor.notNowSnooze)
        )
        settings.mentor.snoozes = SuppressionRules.adding(
          snooze,
          to: settings.mentor.snoozes,
          now: clock.date
        )
      }
    case .never:
      if let suggestion {
        let rule = NeverRule(
          bundleID: suggestion.bundleID,
          appName: suggestion.appName,
          category: suggestion.category,
          createdAt: clock.date
        )
        settings.mentor.neverRules = SuppressionRules.adding(rule, to: settings.mentor.neverRules)
      }
    case .tellMeMore, .expired, .expiredUnseen, .dismissed:
      break
    }
    AppState.log.notice(
      "suggestion \(suggestionID) feedback \(feedback.rawValue, privacy: .public)"
    )
    return Task { await mentor?.recordFeedback(suggestionID: suggestionID, feedback: feedback) }
  }

  /// The most recent suggestion that was ever on screen.
  ///
  /// One that expired unseen while another toast was talked to stays in the
  /// history but is not the last suggestion: the user never saw it and its
  /// screen is gone.
  var lastShownSuggestion: Suggestion? {
    suggestionHistory.first { $0.feedback != .expiredUnseen }
  }

  /// Answers the suggestion on screen from the menu, the way its buttons
  /// do: the keyboard and VoiceOver reach the menu, never the toast.
  func answerActiveSuggestion(_ feedback: SuggestionFeedback) {
    guard let active = activeSuggestion else { return }
    if feedback == .tellMeMore {
      toast.expand()
      toast.bringToFront()
    }
    respond(to: active.id, with: feedback)
  }

  /// Brings the most recent suggestion back as a toast, for one that was
  /// missed.
  ///
  /// A toast the user asked for stays until answered or closed; its callout
  /// comes back only when the spot still checks out.
  func showLastSuggestion() {
    guard let latest = lastShownSuggestion else { return }
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
    if let active = activeSuggestion, active.id == suggestion.id {
      cancelToastExpiry()
      toast.bringToFront()
      if !callouts.isVisible {
        placeCallout(for: suggestion)
      }
      return
    }
    if let active = activeSuggestion {
      respond(to: active.id, with: .expired)
    }
    cancelToastExpiry()
    toastHovered = false
    cancelTalkBack()
    activeSuggestion = suggestion
    toast.show(suggestion, expanded: false, exchange: exchange(for: suggestion.id))
    // With VoiceOver or Switch Control on, a suggestion waits to be
    // answered or closed instead of timing out while it is being reached.
    if autoExpires, !AppState.assistiveTechnologyIsRunning {
      scheduleToastExpiry(for: suggestion.id, after: settings.mentor.toastTimeout)
    }
    placeCallout(for: suggestion)
  }

  /// Everything that goes with the toast goes with it: the callout and a
  /// recording in progress.
  ///
  /// If the toast was talked to, this is where the exchange ends and a
  /// suggestion held meanwhile may be shown.
  private func takeDown() {
    toast.dismiss()
    callouts.dismiss()
    stopCalloutWatch()
    activeSuggestion = nil
    talkedToSuggestionID = nil
    cancelTalkBack()
    endHold()
  }

  /// Tells the loop no talked-to toast is up, so a suggestion held for it
  /// is shown if still fresh; while pausing it expires instead.
  private func endHold() {
    let pausing = isPaused
    Task {
      if pausing { await mentor?.expireHeldSuggestion() }
      await mentor?.setTalkingBack(false)
    }
  }

  /// Settles a press that has ended, by `TalkBackPress`: a talked-to toast
  /// keeps the hold and no countdown; otherwise the hold ends and the
  /// countdown the press interrupted resumes.
  private func settlePress(_ match: TranscriptMatcher.Match?, for suggestion: Suggestion) {
    let outcome = TalkBackPress.outcome(
      match: match,
      toastTalkedTo: talkedToSuggestionID == suggestion.id,
      countdownRemaining: toastCountdown.held
    )
    toastCountdown.cancel()
    switch outcome {
    case .talkedTo:
      talkedToSuggestionID = suggestion.id
    case .notAnExchange(let countdown):
      endHold()
      guard let countdown, activeSuggestion?.id == suggestion.id else { return }
      if toastHovered {
        // Held again under the pointer, with what it had.
        toastCountdown.run(for: countdown, from: clock.date)
        toastCountdown.hold(at: clock.date)
      } else {
        scheduleToastExpiry(for: suggestion.id, after: countdown)
      }
    }
  }

  /// The countdown pauses while the pointer is over the toast and resumes
  /// with the remaining time when it leaves.
  private func toastHoverChanged(_ hovering: Bool) {
    toastHovered = hovering
    guard let active = activeSuggestion, !talkBack.keepsToastUp else { return }
    if hovering {
      guard toastCountdown.deadline != nil else { return }
      toastTask?.cancel()
      toastCountdown.hold(at: clock.date)
    } else if let remaining = toastCountdown.held {
      scheduleToastExpiry(for: active.id, after: remaining)
    }
  }

  private func scheduleToastExpiry(for suggestionID: Int64, after timeout: TimeInterval) {
    // An exchange in progress keeps the toast up; nothing schedules its end.
    guard !talkBack.keepsToastUp else { return }
    toastTask?.cancel()
    toastCountdown.run(for: timeout, from: clock.date)
    guard let deadline = toastCountdown.deadline else { return }
    let clock = clock
    toastTask = Task { [weak self] in
      try? await clock.sleep(untilDate: deadline)
      // Still this countdown: not held, cancelled, or run again meanwhile.
      guard !Task.isCancelled,
        let self,
        self.activeSuggestion?.id == suggestionID,
        self.toastCountdown.deadline == deadline
      else { return }
      self.respond(to: suggestionID, with: .expired)
    }
  }

  private func cancelToastExpiry() {
    toastTask?.cancel()
    toastTask = nil
    toastCountdown.cancel()
  }

  // MARK: Callouts

  /// Draws the callout when the suggestion points at a spot and the spot
  /// still checks out, then re-checks once a second while it is up so a
  /// window that moves, loses focus, or changes takes it down. Every
  /// decision is `CalloutAnchor`'s; this gathers the live readings.
  private func placeCallout(for suggestion: Suggestion) {
    callouts.dismiss()
    stopCalloutWatch()
    guard let region = suggestion.region else { return }
    guard settings.mentor.showCallouts else {
      lastCallout = CalloutRecord(
        at: clock.date,
        suggestionID: suggestion.id,
        region: region,
        status: .notShown,
        reason: "callouts are off in Settings"
      )
      return
    }
    calloutTask = Task { [weak self] in
      guard let self else { return }
      guard let observation = await self.observationForCallout(suggestion) else {
        self.lastCallout = CalloutRecord(
          at: self.clock.date,
          suggestionID: suggestion.id,
          region: region,
          status: .notShown,
          reason: "the frame is no longer in the journal"
        )
        return
      }
      var witness = CalloutWitness(region: region.rect, original: observation)
      // A frame kept since the suggestion was made already says whether the text is still there.
      if let latest = self.latestObservation, latest.id != observation.id {
        guard witness.observe(latest) else {
          self.lastCallout = CalloutRecord(
            at: self.clock.date,
            suggestionID: suggestion.id,
            region: region,
            status: .notShown,
            reason: CalloutRejection.contentChanged.label
          )
          return
        }
      }
      // Near duplicates of that frame since it was kept confirm the screen too,
      // so a suggestion brought back on an untouched screen gets its callout.
      if let lastNearDuplicateAt = self.lastNearDuplicateAt {
        witness.noteDroppedCapture(at: lastNearDuplicateAt)
      }
      self.calloutWitness = witness
      var shown = false
      while !Task.isCancelled {
        let result = await self.resolveAnchor(
          region,
          observation: observation,
          confirmedAt: self.calloutWitness?.confirmedAt
        )
        guard !Task.isCancelled, self.activeSuggestion?.id == suggestion.id else { return }
        switch result {
        case .success(let placement):
          if !shown || self.callouts.placement != placement {
            self.callouts.show(placement)
            self.toast.bringToFront()
          }
          if self.lastCallout?.status != .shown || self.lastCallout?.suggestionID != suggestion.id
            || self.lastCallout?.placement != placement
          {
            self.lastCallout = CalloutRecord(
              at: self.clock.date,
              suggestionID: suggestion.id,
              region: region,
              placement: placement,
              status: .shown
            )
          }
          if !shown {
            shown = true
            AppState.log.notice(
              """
              callout shown for suggestion \(suggestion.id) at \
              \(Formatting.rect(placement.screenRect), privacy: .public)
              """
            )
            if !suggestion.calloutShown {
              await self.noteCalloutShown(suggestionID: suggestion.id)
            }
          }
        case .failure(let rejection):
          self.callouts.dismiss()
          let record = CalloutRecord(
            at: self.clock.date,
            suggestionID: suggestion.id,
            region: region,
            status: shown ? .takenDown : .notShown,
            reason: rejection.label
          )
          self.lastCallout = record
          self.calloutWitness = nil
          AppState.log.notice(
            "callout for suggestion \(suggestion.id) \(record.summary, privacy: .public)"
          )
          return
        }
        try? await self.clock.sleep(for: .seconds(1))
      }
    }
  }

  private func stopCalloutWatch() {
    calloutTask?.cancel()
    calloutTask = nil
    calloutWitness = nil
  }

  /// Every kept frame goes to the witness: one of the same window that no
  /// longer shows the framed text in place takes the callout down.
  private func checkCalloutContent(against latest: ActivityObservation) {
    guard var witness = calloutWitness, let active = activeSuggestion, let region = active.region
    else { return }
    if witness.observe(latest) {
      calloutWitness = witness
      return
    }
    callouts.dismiss()
    stopCalloutWatch()
    let record = CalloutRecord(
      at: clock.date,
      suggestionID: active.id,
      region: region,
      status: .takenDown,
      reason: CalloutRejection.contentChanged.label
    )
    lastCallout = record
    AppState.log.notice("callout for suggestion \(active.id) \(record.summary, privacy: .public)")
  }

  /// A capture the pipeline dropped as a near duplicate confirms the screen
  /// under the callout is unchanged, when the frame it duplicates is a witness.
  private func noteCadence(_ status: CadenceStatus) {
    defer { lastDroppedCount = status.droppedCount }
    guard status.droppedCount > lastDroppedCount else { return }
    let at = status.lastCaptureAt ?? clock.date
    lastNearDuplicateAt = at
    guard var witness = calloutWitness else { return }
    witness.noteDroppedCapture(at: at)
    calloutWitness = witness
  }

  /// The observation the suggestion was made from: the latest one when it
  /// still is, otherwise the journal's copy.
  private func observationForCallout(_ suggestion: Suggestion) async -> ActivityObservation? {
    guard let id = suggestion.observationID else { return nil }
    if let latest = latestObservation, latest.id == id { return latest }
    return try? await journal?.observation(id: id)
  }

  private func resolveAnchor(
    _ region: CalloutRegion,
    observation: ActivityObservation,
    confirmedAt: Date?
  ) async -> Result<CalloutPlacement, CalloutRejection> {
    let live = CalloutAnchor.Live(
      frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
      focus: await tracker?.peekCurrent(),
      displays: NSScreen.currentDisplays,
      now: clock.date
    )
    return CalloutAnchor.resolve(region, for: observation, live: live, confirmedAt: confirmedAt)
  }

  private func displayConfigurationChanged() {
    guard callouts.isVisible, let record = lastCallout else { return }
    callouts.dismiss()
    stopCalloutWatch()
    lastCallout = CalloutRecord(
      at: clock.date,
      suggestionID: record.suggestionID,
      region: record.region,
      status: .takenDown,
      reason: CalloutRejection.displayChanged.label
    )
  }

  /// Persists that the callout was drawn and mirrors it into the history.
  private func noteCalloutShown(suggestionID: Int64) async {
    guard let mentor else { return }
    guard let updated = await mentor.noteCalloutShown(suggestionID: suggestionID) else { return }
    if let index = suggestionHistory.firstIndex(where: { $0.id == suggestionID }) {
      suggestionHistory[index].calloutShown = updated.calloutShown
    }
    if activeSuggestion?.id == suggestionID {
      activeSuggestion?.calloutShown = updated.calloutShown
    }
  }

  // MARK: Talking back

  /// The exchange about one suggestion, oldest first.
  func exchange(for suggestionID: Int64) -> [FollowUp] {
    followUps.filter { $0.suggestionID == suggestionID }.sorted {
      $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.id < $1.id
    }
  }

  /// The talk-back hotkey for the toast's hint, once everything it needs is in place.
  var talkBackKey: String? {
    guard let key = settings.mentor.pushToTalkHotKey,
      speechAvailability.isAvailable,
      permissions.voiceGranted
    else { return nil }
    return key.displayString
  }

  /// Whether an assistive technology that moves through the interface
  /// element by element is on, so nothing should time out under it.
  static var assistiveTechnologyIsRunning: Bool {
    NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
  }

  /// The menu command that sets talking back up, when it is not yet usable
  /// for a reason the person can fix.
  var talkBackAction: MenuModel.StatusAction? {
    guard speechAvailability.isAvailable else { return nil }
    if settings.mentor.pushToTalkHotKey == nil {
      return MenuModel.StatusAction(
        title: "Set Up Talk Back…",
        command: .openSettings(pane: SettingsPane.general.rawValue)
      )
    }
    if !permissions.voiceGranted {
      return MenuModel.StatusAction(title: "Set Up Talk Back…", command: .openPermissions)
    }
    return nil
  }

  /// The menu command that lets the mentor loop run, when a missing key holds it.
  var menuStatusAction: MenuModel.StatusAction? {
    guard !clientMode.isOffline, mentorStatus.availability == .noAPIKey else { return nil }
    return MenuModel.StatusAction(
      title: "Add API Key…",
      command: .openSettings(pane: SettingsPane.models.rawValue)
    )
  }

  /// The menu bar item's menu, which the menu bar extra draws and the
  /// control API reads.
  var menuModel: MenuModel {
    MenuModel(
      MenuModel.State(
        statusLines: [statusLine, clientModeLine, clockLine, launchRefusalsLine, controlLine]
          .compactMap { $0 },
        mentor: menuStatusAction.map { .action($0) } ?? .line(mentorLine),
        mentorContextLine: mentorContextLine,
        understandingLine: understandingLine,
        talkBack: talkBackAction.map { .action($0) } ?? .line(talkBackLine),
        isPaused: isPaused,
        pauseShortcut: settings.pauseHotKey,
        capturesFrames: mode.capturesFrames,
        hasLastSuggestion: lastShownSuggestion != nil,
        hasActiveSuggestion: activeSuggestion != nil,
        showsDebugPanel: settings.showDebugPanel
      )
    )
  }

  /// Opens Athina's windows for code outside any view: the menu's commands,
  /// which a hermetic run's control API runs with no menu bar extra up.
  /// `AthinaApp` hands it the app's own actions as it builds its scenes.
  let windows = WindowOpener()

  /// Runs one of the menu's commands: chosen from the menu bar extra's menu,
  /// or through the control API.
  func perform(_ command: MenuModel.Command) {
    switch command {
    case .togglePause: togglePause()
    case .captureNow: captureNow()
    case .showLastSuggestion: showLastSuggestion()
    case .answer(let feedback): answerActiveSuggestion(feedback)
    case .openSuggestions: windows.open(WindowID.history)
    case .openPermissions: windows.open(WindowID.permissions)
    case .openSettings(let pane):
      pane.flatMap(SettingsPane.init(rawValue:))?.select()
      windows.openSettings()
    case .openDebugPanel: windows.open(WindowID.debug)
    case .about:
      AppActivation.request()
      NSApp.orderFrontStandardAboutPanel(nil)
    case .quit: NSApp.terminate(nil)
    }
  }

  /// One line for the menu on talking back: how to do it, or what it needs.
  var talkBackLine: String {
    if case .unavailable = speechAvailability {
      return "Talk back: no on-device recognition for this language"
    }
    guard let key = settings.mentor.pushToTalkHotKey else { return "Talk back: no shortcut set" }
    if !permissions.voiceGranted { return "Talk back: needs Microphone and Speech Recognition" }
    if isRunning, !pushToTalkRegistered {
      return "Talk back: \(key.displayString) could not be registered"
    }
    switch talkBack {
    case .listening: return "Talk back: listening…"
    case .waiting: return "Talk back: waiting for the mentor's current call…"
    case .thinking: return "Talk back: asking the mentor…"
    case .idle: return "Talk back: hold \(key.displayString)"
    }
  }

  /// The loop hears when an exchange begins, so a suggestion that arrives
  /// before the talked-to toast is closed (`takeDown`) waits instead of
  /// replacing it.
  private func setTalkBack(_ state: TalkBackState) {
    let begins = talkBack == .idle && state != .idle
    talkBack = state
    toast.setTalkBack(state)
    if begins {
      Task { await mentor?.setTalkingBack(true) }
    }
  }

  /// The toast says when the question is waiting for the mentor's current
  /// call to return, and when it has been asked.
  private func syncTalkBack(with status: MentorStatus) {
    switch talkBack {
    case .thinking(let question) where status.pendingFollowUp?.question == question:
      setTalkBack(.waiting(question: question))
    case .waiting(let question) where status.pendingFollowUp == nil:
      setTalkBack(.thinking(question: question))
    case .idle, .listening, .waiting, .thinking:
      break
    }
  }

  /// The key went down: bring up the suggestion to talk to, and listen.
  ///
  /// A question still waiting its turn is withdrawn; the new one takes its
  /// place.
  private func pushToTalkPressed() {
    guard talkBack.acceptsAQuestion else { return }
    guard activeSuggestion != nil || lastShownSuggestion != nil else {
      toast.showNote("Nothing to reply to yet: Athina has not made a suggestion.")
      return
    }
    if case .unavailable(let reason) = speechAvailability {
      toast.showNote(reason)
      return
    }
    refreshPermissions()
    guard permissions.voiceGranted else {
      let missing = Permission.optional.filter { !permissions.isGranted($0) }
      let asking = missing.contains { undeterminedPermissions.contains($0) }
      for permission in missing {
        requestPermission(permission)
      }
      // The system shows its own request only for a permission it has
      // never asked about; otherwise the answer is in System Settings.
      toast.showNote(
        asking
          ? """
          Athina needs Microphone and Speech Recognition to hear you. Answer the system's \
          request, then hold the shortcut again.
          """
          : """
          Athina needs Microphone and Speech Recognition to hear you. Choose Set Up Talk \
          Back in the Athina menu to allow them.
          """
      )
      return
    }
    guard mode.isActive else {
      toast.showNote("Athina is \(mode.label.lowercased()), so it is not listening.")
      return
    }
    guard let suggestion = suggestionToTalkTo() else { return }
    do {
      try listener.start { [weak self] partial in
        guard let self, case .listening = self.talkBack else { return }
        self.setTalkBack(.listening(partial: partial))
      }
    } catch {
      AppState.log.error(
        "listening failed to start: \(String(describing: error), privacy: .public)"
      )
      toast.showNote("Could not start listening: \(error).")
      return
    }
    AppState.log.notice("listening for suggestion \(suggestion.id)")
    if case .waiting = talkBack {
      Task { await mentor?.withdrawFollowUp() }
    }
    setTalkBack(.listening(partial: ""))
    let clock = clock
    listeningLimitTask = Task { [weak self] in
      try? await clock.sleep(for: .seconds(SpeechListener.maxDuration))
      guard !Task.isCancelled, let self, case .listening = self.talkBack else { return }
      self.pushToTalkReleased()
    }
  }

  /// The suggestion a reply is about: the toast that is up, or the most recent
  /// suggestion brought back as a toast that stays until it is closed.
  ///
  /// An exchange keeps the toast up, like expanding it, so its countdown stops;
  /// what was left of it is kept in case nothing is heard. Nil, with a note,
  /// when Athina has not made a suggestion yet.
  private func suggestionToTalkTo() -> Suggestion? {
    let suggestion: Suggestion
    if let active = activeSuggestion {
      suggestion = active
    } else if let latest = lastShownSuggestion {
      suggestion = latest
      show(latest, autoExpires: false)
    } else {
      toast.showNote("Nothing to reply to yet: Athina has not made a suggestion.")
      return nil
    }
    toastTask?.cancel()
    toastCountdown.hold(at: clock.date)
    return suggestion
  }

  /// Whether the debug panel's Talk back field may send now.
  var canTalkBackTyped: Bool {
    talkBack.acceptsAQuestion && (activeSuggestion != nil || lastShownSuggestion != nil)
  }

  /// The debug panel's Talk back field: typed words take the path a released
  /// key does, from transcript matching to the follow-up call, the answer in
  /// the toast.
  ///
  /// It is how the follow-up path is checked, and a follow-up fixture recorded,
  /// on a Mac without a microphone grant.
  func talkBack(typed text: String) {
    guard canTalkBackTyped, let suggestion = suggestionToTalkTo() else { return }
    AppState.log.notice("typed talk-back for suggestion \(suggestion.id)")
    if case .waiting = talkBack {
      Task { await mentor?.withdrawFollowUp() }
    }
    Task { await act(on: text, for: suggestion) }
  }

  /// The key came up: finish the transcript and act on it.
  private func pushToTalkReleased() {
    guard case .listening = talkBack else { return }
    listeningLimitTask?.cancel()
    listeningLimitTask = nil
    let suggestion = activeSuggestion
    transcriptTask = Task { [weak self] in
      guard let self else { return }
      let text = await self.listener.finish()
      guard !Task.isCancelled else { return }
      self.transcriptTask = nil
      await self.handleTranscript(text, for: suggestion)
    }
  }

  /// Ends the exchange: the recording is dropped, a transcript still being
  /// finalized is ignored, and a question waiting its turn is withdrawn.
  ///
  /// A follow-up call already in flight completes and its answer is journaled.
  /// A recording cut short counts as nothing heard.
  private func cancelTalkBack() {
    listeningLimitTask?.cancel()
    listeningLimitTask = nil
    transcriptTask?.cancel()
    transcriptTask = nil
    listener.cancel()
    let state = talkBack
    if state != .idle {
      setTalkBack(.idle)
    }
    switch state {
    case .listening:
      if let active = activeSuggestion {
        settlePress(nil, for: active)
      } else {
        endHold()
      }
    case .waiting, .thinking:
      Task { await mentor?.withdrawFollowUp() }
    case .idle:
      break
    }
  }

  private func handleTranscript(_ text: String?, for suggestion: Suggestion?) async {
    guard case .listening = talkBack else { return }
    guard let suggestion, activeSuggestion?.id == suggestion.id else {
      setTalkBack(.idle)
      return
    }
    await act(on: text, for: suggestion)
  }

  /// What a transcript, heard or typed, does: one of the toast's answers, or
  /// one follow-up question whose answer lands in the toast.
  ///
  /// Either makes the toast a talked-to one that stays up, and holds new
  /// suggestions, until it is closed. A press that heard nothing is not an
  /// exchange: the toast gets back whatever countdown it had, and nothing is
  /// held for it.
  private func act(on text: String?, for suggestion: Suggestion) async {
    let match = text.flatMap(TranscriptMatcher.match)
    setTalkBack(.idle)
    settlePress(match, for: suggestion)
    guard let text, let match else {
      lastTranscript = TranscriptRecord(at: clock.date, text: text ?? "", handling: "nothing heard")
      toast.showNote("Athina did not catch that.")
      return
    }
    switch match {
    case .answer(let feedback):
      lastTranscript = TranscriptRecord(
        at: clock.date,
        text: text,
        handling: "answered: \(feedback.label)"
      )
      AppState.log.notice("transcript answered \(feedback.rawValue, privacy: .public)")
      if feedback == .tellMeMore { toast.expand() }
      respond(to: suggestion.id, with: feedback)
      if activeSuggestion?.id == suggestion.id {
        Task { await mentor?.setTalkingBack(true) }
      }
    case .question(let question):
      lastTranscript = TranscriptRecord(at: clock.date, text: text, handling: "asked the mentor")
      AppState.log.notice("transcript asked the mentor")
      setTalkBack(.thinking(question: question))
      guard let mentor else {
        setTalkBack(.idle)
        return
      }
      guard let followUp = await mentor.askFollowUp(about: suggestion, question: question) else {
        return
      }
      upsert(followUp)
      guard activeSuggestion?.id == suggestion.id,
        talkBack == .thinking(question: question) || talkBack == .waiting(question: question)
      else { return }
      setTalkBack(.idle)
      toast.setExchange(exchange(for: suggestion.id))
    }
  }

  private func upsert(_ followUp: FollowUp) {
    if let index = followUps.firstIndex(where: { $0.id == followUp.id }) {
      followUps[index] = followUp
    } else {
      followUps.insert(followUp, at: 0)
      if followUps.count > AppState.followUpLimit {
        followUps.removeLast(followUps.count - AppState.followUpLimit)
      }
    }
  }

  // MARK: Presentation helpers

  /// Which variant of the mark the menu bar draws.
  ///
  /// The decision itself is a pure function in `MenuBarMark`, so it is covered
  /// by tests and so choosing a different set later changes one table rather
  /// than the app.
  var menuBarMark: MenuBarMark {
    MenuBarMark.resolve(
      mode: mode,
      availability: mentorStatus.availability,
      offline: clientMode.isOffline
    )
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

  /// A short word beside the menu bar icon while calls are not plain live
  /// ones, so a replay is never mistaken for the real thing, with how fast
  /// its clock runs when that is not real time.
  var clientModeBadge: String? {
    switch clientMode {
    case .live: nil
    case .record: "Recording"
    case .replay, .invalid: clockScale.map { "Replay \(Formatting.multiplier($0))" } ?? "Replay"
    }
  }

  // MARK: Clock control

  /// How many times real time a replay's clock runs, or nil at real time.
  var clockScale: Double? {
    guard let clockControl, clockControl.scale != 1 else { return nil }
    return clockControl.scale
  }

  /// One line for the menu on the clock, or nil while it is plain real time.
  var clockLine: String? {
    var parts: [String] = []
    if let scale = clockScale {
      parts.append("\(Formatting.multiplier(scale)) real time")
    } else if clockMode.refusal != nil {
      parts.append("real time")
    }
    if clockMovedAhead > 0 {
      parts.append("moved ahead \(ClockInterval.description(of: clockMovedAhead))")
    }
    if let refusal = clockMode.refusal { parts.append(refusal) }
    return parts.isEmpty ? nil : "Clock: \(parts.joined(separator: ", "))"
  }

  /// For the log at launch.
  private var clockLog: String {
    switch clockMode {
    case .system: "real time"
    case .refused(let reason): "real time, refused: \(reason)"
    case .replay(let scale, _, let refusal):
      """
      replay clock at \(Formatting.multiplier(scale)) real time, moved ahead \
      \(ClockInterval.description(of: clockMovedAhead)), now \
      \(ClockFormat.dayAndTime(clock.date))
      """
        + (refusal.map { ", refused: \($0)" } ?? "")
    }
  }

  /// Moves a replay's clock ahead by `seconds`, as if that much time went by at
  /// once with the Mac awake in whatever mode Athina is in: a wait due in it
  /// ends, and while watching it counts as active use.
  ///
  /// False, changing nothing, outside a replay or for an interval `ClockMode`
  /// does not accept.
  @discardableResult
  func advanceClock(by seconds: TimeInterval) -> Bool {
    guard let clockControl, ClockMode.accepts(advance: seconds) else { return false }
    clockControl.advance(by: .seconds(seconds))
    clockMovedAhead = clockControl.movedAhead.timeInterval
    AppState.log.notice(
      """
      clock moved ahead \(ClockInterval.description(of: seconds), privacy: .public): \
      \(self.clockLog, privacy: .public)
      """
    )
    return true
  }

  /// Moves a replay's clock ahead for another process (`ClockRemote`), and
  /// answers the request where it asked, so the script that made it knows it
  /// was heard rather than assuming so.
  ///
  /// A request that cannot be answered there moves nothing.
  private func advanceClock(
    onRequest request: Result<TimeInterval, ClockRemote.Refusal>,
    answeringAt replyURL: URL?
  ) {
    do {
      try ClockRemote.answer(request, at: replyURL) { request in
        switch request {
        case .success(let seconds):
          if advanceClock(by: seconds) {
            return ClockRemote.Reply(moved: true, movedAhead: clockMovedAhead, now: clock.date)
          }
          let reason = "this launch has no replay clock"
          AppState.log.error("clock advance request refused: \(reason, privacy: .public)")
          return ClockRemote.Reply(
            moved: false,
            reason: reason,
            movedAhead: clockMovedAhead,
            now: clock.date
          )
        case .failure(let refusal):
          AppState.log.error("clock advance request refused: \(refusal.reason, privacy: .public)")
          return ClockRemote.Reply(
            moved: false,
            reason: refusal.reason,
            movedAhead: clockMovedAhead,
            now: clock.date
          )
        }
      }
    } catch let refusal as ClockRemote.Refusal {
      AppState.log.error("clock advance request refused: \(refusal.reason, privacy: .public)")
    } catch {
      AppState.log.error(
        """
        could not answer the clock request at \(replyURL?.path ?? "", privacy: .public): \
        \(String(describing: error), privacy: .public)
        """
      )
    }
  }

  // MARK: Control API

  /// One line for the menu when `--control` was refused or could not
  /// listen, or nil.
  var controlLine: String? {
    if let refusal = controlMode.refusal { return "Control API refused: \(refusal)" }
    return controlFailure.map { "Control API failed: \($0)" }
  }

  // MARK: Launch files

  /// Every launch flag that was refused and has no line of its own, in the
  /// order they were found: the file flags, then the replay latency.
  ///
  /// A refused clock flag is on the Clock line instead.
  var launchRefusals: [String] {
    launchFiles.refusals + [replayLatency.refusal].compactMap { $0 }
  }

  /// One line for the menu when a launch flag was refused, or nil.
  var launchRefusalsLine: String? {
    launchRefusals.isEmpty ? nil : "Refused: \(launchRefusals.joined(separator: "; "))"
  }

  /// For the log at launch.
  private var launchFilesLog: String {
    var line =
      """
      data in \
      \(launchFiles.dataDirectory.path)\(clientMode.isOffline ? " (this launch only)" : ""), \
      settings from \(launchFiles.settingsSource.path)
      """
    if !launchFiles.refusals.isEmpty {
      line += ", refused: \(launchFiles.refusals.joined(separator: "; "))"
    }
    return line
  }

  /// One line for the menu saying where calls go, or nil when they are live.
  var clientModeLine: String? {
    switch clientMode {
    case .live:
      return nil
    case .record(let directory):
      if let reason = recordingUnavailableReason { return "Recording unavailable: \(reason)" }
      return "Recording model calls to \(Formatting.path(directory))"
    case .invalid(let reason):
      return "Calls refused: \(reason)"
    case .replay:
      guard let summary = replaySummary else { return "Replay mode" }
      if let reason = summary.unavailableReason { return "Replay unavailable: \(reason)" }
      let folder = summary.directory.pathComponents.suffix(2).joined(separator: "/")
      var line =
        "Replaying \(Plural.count(summary.total, "recorded call", "recorded calls")) from \(folder)"
      if summary.staleCount > 0 {
        line +=
          summary.allowStale
          ? ", \(summary.staleCount) stale allowed" : ", \(summary.staleCount) stale refused"
      }
      return line
    }
  }

  /// For the log at launch.
  private var clientModeLog: String {
    var line =
      switch clientMode {
      case .live: "live"
      case .record(let directory):
        recordingUnavailableReason.map { "refused: \($0)" }
          ?? "live, recording to \(directory.path)"
      case .replay(let directory, let allowStale):
        """
        replaying from \(directory.path)\(allowStale ? ", stale fixtures allowed" : ""), \
        \(replayLatency.latency.rawValue) latency
        """
      case .invalid(let reason): "refused: \(reason)"
      }
    if let refusal = replayLatency.refusal { line += ", refused: \(refusal)" }
    return line
  }

  /// One line for the menu: spend this hour against the cap, or why the loop is off.
  var mentorLine: String {
    if clientMode.isOffline {
      return settings.mentor.enabled ? "Mentor: replay mode, nothing billed" : "Mentor: off"
    }
    switch mentorStatus.availability {
    case .ready, .capReached:
      let spend = Formatting.dollars(mentorStatus.spendThisHour)
      let cap = Formatting.dollars(settings.mentor.hourlySpendCap)
      if case .capReached = mentorStatus.availability {
        return "Mentor: \(spend) of \(cap) this hour, cap reached"
      }
      if mentorStatus.isCadenceSlowed {
        return
          """
          Mentor: \(spend) of \(cap) this hour, slowed \
          \(Formatting.multiplier(mentorStatus.cadenceMultiplier))
          """
      }
      return "Mentor: \(spend) of \(cap) this hour"
    case .disabled: return "Mentor: off"
    case .noAPIKey: return "Mentor: no API key"
    }
  }

  /// One line for the menu saying where the declared contexts put the current
  /// activity, or nil when contexts have nothing to say: they are not being
  /// enforced.
  ///
  /// A verdict is only shown while it is still about the frontmost app and was
  /// reached under enforcement, because the record is rewritten only when
  /// triage runs and most observations hold before that.
  var mentorContextLine: String? {
    let mentor = settings.mentor
    guard mentor.onlyMentorInsideContexts else { return nil }
    var notJudgedYet: String {
      if mentor.contexts.isEmpty { return "Context: none declared, so nothing is mentored" }
      guard let appName = focus?.appName else { return "Context: not judged yet" }
      return "Context: not yet judged in \(appName)"
    }
    guard let record = mentorStatus.lastContext, record.appName == focus?.appName else {
      return notJudgedYet
    }
    switch record.placement {
    case .notEnforced:
      return notJudgedYet
    case .inside(let match):
      return "Context: \(match.label)"
    case .outside(let exclusion):
      return "Context: out, \(exclusion.label)"
    }
  }

  /// One line for the menu: what Athina currently thinks the user is working
  /// toward, so the inference is visible without opening anything.
  ///
  /// A goal sentence can run long and a menu item widens to fit it, so it is
  /// cut here; the debug panel shows the whole thing. Nil, so the menu shows no
  /// goal line, while Athina is off or has no key and nothing works one out.
  var understandingLine: String? {
    guard mentorStatus.availability.formsUnderstanding else { return nil }
    guard let goal = mentorStatus.understanding?.content.primaryGoal else {
      return "Goal: not worked out yet"
    }
    return "Goal: \(Formatting.clipped(goal.goal, to: 64))"
  }

  // MARK: Private

  private func handle(_ event: SensingEvent) {
    switch event {
    case .observation(let observation):
      latestObservation = observation
      latestImage = observation.frame.jpeg.flatMap(NSImage.init(data:))
      var slim = observation
      slim.frame.jpeg = nil
      timeline.insert(.observation(slim))
      lastNearDuplicateAt = nil
      checkCalloutContent(against: observation)
    case .focusChanged(let context):
      focus = context
    case .modeChanged(let newMode):
      mode = newMode
      AppState.log.notice("mode: \(newMode.rawValue, privacy: .public)")
      if !newMode.isActive {
        cancelTalkBack()
      }
      refreshPermissions()
    case .event(let journalEvent):
      timeline.insert(.event(journalEvent))
    case .cadence(let status):
      noteCadence(status)
      if status != cadence { cadence = status }
    }
  }

  private func handle(_ event: MentorEvent) {
    switch event {
    case .status(let status):
      if status != mentorStatus { mentorStatus = status }
      syncTalkBack(with: status)
    case .suggestion(let suggestion):
      present(suggestion)
    case .feedback(let suggestion):
      if let index = suggestionHistory.firstIndex(where: { $0.id == suggestion.id }) {
        suggestionHistory[index] = suggestion
      } else {
        let index =
          suggestionHistory.firstIndex { $0.timestamp < suggestion.timestamp }
          ?? suggestionHistory.endIndex
        suggestionHistory.insert(suggestion, at: index)
      }
    case .followUp(let followUp):
      upsert(followUp)
      if activeSuggestion?.id == followUp.suggestionID {
        toast.setExchange(exchange(for: followUp.suggestionID))
      }
    case .call(let record):
      callLog.insert(record, at: 0)
      if callLog.count > AppState.callLogLimit {
        callLog.removeLast(callLog.count - AppState.callLogLimit)
      }
    case .event(let journalEvent):
      timeline.insert(.event(journalEvent))
    }
  }

  private func loadInitialTimeline(from journal: Journal) async {
    if let entries = try? await journal.recentEntries(limit: AppState.timelineLimit) {
      timeline.merge(entries)
    }
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
