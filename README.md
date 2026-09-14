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
make build            # builds build/Mentor.app from the SwiftPM binary
make run              # builds, quits a running copy, and launches the app
make run-replay       # the same, answering every model call from recorded fixtures: no network, no key, no spend
make record           # the same, live, writing every model call to a fixture file (spends API credits)
make clear-recordings # deletes the app's own recordings directory
make fixture-status   # reports whether the committed fixtures are current, never failing, with no network
make test             # runs the unit tests (swift test), the loop included, with no network
make measure          # samples the running app's CPU and memory for 60 seconds
```

There is no Xcode project. `Package.swift` defines the targets and
`scripts/bundle.sh` wraps the release binary in an app bundle with
`Resources/Info.plist` and `Resources/Mentor.entitlements`, then signs it.
`swift build` and `swift test` work directly too.

`Mentor --snapshot <dir>` renders every window with sample data to PNG files
(light and dark) without starting the pipeline or calling any model. It is how
UI changes get checked without a person at the screen; it needs no permissions
and never reads the keychain. Replay mode has renders of its own.
`open build/Mentor.app --args --open debug` (or `settings`, `settings:mentor`,
`permissions`, `history`) launches the app with that window already open, which
is how the live panel gets screenshotted from a shell. `--replay <dir>` and
`--record [<dir>]` choose where model calls go; see Iterating without the
network.

### Setup: the Anthropic API key

The mentor loop needs an Anthropic API key. Open Settings > Mentor, paste the
key, press Save, then Test Connection: it sends one tiny request on the triage
model and reports the answering model or the API's own error message. The key
goes into your login keychain (`com.ahcarpenter.mentor` /
`anthropic-api-key`) and nowhere else; the app only ever shows its last four
characters. Without a key the loop stays idle and the menu says so. Remove
deletes the keychain item. A replay needs no key, and the app never reads the
keychain while replaying.

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

## Iterating without the network

Working on Mentor never needs a live call to Anthropic. The app, its tests, and
every verification run use **replay**: each model call is answered from a
recorded fixture, with no network, no API key, and no spend. Replay is the
default way to exercise the app, including the end-to-end checks a change gets
before it ships. Live calls are for two deliberate occasions only: recording
fixtures, and the separate live check of the models' answers.

### Replay

```sh
make run-replay                                   # the committed fixtures
make run-replay REPLAY_DIR=~/Library/Application\ Support/mentor/recordings
make run-replay ALLOW_STALE=1                     # also serve stale fixtures, see below
open build/Mentor.app --args --replay <dir> --open debug
```

The whole product runs as it does live. Sensing watches the real screen, the
triage and mentor gates decide as usual, and each call they allow is answered
from `<dir>` by `ReplayClaudeClient`. It matches a call on its kind (the tier:
`triage`, `mentor`, `test`, and any kind added later), never on the request
bytes, which differ on every run. The fixtures of a kind are served in file-name
order, then from the first again, so a long session keeps working and the same
sequence of calls always gets the same answers. Each answer arrives after the
recorded latency, so the in-flight states look the way they do live. Suggestions
from replayed answers become toasts, take feedback, and land in the history like
live ones. Test Connection replays the recorded test call.

**A replay runs against an isolated copy seeded from your live settings.** A
replay, and a replay that was refused, keeps its journal and settings in
`~/Library/Application Support/mentor/replay` rather than beside the live ones.
Every replay launch starts from your live settings, read and never written (or
from the defaults when there are none), so the apps you excluded stay
excluded, and your retention and sensing choices hold, exactly as you set them.
Nothing a replay does, a suggestion and its feedback, a Not now or Never for
this, a changed setting, reaches the live journal, the live settings, or the
prompts of a later live run; a setting changed during a replay lasts until the
app quits. Delete that directory to clear the replay journal. `--record` is a
real session and uses the live files.

Nothing about a replay can be mistaken for a live call:

- the menu bar shows **Replay** beside the eye, and the menu says where the
  answers come from and that nothing is billed;
- the debug panel's status bar and Mentor card carry a Replay badge, the card
  lists the fixtures by kind with their directory, and every replayed row in
  the model call log is tagged Replay and shows "not billed";
- every replayed call is journaled in `model_calls` with `replayed = 1` and a
  cost of zero; its token counts are the recorded ones;
- replayed calls never count toward the hour's spend or the cap, and a
  replay's own journal holds no live spend, so none can hold it at the cap.

If the fixtures cannot be loaded, or the command line is contradictory (for
example `--record` with `--replay`), every call is refused with the reason,
which shows in the menu, the Mentor card, and the call log. The app never falls
back to live calls.

**Stale fixtures.** Each fixture carries the `MentorPrompts.version` it was
recorded with. A fixture whose version differs from the current one is stale:
on its turn the app refuses it with a message naming the file and both
versions, and the call is logged as an error. While iterating on prompts, pass
`--allow-stale-fixtures` (`make run-replay ALLOW_STALE=1`) to serve stale
fixtures anyway. The tests replay the committed set as it is, stale or not, so
bumping the prompt version never fails CI (see The committed fixtures).

### Record

```sh
make record                          # into ~/Library/Application Support/mentor/recordings
make record RECORD_DIR=recordings    # into ./recordings, which git ignores
```

`--record` runs live, with the saved key and real spend, and
`RecordingClaudeClient` writes each call to its own JSON file named
`<UTC time>-<kind>-<id>.json`. A file holds the fixture format version, the
call's kind and prompt version, the time, the model, the request exactly as it
was sent (system blocks, messages with the screenshot, output format, effort),
the response as Mentor decodes it or the error, usage, latency, and the
estimated cost. The key is never written: the recorder redacts it, and anything
shaped like an Anthropic key, from the text before writing. Files are created
with mode 0600, in a directory created with mode 0700. A relative
`--record <dir>` is taken inside the app's recordings directory, never against
the working directory (which is `/` for an app started with `open`);
`make record RECORD_DIR=...` passes an absolute path. Before the first call
the app creates the directory and writes and removes a probe file there; if
that fails, every call is refused with the reason, which shows in the menu,
the Mentor card, and the call log, so a recording that could write nothing
never spends anything. The menu bar shows **Recording** beside the eye while
it runs. `make clear-recordings` deletes the
app's own recordings directory, `~/Library/Application Support/mentor/recordings`.

Any call the loop makes through its single call path (`MentorLoop.perform`) is
recorded under its tier's raw value and replayed by that name, and neither
client knows the list of kinds. The calls later phases add, the periodic
understanding refresh (tier `understanding`) and the follow-up question about a
suggestion (tier `followUp`), are therefore recordable and replayable without
any change to either client: they need only a fixture of their kind in the
replay directory, and a replay without one refuses that kind of call by name.

### The committed fixtures

`Tests/MentorCoreTests/Fixtures/Replay` is a small set recorded live once from a
staged, synthetic scenario (see its README), never from anyone's real work, on
the cheapest models that exercise every call kind. `ReplayLoopTests` runs the
whole loop against it: every triage fixture in turn, the mentor calls they
lead to, the suggestion, its feedback, the journal rows, zero spend, and the
cycle starting over. The same tests fail when a file carries anything shaped
like a key, or an em dash.

A stale fixture, or a tier with no fixture, never fails them. The loop tests
replay stale fixtures as they are, so their coverage survives a prompt bump,
and the run reports each stale fixture with both prompt versions, and each tier
with no fixture, as a known issue. `make fixture-status` prints that report on
its own, with no network.

Recording the set again spends API credits, so it happens in the deliberate
live quality round, never to make CI pass:

1. Quit Mentor and move the journal aside (keep it to put back). Triage and
   mentor requests carry recent journal events and screens, so a recording made
   on a lived-in journal carries that history too.
2. Stage a synthetic scenario in real windows that fill the display (the
   documents in the fixture directory's `scenario/` folder work), and add every
   other running app to Settings > Privacy > Excluded apps.
3. Run `make record RECORD_DIR=recordings`, drive it through a moment worth a
   look that yields a shown suggestion, a quiet moment, and a Test Connection,
   then quit.
4. Read every file, text and screenshot, copy the ones you keep into the
   fixture directory, delete the rest, put the journal and settings back, and
   run `make fixture-status` and `swift test`.

`ScriptedClaudeClient` stays for unit tests that need one exact hand-written
answer, such as a refusal, an unparseable reply, or a slow call.

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
  Claude/                     ClaudeClient (Messages API request and response types, CallIdentity, AnthropicClient
                              over URLSession), CallFixture (recorded call format and files), RecordingClaudeClient,
                              ReplayClaudeClient, ModelClientMode (live, record, or replay from the command line),
                              ScriptedClaudeClient (hand-written answers for tests), ModelCatalog and PriceTable,
                              KeyStore (Keychain and in-memory), JSONValue (schemas)
  Mentor/                     MentorScheduler (pure trigger, debounce, and gate state machine), SpendMeter,
                              SuppressionRules (snooze and never-for-this), MentorshipContexts (declared
                              contexts, normalizing, placement), ContextBuilder (rolling window, prompt
                              text), Prompts (versioned system prompts and output schemas), Suggestion and
                              ModelCallRecord, MentorLoop (orchestration)
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

The mentor loop adds two tables: `suggestions` (every suggestion shown, with
the user's feedback) and `model_calls` (one row per API call: tier, model,
prompt version and size, token counts, estimated cost, latency, outcome, and
the model's one-line reason, and whether it was replayed; never the prompt
text). A moment held at the context boundary is recorded there as the
`outOfContext` outcome. Both expire
with `textRetention` and are emptied by Clear Journal.

Settings live next to it in `settings.json`; missing or unknown keys fall back
to defaults so older files keep working. A replay keeps both files in a
`replay` directory of its own and starts from the live settings (see Iterating
without the network).

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
2. **Triage call** on the cheap model (`claude-haiku-4-5-20251001` by default;
   Sonnet 5, Opus 5, and Fable 5.1 are offered too) with structured output:
   `{"worth_a_look": bool, "reason": string}`, plus `context` while
   mentorship contexts are enforced.
3. **Mentor gate** (`MentorScheduler.mentorGate`), the single yes-or-no between
   triage and the strong model: the activity is inside a declared mentorship
   context (see below), triage said yes, the spend cap is not reached, and at
   least `mentorMinInterval` (2 min) has passed since the last mentor call.
4. **Mentor call** on the strong model (`claude-opus-5` at medium effort by
   default; Sonnet 5 and Fable 5.1 are offered too) with a rolling window of
   recent observations' text (bounded by `mentorWindowDuration` and
   `mentorWindowTokenBudget`), a compact event summary, the categories
   currently suppressed for the app, and, when `sendThumbnail` is on, the
   latest kept thumbnail as an image. While mentorship contexts are enforced
   the message also names the declared context the moment was placed in, with
   its description, so the suggestion stays useful for that work. The reply is
   `{"reason": string,
   "suggestion": null | {title, body, explanation, category, confidence}}`. A
   null suggestion is the normal outcome.

   Each tier has its own model and effort in Settings > Mentor. Effort (low,
   medium, high, extra high) goes out as `output_config.effort` only to models
   that accept it; Haiku 4.5 rejects the parameter, so its effort control is
   disabled and nothing is sent. Thinking is left at each model's default
   (adaptive on Sonnet 5, Opus 5, and Fable 5.1); no thinking configuration is
   sent.

5. **Delivery.** A suggestion under `minimumConfidence` or in a snoozed or
   never-for-this category is logged and dropped. Otherwise it is journaled and
   shown as a toast: a floating, non-activating panel under the menu bar that
   never takes keyboard focus and auto-dismisses after `toastTimeout` (60 s;
   the countdown pauses while the pointer is over it). Closing it with the x,
   or a mouse-down in any other window or on the desktop, is journaled as
   dismissed, a timeout or quitting the app with the toast still up as
   expired. *Tell me more* expands the full explanation above the
   button bar (scrolling past 300 points) and becomes *Show less*; the three
   buttons stay pinned to the bottom edge in both states, and an expanded
   toast stays until closed. *Not now* dismisses and snoozes that category for
   that app for `notNowSnooze` (1 h). *Never for this* records that the
   category must never be raised for that app again (the rule is listed and
   removable in Settings > Mentor). Every suggestion and every answer is
   journaled, and the history window (menu > Suggestions) lists them with
   time, app, category, feedback, and full text.

Both system prompts and both output schemas live in `Prompts.swift` under a
version number that is stored with every call and suggestion. Each system
prompt carries a `cache_control` marker, and the request encoder sorts keys so
the cached prefix is byte identical between calls. Caching only engages above
a model's minimum cacheable prefix (512 tokens on Claude Fable 5.1 and Opus 5,
1024 on Sonnet 5, 4096 on Haiku 4.5), so in practice the mentor prompt is
served from cache within its five-minute window and the small triage prompt
is not; the marker stays so a triage model with a lower minimum benefits.
Menu > Show Last Suggestion brings a missed toast back; a toast asked for
that way never expires on its own, and a non-answer never overwrites an
answer already given. The API key is read from the Keychain inside the loop
and passed per request; it is never journaled or logged.

### Mentorship contexts

Settings > Mentor > Mentorship contexts is where you say what you want
mentoring in, in your own words: a short name such as "building web apps" and
an optional sentence saying what counts. **Only mentor inside these contexts**
turns that list into a hard boundary; it is off by default, and while it is off
the contexts change nothing.

While it is on, the declared names and descriptions are appended to the triage
system prompt and triage answers `context` (one of the declared names, or null)
alongside its usual verdict, so placing the moment costs no extra call. Null is
the one way the model declines to place a snapshot, and the prompt tells it to
answer null whenever it is unsure rather than guessing. A moment triage leaves
at null never reaches the mentor tier and never becomes a suggestion; the
triage call is logged with the `outOfContext` outcome and the reason. The
schema offers only the declared names, so the model cannot answer with a
context that does not exist. The declared list is part of the triage system
prompt's single cached block, so an edit changes that prefix once; whether the
triage prompt is served from cache at all is the per-model question answered
above.

Up to `ContextRules.maxContexts` (12) contexts may be declared, each with a
unique name of at most 60 characters and a description of at most 280. The
editor disables Add at the cap, refuses a name another context already uses,
and caps both fields as they are typed with a note at the limit, so nothing
saved is dropped or cut on the way in. With the switch on and no context
declared, nothing is inside anything: no triage call is made at all, and the
settings section, the menu, and the debug panel all say so.

To keep an app from being looked at at all, exclude it in Settings > Privacy >
Excluded apps: while an excluded app is frontmost nothing is captured, so
nothing about it can reach either tier.

The menu bar menu shows the current verdict (`Context: inside "writing Swift"`,
or why it is out) while it is still about the frontmost app, and
`Context: not yet judged in <app>` otherwise; the debug panel's Mentor card
shows it with the app it was made for and its age, and the model call log marks
a held call with the `outOfContext` outcome.

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
panel status bar, and the Mentor card. Replayed calls cost nothing and are never
counted (see Iterating without the network).

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
  which case the mentor tier receives text only. While mentorship contexts
  are enforced, the mentor tier also receives the name and description of the
  declared context the moment was placed in. Nothing else is sent: no file
  names, no keystrokes, no earlier thumbnails, no key.
- The API key lives in the login keychain, is passed per request, and is never
  written to the journal, the logs, or the debug panel, which show at most its
  last four characters.
- With **only mentor inside these contexts** on, the declared context names and
  descriptions are part of the triage system prompt, so they do leave the
  machine with every triage call. When triage places a moment inside one of
  them, the mentor call carries that one context's name and description so the
  suggestion stays useful for that work. A moment placed outside never reaches
  the mentor tier, so no context information is sent for it; the placement
  itself is decided here from the model's answer, not there.
- **Excluded apps** (Settings > Privacy) default to Keychain Access, Passwords,
  and common password managers. While one is frontmost Mentor captures no frame,
  reads no window title or element, runs no OCR, and journals only that the app
  was excluded, so nothing from them can reach either tier.
- Secure text fields are never read, even in non-excluded apps, so their
  contents never reach either tier.
- Model calls are journaled as counts (tokens, cost, latency, outcome) with the
  model's one-line reason, never with the prompt or the screen text that was
  sent.
- **Recordings** are the one exception, and only when the app is launched with
  `--record`: each call's whole request, screen text and screenshot included,
  and its answer are written to a file on this Mac
  (`~/Library/Application Support/mentor/recordings` unless another directory is
  given, mode 0700, files 0600). The API key is never written, and any
  Anthropic key visible in the screen text is redacted, though not inside the
  screenshot. `make clear-recordings` deletes them; Clear Journal does not. A
  replay (`--replay`) sends nothing anywhere, keeps its own journal and
  settings, and starts from the live settings, so excluded apps stay excluded
  while replaying.
- **Committed fixtures** carry only staged, synthetic screen content, recorded
  for the purpose, never the captain's or any user's real work. Every recording
  is read, text and screenshot, before it is committed.
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
(availability, the last triage gate decision and its reason, the current
mentorship context verdict, the last triage and mentor calls with tokens, cached
tokens, estimated cost and latency, spend this hour, and the cadence state with
the current slowdown), focused element
(role, title, description, text), cadence settings and counters, journal size
and path. Centre: the latest kept frame with OCR boxes overlaid and the
recognized text below; selecting an observation in the timeline shows that
frame instead. Right: a live timeline of observations and events from the
journal (suggestions and feedback included), or, under Model calls, a scrolling
log of every API call with prompt size, tokens, cost, latency, outcome, and the
model's reason. The status bar shows mode, permission state, last and next
capture with reason, seconds since input, spend this hour against the cap, and
the app's own CPU and memory. While calls are replayed or recorded, the status
bar and the Mentor card carry a Replay or Recording badge, the card says where
calls go (for a replay, the fixtures by kind and their directory, and any stale
ones), and each replayed call in the log is tagged Replay and not billed.

## Continuous integration

`.github/workflows/ci.yml` runs `swift test`, the bundle script, and
`Mentor --snapshot` on GitHub's `macos-26` runner, which ships Xcode 26 and the
macOS 26 SDK this package targets, and uploads the rendered PNGs, replay-mode
renders included, as the `ui-snapshots` artifact. The tests exercise the pure
parts (hashing, cadence, journal, retention, settings, the mentor scheduler and
gates, mentorship context rules and placement, spend accounting, snooze and
never-for-this rules, the rolling window, request and response coding against
fixture JSON, recording, redaction, replay matching and stale refusal, launch
flags, a replay's separate files, the whole loop against a scripted client, and
the whole loop against the committed replay fixtures) and Vision OCR on a drawn bitmap, so they need no
permissions, display, network, or API key.
