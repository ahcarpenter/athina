# Architecture

```
Sources/AthinaCore            library, fully testable
  Settings/                   SensingSettings (every threshold and cadence), MentorSettings (the loop's
                              section of the same file), SettingsStore (JSON), ExcludedApps, HotKey,
                              LaunchFiles (a launch's data directory and starting settings: a replay's own
                              directory, --settings, the started line that names it, and the lock that keeps it one replay's)
  Model/ActivityObservation   FocusContext, FrameInfo, TextBlock, ActivityObservation, JournalEvent,
                              SensingEvent (the stream the mentor loop consumes), SensingMode, CadenceStatus
  Scheduling/                 CaptureScheduler (pure trigger and cadence state machine),
                              FrameKeepPolicy (near-duplicate drop rule)
  Imaging/                    PerceptualHash (256-bit dHash), FrameImaging (downscale, hash, JPEG)
  Journal/                    Journal actor over the system SQLite, RetentionPolicy
  Sensing/                    AXActor (run-loop thread for the AX API), FocusTracker (NSWorkspace + AXObserver),
                              ScreenCapturer (ScreenCaptureKit), TextRecognizer (Vision),
                              SensingPipeline (orchestration), EventBroadcaster (fan-out AsyncStream)
  Claude/                     ClaudeClient (Messages API request and response types, CallIdentity, AnthropicClient
                              over URLSession), CallFixture (recorded call format and files), RecordingClaudeClient,
                              ReplayClaudeClient, ModelClientMode (live, record, or replay from the command line),
                              ScriptedClaudeClient (hand-written answers for tests), ModelCatalog and PriceTable,
                              KeyStore (Keychain and in-memory), JSONValue (schemas)
  Mentor/                     MentorScheduler (pure trigger, debounce, and gate state machine, including the
                              refresh gate), SpendMeter, SuppressionRules (snooze and never-for-this),
                              MentorshipContexts (declared contexts, normalizing, placement), ContextBuilder
                              (rolling window, prompt text, follow-up message), Prompts (versioned system
                              prompts and output schemas), Understanding (the standing record, its bounding,
                              rendering, and expiry), Suggestion, FollowUp and ModelCallRecord, Callout
                              (CalloutRegion, CalloutAnchor: frame-to-screen mapping and every rule that
                              refuses a callout), TalkBack (TranscriptMatcher, FollowUp, TalkBackState),
                              ToastCountdown (a toast's countdown, held and resumed), MenuBarMark (which variant
                              of the mark the menu bar shows), MentorLoop (orchestration)
  System/                     PermissionProbe (all four permissions), InputActivity (idle seconds),
                              ProcessResources (CPU, memory), AthinaClock (the one time source: SystemClock,
                              and AdjustableClock for tests and a replay), ClockMode (a replay's clock flags)
                              and ClockRemote (moving a replay's clock from a script), RuntimeEnvironment
                              (whether the process is sandboxed, and which app bundle it runs from),
                              ControlMode (whether a launch serves the control API, see docs/e2e.md)
Sources/AthinaSQLiteShim      C, one function: the `sqlite3_db_config` call Swift cannot make (it is variadic),
                              so `DataMigration` can read the old journal without altering it
Sources/Athina                the app: MenuBarExtra, AppState, windows, ToastController (floating panel),
                              Overlay/CalloutController (click-through overlay), Voice/SpeechListener
                              (on-device speech recognition), HotKeyCenter (Carbon, press and release),
                              Snapshots
Tests/AthinaCoreTests         Swift Testing suites for the pure parts, with JSON fixtures under Fixtures/
```

## Sensing loop

`SensingPipeline` is an actor with one loop. Each turn it:

1. re-reads permissions (every 2 s) and runs journal retention (every 10 min by default),
2. polls seconds-since-last-input and marks idle after `idleThreshold`,
3. computes the mode (`paused` > `waitingForPermissions` > `excluded` > `idle` > `watching` / `accessibilityOnly` / `screenOnly`),
4. asks `CaptureScheduler` whether a capture is due, and
5. sleeps until the next due time or the poll interval, or until a focus change wakes it.

Captures are triggered by app or window switches (after `focusSettleDelay`), by
input bursts settling (`inputSettleDelay`), by a slow floor cadence
(`floorInterval`) while active, or manually. Nothing runs while paused, idle,
on an excluded app, or without permissions. `minCaptureInterval` bounds the rate.
A capture consumes only the triggers noted before it started: a switch, input,
or manual request that lands while one is in flight stays pending, so the next
capture follows it under the same delays.

A capture reads the fresh accessibility context, grabs the display containing
the focused window with `SCScreenshotManager` (Athina's own windows excluded,
downscaled to `maxFrameDimension`), hashes it, and drops it if the hash is
within `hashDistanceThreshold` of the previous kept frame **and** neither the
window nor the focused text changed. Kept frames go through Vision OCR (text
blocks with bounding boxes in frame pixels and in global display points), are
JPEG-encoded, written to the journal, and published as `SensingEvent.observation`.
Because the user can switch apps while the screenshot or OCR is in flight, the
pipeline asks NSWorkspace for the live frontmost app after each of those steps
and discards the frame, without OCR or journaling, when that app is not the one
the frame was captured for or is excluded.

## Journal

`~/Library/Application Support/athina/journal.sqlite`, WAL mode, incremental
vacuum. Tables: `observations` (timestamp, app, window, accessibility summary
and JSON, OCR text and blocks, frame hash, frame geometry, reason), `thumbnails`
(JPEG blob per observation, separate so it can expire first), `events`
(start/stop, app and window switches, idle, pause, exclusion, permissions,
retention, clear). Retention deletes thumbnails older than `thumbnailRetention`,
then text and events older than `textRetention`, which settings clamp to at
least `thumbnailRetention` so text and events never expire before their
thumbnails, and then, if the file is still over `journalSizeCapBytes`, the
oldest thumbnails and finally the oldest observations and events until it fits.
"Clear Journal" in settings deletes everything.

The mentor loop adds five tables: `suggestions` (every suggestion shown, with
the user's feedback, the inferred goal it was judged against, the region it
pointed at if any, and whether a callout was drawn), `model_calls` (one row per
API call: tier, model, prompt version and size, token counts, estimated cost,
latency, outcome, the model's one-line reason, and whether it was replayed;
never the prompt text), `understanding` (one row per revision of the standing
understanding, see [Standing understanding](mentor-loop.md#standing-understanding)), `refresh_period` (a single row: the active use
counted toward the next understanding refresh), and `follow_ups` (one row per
question talked back: the transcript, the answer or why there is none, and the
model). A moment held at the context boundary is recorded in `model_calls` as
the `outOfContext` outcome. All five expire with `textRetention`, the
understanding goes with the oldest observations and events in a size-cap sweep,
and all five are emptied by Clear Journal. A journal written by an earlier build
is migrated in place when it is opened: missing tables are created and columns
added or dropped, so nothing has to be thrown away.

Settings live next to it in `settings.json`; missing or unknown keys fall back
to defaults so older files keep working. A replay keeps both files in a data
directory of its own and starts from the live settings or the file `--settings`
names (see [Replays side by side](replay.md#replays-side-by-side)).

## Subscription point

`SensingPipeline.events()` returns an `AsyncStream<SensingEvent>`; every
subscriber sees every event from the moment it subscribes. The mentor loop
consumes `.observation(ActivityObservation)` (already journaled, with id) and
the mode events, and reads history from `Journal`. Later phases subscribe the
same way, and to `MentorLoop.events()` for suggestions and feedback.
