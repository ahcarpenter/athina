import Foundation
import OSLog

/// Subscribes to the sensing stream, runs the two Claude tiers behind
/// `MentorScheduler`'s gates, accounts spend, and publishes suggestions.
///
/// Everything that reaches the network passes through `perform`, which is the
/// only place the API key is read. Prompt text is never journaled or logged.
///
/// With a replay client (`ClaudeClient.isReplay`) no key is read at all, every
/// call is journaled as a replay with zero cost, and none of them counts
/// toward the hour's spend or its cap.
public actor MentorLoop {
    public static let triageTimeout: TimeInterval = 30
    public static let mentorTimeout: TimeInterval = 180
    public static let testTimeout: TimeInterval = 30
    /// Triage answers a short JSON object.
    public static let triageMaxTokens = 200
    /// Mentor replies include adaptive thinking, which counts against this.
    public static let mentorMaxTokens = 6000
    /// How many journal rows feed the event summaries and the rolling window.
    public static let eventLookback = 40
    public static let windowLookback = 200

    private static let log = Logger(subsystem: "com.ahcarpenter.mentor", category: "mentor")

    /// Stands in for the key while calls are replayed. It is not a secret, the
    /// replay client ignores it, and it lets every call path run unchanged
    /// without reading the keychain.
    public static let replayCredential = "replay-needs-no-key"

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
    private var consumeTask: Task<Void, Never>?

    public init(
        settings: MentorSettings,
        journal: Journal,
        client: any ClaudeClient,
        keyStore: any KeyStore,
        events: AsyncStream<SensingEvent>
    ) {
        let validated = settings.validated()
        self.settings = validated
        self.journal = journal
        self.client = client
        self.keyStore = keyStore
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

    public func start() async {
        guard consumeTask == nil else { return }
        reloadKey()
        await seedFromJournal()
        await publishStatus()
        consumeTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.source {
                await self.handle(event)
            }
        }
    }

    public func stop() async {
        consumeTask?.cancel()
        consumeTask = nil
        await broadcaster.finish()
    }

    public func updateSettings(_ newSettings: MentorSettings) async {
        let validated = newSettings.validated()
        if validated.onlyMentorInsideContexts != settings.onlyMentorInsideContexts
            || validated.contexts != settings.contexts {
            status.lastContext = nil
        }
        settings = validated
        scheduler.settings = validated
        spend.cap = validated.hourlySpendCap
        await publishStatus()
    }

    /// Call after the key is saved or removed in Settings.
    public func apiKeyChanged() async {
        reloadKey()
        await publishStatus()
    }

    public var hasAPIKey: Bool { apiKey != nil }

    public func currentStatus() -> MentorStatus { status }

    /// Records the user's response to a suggestion and journals it.
    @discardableResult
    public func recordFeedback(suggestionID: Int64, feedback: SuggestionFeedback, at now: Date = Date()) async -> Suggestion? {
        let updated: Suggestion?
        do {
            updated = try await journal.updateFeedback(suggestionID: suggestionID, feedback: feedback, at: now)
        } catch {
            MentorLoop.log.error("feedback not journaled: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let updated else { return nil }
        await journalEvent(JournalEvent(
            timestamp: now, kind: .feedback, bundleID: updated.bundleID, appName: updated.appName,
            detail: "\(feedback.label): \(updated.title)"
        ))
        await broadcaster.send(.feedback(updated))
        return updated
    }

    /// One tiny request on the triage model. Returns the model that answered,
    /// or the API's own error message. Counted as spend like any other call.
    public func testConnection() async -> Result<String, ClaudeClientError> {
        reloadKey()
        guard let apiKey else { return .failure(.transport("no API key saved")) }
        let request = MessagesRequest(
            model: settings.triageModel,
            maxTokens: 16,
            system: [],
            messages: [Message(role: .user, content: [.text("Reply with the single word OK.")])]
        )
        let call = await perform(tier: .test, request: request, apiKey: apiKey, timeout: MentorLoop.testTimeout)
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
            mode = newMode
            await publishStatus()
        case .observation(let observation):
            await consider(observation)
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
            spendFraction: spend.fraction(now: now),
            cadenceMultiplier: spend.cadenceMultiplier(now: now),
            nextHourStart: SpendMeter.nextHourStart(after: now)
        )
    }

    /// The whole loop for one observation: triage gate, triage call, mentor gate, mentor call.
    private func consider(_ observation: ActivityObservation) async {
        var now = Date()
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
        noteContext(placement, for: observation, at: Date())

        now = Date()
        switch scheduler.mentorGate(triage: verdict, context: placement, conditions: conditions(now: now), now: now) {
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

    private func noteContext(_ placement: ContextPlacement, for observation: ActivityObservation, at now: Date) {
        status.lastContext = MentorStatus.ContextRecord(
            at: now, placement: placement, appName: observation.focus.appName
        )
    }

    // MARK: Triage tier

    /// Text only: app and window, accessibility summary, the latest OCR text,
    /// and a compact event summary. While contexts are enforced the system
    /// prompt also carries the declared list and the reply places the snapshot
    /// in one of them, so the placement costs no extra call. Returns the
    /// verdict with that placement, or nil when the call did not produce one.
    private func runTriage(_ observation: ActivityObservation) async -> (TriageVerdict, ContextPlacement)? {
        guard let apiKey else { return nil }
        let now = Date()
        let events = (try? await journal.recentEvents(limit: MentorLoop.eventLookback)) ?? []
        let contexts = settings.onlyMentorInsideContexts ? settings.contexts : []
        let text = PromptBuilder.triageMessage(observation: observation, recentEvents: events, now: now)
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
        let call = await perform(tier: .triage, request: request, apiKey: apiKey, timeout: MentorLoop.triageTimeout)
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
                record.outcome = placement.isOutside ? .outOfContext : (decoded.worthALook ? .candidate : .quiet)
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

    /// The rolling window of recent observations' text plus, when enabled,
    /// the latest kept thumbnail as an image.
    private func runMentor(_ observation: ActivityObservation, context: ContextPlacement) async {
        guard let apiKey else { return }
        let now = Date()
        let since = now.addingTimeInterval(-settings.mentorWindowDuration)
        var history = (try? await journal.recentObservations(since: since, limit: MentorLoop.windowLookback)) ?? []
        if !history.contains(where: { $0.id == observation.id }) {
            history.append(observation)
        }
        let window = RollingWindow.build(
            observations: history, now: now,
            duration: settings.mentorWindowDuration, tokenBudget: settings.mentorWindowTokenBudget
        )
        let events = (try? await journal.recentEvents(limit: MentorLoop.eventLookback)) ?? []
        let suppressed = settings.suppressedCategories(bundleID: observation.focus.bundleID, now: now)

        var content: [ContentBlock] = []
        let jpeg = settings.sendThumbnail ? observation.frame.jpeg : nil
        if let jpeg {
            content.append(.image(mediaType: "image/jpeg", base64: jpeg.base64EncodedString()))
        }
        content.append(.text(PromptBuilder.mentorMessage(
            window: window, latest: observation, recentEvents: events,
            suppressed: suppressed, includesImage: jpeg != nil,
            context: settings.contexts.first { $0.id == context.contextID }, now: now
        )))
        let model = settings.mentorModelInfo
        let request = MessagesRequest(
            model: model.id,
            maxTokens: MentorLoop.mentorMaxTokens,
            system: [SystemBlock(text: MentorPrompts.mentorSystem)],
            messages: [Message(role: .user, content: content)],
            outputConfig: OutputConfig(
                format: OutputFormat(schema: MentorPrompts.mentorSchema),
                effort: settings.effort(for: .mentor)
            )
        )
        let call = await perform(tier: .mentor, request: request, apiKey: apiKey, timeout: MentorLoop.mentorTimeout)
        let shownAt = Date()
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
                if let payload = verdict.suggestion {
                    let title = payload.title.withPlainDashes
                    if payload.confidence < settings.minimumConfidence {
                        record.outcome = .belowConfidence
                        record.detail = "\(title) (confidence \(Int((payload.confidence * 100).rounded()))%)"
                    } else if let reason = settings.suppression(for: payload.category, bundleID: observation.focus.bundleID, now: now) {
                        record.outcome = .suppressed
                        record.detail = "\(title) (\(reason.label))"
                    } else {
                        record.outcome = .suggested
                        record.detail = title
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
                            observationID: observation.id == 0 ? nil : observation.id,
                            model: response.model,
                            promptVersion: MentorPrompts.version
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
            MentorLoop.log.error("suggestion not journaled: \(String(describing: error), privacy: .public)")
        }
        await journalEvent(JournalEvent(
            timestamp: shownAt, kind: .suggested, bundleID: stored.bundleID, appName: stored.appName,
            detail: "\(stored.category.label): \(stored.title)"
        ))
        await broadcaster.send(.suggestion(stored))
    }

    // MARK: Calls

    private struct CallResult {
        var result: Result<MessagesResponse, ClaudeClientError>
        var record: ModelCallRecord
    }

    /// The single path to the network. Marks the tier in flight, times the
    /// call, and prices its usage; the caller sets the outcome.
    private func perform(tier: ModelTier, request: MessagesRequest, apiKey: String, timeout: TimeInterval) async -> CallResult {
        inFlight.insert(tier)
        await publishStatus()
        let started = Date()
        let identity = CallIdentity(kind: tier.rawValue, promptVersion: MentorPrompts.version)
        let result: Result<MessagesResponse, ClaudeClientError>
        do {
            result = .success(try await client.send(request, call: identity, apiKey: apiKey, timeout: timeout))
        } catch let error as ClaudeClientError {
            result = .failure(error)
        } catch {
            result = .failure(.transport(error.localizedDescription))
        }
        let latency = Date().timeIntervalSince(started)
        inFlight.remove(tier)
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
            MentorLoop.log.error("model call not journaled: \(String(describing: error), privacy: .public)")
        }
        if !record.replayed {
            spend.record(cost: record.cost, at: record.timestamp)
        }
        MentorLoop.log.notice(
            "\(record.tier.rawValue, privacy: .public) \(record.model, privacy: .public) \(record.outcome.rawValue, privacy: .public)\(record.replayed ? " replayed" : "", privacy: .public) in=\(record.usage.totalInputTokens) cached=\(record.usage.cacheReadInputTokens) out=\(record.usage.outputTokens) cost=\(record.cost, format: .fixed(precision: 4)) latency=\(record.latency, format: .fixed(precision: 2))s"
        )
        await broadcaster.send(.call(stored))
        return stored
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
        let now = Date()
        spend.prune(now: now)
        let multiplier = spend.cadenceMultiplier(now: now)
        status.availability = availability(now: now)
        status.spendThisHour = spend.spent(now: now)
        status.hourStart = SpendMeter.hourStart(of: now)
        status.callsThisHour = spend.callCount(now: now)
        status.cadenceMultiplier = multiplier
        status.nextTriageAt = scheduler.nextTriageAllowed(multiplier: multiplier)
        status.nextMentorAt = scheduler.nextMentorAllowed(multiplier: multiplier)
        status.inFlight = ModelTier.allCases.first { inFlight.contains($0) }
        guard status != lastPublishedStatus else { return }
        lastPublishedStatus = status
        await broadcaster.send(.status(status))
    }

    private func reloadKey() {
        guard !client.isReplay else {
            apiKey = MentorLoop.replayCredential
            return
        }
        do {
            apiKey = try keyStore.load()
        } catch {
            apiKey = nil
            MentorLoop.log.error("api key unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Restores this hour's spend and the last call of each tier after a relaunch.
    private func seedFromJournal() async {
        let now = Date()
        if let calls = try? await journal.modelCalls(since: SpendMeter.hourStart(of: now)) {
            for call in calls {
                spend.record(cost: call.cost, at: call.timestamp)
            }
        }
        if let recent = try? await journal.recentModelCalls(limit: 50) {
            status.lastTriage = recent.first { $0.tier == .triage }
            status.lastMentor = recent.first { $0.tier == .mentor }
        }
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
