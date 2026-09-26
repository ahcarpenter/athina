import Foundation
import OSLog

/// Subscribes to the sensing stream, runs the three Claude tiers behind
/// `MentorScheduler`'s gates, accounts spend, and publishes suggestions.
///
/// Everything that reaches the network passes through `perform`, which is the
/// only place the API key is read. Prompt text is never journaled or logged.
///
/// With a replay client (`ClaudeClient.isReplay`) no key is read at all, every
/// call is journaled as a replay with zero cost, and none of them counts
/// toward the hour's spend or its cap.
public actor MentorLoop {
  /// How long a triage call may take, in seconds.
  public static let triageTimeout: TimeInterval = 30
  /// How long a Test Connection call may take, in seconds.
  public static let testTimeout: TimeInterval = 30
  /// Output tokens a second a reply is assumed to arrive at, under the rate
  /// measured on Opus 5 (docs/mentor-loop.md "Standing understanding"), so a
  /// reply that runs to max_tokens still finishes inside its timeout.
  public static let outputTokensPerSecond = 15.0

  /// The timeout for a call whose reply may run to `maxTokens`, never past
  /// the client's own cap on a whole call.
  public static func timeout(forReplyOf maxTokens: Int) -> TimeInterval {
    min(AnthropicClient.resourceTimeout, 30 + Double(maxTokens) / outputTokensPerSecond)
  }
  /// Triage answers a short JSON object.
  public static let triageMaxTokens = 200
  /// Mentor replies include adaptive thinking, which counts against this.
  ///
  /// They now also carry the rewritten understanding.
  public static let mentorMaxTokens = 8000
  /// A follow-up answer is a few short sentences, plus the same thinking.
  public static let followUpMaxTokens = 3000
  /// What a reply keeps for adaptive thinking, which every default model but
  /// Haiku spends and which counts against max_tokens.
  ///
  /// The budget's range is sized so a mentor reply keeps this beside the
  /// suggestion and a record at the top of the range.
  public static let thinkingAllowance = 3000
  /// The JSON around the record and the reason sentence in a refresh reply.
  public static let understandingReplyOverhead = 1000

  /// A refresh reply is the record at its budget, the JSON and reason
  /// around it, and the thinking before it.
  public static func understandingMaxTokens(for budget: Int) -> Int {
    budget + understandingReplyOverhead + thinkingAllowance
  }
  /// How many journal rows feed the event summaries.
  public static let eventLookback = 40
  /// The most recent observations read for the rolling window; any beyond
  /// it are counted as left out.
  public static let windowLookback = 200
  /// How many past suggestions a refresh call is told about.
  public static let suggestionLookback = 20

  private static let log = Logger(subsystem: "com.ahcarpenter.athina", category: "mentor")

  /// Stands in for the key while calls are replayed.
  ///
  /// It is not a secret, the replay client ignores it, and it lets every call
  /// path run unchanged without reading the keychain.
  public static let replayCredential = "replay-needs-no-key"

  /// The settings the loop runs on, as validated; `updateSettings(_:)`
  /// replaces them.
  public private(set) var settings: MentorSettings
  private let journal: Journal
  private let client: any ClaudeClient
  private let keyStore: any KeyStore
  private let source: AsyncStream<SensingEvent>
  private let broadcaster = EventBroadcaster<MentorEvent>()

  private var scheduler: MentorScheduler
  private var spend: SpendMeter
  private var status = MentorStatus()
  private var lastPublishedStatus: MentorStatus?
  private var mode: SensingMode = .stopped
  private var apiKey: String?
  /// Tiers with a call in progress; a Test Connection can overlap a tier call.
  private var inFlight: Set<ModelTier> = []
  /// A toast the user has talked to is up (`setTalkingBack`).
  private var talkingBack = false
  /// A suggestion made while that toast was up, waiting for it to close.
  private var heldSuggestion: Suggestion?
  /// The one question waiting for the call in flight to return; a newer one takes its place.
  private struct PendingQuestion {
    var record: MentorStatus.PendingFollowUp
    var continuation: CheckedContinuation<Bool, Never>
  }
  private var pendingQuestion: PendingQuestion?
  private var consumeTask: Task<Void, Never>?
  /// The understanding carried between calls, nil until one forms.
  private var understanding: UnderstandingRecord?
  /// When the last observation arrived: the idle gap that expires the
  /// understanding is measured from it, and the refresh gate holds until it
  /// exists.
  ///
  /// Seeded from the journal at launch so the gap is measured from real
  /// activity rather than from the record's last write.
  private var lastActivityAt: Date?
  /// The active use counted toward the next refresh: begun at the record's last
  /// write, or at the first observation while there is no record, and cleared
  /// with the record so the next stretch gets a whole interval for a mentor
  /// call to write the record for free.
  ///
  /// Counted whenever the mode changes and kept in the journal, so a relaunch
  /// carries on from it.
  private var period: RefreshPeriod?
  /// The system uptime when `period` was last counted or replaced.
  ///
  /// Uptime stops while the Mac sleeps, so the next count measures only time
  /// awake. Nil until this run first sets the period, so nothing from before
  /// the launch is counted.
  private var uptimeAtCount: TimeInterval?
  /// Counts Reset Understanding, so a request built before one cannot
  /// store the record it was shown.
  private var resets = 0

  /// Every date, wait, and measure of time awake the loop reads.
  private let clock: any AthinaClock
  /// Decides when a day ends for expiry.
  private let calendar: Calendar

  /// Creates a loop that reads `events` and journals to `journal`; call
  /// `start()` to begin.
  ///
  /// - Parameters:
  ///   - settings: The mentor settings, validated before use.
  ///   - journal: Where every call, suggestion, and understanding is kept.
  ///   - client: The seam every model call goes through: live or replay.
  ///   - keyStore: Where the API key is read from; never read in a replay.
  ///   - events: The sensing stream.
  ///   - clock: The clock every date, wait, and uptime is read from.
  ///   - calendar: Decides when a day ends for expiry.
  public init(
    settings: MentorSettings,
    journal: Journal,
    client: any ClaudeClient,
    keyStore: any KeyStore,
    events: AsyncStream<SensingEvent>,
    clock: any AthinaClock,
    calendar: Calendar = .current
  ) {
    let validated = settings.validated()
    self.settings = validated
    self.journal = journal
    self.client = client
    self.keyStore = keyStore
    self.clock = clock
    self.calendar = calendar
    source = events
    scheduler = MentorScheduler(settings: validated)
    spend = SpendMeter(cap: validated.hourlySpendCap)
  }

  // MARK: Subscription

  /// Every subscriber gets every event from the moment it subscribes.
  public func events() async -> AsyncStream<MentorEvent> {
    await broadcaster.subscribe()
  }

  // MARK: Control

  /// Reads the key, restores this hour's spend, the last calls, and the
  /// understanding from the journal, publishes the status, and starts
  /// reading the sensing stream.
  ///
  /// Does nothing when already started.
  public func start() async {
    guard consumeTask == nil else { return }
    await reloadKey()
    await seedFromJournal()
    await publishStatus()
    consumeTask = Task { [weak self] in
      guard let self else { return }
      for await event in self.source {
        await self.handle(event)
      }
    }
  }

  /// Stops reading the sensing stream, drops a question waiting on a call,
  /// counts the active use toward the next refresh, and ends every
  /// subscriber's event stream.
  public func stop() async {
    consumeTask?.cancel()
    consumeTask = nil
    dropPendingQuestion()
    await countActiveUse(now: clock.date)
    await broadcaster.finish()
  }

  /// Call as an exchange with the toast begins and ends: from the key going
  /// down until the toast that was talked to is closed, so its answer can be
  /// read.
  ///
  /// While it is on, a new suggestion is held rather than shown; when it goes
  /// off, the held one is shown if it is still fresh, otherwise it expires
  /// unseen. `now` defaults to the clock's.
  public func setTalkingBack(_ active: Bool, at now: Date? = nil) async {
    guard talkingBack != active else { return }
    talkingBack = active
    guard !active, let held = heldSuggestion else { return }
    heldSuggestion = nil
    await publish(held, now: now ?? clock.date)
  }

  /// A held suggestion is not shown while the user is pausing Athina.
  ///
  /// The pause reaches the loop through the sensing stream too, but the app
  /// calls this first when it ends a hold while pausing, so the held suggestion
  /// cannot slip out in between.
  public func expireHeldSuggestion(now: Date? = nil) async {
    guard let held = heldSuggestion else { return }
    heldSuggestion = nil
    await expireUnseen(held, now: now ?? clock.date)
  }

  private func expireUnseen(_ suggestion: Suggestion, now: Date) async {
    MentorLoop.log.notice("suggestion \(suggestion.id) expired unseen")
    await recordFeedback(suggestionID: suggestion.id, feedback: .expiredUnseen, at: now)
  }

  /// Drops the question waiting for the call in flight, if any: the user
  /// closed the toast, moved on, or is asking something else.
  public func withdrawFollowUp() async {
    guard dropPendingQuestion() else { return }
    await publishStatus()
  }

  /// Applies new settings, validated, to the gates and the spend cap, and
  /// publishes the status.
  ///
  /// A change to the contexts, or to whether the mentor tier runs only inside
  /// them, clears the last context verdict.
  public func updateSettings(_ newSettings: MentorSettings) async {
    let validated = newSettings.validated()
    if validated.onlyMentorInsideContexts != settings.onlyMentorInsideContexts
      || validated.contexts != settings.contexts
    {
      status.lastContext = nil
    }
    settings = validated
    scheduler.settings = validated
    spend.cap = validated.hourlySpendCap
    await publishStatus()
  }

  /// Call after the key is saved or removed in Settings.
  public func apiKeyChanged() async {
    await reloadKey()
    await publishStatus()
  }

  /// Whether the loop holds a key to call with: one read from the key store,
  /// or the replay stand-in when calls are replayed.
  public var hasAPIKey: Bool { apiKey != nil }

  /// Returns the loop's status as it stands now.
  public func currentStatus() -> MentorStatus { status }

  /// Records the user's response to a suggestion and journals it, at the
  /// clock's date unless `now` says otherwise.
  @discardableResult
  public func recordFeedback(
    suggestionID: Int64,
    feedback: SuggestionFeedback,
    at now: Date? = nil
  ) async -> Suggestion? {
    let now = now ?? clock.date
    let updated: Suggestion?
    do {
      updated = try await journal.updateFeedback(
        suggestionID: suggestionID,
        feedback: feedback,
        at: now
      )
    } catch {
      MentorLoop.log.error("feedback not journaled: \(String(describing: error), privacy: .public)")
      return nil
    }
    guard let updated else { return nil }
    await journalEvent(
      JournalEvent(
        timestamp: now,
        kind: .feedback,
        bundleID: updated.bundleID,
        appName: updated.appName,
        detail: "\(feedback.label): \(updated.title)"
      )
    )
    await broadcaster.send(.feedback(updated))
    return updated
  }

  /// Records that a callout was drawn for a suggestion.
  ///
  /// Returns the suggestion as journaled, or nil when it is unknown.
  @discardableResult
  public func noteCalloutShown(suggestionID: Int64) async -> Suggestion? {
    do {
      return try await journal.noteCalloutShown(suggestionID: suggestionID)
    } catch {
      MentorLoop.log.error("callout not journaled: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  /// One tiny request on the triage model.
  ///
  /// Returns the model that answered, or the API's own error message. Counted
  /// as spend like any other call.
  public func testConnection() async -> Result<String, ClaudeClientError> {
    await reloadKey()
    guard let apiKey else { return .failure(.transport("no API key saved")) }
    let request = MessagesRequest(
      model: settings.triageModel,
      maxTokens: 16,
      system: [],
      messages: [Message(role: .user, content: [.text("Reply with the single word OK.")])]
    )
    let call = await perform(
      tier: .test,
      request: request,
      apiKey: apiKey,
      timeout: MentorLoop.testTimeout
    )
    var record = call.record
    switch call.result {
    case .success(let response):
      record.outcome = .ok
      record.detail = response.model
      await store(record)
      await publishStatus()
      return .success(response.model)
    case .failure(let error):
      record.outcome = .error
      record.detail = error.description
      await store(record)
      await publishStatus()
      return .failure(error)
    }
  }

  // MARK: Events

  private func handle(_ event: SensingEvent) async {
    switch event {
    case .modeChanged(let newMode):
      await countActiveUse(now: clock.date)
      mode = newMode
      status.mode = newMode
      if newMode == .paused {
        await expireHeldSuggestion()
      }
      // The refresh gate's last hold was reached in the old mode; the
      // next observation gates again in this one.
      status.lastRefreshHold = nil
      await publishStatus()
    case .observation(let observation):
      await expireUnderstandingIfNeeded(now: clock.date)
      lastActivityAt = observation.timestamp
      if period == nil { await setPeriod(RefreshPeriod(startedAt: observation.timestamp)) }
      await consider(observation)
      // After the interactive path, so a mentor call that just refreshed
      // the record leaves nothing for the refresh gate to do, and the
      // context verdict triage just reached is the one the gate sees.
      await refreshUnderstandingIfDue(after: observation)
    case .focusChanged, .event, .cadence:
      break
    }
  }

  private func conditions(now: Date) -> MentorScheduler.Conditions {
    spend.prune(now: now)
    return MentorScheduler.Conditions(
      mode: mode,
      hasAPIKey: apiKey != nil,
      callInFlight: !inFlight.isEmpty,
      talkingBack: talkingBack,
      spendFraction: spend.fraction(now: now),
      cadenceMultiplier: spend.cadenceMultiplier(now: now),
      nextHourStart: SpendMeter.nextHourStart(after: now)
    )
  }

  /// The whole loop for one observation: triage gate, triage call, mentor gate, mentor call.
  private func consider(_ observation: ActivityObservation) async {
    var now = clock.date
    switch scheduler.triageGate(for: observation, conditions: conditions(now: now), now: now) {
    case .hold(let hold):
      status.lastGate = MentorStatus.GateRecord(at: now, observationID: observation.id, hold: hold)
      if case .noContextsDeclared = hold {
        noteContext(.outside(.noContextsDeclared), for: observation, at: now)
      }
      await publishStatus()
      return
    case .run:
      status.lastGate = MentorStatus.GateRecord(at: now, observationID: observation.id, hold: nil)
    }
    scheduler.noteTriageStarted(observation: observation, now: now)
    guard let triaged = await runTriage(observation) else {
      await publishStatus()
      return
    }
    let (verdict, placement) = triaged
    noteContext(placement, for: observation, at: clock.date)

    now = clock.date
    switch scheduler.mentorGate(
      triage: verdict,
      context: placement,
      conditions: conditions(now: now),
      now: now
    ) {
    case .hold(let hold):
      status.lastMentorHold = MentorStatus.MentorHoldRecord(at: now, hold: hold)
      await publishStatus()
      return
    case .run:
      status.lastMentorHold = nil
    }
    scheduler.noteMentorStarted(now: now)
    await runMentor(observation, context: placement)
    await publishStatus()
  }

  private func noteContext(
    _ placement: ContextPlacement,
    for observation: ActivityObservation,
    at now: Date
  ) {
    status.lastContext = MentorStatus.ContextRecord(
      at: now,
      placement: placement,
      appName: observation.focus.appName
    )
  }

  /// The latest context verdict while it is still about this observation's
  /// app, as the menu shows it: the verdict is rewritten only when triage
  /// runs, and most observations hold before that.
  private func contextPlacement(for observation: ActivityObservation) -> ContextPlacement? {
    guard let record = status.lastContext, record.appName == observation.focus.appName else {
      return nil
    }
    return record.placement
  }

  // MARK: Triage tier

  /// Text only: app and window, accessibility summary, the latest OCR text, and
  /// a compact event summary.
  ///
  /// While contexts are enforced the system prompt also carries the declared
  /// list and the reply places the snapshot in one of them, so the placement
  /// costs no extra call. Returns the verdict with that placement, or nil when
  /// the call did not produce one.
  private func runTriage(
    _ observation: ActivityObservation
  ) async -> (TriageVerdict, ContextPlacement)? {
    guard let apiKey else { return nil }
    let now = clock.date
    let events = (try? await journal.recentEvents(limit: MentorLoop.eventLookback)) ?? []
    let contexts = settings.onlyMentorInsideContexts ? settings.contexts : []
    let text = PromptBuilder.triageMessage(
      observation: observation,
      recentEvents: events,
      understanding: understanding?.content,
      now: now
    )
    let model = settings.triageModelInfo
    let request = MessagesRequest(
      model: model.id,
      maxTokens: MentorLoop.triageMaxTokens,
      system: [SystemBlock(text: MentorPrompts.triageSystem(contexts: contexts))],
      messages: [Message(role: .user, content: [.text(text)])],
      outputConfig: OutputConfig(
        format: OutputFormat(schema: MentorPrompts.triageSchema(contexts: contexts)),
        effort: settings.effort(for: .triage)
      )
    )
    let call = await perform(
      tier: .triage,
      request: request,
      apiKey: apiKey,
      timeout: MentorLoop.triageTimeout
    )
    var record = call.record
    var triaged: (TriageVerdict, ContextPlacement)?
    switch call.result {
    case .failure(let error):
      record.outcome = .error
      record.detail = error.description
    case .success(let response):
      if response.isRefusal {
        record.outcome = .refused
        record.detail = "the API declined this request"
      } else if var decoded = MentorLoop.decode(TriageVerdict.self, from: response) {
        decoded.reason = decoded.reason.withPlainDashes
        let placement = settings.contextPlacement(triage: decoded)
        triaged = (decoded, placement)
        record.outcome =
          placement.isOutside ? .outOfContext : (decoded.worthALook ? .candidate : .quiet)
        record.detail = decoded.reason
      } else {
        record.outcome = response.isTruncated ? .truncated : .error
        record.detail = "could not parse the triage reply"
      }
    }
    status.lastTriage = await store(record)
    return triaged
  }

  // MARK: Mentor tier

  /// The rolling window of recent observations' text plus, when enabled, the
  /// latest kept thumbnail as an image.
  ///
  /// With a record standing, the window also takes every screen journaled after
  /// the ones its last write read, since the reply rewrites it.
  private func runMentor(_ observation: ActivityObservation, context: ContextPlacement) async {
    guard let apiKey else { return }
    let now = clock.date
    let window = await screens(
      since: now.addingTimeInterval(-settings.mentorWindowDuration),
      after: understanding?.coveredThroughObservationID,
      now: now,
      including: observation
    )
    let events = (try? await journal.recentEvents(limit: MentorLoop.eventLookback)) ?? []
    let suppressed = settings.suppressedCategories(bundleID: observation.focus.bundleID, now: now)
    let resetsAtRequest = resets

    var content: [ContentBlock] = []
    let jpeg = settings.sendThumbnail ? observation.frame.jpeg : nil
    if let jpeg {
      content.append(.image(mediaType: "image/jpeg", base64: jpeg.base64EncodedString()))
    }
    content.append(
      .text(
        PromptBuilder.mentorMessage(
          window: window.entries,
          latest: observation,
          recentEvents: events,
          suppressed: suppressed,
          includesImage: jpeg != nil,
          context: settings.contexts.first { $0.id == context.contextID },
          hasUnderstanding: understanding != nil,
          understandingTokenBudget: settings.understandingTokenBudget,
          screensLeftOut: window.leftOut,
          now: now
        )
      )
    )
    let model = settings.mentorModelInfo
    // The understanding is its own uncached system block after the cached
    // prompt: it changes on every mentor call, so a marker on it would only
    // pay the cache write and never be read.
    var system = [SystemBlock(text: MentorPrompts.mentorSystem)]
    if let understanding {
      system.append(MentorPrompts.understandingBlock(understanding))
    }
    let strongestGoal = understanding?.content.primaryGoal?.goal
    let request = MessagesRequest(
      model: model.id,
      maxTokens: MentorLoop.mentorMaxTokens,
      system: system,
      messages: [Message(role: .user, content: content)],
      outputConfig: OutputConfig(
        format: OutputFormat(schema: MentorPrompts.mentorSchema),
        effort: settings.effort(for: .mentor)
      )
    )
    let call = await perform(
      tier: .mentor,
      request: request,
      apiKey: apiKey,
      timeout: MentorLoop.timeout(forReplyOf: request.maxTokens)
    )
    let shownAt = clock.date
    var record = call.record
    var toShow: Suggestion?
    switch call.result {
    case .failure(let error):
      record.outcome = .error
      record.detail = error.description
    case .success(let response):
      if response.isRefusal {
        record.outcome = .refused
        record.detail = "the API declined this request"
      } else if let verdict = MentorLoop.decode(MentorVerdict.self, from: response) {
        record.detail = verdict.reason.withPlainDashes
        // Every mentor call rewrites the record, so the refresh rides
        // along and the periodic call only fires in the gaps.
        if let updated = verdict.updatedUnderstanding, resets == resetsAtRequest {
          await adopt(
            updated,
            at: shownAt,
            coveredThrough: window.readThrough,
            model: response.model,
            source: .mentorCall,
            cost: 0
          )
        }
        if let payload = verdict.suggestion {
          let title = payload.title.withPlainDashes
          if payload.isBlank {
            // Structured output guarantees the fields exist, not
            // that they say anything; a toast with no words is noise.
            record.outcome = .error
            record.detail =
              """
              the mentor reply had a \(payload.category.rawValue) suggestion with an empty \
              title or body
              """
          } else if payload.confidence < settings.minimumConfidence {
            record.outcome = .belowConfidence
            record.detail = "\(title) (confidence \(Int((payload.confidence * 100).rounded()))%)"
          } else if let reason = settings.suppression(
            for: payload.category,
            bundleID: observation.focus.bundleID,
            now: now
          ) {
            record.outcome = .suppressed
            record.detail = "\(title) (\(reason.label))"
          } else if payload.category.judgesAgainstGoal, strongestGoal == nil {
            record.outcome = .suppressed
            record.detail = "\(title) (no goal to judge against)"
          } else {
            record.outcome = .suggested
            record.detail = title
            let region = MentorLoop.region(
              from: payload.region,
              frame: observation.frame,
              sawImage: jpeg != nil
            )
            if payload.region != nil, region == nil {
              MentorLoop.log.notice(
                """
                region dropped: \
                \(jpeg == nil ? "no image was sent" : "outside the frame", privacy: .public)
                """
              )
            }
            toShow = Suggestion(
              timestamp: shownAt,
              bundleID: observation.focus.bundleID,
              appName: observation.focus.appName,
              windowTitle: observation.focus.windowTitle,
              category: payload.category,
              title: title,
              body: payload.body.withPlainDashes,
              explanation: payload.explanation.withPlainDashes,
              confidence: payload.confidence,
              judgedGoal: judgedGoal(for: payload, strongestGoal: strongestGoal),
              observationID: observation.id == 0 ? nil : observation.id,
              model: response.model,
              promptVersion: MentorPrompts.version,
              region: region
            )
          }
        } else {
          record.outcome = .nothingToSay
        }
      } else {
        record.outcome = response.isTruncated ? .truncated : .error
        record.detail = "could not parse the mentor reply"
      }
    }
    status.lastMentor = await store(record)

    guard let suggestion = toShow else { return }
    var stored = suggestion
    do {
      stored = try await journal.record(suggestion)
    } catch {
      MentorLoop.log.error(
        "suggestion not journaled: \(String(describing: error), privacy: .public)"
      )
    }
    await journalEvent(
      JournalEvent(
        timestamp: shownAt,
        kind: .suggested,
        bundleID: stored.bundleID,
        appName: stored.appName,
        detail: "\(stored.category.label): \(stored.title)"
      )
    )
    await publish(stored, now: clock.date)
  }

  /// Shows a journaled suggestion, holds it while a talked-to toast is up,
  /// or expires it when it was held too long.
  private func publish(_ suggestion: Suggestion, now: Date) async {
    switch scheduler.publishGate(
      madeAt: suggestion.timestamp,
      conditions: conditions(now: now),
      now: now
    ) {
    case .show:
      await broadcaster.send(.suggestion(suggestion))
    case .hold:
      if let older = heldSuggestion {
        await expireUnseen(older, now: now)
      }
      heldSuggestion = suggestion
      MentorLoop.log.notice("suggestion \(suggestion.id) held while the user talks back")
    case .expired:
      await expireUnseen(suggestion, now: now)
    }
  }

  /// The spot the model pointed at, kept only when it saw the image and the
  /// spot lies inside it.
  ///
  /// Anything else is a guess and is dropped here, so the journal never holds a
  /// region that cannot be placed.
  static func region(
    from raw: MentorVerdict.Payload.Region?,
    frame: FrameInfo,
    sawImage: Bool
  ) -> CalloutRegion? {
    guard let raw, sawImage, CalloutAnchor.screenRect(for: raw.rect, in: frame) != nil else {
      return nil
    }
    return CalloutRegion(
      rect: raw.rect,
      note: raw.note.withPlainDashes.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  // MARK: Follow-up

  /// One thing the user said about a suggestion, answered by the mentor model
  /// at the mentor tier's effort.
  ///
  /// The exchange is journaled as a follow-up row and the call as a model call,
  /// counted against the hour's spend like every other call. A held question is
  /// journaled with the reason and never sent. A question asked while a call is
  /// in flight waits for it to return and is then asked; only one waits at a
  /// time, and a newer question, or `withdrawFollowUp`, drops it, in which case
  /// this returns nil and nothing is journaled. `now` defaults to the clock's.
  public func askFollowUp(
    about suggestion: Suggestion,
    question: String,
    at now: Date? = nil
  ) async -> FollowUp? {
    let now = now ?? clock.date
    var followUp = FollowUp(
      suggestionID: suggestion.id,
      timestamp: now,
      question: question,
      model: settings.mentorModel,
      promptVersion: MentorPrompts.version
    )
    var asking = now
    var gate = scheduler.followUpGate(conditions: conditions(now: asking))
    while gate == .wait {
      let record = MentorStatus.PendingFollowUp(
        suggestionID: suggestion.id,
        question: question,
        since: now
      )
      let asked = await withCheckedContinuation {
        (continuation: CheckedContinuation<Bool, Never>) in
        dropPendingQuestion()
        pendingQuestion = PendingQuestion(record: record, continuation: continuation)
        status.pendingFollowUp = record
        Task { await self.publishStatus() }
      }
      guard asked else { return nil }
      asking = clock.date
      gate = scheduler.followUpGate(conditions: conditions(now: asking))
    }
    if case .hold(let hold) = gate {
      followUp.error = hold.label
      return await finish(followUp, about: suggestion)
    }
    guard let apiKey else {
      followUp.error = MentorScheduler.Hold.noAPIKey.label
      return await finish(followUp, about: suggestion)
    }
    let exchange = (try? await journal.followUps(suggestionID: suggestion.id)) ?? []
    var screenText: String?
    if let observationID = suggestion.observationID {
      screenText = try? await journal.observation(id: observationID)?.ocrText
    }
    let text = PromptBuilder.followUpMessage(
      suggestion: suggestion,
      screenText: screenText,
      exchange: exchange,
      question: question,
      now: asking
    )
    let model = settings.mentorModelInfo
    let request = MessagesRequest(
      model: model.id,
      maxTokens: MentorLoop.followUpMaxTokens,
      system: [SystemBlock(text: MentorPrompts.followUpSystem)],
      messages: [Message(role: .user, content: [.text(text)])],
      outputConfig: OutputConfig(
        format: OutputFormat(schema: MentorPrompts.followUpSchema),
        effort: settings.effort(for: .followUp)
      )
    )
    let call = await perform(
      tier: .followUp,
      request: request,
      apiKey: apiKey,
      timeout: MentorLoop.timeout(forReplyOf: request.maxTokens)
    )
    var record = call.record
    switch call.result {
    case .failure(let error):
      record.outcome = .error
      record.detail = error.description
      followUp.error = error.description
    case .success(let response):
      followUp.model = response.model
      if response.isRefusal {
        record.outcome = .refused
        record.detail = "the API declined this request"
        followUp.error = record.detail
      } else if let reply = MentorLoop.decode(FollowUpReply.self, from: response) {
        let answer = reply.answer.withPlainDashes.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty {
          record.outcome = .error
          record.detail = "the follow-up reply had an empty answer"
          followUp.error = record.detail
        } else {
          record.outcome = .answered
          record.detail = String(answer.prefix(160))
          followUp.answer = answer
        }
      } else {
        record.outcome = response.isTruncated ? .truncated : .error
        record.detail = "could not parse the follow-up reply"
        followUp.error = record.detail
      }
    }
    await store(record)
    return await finish(followUp, about: suggestion)
  }

  /// Journals the exchange and its event, publishes it, and returns it with its id.
  private func finish(_ followUp: FollowUp, about suggestion: Suggestion) async -> FollowUp {
    var stored = followUp
    do {
      stored = try await journal.record(followUp)
    } catch {
      MentorLoop.log.error(
        "follow-up not journaled: \(String(describing: error), privacy: .public)"
      )
    }
    let detail =
      followUp.answer == nil
      ? "\"\(followUp.question)\" (\(followUp.error ?? "no answer"))"
      : "\"\(followUp.question)\""
    await journalEvent(
      JournalEvent(
        timestamp: followUp.timestamp,
        kind: .talkBack,
        bundleID: suggestion.bundleID,
        appName: suggestion.appName,
        detail: detail
      )
    )
    await broadcaster.send(.followUp(stored))
    await publishStatus()
    return stored
  }

  // MARK: Understanding

  /// The goal a suggestion was judged against: what the model named, falling
  /// back to the strongest goal it was shown, and nothing at all for the
  /// categories that do not judge against one.
  private func judgedGoal(for payload: MentorVerdict.Payload, strongestGoal: String?) -> String? {
    guard payload.category.judgesAgainstGoal else { return nil }
    if let named = payload.judgedGoal?.withPlainDashes.trimmingCharacters(
      in: .whitespacesAndNewlines
    ),
      !named.isEmpty
    {
      return named
    }
    return strongestGoal
  }

  /// Takes a rewritten record as the current one: bounds it to the token
  /// budget and stores it as the next revision; the caller publishes the
  /// status that carries it.
  ///
  /// False when the record was empty and nothing changed. `coveredThrough` is
  /// the highest observation id the writing call read.
  @discardableResult
  private func adopt(
    _ content: Understanding,
    at time: Date,
    coveredThrough: Int64?,
    model: String,
    source: UnderstandingSource,
    cost: Double
  ) async -> Bool {
    let bounded = content.bounded(toTokens: settings.understandingTokenBudget)
    guard !bounded.isEmpty else { return false }
    var record: UnderstandingRecord
    if let current = understanding {
      record = current.next(
        content: bounded,
        at: time,
        model: model,
        source: source,
        cost: cost,
        promptVersion: MentorPrompts.version,
        coveredThroughObservationID: coveredThrough
      )
    } else {
      record = UnderstandingRecord.first(
        content: bounded,
        at: time,
        model: model,
        source: source,
        cost: cost,
        promptVersion: MentorPrompts.version,
        coveredThroughObservationID: coveredThrough
      )
    }
    do {
      record = try await journal.record(record)
    } catch {
      MentorLoop.log.error(
        "understanding not journaled: \(String(describing: error), privacy: .public)"
      )
    }
    understanding = record
    await setPeriod(RefreshPeriod(startedAt: record.updatedAt))
    MentorLoop.log.notice(
      """
      understanding revision \(record.revision) by \(source.rawValue, privacy: .public), \
      \(record.content.goals.count) goals, \(record.content.estimatedTokens) tokens
      """
    )
    return true
  }

  /// Drops an understanding that no longer describes the present: a long gap
  /// with no activity, or a new day.
  ///
  /// A period still counting toward the first record goes by the same rules,
  /// quietly, since nothing was formed.
  private func expireUnderstandingIfNeeded(now: Date) async {
    guard let writtenAt = understanding?.updatedAt ?? period?.startedAt,
      let expiry = UnderstandingExpiry.of(
        writtenAt: writtenAt,
        now: now,
        idleGap: settings.understandingIdleGap,
        lastActivityAt: lastActivityAt,
        calendar: calendar
      )
    else { return }
    let expired = understanding
    understanding = nil
    await setPeriod(nil)
    guard let record = expired else { return }
    MentorLoop.log.notice("understanding expired: \(expiry.label, privacy: .public)")
    await journalEvent(
      JournalEvent(
        timestamp: now,
        kind: .understanding,
        detail: "expired after revision \(record.revision): \(expiry.label)"
      )
    )
    await publishStatus()
  }

  /// Forgets the understanding entirely, from Settings or the debug panel.
  public func resetUnderstanding(at now: Date? = nil) async {
    let now = now ?? clock.date
    let previous = understanding
    understanding = nil
    resets += 1
    await setPeriod(nil)
    status.lastRefreshHold = nil
    do {
      try await journal.clearUnderstanding()
    } catch {
      MentorLoop.log.error(
        "understanding not cleared: \(String(describing: error), privacy: .public)"
      )
    }
    await journalEvent(
      JournalEvent(
        timestamp: now,
        kind: .understanding,
        detail: previous.map { "reset after revision \($0.revision)" } ?? "reset"
      )
    )
    await publishStatus()
  }

  /// Returns the understanding carried between calls, or nil until one forms.
  public func currentUnderstanding() -> UnderstandingRecord? { understanding }

  /// Replaces the refresh period and keeps it in the journal.
  private func setPeriod(_ newPeriod: RefreshPeriod?) async {
    period = newPeriod
    uptimeAtCount = clock.uptime
    do {
      try await journal.storeRefreshPeriod(newPeriod)
    } catch {
      MentorLoop.log.error(
        "refresh period not journaled: \(String(describing: error), privacy: .public)"
      )
    }
  }

  /// Counts the time awake since the period was last counted as active use when
  /// the current mode captures the screen.
  ///
  /// Runs before every mode change, so all of that time was spent in the
  /// current mode.
  private func countActiveUse(now: Date) async {
    guard let period else { return }
    let awake = uptimeAtCount.map { clock.uptime - $0 }
    await setPeriod(period.counted(through: now, awake: awake, in: mode))
  }

  /// Runs the periodic refresh when the gate allows it.
  ///
  /// Every mentor call refreshes the record for free, so this only fires in a
  /// stretch of active use with no mentor call in it.
  private func refreshUnderstandingIfDue(after observation: ActivityObservation) async {
    let now = clock.date
    await countActiveUse(now: now)
    let gate = scheduler.refreshGate(
      conditions: conditions(now: now),
      context: contextPlacement(for: observation),
      period: period,
      lastActivityAt: lastActivityAt,
      now: now
    )
    let since: Date
    switch gate {
    case .hold(let hold):
      status.lastRefreshHold = MentorStatus.RefreshHoldRecord(at: now, hold: hold)
      await publishStatus()
      return
    case .run(let periodStart):
      status.lastRefreshHold = nil
      since = periodStart
    }
    await setPeriod(period?.restarted(at: now))
    await runRefresh(since: since, now: now)
    await publishStatus()
  }

  /// Text only: the record as it stands, recent suggestions and events, and
  /// the screens since it was last written: every one journaled after the
  /// ones its last write read, or those since `since` before it has read any.
  private func runRefresh(since: Date, now: Date) async {
    guard let apiKey else { return }
    let cursor = understanding?.coveredThroughObservationID
    let window = await screens(since: cursor == nil ? since : nil, after: cursor, now: now)
    let events = (try? await journal.recentEvents(limit: MentorLoop.eventLookback)) ?? []
    let suggestions =
      (try? await journal.recentSuggestions(limit: MentorLoop.suggestionLookback)) ?? []
    let resetsAtRequest = resets
    let text = PromptBuilder.understandingMessage(
      current: understanding,
      window: window.entries,
      recentEvents: events,
      recentSuggestions: suggestions,
      tokenBudget: settings.understandingTokenBudget,
      screensLeftOut: window.leftOut,
      now: now
    )
    let request = MessagesRequest(
      model: settings.understandingModelInfo.id,
      maxTokens: MentorLoop.understandingMaxTokens(for: settings.understandingTokenBudget),
      system: [SystemBlock(text: MentorPrompts.understandingSystem)],
      messages: [Message(role: .user, content: [.text(text)])],
      outputConfig: OutputConfig(
        format: OutputFormat(schema: MentorPrompts.understandingRefreshSchema),
        effort: settings.effort(for: .understanding)
      )
    )
    let call = await perform(
      tier: .understanding,
      request: request,
      apiKey: apiKey,
      timeout: MentorLoop.timeout(forReplyOf: request.maxTokens)
    )
    var record = call.record
    switch call.result {
    case .failure(let error):
      record.outcome = .error
      record.detail = error.description
    case .success(let response):
      if response.isRefusal {
        record.outcome = .refused
        record.detail = "the API declined this request"
      } else if let verdict = MentorLoop.decode(UnderstandingVerdict.self, from: response) {
        if resets != resetsAtRequest {
          record.outcome = .error
          record.detail = "the understanding was reset during the call"
        } else if await adopt(
          verdict.understanding,
          at: clock.date,
          coveredThrough: window.readThrough,
          model: response.model,
          source: .periodic,
          cost: record.cost
        ) {
          record.outcome = .refreshed
          record.detail = verdict.reason.withPlainDashes
        } else {
          record.outcome = .error
          record.detail = "the refresh reply carried no understanding"
        }
      } else {
        record.outcome = response.isTruncated ? .truncated : .error
        record.detail = "could not parse the refresh reply"
      }
    }
    status.lastRefresh = await store(record)
  }

  /// The screens a call reads: those at or after `since`, and every one
  /// journaled after `cursor`, the highest id the record's last write read.
  ///
  /// Returns the newest that fit the observation token budget; how many older
  /// ones were left out, counting the rows a capped journal read never returned
  /// and, with a cursor, only those after it, because the record already covers
  /// the rest; and the highest id read, for the next revision's cursor.
  /// `observation` is the one being considered, added when the journal has not
  /// stored it.
  private func screens(
    since: Date?,
    after cursor: Int64?,
    now: Date,
    including observation: ActivityObservation? = nil
  ) async -> (entries: [RollingWindow.Entry], leftOut: Int, readThrough: Int64?) {
    // Observation ids are SQLite rowids, assigned at insert as one past the
    // largest in the table, so they follow the order rows were journaled
    // whatever their capture timestamps.
    var history =
      (try? await journal.recentObservations(
        since: since,
        after: cursor,
        limit: MentorLoop.windowLookback
      )) ?? []
    let readThrough = history.map(\.id).max().map { max($0, cursor ?? 0) } ?? cursor
    func uncovered(_ row: ActivityObservation) -> Bool { cursor.map { row.id > $0 } ?? true }
    var unread = 0
    if history.count >= MentorLoop.windowLookback,
      let total = try? await journal.observationCount(
        since: cursor == nil ? since : nil,
        after: cursor
      )
    {
      unread = max(0, total - history.filter(uncovered).count)
    }
    if let observation, !history.contains(where: { $0.id == observation.id }) {
      history.append(observation)
    }
    let window = RollingWindow.fill(
      observations: history,
      now: now,
      duration: now.timeIntervalSince(history.map(\.timestamp).min() ?? now),
      tokenBudget: settings.mentorWindowTokenBudget,
      countingAfter: cursor
    )
    return (window.entries, window.leftOut + unread, readThrough)
  }

  // MARK: Calls

  private struct CallResult {
    var result: Result<MessagesResponse, ClaudeClientError>
    var record: ModelCallRecord
  }

  /// The single path to the network.
  ///
  /// Marks the tier in flight, times the call, and prices its usage; the caller
  /// sets the outcome.
  private func perform(
    tier: ModelTier,
    request: MessagesRequest,
    apiKey: String,
    timeout: TimeInterval
  ) async -> CallResult {
    inFlight.insert(tier)
    await publishStatus()
    let started = clock.date
    let identity = CallIdentity(kind: tier.rawValue, promptVersion: MentorPrompts.version)
    let result: Result<MessagesResponse, ClaudeClientError>
    do {
      result = .success(
        try await client.send(request, call: identity, apiKey: apiKey, timeout: timeout)
      )
    } catch let error as ClaudeClientError {
      result = .failure(error)
    } catch {
      result = .failure(.transport(error.localizedDescription))
    }
    let latency = clock.date.timeIntervalSince(started)
    inFlight.remove(tier)
    if inFlight.isEmpty, let pending = pendingQuestion {
      pendingQuestion = nil
      status.pendingFollowUp = nil
      pending.continuation.resume(returning: true)
    }
    let usage = (try? result.get().usage) ?? Usage()
    let replayed = client.isReplay
    let record = ModelCallRecord(
      timestamp: started,
      tier: tier,
      // A replayed answer came from whichever model was recorded, not
      // necessarily the one the settings ask for now.
      model: replayed ? ((try? result.get().model) ?? request.model) : request.model,
      promptVersion: identity.promptVersion,
      promptCharacters: request.promptCharacterCount,
      imageBytes: request.imageByteCount,
      usage: usage,
      cost: replayed ? 0 : (settings.prices.cost(of: usage, model: request.model) ?? 0),
      latency: latency,
      outcome: .error,
      detail: nil,
      replayed: replayed
    )
    return CallResult(result: result, record: record)
  }

  /// Journals the call, adds it to the hour's spend unless it was replayed,
  /// and publishes it.
  @discardableResult
  private func store(_ record: ModelCallRecord) async -> ModelCallRecord {
    var stored = record
    do {
      stored = try await journal.record(record)
    } catch {
      MentorLoop.log.error(
        "model call not journaled: \(String(describing: error), privacy: .public)"
      )
    }
    if !record.replayed {
      spend.record(cost: record.cost, at: record.timestamp)
    }
    MentorLoop.log.notice(
      """
      \(record.tier.rawValue, privacy: .public) \(record.model, privacy: .public) \
      \(record.outcome.rawValue, privacy: .public)\
      \(record.replayed ? " replayed" : "", privacy: .public) \
      in=\(record.usage.totalInputTokens) cached=\(record.usage.cacheReadInputTokens) \
      out=\(record.usage.outputTokens) cost=\(record.cost, format: .fixed(precision: 4)) \
      latency=\(record.latency, format: .fixed(precision: 2))s
      """
    )
    await broadcaster.send(.call(stored))
    return stored
  }

  /// Resumes the waiting question, if any, as dropped.
  ///
  /// True when there was one.
  @discardableResult
  private func dropPendingQuestion() -> Bool {
    guard let pending = pendingQuestion else { return false }
    pendingQuestion = nil
    status.pendingFollowUp = nil
    pending.continuation.resume(returning: false)
    return true
  }

  static func decode<T: Decodable>(_ type: T.Type, from response: MessagesResponse) -> T? {
    let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
  }

  // MARK: Status

  private func availability(now: Date) -> MentorStatus.Availability {
    if !settings.enabled { return .disabled }
    if apiKey == nil { return .noAPIKey }
    if spend.isCapped(now: now) { return .capReached(until: SpendMeter.nextHourStart(after: now)) }
    return .ready
  }

  private func publishStatus() async {
    let now = clock.date
    spend.prune(now: now)
    let multiplier = spend.cadenceMultiplier(now: now)
    status.availability = availability(now: now)
    status.spendThisHour = spend.spent(now: now)
    status.hourStart = SpendMeter.hourStart(of: now)
    status.callsThisHour = spend.callCount(now: now)
    status.cadenceMultiplier = multiplier
    status.nextTriageAt = scheduler.nextTriageAllowed(multiplier: multiplier)
    status.nextMentorAt = scheduler.nextMentorAllowed(multiplier: multiplier)
    status.understanding = understanding
    status.nextRefreshAt = scheduler.nextRefreshAllowed(
      after: period,
      mode: mode,
      multiplier: multiplier
    )
    status.inFlight = ModelTier.allCases.first { inFlight.contains($0) }
    guard status != lastPublishedStatus else { return }
    lastPublishedStatus = status
    await broadcaster.send(.status(status))
  }

  private func reloadKey() async {
    guard !client.isReplay else {
      apiKey = MentorLoop.replayCredential
      return
    }
    do {
      apiKey = try await keyStore.loadInBackground()
    } catch {
      apiKey = nil
      MentorLoop.log.error("api key unreadable: \(String(describing: error), privacy: .public)")
    }
  }

  /// Restores this hour's spend and the last call of each tier after a relaunch.
  private func seedFromJournal() async {
    let now = clock.date
    if let calls = try? await journal.modelCalls(since: SpendMeter.hourStart(of: now)) {
      for call in calls {
        spend.record(cost: call.cost, at: call.timestamp)
      }
    }
    if let recent = try? await journal.recentModelCalls(limit: 50) {
      status.lastTriage = recent.first { $0.tier == .triage }
      status.lastMentor = recent.first { $0.tier == .mentor }
      status.lastRefresh = recent.first { $0.tier == .understanding }
    }
    // The understanding survives a relaunch, so a restart mid-task does not
    // throw away what Athina had worked out. Expiry runs here as on every
    // observation, so one that went stale while the app was closed is
    // journaled as expired rather than silently skipped. The journal's
    // newest observation is the activity this run has not seen yet. The
    // count toward the next refresh survives with it; one kept from before
    // the record's last write, or none, starts over at that write.
    understanding = try? await journal.latestUnderstanding()
    lastActivityAt = (try? await journal.recentObservations(limit: 1))?.first?.timestamp
    period = try? await journal.refreshPeriod()
    if let record = understanding, (period?.startedAt ?? .distantPast) < record.updatedAt {
      await setPeriod(RefreshPeriod(startedAt: record.updatedAt))
    }
    await expireUnderstandingIfNeeded(now: now)
  }

  private func journalEvent(_ event: JournalEvent) async {
    var stored = event
    do {
      stored = try await journal.record(event)
    } catch {
      MentorLoop.log.error("event not journaled: \(String(describing: error), privacy: .public)")
    }
    await broadcaster.send(.event(stored))
  }
}
