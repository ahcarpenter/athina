# mentor

Live mentor for macOS: watches what you are doing and offers timely guidance.

Two phases are in place. The **foundation** is a menu-bar app that senses what
you are doing (accessibility context plus low-cadence screen capture with
on-device OCR), records it in a local journal, and shows a debug panel with what
it currently thinks you are doing. The **mentor loop** subscribes to that
stream and asks Claude, in two tiers, whether there is a genuinely more helpful
way to approach what you are doing; when there is, a small toast says so and
learns from your answer. Callouts, voice, and halt-and-redirect are later
phases.

## Requirements

- macOS 26 or later (developed and measured on macOS 27, Apple Silicon)
- Xcode 26 or later with its command line tools (`swift`, `codesign`)
- No third-party dependencies: SwiftUI, ScreenCaptureKit, Vision, the
  accessibility API, Carbon hotkeys, and the system SQLite

## Build, run, test

```sh
make build   # builds build/Mentor.app from the SwiftPM binary
make run     # builds, quits a running copy, and launches the app
make test    # runs the unit tests (swift test)
make measure # samples the running app's CPU and memory for 60 seconds
```

There is no Xcode project. `Package.swift` defines the targets and
`scripts/bundle.sh` wraps the release binary in an app bundle with
`Resources/Info.plist` and `Resources/Mentor.entitlements`, then signs it.
`swift build` and `swift test` work directly too.

`Mentor --snapshot <dir>` renders every window with sample data to PNG files
(light and dark) without starting the pipeline or calling any model. It is how
UI changes get checked without a person at the screen; it needs no permissions.
`open build/Mentor.app --args --open debug` (or `settings`, `settings:mentor`,
`permissions`, `history`) launches the app with that window already open, which
is how the live panel gets screenshotted from a shell.

### Setup: the Anthropic API key

The mentor loop needs an Anthropic API key. Open Settings > Mentor, paste the
key, press Save, then Test Connection: it sends one tiny request on the triage
model and reports the answering model or the API's own error message. The key
goes into your login keychain (`com.ahcarpenter.mentor` /
`anthropic-api-key`) and nowhere else; the app only ever shows its last four
characters. Without a key the loop stays idle and the menu says so. Remove
deletes the keychain item.

### Code signing

The bundle script signs with `$MENTOR_SIGN_IDENTITY` if set, otherwise with the
first Apple Development or Developer ID Application identity in the keychain,
otherwise ad-hoc. macOS ties Screen Recording and Accessibility grants to the
app's designated code requirement, recorded when the grant is made. An ad-hoc
signature's default requirement is the hash of the exact binary, so a plain
ad-hoc rebuild silently invalidates both grants: System Settings still shows
the switches on, toggling them does not help, and the TCC daemon logs
"Failed to match existing code requirement". The ad-hoc path therefore signs
with an explicit requirement on the bundle identifier
(`identifier "com.ahcarpenter.mentor"`), which every rebuild satisfies, so a
grant made once stays valid. The trade-off is that any ad-hoc binary claiming
that identifier would inherit the grants, which is acceptable on a development
machine and is exactly what a development certificate fixes.

If a grant was made against an older build (the app shows a permission as
missing although System Settings shows it on), remove the stale record and
grant again:

```sh
tccutil reset Accessibility com.ahcarpenter.mentor
tccutil reset ScreenCapture com.ahcarpenter.mentor
```

## Permissions

Mentor asks for two permissions and explains each in a first-run window that
opens whenever one is missing. The window triggers each missing permission's
system prompt once when it opens, so Mentor appears in both System Settings
lists, shows live status, deep-links to the matching System Settings pane, and
re-checks every second while open and when the app regains focus.

| Permission | Used for | Without it |
| --- | --- | --- |
| Screen Recording | ScreenCaptureKit capture of the display containing the focused window, then Vision OCR | Accessibility-only mode: app, window, and focused element are still sensed; no frames |
| Accessibility | Focused app, window title, focused element role and text, via the AX API | Screen-only mode: frames and OCR only; app identity comes from NSWorkspace |

Idle detection uses `CGEventSource.secondsSinceLastEventType`, which needs no
permission. Input Monitoring is never requested. The only network connection
the app ever opens is to `api.anthropic.com`, from the mentor loop, and only
when a key is saved (see Privacy model).

## Architecture

```
Sources/MentorCore            library, fully testable
  Settings/                   SensingSettings (every threshold and cadence), MentorSettings (the loop's
                              section of the same file), SettingsStore (JSON), ExcludedApps, HotKey
  Model/ActivityObservation   FocusContext, FrameInfo, TextBlock, ActivityObservation, JournalEvent,
                              SensingEvent (the stream the mentor loop consumes), SensingMode, CadenceStatus
  Scheduling/                 CaptureScheduler (pure trigger and cadence state machine),
                              FrameKeepPolicy (near-duplicate drop rule)
  Imaging/                    PerceptualHash (256-bit dHash), FrameImaging (downscale, hash, JPEG)
  Journal/                    Journal actor over the system SQLite, RetentionPolicy
  Sensing/                    AXActor (run-loop thread for the AX API), FocusTracker (NSWorkspace + AXObserver),
                              ScreenCapturer (ScreenCaptureKit), TextRecognizer (Vision),
                              SensingPipeline (orchestration), EventBroadcaster (fan-out AsyncStream)
  Claude/                     ClaudeClient (Messages API request and response types, AnthropicClient over
                              URLSession), ScriptedClaudeClient (mock for tests), ModelCatalog and PriceTable,
                              KeyStore (Keychain and in-memory), JSONValue (schemas)
  Mentor/                     MentorScheduler (pure trigger, debounce, and gate state machine), SpendMeter,
                              SuppressionRules (snooze and never-for-this), ContextBuilder (rolling window,
                              prompt text), Prompts (versioned system prompts and output schemas),
                              Suggestion and ModelCallRecord, MentorLoop (orchestration)
  System/                     PermissionProbe, InputActivity (idle seconds), ProcessResources (CPU, memory)
Sources/Mentor                the app: MenuBarExtra, AppState, windows, ToastController (floating panel),
                              HotKeyCenter (Carbon), Snapshots
Tests/MentorCoreTests         Swift Testing suites for the pure parts, with JSON fixtures under Fixtures/
```

### Sensing loop

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

A capture reads the fresh accessibility context, grabs the display containing
the focused window with `SCScreenshotManager` (Mentor's own windows excluded,
downscaled to `maxFrameDimension`), hashes it, and drops it if the hash is
within `hashDistanceThreshold` of the previous kept frame **and** neither the
window nor the focused text changed. Kept frames go through Vision OCR (text
blocks with bounding boxes in frame pixels and in global display points), are
JPEG-encoded, written to the journal, and published as `SensingEvent.observation`.
Because the user can switch apps while the screenshot or OCR is in flight, the
pipeline asks NSWorkspace for the live frontmost app after each of those steps
and discards the frame, without OCR or journaling, when that app is not the one
the frame was captured for or is excluded.

### Journal

`~/Library/Application Support/mentor/journal.sqlite`, WAL mode, incremental
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

Settings live next to it in `settings.json`; missing or unknown keys fall back
to defaults so older files keep working.

Settings live next to it in `settings.json`; missing or unknown keys fall back
to defaults so older files keep working. The mentor loop adds two tables:
`suggestions` (every suggestion shown, with the user's feedback) and
`model_calls` (one row per API call: tier, model, prompt version and size,
token counts, estimated cost, latency, outcome, and the model's one-line
reason; never the prompt text). Both expire with `textRetention` and are
emptied by Clear Journal.

### Subscription point

`SensingPipeline.events()` returns an `AsyncStream<SensingEvent>`; every
subscriber sees every event from the moment it subscribes. The mentor loop
consumes `.observation(ActivityObservation)` (already journaled, with id) and
the mode events, and reads history from `Journal`. Later phases subscribe the
same way, and to `MentorLoop.events()` for suggestions and feedback.

## Mentor loop

`MentorLoop` is an actor with one consumer task over the sensing stream. For
each kept observation it runs, in order:

1. **Triage gate** (`MentorScheduler.triageGate`). The triage tier runs only on
   change moments: a kept observation whose reason is a focus change, settled
   input, or a manual capture, never a floor-cadence frame. It is debounced to
   one call per `triageMinInterval` (20 s by default) and skipped when the
   screen text is near-identical to the last triaged screen of the same window
   (line-set overlap of at least `triageSimilarityThreshold`, 0.9). Nothing
   runs while paused, idle, on an excluded app, without permissions, without an
   API key, while another call is in flight, or while the spend cap holds.
2. **Triage call** on the cheap model (`claude-haiku-4-5-20251001` by default)
   with structured output: `{"worth_a_look": bool, "reason": string}`.
3. **Mentor gate** (`MentorScheduler.mentorGate`), the single yes-or-no between
   triage and the strong model: triage said yes, the spend cap is not reached,
   and at least `mentorMinInterval` (2 min) has passed since the last mentor
   call. A later phase adds its declared-contexts check inside this gate.
4. **Mentor call** on the strong model (`claude-fable-5-1` by default, or
   `claude-opus-5` from Settings) with a rolling window of recent observations'
   text (bounded by `mentorWindowDuration` and `mentorWindowTokenBudget`), a
   compact event summary, the categories currently suppressed for the app,
   and, when `sendThumbnail` is on, the latest kept thumbnail as an image. The
   reply is `{"reason": string, "suggestion": null | {title, body, explanation,
   category, confidence}}`. A null suggestion is the normal outcome.
5. **Delivery.** A suggestion under `minimumConfidence` or in a snoozed or
   never-for-this category is logged and dropped. Otherwise it is journaled and
   shown as a toast: a floating, non-activating panel under the menu bar that
   never takes keyboard focus and auto-dismisses after `toastTimeout`. *Tell me
   more* expands the full explanation in place. *Not now* dismisses and snoozes
   that category for that app for `notNowSnooze` (1 h). *Never for this*
   records that the category must never be raised for that app again (the rule
   is listed and removable in Settings > Mentor). Every suggestion and every
   answer is journaled, and the history window (menu > Suggestions) lists them
   with time, app, category, feedback, and full text.

Both system prompts and both output schemas live in `Prompts.swift` under a
version number that is stored with every call and suggestion. Each system
prompt carries a `cache_control` marker, and the request encoder sorts keys so
the cached prefix is byte identical between calls. Caching only engages above
a model's minimum cacheable prefix (512 tokens on Claude Fable 5.1 and Opus 5,
1024 on Sonnet 5, 4096 on Haiku 4.5), so in practice the mentor prompt is
served from cache within its five-minute window and the small triage prompt
is not; the marker stays so a triage model with a lower minimum benefits.
Menu > Show Last Suggestion brings a missed toast back. The API key is read from the Keychain inside the loop
and passed per request; it is never journaled or logged.

### Spend control

Every response's usage fields (`input_tokens`, `output_tokens`,
`cache_creation_input_tokens`, `cache_read_input_tokens`) are priced with the
table in Settings > Mentor (dollars per million tokens, defaults checked
against Anthropic's pricing page on the date shown there, editable) and added
to a per-clock-hour total. As the total approaches `hourlySpendCap` ($1 by
default) both minimum intervals stretch by `1 / (1 - spent / cap)`, capped at
8x: 2x at half the cap, 4x at three quarters. At the cap no call is made until
the next clock hour. The hour's total is seeded from the journal at launch, so
relaunching does not reset it. Spend this hour shows in the menu, the debug
panel status bar, and the Mentor card.

## Privacy model

- Sensing stays on this Mac: the journal, thumbnails, and settings never leave
  it. The only network peer is `api.anthropic.com`, reached only by the mentor
  loop, only when an API key is saved and the loop is enabled. No other part
  of the app has network code.
- **What leaves the machine.** The triage tier receives text only: the
  frontmost app and window title, the accessibility summary (focused element
  role and an excerpt of its text), the OCR text of the latest kept
  observation (cut at 6000 characters), and a compact summary of recent
  journal events. The mentor tier receives the rolling window of recent
  observations' text (app, window, accessibility summary, and OCR text of
  each, bounded by the window duration and token budget in Settings) and, by
  default, the latest kept thumbnail as a JPEG image. "Send the latest
  screenshot to the mentor model" in Settings > Mentor turns the image off, in
  which case the mentor tier receives text only. Nothing else is sent: no
  file names, no keystrokes, no earlier thumbnails, no key.
- The API key lives in the login keychain, is passed per request, and is never
  written to the journal, the logs, or the debug panel, which show at most its
  last four characters.
- **Excluded apps** (Settings > Privacy) default to Keychain Access, Passwords,
  and common password managers. While one is frontmost Mentor captures no frame,
  reads no window title or element, runs no OCR, and journals only that the app
  was excluded, so nothing from them can reach either tier.
- Secure text fields are never read, even in non-excluded apps, so their
  contents never reach either tier.
- Model calls are journaled as counts (tokens, cost, latency, outcome) with the
  model's one-line reason, never with the prompt or the screen text that was
  sent.
- **Pause** from the menu or with the global hotkey (default ⌃⌥⌘P) stops all
  sensing; the menu bar icon switches from a filled eye to a crossed eye. Idle
  shows an outlined eye, an excluded app a raised hand, and missing permissions
  an eye with a warning badge.
- Thumbnails expire after 6 hours and text after 7 days by default; the journal
  is capped at 500 MB; all three are adjustable, and the journal can be cleared
  at any time.
- The journal directory is created with mode 0700.

## Debug panel

Menu bar > Debug Panel. Left: frontmost app, window, the Mentor loop card
(availability, the last triage gate decision and its reason, the last triage
and mentor calls with tokens, cached tokens, estimated cost and latency, spend
this hour, and the cadence state with the current slowdown), focused element
(role, title, description, text), cadence settings and counters, journal size
and path. Centre: the latest kept frame with OCR boxes overlaid and the
recognized text below; selecting an observation in the timeline shows that
frame instead. Right: a live timeline of observations and events from the
journal (suggestions and feedback included), or, under Model calls, a scrolling
log of every API call with prompt size, tokens, cost, latency, outcome, and the
model's reason. The status bar shows mode, permission state, last and next
capture with reason, seconds since input, spend this hour against the cap, and
the app's own CPU and memory.

## Continuous integration

`.github/workflows/ci.yml` runs `swift test`, the bundle script, and
`Mentor --snapshot` on GitHub's `macos-26` runner, which ships Xcode 26 and the
macOS 26 SDK this package targets, and uploads the rendered PNGs as the
`ui-snapshots` artifact. The tests exercise the pure parts (hashing, cadence,
journal, retention, settings, the mentor scheduler and gates, spend accounting,
snooze and never-for-this rules, the rolling window, request and response
coding against fixture JSON, and the whole loop against a scripted client) and
Vision OCR on a drawn bitmap, so they need no permissions, display, network,
or API key.
