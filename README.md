# mentor

Live mentor for macOS: watches what you are doing and offers timely guidance.

The **foundation** is a menu-bar app that senses what you are doing
(accessibility context plus low-cadence screen capture with on-device OCR),
records it in a local journal, and shows a debug panel with what it currently
thinks you are doing. The **mentor loop** subscribes to that stream and asks
Claude, in two tiers, whether there is a genuinely more helpful way to approach
what you are doing; when there is, a small toast says so and learns from your
answer. The **standing understanding** carries what you appear to be working
toward from one call to the next, so Mentor can look out for you: it calls out
an approach that will not reach your goal, one that is slower than an
alternative you have, or one that will reach it and bring a side effect you
would not want. **Callouts and voice** let a suggestion point at the spot on
screen it is about and take a spoken reply: an answer to the toast, or a
question the mentor tier answers. Reading suggestions aloud is deferred.
Halt-and-redirect and learned suppression are later phases.

## Requirements

- macOS 26 or later (developed and measured on macOS 27, Apple Silicon)
- Xcode 26 or later with its command line tools (`swift`, `codesign`)
- No third-party dependencies: SwiftUI, ScreenCaptureKit, Vision, the
  accessibility API, Carbon hotkeys, AVFoundation and Speech for talking
  back, and the system SQLite

## Build, run, test

```sh
make build            # builds build/Mentor.app from the SwiftPM binary
make run              # builds, quits a running copy, and launches the app
make run-replay       # the same, answering every model call from recorded fixtures: no network, no key, no spend (TIME_SCALE=60 runs its clock faster)
make record           # the same, live, writing every model call to a fixture file (spends API credits)
make clear-recordings # deletes the app's own recordings directory
make fixture-status   # checks that the committed fixtures are current (fails when not), with no network
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
`--record [<dir>]` choose where model calls go, and `--time-scale <n>` and
`--advance-clock <interval>` set a replay's clock; see Iterating without the
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

The keychain is stricter than TCC: for an app that is not Apple-signed it
trusts a keychain item's readers by the hash of the exact binary, so the
first time a rebuilt ad-hoc Mentor reads the API key, macOS can show its
"Mentor wants to access key" prompt. The app reads the key off the main
thread and keeps sensing behind the prompt, but makes no live call until it
is answered. Always Allow adds that build to the item's list; Deny leaves the
loop without a key until the next launch. A replay never reads the key, so it
never shows the prompt. A development certificate makes this go away too.

If a grant was made against an older build (the app shows a permission as
missing although System Settings shows it on), remove the stale record and
grant again:

```sh
tccutil reset Accessibility com.ahcarpenter.mentor
tccutil reset ScreenCapture com.ahcarpenter.mentor
```

## Iterating without the network

Working on Mentor needs no live call to Anthropic to build, test, or verify.
The app, its tests, and every verification run use **replay**: each model call
is answered from a recorded fixture, with no network, no API key, and no spend.
Replay is the default way to exercise the app, including the end-to-end checks
a change gets before it ships. Live calls are for two deliberate occasions
only: recording fixtures, including re-recording the committed set when a
change makes it stale, and the separate live check of the models' answers.

### Replay

```sh
make run-replay                                   # the committed fixtures
make run-replay REPLAY_DIR=~/Library/Application\ Support/mentor/recordings
make run-replay ALLOW_STALE=1                     # also serve stale fixtures, see below
make run-replay TIME_SCALE=60                     # on a clock 60 times real time, see A faster clock
open build/Mentor.app --args --replay <dir> --open debug
```

The whole product runs as it does live. Sensing watches the real screen, the
triage and mentor gates decide as usual, and each call they allow is answered
from `<dir>` by `ReplayClaudeClient`. It matches a call on its kind (the tier:
`triage`, `mentor`, `understanding`, `followUp`, `test`, and any kind added later), never on the request
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
versions, and the call is logged as an error. The tests replay the committed
set just as strictly and fail on a stale fixture, so a change that bumps the
prompt version re-records the committed set live in the same change (see The
committed fixtures). `--allow-stale-fixtures` (`make run-replay ALLOW_STALE=1`)
serves stale fixtures anyway, and is only for replaying locally while
iterating on prompts.

### A faster clock

Replay takes away the model's cost and latency, not the clock. A refresh that
comes due after fifteen minutes of use, a Not now that lasts an hour, the spend
hour, and a new day all still take that long. So every time-based behavior in
Mentor reads one time source, `MentorClock`
(`Sources/MentorCore/System/MentorClock.swift`): the dates the journal is
stamped with and the gates compare, the time awake a refresh counts, and every
wait (a toast's countdown, the callout check, the sensing cadence and idle
threshold, the talk-back timers, a replayed call's latency). The shipped app
runs on `SystemClock`, which is `ContinuousClock` and `Date`, so a live run is
exactly what it was. A replay runs on a clock of its own that a scripted check
can compress:

```sh
make run-replay TIME_SCALE=60
open build/Mentor.app --args --replay <dir> --time-scale 60 --advance-clock 1d --open debug
```

- `--time-scale <n>` runs the replay's clock n times faster than real time,
  from 1 to 100. Everything above shrinks with it: at 60x the fifteen-minute
  refresh comes due after fifteen seconds of use and a toast expires after one.
  So does the idle threshold, so raise Settings > Cadence > Idle after for the
  session, or keep input arriving, or sensing goes idle after a second. Timers
  paced for a person shrink too: at 60x a held talk-back key is cut off after
  half a second, so talk back to a scaled replay through the Talk back field.
  A capture still takes its real time, so at a high scale one is nearly always
  in flight, and a change moment that lands during one can be missed; use a
  low scale around window switches and the advance directives below for long
  waits.
- `--advance-clock <interval>` starts the clock that far ahead: `90s`, `15m`,
  `2h`, `1d12h`, up to `30d`.
- The debug panel's Mentor card has an **Advance** field (accessibility label
  "Advance clock"): type an interval and press Return, and the clock moves
  ahead at once, as if that much time went by with the Mac awake in the mode
  Mentor is in; the seconds since the last input are the system's, so moving
  ahead never makes sensing idle by itself. Every wait due in it ends: a toast
  expires, a snooze or the spend cap releases, the next capture falls due.
  While watching it counts as active use toward the next refresh; while paused
  or idle it counts nothing; and past midnight the next observation expires the
  understanding.

A replay's clock never starts behind its own journal. A faster or advanced
session leaves rows stamped ahead of real time, so a relaunch carries on from
the newest of them, then moves `--advance-clock` further, rather than going
back in time. Delete the replay directory to start from real time again.

The menu bar and the debug panel's Replay badges read **Replay 60x** while the
clock is scaled, and the menu's Clock line and the Mentor card's Clock field
say how fast it runs, how far it was moved ahead, and, in the card, the date it
reads. A launch that asked for a replay it could not start keeps the replay's
journal, and so its clock. Either flag on a live or recording launch is
refused: the app runs on real time, and the menu, the Mentor card, and the log
say why, so a live or recording run can never use a controlled clock. A replay
given a flag value it cannot use says why in the same places, and runs on its
own clock at real time with nothing added ahead: it still carries on from its
journal, and the Advance field still moves it.

The tests run on the same kind of clock with no real time at all: an
`AdjustableClock` made with a start date stands still until a test advances
it, a sleep on it ends exactly when an advance reaches its deadline, and
`waitForSleepers` lets a test advance it only once the code it drives is
waiting. No test sleeps: a refresh after fifteen minutes of use across a pause
and a closed lid, a snooze running out, the spend cap releasing at the top of
the hour, a toast's paused countdown, a callout aging out, and expiry at a new
day are each proven in milliseconds.

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
never spends anything. Those refused calls are journaled as live errors that
cost nothing, not as replays. The menu bar shows **Recording** beside the eye
while it runs. `make clear-recordings` deletes the app's own recordings
directory, `~/Library/Application Support/mentor/recordings`.

Any call the loop makes through its single call path (`MentorLoop.perform`) is
recorded under its tier's raw value and replayed by that name, and neither
client knows the list of kinds. The periodic understanding refresh (tier
`understanding`, see Standing understanding) and the follow-up question about a
suggestion (tier `followUp`) are recorded and replayed that way with no change
to either client, and so is any call a later phase adds: each needs only a
fixture of its kind in the replay directory, and a replay without one refuses
that kind of call by name. A replayed refresh becomes the next revision like a
live one, and its cost, like every replayed call's, is zero.

### The committed fixtures

`Tests/MentorCoreTests/Fixtures/Replay` is a small set recorded live from a
staged, synthetic scenario (see its README), never from anyone's real work, on
the cheapest models whose answers are worth replaying for every call kind (its
README names them). `ReplayLoopTests` runs the whole loop against it: every
triage fixture in turn, the mentor calls they lead to, the understanding each
mentor reply rewrites, the suggestion, its feedback, the journal rows, zero
spend, and the cycle starting over, and a periodic refresh answered by the
understanding fixture. `ReplayInterventionTests` replays the mentor reply's
region into a placed callout and the recorded follow-up answer. The same tests
fail when a file carries anything shaped like a key, or an em dash, and when the
set has no shown suggestion with a region or no follow-up answer.

They also fail when the set is not current: a fixture recorded with another
prompt version than `MentorPrompts.version`, or a tier with no fixture, fails
`swift test` with a message naming each stale fixture with both versions and
each tier with no fixture. The loop replay is strict, as the app's is.
`make fixture-status` runs that check on its own, with no network.

So when a prompt or schema change bumps the prompt version, or a new call kind
is added, re-record the committed set live in the same change so the tests
pass. It is a deliberate `make record` session of a few cents, on a staged
scenario and an empty journal:

1. Quit Mentor and move the journal aside (keep it to put back). Triage and
   mentor requests carry recent journal events and screens, so a recording made
   on a lived-in journal carries that history too.
2. Stage a synthetic scenario in real windows that fill the display (the
   documents in the fixture directory's `scenario/` folder work), and add every
   other running app to Settings > Privacy > Excluded apps.
3. Run `make record RECORD_DIR=recordings`, drive it through a moment worth a
   look that yields a shown suggestion pointing at one spot, a quiet moment, a
   follow-up question typed into the debug panel's Talk back field, a Test
   Connection, and one call of every other kind, then quit. Drive it without
   keystrokes (TextEdit scripting and accessibility actions), so no other app
   takes the front and reaches a request's event history; raise the idle
   threshold for the session so sensing does not stop behind it. For the
   `understanding` kind, set Settings > Mentor > Refresh at most every to its
   lowest value before recording and leave the scenario in front for that whole
   interval after the last mentor call; setting Settings > Cadence > Idle after
   above the interval keeps the loop watching with no input. Add Mentor itself
   to the excluded apps, so opening Settings for Test Connection is never
   captured.
4. Read every file, text and screenshot, and every reply for quality (a model
   can fill a required field with an empty string), replace the fixture directory's
   recordings with the ones you keep, update its README, delete the rest, put
   the journal and settings back, and run `make fixture-status` and
   `swift test`.

`ScriptedClaudeClient` stays for unit tests that need one exact hand-written
answer, such as a refusal, an unparseable reply, or a slow call.

## Permissions

Mentor needs two permissions and explains each in a first-run window that
opens whenever one is missing. The window triggers each missing sensing
permission's system prompt once when it opens, so Mentor appears in both
System Settings lists, shows live status, deep-links to the matching System
Settings pane, and re-checks every second while open and when the app regains
focus. Two more are optional and serve only talking back; the window lists
them below the required pair and asks for them only when you press Grant or
first hold the talk-back key.

| Permission | Used for | Without it |
| --- | --- | --- |
| Screen Recording | ScreenCaptureKit capture of the display containing the focused window, then Vision OCR | Accessibility-only mode: app, window, and focused element are still sensed; no frames |
| Accessibility | Focused app, window title, focused element role and text, via the AX API; the live window frame a callout is checked against | Screen-only mode: frames and OCR only; app identity comes from NSWorkspace; no callouts, since the window cannot be verified |
| Microphone (optional) | Hearing you while the talk-back key is held | Talking back is off; a key press says so |
| Speech Recognition (optional) | Turning that audio into text on this Mac with the system recognizer, on-device only | Talking back is off; a key press says so |

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
  Mentor/                     MentorScheduler (pure trigger, debounce, and gate state machine, including the
                              refresh gate), SpendMeter, SuppressionRules (snooze and never-for-this),
                              MentorshipContexts (declared contexts, normalizing, placement), ContextBuilder
                              (rolling window, prompt text, follow-up message), Prompts (versioned system
                              prompts and output schemas), Understanding (the standing record, its bounding,
                              rendering, and expiry), Suggestion, FollowUp and ModelCallRecord, Callout
                              (CalloutRegion, CalloutAnchor: frame-to-screen mapping and every rule that
                              refuses a callout), TalkBack (TranscriptMatcher, FollowUp, TalkBackState),
                              ToastCountdown (a toast's countdown, held and resumed), MentorLoop (orchestration)
  System/                     PermissionProbe (all four permissions), InputActivity (idle seconds),
                              ProcessResources (CPU, memory), MentorClock (the one time source: SystemClock,
                              and AdjustableClock for tests and a replay), ClockMode (a replay's clock flags)
Sources/Mentor                the app: MenuBarExtra, AppState, windows, ToastController (floating panel),
                              Overlay/CalloutController (click-through overlay), Voice/SpeechListener
                              (on-device speech recognition), HotKeyCenter (Carbon, press and release),
                              Snapshots
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

The mentor loop adds five tables: `suggestions` (every suggestion shown, with
the user's feedback, the inferred goal it was judged against, the region it
pointed at if any, and whether a callout was drawn), `model_calls` (one row per
API call: tier, model, prompt version and size, token counts, estimated cost,
latency, outcome, the model's one-line reason, and whether it was replayed;
never the prompt text), `understanding` (one row per revision of the standing
understanding, see below), `refresh_period` (a single row: the active use
counted toward the next understanding refresh), and `follow_ups` (one row per
question talked back: the transcript, the answer or why there is none, and the
model). A moment held at the context boundary is recorded in `model_calls` as
the `outOfContext` outcome. All five expire with `textRetention`, the
understanding goes with the oldest observations and events in a size-cap sweep,
and all five are emptied by Clear Journal. A journal written by an earlier build
is migrated in place when it is opened: missing tables are created and columns
added or dropped, so nothing has to be thrown away.

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
   currently suppressed for the app, the standing understanding as its own
   system block, and, when `sendThumbnail` is on, the latest kept thumbnail as
   an image. While mentorship contexts are enforced the message also names the
   declared context the moment was placed in, with its description, so the
   suggestion stays useful for that work. The reply is `{"reason": string,
   "suggestion": null | {title, body, explanation, category, confidence,
   judged_goal, region}, "updated_understanding": {...}}`. A null suggestion is
   the normal outcome, and a null region is the normal suggestion; the region is
   filled only when the suggestion is about one specific spot visible in the
   attached screenshot (see Callouts). The understanding comes back on every
   call.

   Each tier has its own model and effort in Settings > Mentor. Effort (low,
   medium, high, extra high) goes out as `output_config.effort` only to models
   that accept it; Haiku 4.5 rejects the parameter, so its effort control is
   disabled and nothing is sent. Thinking is left at each model's default
   (adaptive on Sonnet 5, Opus 5, and Fable 5.1); no thinking configuration is
   sent.

5. **Delivery.** A suggestion under `minimumConfidence`, in a snoozed or
   never-for-this category, with an empty title or body, or in a goal category
   with no goal to judge against (see Standing understanding) is logged and
   dropped. Otherwise it is journaled and shown as a toast: a floating,
   non-activating panel under the menu bar that never takes keyboard focus and
   auto-dismisses after `toastTimeout` (60 s;
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

The system prompts and output schemas of every tier live in
`Prompts.swift` under a version number that is stored with every call and
suggestion. Each system prompt carries a `cache_control` marker, and the
request encoder sorts keys so the cached prefix is byte identical between
calls. Caching only engages above
a model's minimum cacheable prefix (512 tokens on Claude Fable 5.1 and Opus 5,
1024 on Sonnet 5, 4096 on Haiku 4.5), so in practice the mentor prompt is
served from cache within its five-minute window and the small triage prompt
is not; the marker stays so a triage model with a lower minimum benefits.
Menu > Show Last Suggestion brings a missed toast back; a toast asked for
that way never expires on its own, and a non-answer never overwrites an
answer already given. The API key is read from the Keychain inside the loop
and passed per request; it is never journaled or logged.

### Callouts

A suggestion that is about one specific spot on screen can point at it. The
mentor output schema carries an optional `region`: a bounding box in the
pixel coordinates of the frame the model saw (the message states the frame's
size) plus a note of a few words, such as "this flag". The prompt tells the
model to leave it null when no screenshot is attached, when the suggestion is
about the work as a whole, or when it is not sure where the spot is, because
a box on the wrong thing is worse than no box. The loop keeps a region only
when an image was actually sent and the box lies inside the frame; anything
else is dropped before the suggestion is journaled.

Placing the callout is `CalloutAnchor`'s job, a pure function the app feeds
live readings to. The region is mapped through the observation's `FrameInfo`
into global display points with the same scale OCR blocks use, so a region
that covers a recognized line lands exactly on that line's `screenRect`. The
callout is then drawn only when every check passes, and the first failure is
the recorded reason:

- the region is inside the frame and at least a few pixels in each dimension;
- the display the frame came from is still attached with the same bounds;
- the screen under the spot was last confirmed unchanged no more than two
  minutes ago (`CalloutAnchor.maxFrameAge`; see below for what confirms it);
- the observation recorded the window's frame, which needs Accessibility;
- the same process is frontmost and a fresh accessibility read shows the same
  window (bundle identifier and title) with its frame within two points of
  where it was captured;
- the spot's centre lies inside that window.

While a callout is up the app repeats the check once a second, and takes the
callout down the moment a check fails: the window moved, another window or app
came to the front, the display configuration changed, or the frame aged out.
A window can also change without moving: a terminal scrolls, a document is
edited. `CalloutWitness` watches for that. Every frame the sensing pipeline
keeps of the same window must still show the recognized text the region
framed within a few pixels (`CalloutAnchor.contentStillMatches`), or the
callout comes down with "content under the spot changed". Such a frame also
confirms the screen, and so does each capture the pipeline then drops as a
near duplicate of it, because it drops one only when the picture, the window,
and the focused text are all unchanged. Staleness counts from the latest
confirmation, so a callout over a screen nobody touches stays up with its
toast, through a follow-up question, while one that nothing has confirmed for
two minutes comes down. The callout also goes
away whenever the toast does, for any reason. Menu > Show Last Suggestion
re-shows the callout only when its anchor still passes.

The overlay itself is `CalloutController`: a transparent, borderless,
non-activating panel above normal windows on the display the frame came from,
with `ignoresMouseEvents` set, so it never takes focus and never intercepts a
click, key, or scroll. It draws a tinted rounded box with a soft glow around
the spot and the note in a material pill beside it, to its right, where the
rest of a line of text is usually empty (below the box, or above it at the
bottom of the display, only when there is no room), styled like the toast. Mentor's own windows are excluded from
capture, so the overlay never appears in a frame. Settings > Mentor > "Show
callouts on screen" (on by default) turns callouts off; the history window
records for each suggestion whether one was drawn, and the debug panel's
Mentor card shows the last callout decision with the region in frame pixels
and in screen points.

### Talking back

A push-to-talk hotkey, recorded in Settings > Mentor the same way as the pause
hotkey and unset by default, captures the microphone only while it is held.
Carbon's hotkey registration delivers both `kEventHotKeyPressed` and
`kEventHotKeyReleased` for a combination it registered, so `HotKeyCenter`
hears the key go down and up without Input Monitoring or any other
permission beyond the two optional ones. The same combination cannot be both
the pause and the talk-back key; the recorder refuses it and validation
clears it. A recording is cut off after 30 seconds in case the release is
missed.

Audio goes to `SFSpeechRecognizer` for the current locale with
`requiresOnDeviceRecognition` set, so nothing is sent to Apple's servers. When
the locale has no on-device recognizer, Settings and the menu say so plainly
and the feature stays off rather than falling back to server recognition.
While the key is held the toast shows a listening indicator and the live
transcript. The toast being talked to is never hidden while voice input is
active: from the key going down until the transcript is handled or the answer
is shown, it does not expire, a click elsewhere does not dismiss it, and it is
kept in front of other windows; afterwards it stays up until it is closed,
like an expanded one, and no new suggestion replaces it until then (see
below). Each recording is its own session: a recognizer result or timeout left
over from an earlier one is ignored, so a re-press never hears the previous
question again.

When the key is released, `TranscriptMatcher` reads the whole utterance,
lowercased, without punctuation, and with filler words such as "please"
trimmed from the ends. "Tell me more", "not now", and "never for this" (and
close variants: "more", "later", "no thanks", "never again", "don't show this
again") perform that answer; "never mind", "close it", and "got it" close the
toast. Anything else becomes one follow-up question to the mentor tier: the
suggestion (title, body, explanation), the exchange so far on that suggestion,
the recognized text of the screen the suggestion was made from when the
journal still has it, and the transcript, on the mentor model and effort,
with structured output `{"answer": string}`. The answer appears in the toast's
exchange area; an empty answer is journaled as an error and the toast says
so. The call is
journaled in the model call log with the `followUp` tier and counted against
the hourly spend cap like every other call; the same gates that hold both
tiers (off, paused, idle, excluded app, no key, the cap) hold a follow-up,
which is then journaled with the reason and never sent
(`MentorScheduler.followUpGate`). A question released while another call is
in flight is not refused: the toast says it is waiting, and it is asked as
soon as that call returns. At most one question waits; pressing the key again
withdraws it and the new question takes its place, and closing the toast or
pausing withdraws it too, in neither case journaling anything. The key does
nothing with no suggestion to talk back to except a brief note in the toast
area, and with no toast up it brings the most recent suggestion back to talk
to. The history window shows the full exchange under each suggestion, and the
debug panel's Mentor card shows the last transcript and what was done with it.

A suggestion the mentor tier finishes while a talked-to toast is up never
replaces it. `MentorScheduler.publishGate` holds it, leaving the toast, the
recording, the pending answer, and the answer on screen untouched; the
exchange ends only when that toast is closed, by the user answering or
dismissing it. A press that hears nothing, or a recording cut short by
pausing, is not an exchange (`TalkBackPress`): the toast gets back whatever
countdown it had (still paused while the pointer is over it), and anything
held in the meantime is shown at once. Show Last Suggestion during a recording
on a different toast ends it the same way; on the toast already on screen it
only brings that toast to the front and does not end its own exchange. The
toast it brings back stays up until closed, as it always does. Otherwise the
held suggestion is shown normally if it is at most 30 s old (the same staleness
bound as a queued observation); otherwise, and
whenever Mentor is paused while one is held, it is journaled with the feedback
"Expired, never shown" and never put on screen, since the screen it describes
is gone. Such a suggestion still appears in the history window but is skipped
by Show Last Suggestion and by a key press with no toast up, which bring back
the most recent suggestion that was actually shown.

The Mentor card also has a **Talk back** field. Words typed there and sent take
exactly the path a released key does, from transcript matching to the
follow-up call and the answer in the toast, so the whole path can be
checked, in a replay or while recording a follow-up fixture, on a Mac where
Microphone and Speech Recognition are not granted.

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
standing understanding (below) stands behind the same boundary: a moment
outside every context neither reaches the mentor tier that rewrites it nor
buys a refresh of its own. The schema offers only the declared names, so the
model cannot answer with a context that does not exist. The declared list is part of the triage system
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
nothing about it can reach any tier.

The menu bar menu shows the current verdict (`Context: inside "writing Swift"`,
or why it is out) while it is still about the frontmost app, and
`Context: not yet judged in <app>` otherwise; the debug panel's Mentor card
shows it with the app it was made for and its age, and the model call log marks
a held call with the `outOfContext` outcome.

### Standing understanding

A mentor call used to see only the last ten minutes, so it could tell you a
faster way to do the thing on screen but never whether that thing would get
you where you were going. Mentor now keeps a short record of the longer arc
and carries it from one call to the next.

**What it contains.** The model writes it, in four parts: the **goals** the
user appears to be working toward, most likely first, each with the evidence
for it and a confidence; a condensed **timeline** of what has happened; the
**mentor history**, what Mentor has already said and how the user answered, so
it never repeats itself or re-raises something dismissed; and **open
concerns** worth watching but not worth an interruption. `Understanding.swift`
holds the type and the pure functions for bounding, rendering, and expiry.

**How it is refreshed.** Every mentor call returns `updated_understanding`
alongside its verdict, so the record is rewritten on the way past and that
refresh costs nothing beyond the call that was made anyway; its screen window
takes every observation journaled after the ones the record's last write read,
so the rewrite folds in everything since. Each revision stores the highest
observation id its call read as that cursor rather than a time, because a
screen is stamped when its capture starts and journaled only after OCR, so one
captured before a call read the journal can land in it after. A **periodic
refresh** (`understandingRefreshInterval`, 15 minutes by default) runs only
when a whole interval of active use has passed with no mentor call to carry
it. Active use is time spent capturing the screen: a break, a pause, a
sleeping Mac, an excluded app, missing permissions, or a closed app counts for
nothing, so coming back never buys a call over the few screens since. The count is kept
in the journal, so a relaunch carries on from it. It is a third tier with its own model and effort picker (`claude-opus-5`
at low effort by default; Haiku 4.5, Sonnet 5, and Fable 5.1 are offered too), its own versioned prompt and
schema, and no screenshot: summarising does not need one. `refreshGate` in
`MentorScheduler` is the single decision, and it holds while the loop is off,
paused, idle, on an excluded app, waiting for permissions, without a key, over
the spend cap, mid-call, not yet due, or before anything has been observed.
While mentorship contexts are enforced it also holds until triage has placed
the frontmost app inside a declared context, and for as long as the last
placement was outside every one, so activity outside the contexts never buys
a refresh; the mentor tier never runs for such a moment either, so neither
path that writes the record is reached from outside them. A refresh attempt
starts the interval over whatever came of it, so a failed call waits a whole
interval like the other tiers rather than retrying on the next observation. Refresh calls appear in the model call log and count
against the hourly spend cap like every other call.

**How it is used.** The record goes to the mentor tier as its own uncached
system block after the cached prompt: every mentor call rewrites it, so the
block changes on every call and a cache marker on it would never be read,
while the prompt before it keeps its marker. Triage receives the same record
as one compact paragraph in its user message, enough to notice an action that
conflicts with the goal without paying for the whole thing. Three suggestion
categories judge the current action against the inferred goal:
`wont_achieve_goal`, `less_efficient`, and `unwanted_side_effect`. They are
raised only when there is an understanding to judge against, they carry the
goal they were judged against (shown in the history window), and "Never for
this" suppresses each one per app exactly like every other category.

**Size and lifetime.** `understandingTokenBudget` (1200 tokens, settable up to
3000 so a mentor reply keeps room for its thinking and a suggestion beside the
record) bounds it: the model is told the budget and the app trims to fit on
the way in, dropping the
oldest timeline entries first, then the oldest mentor history, then concerns,
then the weakest goals, always keeping the strongest goal. It expires after
`understandingIdleGap` with no activity (4 hours) and always at a new day;
expiry and reset are journaled.
**Reset Understanding**, in Settings > Mentor and in the debug panel, forgets
every revision at once. Revisions are inserted rather than updated, so the
journal keeps the trail of how the reading developed, and the current one
survives a relaunch.

**What it costs.** The common case is free: a mentor call was going to happen
anyway and the record rides along in its reply, paying only for the extra
output tokens it writes. A periodic refresh is one call on the understanding
model, text only. Measured on 2026-09-13 writing the first record from a
15-minute window: 12,899 input and 1,161 output tokens, $0.09, 70 seconds on
Claude Opus 5 at low effort. So an hour of reading and browsing with no mentor
call in it costs about $0.38 in refreshes against the $1 default cap. Raise
the interval, or pick Claude Haiku 4.5 for this tier, to spend less; both are
in Settings > Mentor. Like the mentor tier, a refresh holds triage while it
runs, so a long one costs a change moment or two as well. The debug panel's
Understanding card shows the revision, when it was last written, which path
wrote it, its size against the budget, and what refresh calls have cost since
this understanding began.

### Spend control

Every response's usage fields (`input_tokens`, `output_tokens`,
`cache_creation_input_tokens`, `cache_read_input_tokens`) are priced with the
table in Settings > Mentor (dollars per million tokens, defaults checked
against Anthropic's pricing page on the date shown there, editable) and added
to a per-clock-hour total. As the total approaches `hourlySpendCap` ($1 by
default) both minimum intervals and the refresh interval stretch by
`1 / (1 - spent / cap)`, capped at 8x: 2x at half the cap, 4x at three
quarters. At the cap no call is made until the next clock hour. The hour's total is seeded from the journal at launch, so
relaunching does not reset it. Spend this hour shows in the menu, the debug
panel status bar, and the Mentor card. Replayed calls cost nothing and are never
counted (see Iterating without the network).

## Privacy model

- Sensing stays on this Mac: the journal, thumbnails, and settings never leave
  it. The only network peer is `api.anthropic.com`, reached only by the mentor
  loop, only when an API key is saved and the loop is enabled. No other part
  of the app has network code.
- **Audio and transcripts stay on this Mac.** The microphone is open only
  while the talk-back key is held, and only the system's on-device recognizer
  ever hears it; audio is never stored. The one exception is deliberate: a transcript you spoke while holding
  the key (or typed into the debug panel's Talk back field), when it is not
  one of the toast's answers, is sent to the mentor tier as your follow-up
  question, together with the suggestion it is about,
  the earlier questions and answers on that suggestion, and the recognized
  text of the screen the suggestion was made from. Transcripts are journaled
  locally with the answers so the history window can show the exchange.
- **What leaves the machine.** The triage tier receives text only: the
  frontmost app and window title, the accessibility summary (focused element
  role and an excerpt of its text), the OCR text of the latest kept
  observation (cut at 6000 characters), and a compact summary of recent
  journal events. The mentor tier receives the rolling window of recent
  observations' text (app, window, accessibility summary, and OCR text of
  each, reaching back to the window duration in Settings and taking every
  screen journaled since the standing record's last write read the journal,
  bounded by the token budget with the oldest left out and said so when the
  record does not already cover them) and, by
  default, the latest kept thumbnail as a JPEG image. "Send the latest
  screenshot to the mentor model" in Settings > Mentor turns the image off, in
  which case the mentor tier receives text only. While mentorship contexts
  are enforced, the mentor tier also receives the name and description of the
  declared context the moment was placed in. The understanding refresh tier
  receives the current record, every screen journaled since its last write
  read the journal (the oldest left out, and said so, when they exceed the
  window's token budget), the event summary, and the app, title, and category
  of recent suggestions with the user's answers; never an image. The triage,
  mentor, and refresh tiers also receive the standing understanding itself, which is the model's own prose about the
  work, never raw screen text. Nothing else is sent: no file names, no
  keystrokes, no earlier thumbnails, no key.
- **The understanding is model-written prose about the work**, kept in the
  journal on this Mac like everything else, readable in full in the debug
  panel, bounded by its token budget, expiring with the idle gap and at a new
  day, and removable at any time with Reset Understanding or Clear Journal.
  The menu bar menu shows its strongest goal, clipped, alongside the debug
  panel and Settings > Mentor, whenever Mentor is on and has a key.
  Both prompts that write it, the mentor prompt and the refresh prompt, tell
  the model to leave out anything private, financial, medical, or personal,
  and anything about other people on screen.
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
  was excluded, so nothing from them can reach any tier.
- Secure text fields are never read, even in non-excluded apps, so their
  contents never reach any tier.
- Model calls are journaled as counts (tokens, cost, latency, outcome) with the
  model's one-line reason, or the first line of a follow-up answer, never with
  the prompt or the screen text that was sent.
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
tokens, estimated cost and latency, spend this hour, the cadence state with
the current slowdown, the last callout decision with its region in frame
pixels and screen points, and the last transcript with what was done with
it), the Understanding card (revision, when and how it was last written, the
inferred goals with their evidence and confidence, the timeline, what has been
said and answered, open concerns, when the next refresh is due or why it is
held, size against the budget, cost since it began, and Reset Understanding),
focused element
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
ones), and each replayed call in the log is tagged Replay and not billed. In a
replay the Mentor card shows what the clock reads and has the Advance field
that moves it ahead, and the badge says how much faster the clock runs when it
does (Replay 60x; see A faster clock).

## Continuous integration

`.github/workflows/ci.yml` runs `swift test`, the bundle script, and
`Mentor --snapshot` on GitHub's `macos-26` runner, which ships Xcode 26 and the
macOS 26 SDK this package targets, and uploads the rendered PNGs, replay-mode
renders on a scaled clock included, as the `ui-snapshots` artifact. No test
waits on real time (see A faster clock). The tests exercise the pure
parts (hashing, cadence, journal, retention and its in-place migration,
settings, the mentor scheduler and every gate, mentorship context rules and
placement, spend accounting, snooze and never-for-this rules per category, the
rolling window, the understanding's encoding, versioning, bounding and expiry,
prompt assembly with and without one, request and response coding against
fixture JSON, recording, redaction, replay matching and stale refusal, launch
flags, a replay's separate files, the clocks and a replay's clock flags, the
toast countdown, callout mapping and every anchor rejection, a callout aging out,
transcript matching, the follow-up prompt and gate, the toast rule for voice
input, the whole loop against a scripted client, follow-ups included, and the
whole loop against the committed replay fixtures, replayed strictly, a region
and a follow-up answer included, and every time-based behavior of the loop on
the test clock) and Vision OCR on a drawn bitmap, so they need no permissions,
display, network, microphone, or API key. A committed fixture
that is stale, or a tier with no committed fixture, fails the run (see The
committed fixtures). The snapshot run covers the callout over the sample frame,
the listening and answered toasts, and the talk-back settings.
