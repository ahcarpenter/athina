# End-to-end harness

Checking Athina against the real app is what takes the time, not building it:
a scratch home has to be prepared, the app launched in replay under a sandbox,
a toast waited for, a real click posted, and the journal read. Every one of
those was written again by hand for each check until now.
`scripts/e2e/athina-e2e` is that work, once, in the repository. A change, a
check, or a validation run drives the app through it rather than writing its
own driving code.

```sh
scripts/e2e/athina-e2e warm          # once per machine: prepare the warm home
scripts/e2e/athina-e2e list          # the scenarios and what each one proves
scripts/e2e/athina-e2e run all       # run them; one JSON line of result each
scripts/e2e/athina-e2e run --jobs 4 all   # up to 4 API-tier scenarios at once
scripts/e2e/athina-e2e run --tier api     # every API-tier scenario, as CI's e2e-api runs them
scripts/e2e/athina-e2e run --tier screen  # every real-screen scenario
scripts/e2e/athina-e2e run toast-menu-answers
scripts/e2e/athina-e2e doctor        # what is missing before a run
scripts/e2e/athina-e2e journal suggestions   # a named query over the last run
```

Every run is replay only: no API key is read, no network is reachable inside
the sandbox, and nothing is billed. The real-screen tier needs a person's
screen and runs only on a Mac; CI's `e2e-api` job runs every API-tier scenario
on the runner, and compares their checkpoints with approved baselines (see
Checkpoints), and CI runs the harness's unit tests with the rest of the suite.
`ATHINA_E2E_APP=<bundle>` runs the scenarios against another bundle than
`build/Athina.app`, such as the hardened release build (see Releasing), which
the harness then checks as it is rather than rebuilding. A bundle without the
control API, as every release build is (`scripts/check-no-control-api.sh`
decides), cannot run the API tier, so each API-tier scenario reports `skip`
with that reason, neither passed nor failed, and the run's tally counts it
apart. Only such a bundle skips: `build/Athina.app` is the development bundle,
so when it carries no control API, as after `scripts/bundle.sh --no-control`,
the harness rebuilds it with the trait, or stops when something runs from it.

What is on the screen is serialized machine-wide, and nothing else is. Each
real-screen scenario first takes one exclusive lock,
`~/Library/Caches/athina-e2e/screen.lock`, for as long as it runs, so only one
session is on the screen at a time across every checkout, and runs from
other checkouts take their turns between this run's scenarios; `warm` and
`clean` take it for all they do. A second run prints who holds it (checkout,
scenario, pid, since when) and waits. A scenario that sets
`SCENARIO_IDLE_FIRST=yes`, as `real-screen` does, first waits for 15 seconds
of quiet keyboard and mouse, before it takes the lock rather than
inside it, so no other checkout waits behind it while someone is at the Mac;
input that comes back while it waits for the lock gives the lock back until
the Mac is quiet again. After 15 minutes of waiting for quiet in all (the
lock waits between do not count), the scenario fails with "could not take the
screen lock". `--lock-timeout <seconds>` gives up instead; `list`, `doctor`,
and `journal` never wait. An API-tier scenario is
hermetic (see Hermetic runs) and takes no lock at all, so any number run at
once, beside each other, beside a real-screen run, and beside whoever is using
the Mac: `run --jobs <n>` runs up to `n` of them at a time, with the
real-screen scenarios one at a time beside them, and each scenario's log lines
carry its name. `run` and `warm` build `build/Athina.app` and `athina-drive`
when a source file was saved after the last build of each started (for
athina-drive, the harness's own; for the app, any `scripts/bundle.sh` build,
`make build` included), and the API tier's copy of the app when the app is not
the one it was made from, before any scenario starts, so no other checkout
waits on this one's build: the log says "building ... before taking the screen
lock", then "took the screen lock". They build again inside the lock only when a
source file was saved after that build started, and say so; a touch-only edit
builds each once. So call the
harness bare: a hand-held `lockf` around it holds the lock through the build
too. Before they build, `run` and `warm` take their checkout's own lock,
`build/athina-e2e.lock`, the same way, and keep it to the end, so a second
run from the same checkout says who holds it and waits rather than build over
the bundle the first runs from; runs from other checkouts never wait on it.
Under a hand-held `lockf` on the screen lock the order is turned round, so
such a run takes its checkout's lock only if it is free, and otherwise stops
at once naming the run that holds it, rather than wait on a run that waits on
it.

Scenarios come in two tiers, which each scenario names in `SCENARIO_TIER`:

- **API** (`api`): the harness drives Athina through its control API (see The
  control API). The app finds a control in its own accessibility tree and
  clicks or types into it through its own event path, so the check still
  proves the control can be hit and is wired, with no real pointer and no wait
  for the keyboard and mouse to go quiet. The run is hermetic (see Hermetic
  runs): it stages nothing, posts no input, shows nothing, senses only what
  the scenario scripts (see Scripted sensing), and takes no lock.
- **Real screen** (`screen`, the default): real HID clicks and presses through
  accessibility from outside, for what only macOS's own routing can prove: the
  menu bar item and the menu the system runs for it, clicks in other apps that
  reach Athina only through a system-wide listener, and the item's width in
  the real menu bar.

`run --tier api|screen|all` runs every scenario of that tier, or, with
scenarios named, those of them on it; `all`, as when no tier is given, runs
both. A validation's live evidence runs the API tier for anything in
Athina's own windows (the menu as the app builds it, the toast and its
buttons, Settings, the debug panel, the About panel): `run --tier api
--jobs 4`, or the API-tier scenarios the change touches by name. It holds no
lock, shows nothing and never waits on whoever is at the Mac. The real screen
is only for what the API tier cannot prove, a change to the menu bar item,
toast dismissal, the Settings links or sensing: `run real-screen` for the
first three, and `run --tier screen`, which adds `capture-race`, for sensing.
A change that touches none of those takes no screen time.

## Scenarios

| name | tier | what it proves |
| --- | --- | --- |
| `real-screen` | screen | everything only macOS's own routing proves, in one scenario, each step named in its checks: (1) a toast comes up; (2) an accessibility press on the menu bar item keeps it; (3) a real click on the item keeps it, and the menu macOS draws matches the one the app built as the control API reads it; (4) Answer Suggestion > Tell Me More by hovering the submenu is recorded; (5) on a new suggestion from a relaunch, since the journal keeps only a suggestion's first answer, Show Last Suggestion, then a real click on empty menu bar space dismisses the toast, recorded as dismissed and attributed to a real mouse-down by a session tap; (6) Show Last Suggestion again, then a real click in a staged TextEdit window dismisses it, attributed to a real mouse-down, and the answer step 5 recorded stays; (7) the item keeps one width watching, in the excluded mode and paused, read from the real bar, with strips of the bar kept as evidence of what is drawn; (8) a real click on each Settings footer link (Contexts to Privacy, Models to Journal) changes the pane in place rather than handing the link to the system. On a quiet Mac it holds the screen for about a minute and a half |
| `toast-menu-answers` | api | with a suggestion up from scripted sensing, the menu's Answer Suggestion offers every answer; Tell Me More from it opens the explanation and keeps the toast up, Not Now is recorded and takes the toast down, and the answers are dimmed, and refused, once no suggestion is up |
| `toast-buttons` | api | clicks on the toast's own buttons: Tell Me More opens the explanation and is recorded once however often Show Less folds it; Close takes it down without writing over the answer; Not Now and Never for This are recorded and add a snooze and a never rule for that kind of suggestion in that app; and a click outside Athina's windows takes a toast brought back by Show Last Suggestion down |
| `about-panel` | api | About Athina, from the menu, opens the About panel, which shows the app's name |
| `capture-race` | screen | counts the change moments kept and dropped while captures are in flight, on a scaled clock (see "A faster clock"); a sensing scenario, kept apart from `real-screen`, for a change to sensing or its scheduling |
| `understanding-surfaces` | api | the understanding the mentor call behind a scripted suggestion writes reaches the menu, the debug panel's card, and Settings > Models; the section's duration rows line up and hold a typed amount to the range the setting accepts; its footer link's target opens the Journal pane in place (`open-link`); and Reset Understanding… asks first, keeps everything on Cancel, and forgets every revision on Reset |
| `debug-panel-access` | api | while Settings > Advanced > Enable debug panel is off, as it starts, the menu has no Debug Panel command and Open Debug Panel is dimmed, a click on it is refused, and one forced onto it opens nothing; turned on, the menu gains Debug Panel in a group of its own after Settings…, and it and the button each open the panel; turned off again, the panel closes and the command leaves the menu |
| `settings-pane-text` | api | every link from one Settings pane's text to another (Contexts to Privacy, Models to Journal) shows as a link to that pane rather than Markdown, and a click on the one below the fold is refused until the pane is scrolled to it |
| `settings-sheet` | api | Settings > Contexts' Add Context… brings up the New Context sheet; while it is up, a click on Add Context… under it is refused as covered, a name typed into the sheet's Name field lands there, and the sheet's own Cancel lands in the sheet and takes it down, adding no context |
| `debug-timeline` | api | the debug panel's Timeline, open from launch, lists each journal row once: its entry count matches the journal, and the startup Started row appears once rather than once from the journal load and again from the live stream |

A scenario prints one JSON line: its name, `pass`, `fail` or `skip`, how long
it took, every check it made, and the directory holding its evidence (transcript,
screenshots, event taps, announcements, and the journal as TSV and as a copy;
for an API-tier run, every request and answer in `api.log`, its checkpoints
in `checkpoints/<scenario>/` (see Checkpoints) and the other pictures it took
of Athina's windows, and what the harness saw of the screen in
`hermetic-windows.log` and `hermetic-bar.log`). A scenario that runs several
steps, as `real-screen` does, names each (`step`), so each check carries its
step (`step 5 a real click on empty menu bar space dismisses a new toast, and
that is recorded: the toast is gone after the click`), and a run that stops
early says at which step.

## The warm fixture home

A fresh scratch home has no text-recognition model cache, so its first capture
blocks inside OCR while the model compiles, and the journal fills with events
and no observations: measured at **93 seconds** on the owner's Mac.
`athina-e2e warm` pays that once into `~/Library/Caches/athina-e2e/warm-home`
(the `com.apple.e5rt.e5bundlecache` the compile leaves behind), keeps the
caches, and throws the session's journal away. Every real-screen run then
clones it with `cp -c`, an APFS copy-on-write copy that costs no measurable
time and no disk, and starts from an empty journal in a home of its own. An
API-tier run captures nothing, so it starts from an empty home and needs no
warm one. A run's **first capture
then lands in 1 second**. Re-warm with `warm --force` after a macOS upgrade.

## Drive helpers

`athina-drive` (`Sources/AthinaDrive`, built on demand) is the one
implementation of every step a scenario takes on the screen. It works by pid
only and never looks an app up by name.

| command | what it does |
| --- | --- |
| `permissions` | whether this shell has Accessibility and Screen Recording |
| `ready <pid>` | print `READY` once the app's menu bar extra exists |
| `windows <pid>` | the on-screen windows of a pid, with ids and frames |
| `toast <pid>` | the window id of the suggestion toast, or nothing |
| `bar [pid]` | menu bar extras and menu titles with frames, the gaps between neighbours, and a point on the bar that is on no item |
| `front` | the frontmost app and its pid |
| `activate <pid>` | bring a pid to the front |
| `ax <pid> <dump\|texts\|menuitems\|menu\|pressextra\|cancelmenu\|get\|press\|pressx\|focus\|set> [role] [match] [value]` | read or press elements through accessibility, with no pointer; `--scope` narrows the search; `menu` prints the open menu's rows as macOS shows them, a title and `enabled` or `dimmed` or `-` for a separator, the shape the control API's `menu` is compared in |
| `click <item <pid> \| at <x> <y> \| window <pid> <x> <y>>` | post a real HID click, aborting if the pointer is moved or the target is not what was asked for, and log the accessibility element and topmost window under it; a window that lets clicks through, such as a window manager's full-screen overlay, does not count as covering the target; `--shot <out.png>` captures the result |
| `raise <pid> [title]` | bring one of a pid's windows to the front, which journals a window switch |
| `close <pid> <title>` | close one of a pid's windows through its close button |
| `menupick <pid> <row> <item>` | hover a submenu row and click one of its items with the pointer |
| `tap <session\|pid> [pid]` | listen-only event taps (`tap session` for every mouse-down, `tap pid <pid>` for one app), which is what attributes a dismissal to a real click rather than a timeout |
| `announce <pid>` | log every `AXAnnouncementRequested` the app posts |
| `flip <x> <y> <w> <h>` | a click-through helper window that changes text and colour on `SIGUSR1`, so sensing has something to see |
| `journal <db> <query>` | a named read-only query over a journal (`journal - queries` lists them), including `capture-race` |
| `key <keycode>` | post a key press, with `--cmd` and `--shift` as modifiers |
| `shot <window <id> \| region <x> <y> <w> <h>> <out.png>` | capture a window by id or a screen region |
| `api <command> [key=value ...]` | one request to a replay's control API, in `ATHINA_CONTROL_DIR` (the harness sets it); prints the answer, or one field of it with `--field <path>` such as `elements.0.enabled`; exit 0 when the answer is ok, 1 when not, 2 when no app answered |

The maths and parsing behind them are a plain library (`Sources/AthinaE2E`)
with unit tests: the journal queries, the menu bar geometry, the capture-race
report, and the drive tool's argument handling. The queries are run against a
journal `Journal` itself creates, so a column renamed in the app fails the
suite rather than every scenario.

## The control API

An API-tier scenario drives Athina through a control API the app serves on a
Unix socket: `athina-drive api <command> [key=value ...]` sends one request
and prints the answer. Each value goes as its parameter takes it: `true` or
`false` for `force` and `present`, a number for `timeout`, JSON for `equals`
(`equals=true`, `equals=3`, and `equals='"30"'` for the text 30), and the text
as written for every other, so `text=30` types 30. The app answers a value of
the wrong type with an error naming its parameter, never carrying on without
it.

| command | what it does |
| --- | --- |
| `ping` | the protocol, the app's pid, and whether it is the active app |
| `windows` | Athina's open windows: title, number, frame, level, key and main |
| `find` | controls in `window=<title>` (every window when it is left out) by `identifier=`, or by `role=`, `subrole=` and `label=` (a control's description or title, whole, ignoring case), read from Athina's own accessibility tree: role, label, identifier, value, enabled, frame |
| `click` | a left click on the first such control, posted to the app's own event queue and dispatched by AppKit as a real click is after the window server; the answer comes once it has been handled. Refused as `disabled` when the control is dimmed, `offscreen` when a scroll area has it out of sight or it is outside its part of the window (the content, or the whole window for the toolbar and title bar), and `covered` when a sheet is up over its window or the window's own hit test at its centre lands on something else. A control inside a sheet is found under the title of the window the sheet covers, and judged against and clicked in the sheet. `force=true` clicks anyway, for proving a refusal |
| `press` | an accessibility press on the first such control, as VoiceOver or Full Keyboard Access presses it: its own action, with no pointer. For the one kind of control a simulated click cannot drive: AppKit lets a destructive button (Reset Understanding…) act on no click into a window that is not in front, and a hermetic run's never are. Refused as `disabled` when the control is dimmed and `unsupported` when it offers no press |
| `type` | `text=` as key presses to the first responder of `window=`, or of the sheet up over it, such as the field a click just focused |
| `scroll` | the scroll view holding a control scrolls it into view |
| `menu` | the menu bar extra's menu as the app builds it (`MenuModel`), without showing it, and with no menu bar extra at all in a hermetic run; `press="<title>"`, or `press="<submenu> > <title>"`, runs that item's command through the handler choosing it from the menu runs, refused as `missing` or `disabled`, naming the step, when an item or submenu on the way is not there or is dimmed |
| `settings` | the live settings, or one of them with `key=<path>` |
| `wait-setting` | waits until `key=<path>` reads `equals=<value>` |
| `wait-window` | waits until a window titled `window=` is open, or with `present=false` gone |
| `snapshot` | a PNG of one of Athina's windows at `path=`, taken as `--snapshot` takes one once macOS has finished animating the window open (up to two seconds): once three of the display's frames in a row changed nothing in it, captured until two captures in a row are the same picture, or, for a window that moves on its own, its last capture with `settled` false; never over an existing file. `appearance=light` or `dark` draws the app in that appearance for the picture and gives it its own back after |
| `outside-click` | a click outside Athina's windows at `x=`, `y=` (points from the top left of the main display, as frames are given), handed to the suggestion toast as its system-wide listener would hand it one, which a hermetic run does not have; `heard` says whether a toast was up |
| `observe` | what a hermetic run senses next (see Scripted sensing): `app=` and `bundle=` in front, in `window=`, showing `text=`, captured at once; or `idle=true` or `idle=false` alone, input going idle or coming back. `kept` says whether the capture was journaled, `why` why not, and `after` is the newest event's sequence before it, for a `wait-event` on what it brings. Refused as `unscripted` in a run that senses the real Mac |
| `wait-event` | waits for the first event named `name=` after the sequence `after=` (every event since launch when left out) whose fields hold every other argument: `wait-event name=feedback feedback=notNow`. The names are what the sensing pipeline and the mentor loop publish, each logged once the app has acted on it: `observation`, `focus`, `mode`, `event` (a journaled event, by `kind`), `status` (with the understanding's `revision` as `understanding`), `suggestion` (logged once its toast is up), `feedback`, `followUp` and `call` (by `tier` and `outcome`); the answer carries the event's `sequence` and fields |
| `journal` | one of the harness's named journal queries (`journal - queries` in the drive helpers lists them), `query=<name>`, answered from the app's own journal connection, which refuses any statement that writes: the `columns`, and the `rows` as objects keyed by column |
| `advance` | moves the replay's clock `seconds=` ahead, as the debug panel's Advance field does, and answers with the clock's time and how far it has been moved ahead in all |
| `open-link` | follows a link in the app's own text, found as `click` finds a control, through the handler a click on it runs, with the URL SwiftUI carries as its identifier (`open-link window=Models identifier=athina-settings:journal`). It proves where the link goes and that the app handles it; that a click reaches it stays a real-screen check. Refused as `missing` when the control is not a link and `unhandled` when the app has no handler for its URL |
| `hotkey` | `key=pause` or `key=talk-back` through the handler Carbon calls, pressed and let go, or only `phase=down` or `phase=up`; `heard=<words>` is what talking back hears while its key is down, since a hermetic run opens no microphone; refused as `disabled` when the key is not registered (unset, unusable, or taken), as Carbon then never reports it |

The waits take `timeout=<seconds>`, 10 unless given, and poll the app's own
state at a fixed real-time pace; the replay's clock is not involved.
`wait-event` reads a log of the newest 2,000 events the app has handled
(`ControlEventLog`), kept only while the API is served; the cadence
bookkeeping the pipeline publishes several times a second is left out of it.

The controls a scenario reaches carry accessibility identifiers
(`advanced.enableDebugPanel`, `debugPanel.timelineRow`; a link in Settings text
carries its URL, `athina-settings:journal`), which no one sees or hears and
which survive a change of wording. The exceptions are the controls the system
draws, which carry none a scenario can give them: the Settings window's toolbar
tabs, since SwiftUI does not carry a `Tab`'s identifier through to them, are
found by label (`label=Models`), and a window's title-bar buttons by subrole
(`subrole=AXCloseButton`). What a click cannot drive: a link
inside a SwiftUI Text follows neither a click the app simulates nor
accessibility's press, so following one stays a real-screen check
(`real-screen`, step 8), and `open-link` checks where it goes; and a
destructive button takes no click into a window that is not in front, as
AppKit keeps the click that only brings a window forward from destroying
anything, so `press` presses it.

**Who can use it.** The API lets a program click Athina's controls, type into
it, and read its state, so it must never reach anyone's own copy of the app.
It is served only when all of these hold, and otherwise refused with the
reason, which the menu, the debug panel's Mentor card and the log show as they
show a refused clock flag, and which the app also writes to stderr for the
harness (`ControlMode`):

- **The build carries it.** The server is its own target, `AthinaControl`,
  linked into the app only under the `ControlAPI` package trait.
  `scripts/bundle.sh` turns the trait on for the development bundle; the
  release build (`scripts/bundle.sh --no-control`, which `make release` uses)
  and the App Store build leave it off, and `scripts/check-no-control-api.sh`,
  which `make release` and CI run, fails a binary that carries it.
- **The launch is a replay**, which reads no key, keeps its own files, and
  bills nothing; a live or recording launch refuses `--control`.
- **The process is not sandboxed**, so a sandboxed build made from the
  development bundle refuses it too.
- **The directory is the harness's own for the run**: absolute, a real
  directory owned by you with mode 0700 exactly, holding the run's
  secret in `secret`, a file closed to everyone else, and short enough for the
  socket's path (103 bytes). The harness makes it with `mktemp` inside your
  per-user temporary directory, not the run's home, whose path is too long.

The app makes its socket, `control.sock`, inside that directory, open to you
alone. It answers a connection only from your own user (`getpeereid`), and a
request only when it carries the run's secret, compared in constant time; no
answer ever repeats a request, so the secret never comes back out.

## Hermetic runs

The harness launches every API-tier scenario with `--hermetic` beside
`--control`, which makes it a hermetic run (`ControlMode.isHermetic`): it
takes nothing from the real world and leaves nothing in it, so API-tier runs
need no lock and any number of them run at once, beside a real-screen run and
beside whoever is using the Mac. Measured on the owner's Mac, four copies of
`debug-panel-access` pass together in 5 to 6 seconds each, where one alone
takes 4, beside a real-screen scenario holding the lock. `--control` alone
serves the API to a launch that is otherwise a replay like any other, on the
screen, in the menu bar and sensing, which a real-screen scenario can drive
through the API too; `--hermetic` is read only with a `--control` the app
serves.

- **It shows nothing.** Every window goes below the desktop picture as it is
  ordered onto the screen (`WindowParking`, in the control API's target), the
  level `--snapshot` renders at: the window server still composites it, so it
  takes every click the API simulates and its checkpoints are the pictures a
  visible window gives, and nobody sees it. Moved any later, even at the end
  of the event loop pass that opened it, a window showed for a frame, and for
  the length of its opening animation. The item stays
  out of the menu bar (`MenuBarExtra(isInserted:)` is false), and the menu's
  content comes from `MenuModel`, which the menu bar extra draws everywhere
  else and the API's `menu` reads and presses here, with the same handler for
  each command. The app never makes itself the active app: every request to
  come forward goes through `AppActivation.request()`, which does nothing
  here. So its windows draw as an inactive app's do, in checkpoints too.
- **It senses only what it is told.** The pipeline runs with
  `SensingSource.hermetic`: no focus tracking, no read of input or
  permissions, and no capture, so a run never journals the screen of whoever
  is at the Mac, and never asks macOS about a permission; it has them all,
  and watches, sensing only what a scenario scripts (see Scripted sensing),
  until it is paused. Talking back hears only the words the API's `hotkey`
  gives it and opens no microphone.
- **It listens to nothing outside itself.** The toast has no system-wide
  click listener, so the owner's clicks cannot dismiss a toast they cannot
  see, and no hot key is registered with Carbon, where it would take the
  combination from every other app. The API's `outside-click` and `hotkey`
  run the same handlers instead.
- **It writes nothing to the owner's preferences.** The API tier runs
  `build/e2e/Athina.app`, a copy of the development bundle the harness makes
  under the identifier `com.ahcarpenter.athina.e2e`, signed ad hoc with a
  requirement on that identifier as the development bundle is, so its
  preferences are a domain of their own and the real `com.ahcarpenter.athina`
  stays byte for byte as it was. Every hermetic run shares that one domain,
  so a hermetic run keeps its choice of Settings pane to itself rather than in
  the preferences, where it would reach every other run's open Settings
  window. The copy needs no Accessibility grant: an app reads its own
  accessibility tree, and the API's clicks land, without one, and nothing asks
  anyone to click anything. A hermetic run never asks macOS whether it is
  trusted either, since the first time an app macOS has not seen asks, macOS
  writes a row for it, denied, and lists it under Privacy & Security >
  Accessibility, switched off. Should the copy be listed there all the same,
  as after a launch of it that was not hermetic, `scripts/e2e/athina-e2e
  clean` removes the row with `tccutil reset Accessibility
  com.ahcarpenter.athina.e2e`, and the copy's preferences with `defaults
  delete com.ahcarpenter.athina.e2e`, once no run is going.
- **It is checked, every run.** From launch to stop, the harness counts the
  run's windows above the desktop picture five times a second and its items
  in the menu bar every couple of seconds (`athina-drive windows` and `bar`,
  into `hermetic-windows.log` and `hermetic-bar.log`); every API-tier run ends
  with checks that both counts stayed at 0, that no look failed, and that the
  bar was really read: some look saw another app's items in it, which a drive
  macOS does not trust for Accessibility never does.

`--show-windows`, given to the harness (`run --show-windows <scenario>`) and
passed on to the app beside `--hermetic`, leaves a hermetic run's windows
where they open, to
watch what a scenario does or to compare its checkpoints with a parked run's;
such a run is on the screen, so it takes the screen lock.

## Scripted sensing

A hermetic run senses only what its scenario scripts, through the API's
`observe` (`SensingPipeline.observe`, `ScriptedObservation`). Each call is
one moment of a person's screen: an app's window in front, filling a display,
with a text area holding the text given focused, as a document in an editor
is. The pipeline senses it the way it senses a real window, with the same
code from the journal on: a change of app or window is journaled as an app
or window switch, an app the settings exclude is read no further than its
name and puts sensing in the excluded mode, and otherwise a capture is taken
at once, a focus-change capture after a switch and an input-settled one after
the text changed, and kept or dropped by the same rule as a capture of the
screen (`FrameKeepPolicy`), so the same window showing the same text again is
a near duplicate. The frame is the text drawn a line at a time, and its
recognised text is those lines, each where it was drawn, so no screen is read
and no text recognition runs. `observe idle=true` and `idle=false` stand in
for the keyboard and mouse going quiet past the idle threshold and coming
back. The debug panel's Latest frame shows each scripted frame as it shows a
real one. A suggestion's callout needs a real window to point at, so a
hermetic run draws none and says so in the debug panel.

The harness scripts the moments the committed fixtures were recorded at, from
the documents in their `scenario/` folder (`scripted_toast` in
`scripts/e2e/lib/harness.sh`): `reading-notes.txt` in front, whose replayed
triage finds nothing worth a look, then, once `advance` has moved the replay
clock past the triage gate's 5 second floor rather than waiting it out, a
switch to `cleanup-script.txt`, whose triage and mentor call make the
suggestion. The toast is up within 2 seconds of that second `observe`,
measured at about 0.1 second, which the run checks, and every step waits on
the event it needs (`wait-event`) rather than on a fixed time or the journal.

## What the harness already handles, so a scenario need not

- **The warm home**, above: no run pays the cold OCR stall again.
- **Fast toasts.** Every launch replays with `--replay-latency immediate`
  (see Replay), and the seeded settings put the triage gate at its 5 second
  floor, so a toast comes seconds after the first capture rather than after
  the recorded 41 second mentor call and a 20 second gate. An API-tier
  scenario scripts its toast (see Scripted sensing). On the real screen,
  `wait_toast` looks for it every quarter second and nudges sensing every 2
  seconds (the helper window flips and TextEdit switches windows), pressing
  Capture Now only after 30 seconds with no toast; it logs how long it waited
  and how long since launch. While it waits for the first capture, the
  harness brings the staged TextEdit forward with each Shift press, since
  sensing captures nothing while an excluded app, such as the terminal of
  whoever is at the Mac, is in front.
- **Idle input.** `real-screen` takes the screen only once the
  keyboard and mouse have been quiet for 15 seconds (above), each of its
  pointer steps waits for a quiet moment after the run's own input, and a
  click aborts if the pointer moves off the target, because the Mac may have
  someone at it. A click by that person
  during a wait dismisses the toast through its global listener, which is
  them using their Mac rather than a failure, so `keep_toast_up` relaunches
  Athina for a new toast (the earlier launch's journal and watcher logs are
  kept as `journal-launch<n>.sqlite` and `<log>-launch<n>.log`, and the
  watchers start again on fresh logs, so the checks read only what the new
  launch saw) and waits again, up to three times. It relaunches rather than
  use Show Last Suggestion, which brings the toast back with the dismissal
  already in the journal, so the checks after it could not tell their answer
  from the one before. An API-tier scenario makes no pointer step and posts no
  input at all, so it waits for none.
- **The owner's apps are excluded** in the scratch settings from the start.
  Replay serves fixtures in order whatever is on screen, so a replayed callout
  would otherwise land over the work of whoever is using the Mac.
- **The preferences leak.** `CFFIXED_USER_HOME` moves Application Support but
  not UserDefaults, so a run still writes through cfprefsd into the real
  `com.ahcarpenter.athina` domain. Every real-screen run saves that domain and
  restores it, even on failure. An API-tier run never touches it: it runs a
  copy of the app with a domain of its own (see Hermetic runs).
- **Nothing is stopped by name.** The harness launches the binary directly and
  stops only the pids it started, never an Athina it did not launch (the make
  targets stop only their own lane, see Replays side by side).
- **A sandbox** denies the real `~/Library/Application Support/athina`, the
  `mentor` folder beside it that the app kept before the rename, and all
  outbound network, so no run can reach live data or make a live call.
- **Cleanup runs on failure**, through a trap: helpers, taps, staged apps, the
  app itself, the preferences, and the scratch home. `clean` leaves a run that
  is still going alone, since an API-tier run of another checkout's waits on
  no lock that `clean` holds.
- **One run on the screen at a time**, across every checkout on the Mac: a
  flock on `~/Library/Caches/athina-e2e/screen.lock` (`scripts/e2e/lib/lock.sh`),
  the file a hand-held `lockf -k` uses too, held by each real-screen scenario
  for exactly as long as it runs, so a killed run leaves no stale lock, and a
  run started under a holder (a hand-held `lockf`) never waits on it. The
  checkout lock, `build/athina-e2e.lock`, works the same way for one checkout,
  held by `run` and `warm` for all they do.

A validation step that needs live evidence should call this harness. Writing
the driving again is how a check ends up overrunning its time limit on a cold
home.

## Evidence and the data directory

Runs land in `~/Library/Caches/athina-e2e/runs/<scenario>-<stamp>/`, or under
`--out <dir>`; `--keep-home` keeps the scratch home to look inside it.
Each run has its own home, and `launch_athina` in `scripts/e2e/lib/harness.sh`
learns where that run's journal is rather than dictating it: the replay makes a
directory for each launch (see Replays side by side), which is what keeps two
replays apart when they share a home, and names it on the line it writes as it
starts. The harness waits for that line in `app.log`, matching its own pid so a
relaunch never reads the last one's, and takes the path from it.
