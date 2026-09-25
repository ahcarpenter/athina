<h1 align="center">Athina</h1>
<p align="center">
  <a href="#requirements"
    ><img
      alt="Platform: macOS"
      src="https://img.shields.io/badge/platform-macOS-blue?style=flat-square"
  /></a>
</p>

<h3 align="center"><strong>A live mentor for your Mac.</strong> It watches how you work and shows you a better way when there is one.</h3>

<p align="center">
  <img src="Resources/Mark/ReadmeIcon.png" width="224" alt="Athina's app icon: Athena in a crested helmet, drawn in dark ink over cream shapes">
</p>

## Overview

The **foundation** is a menu-bar app that senses what you are doing
(accessibility context plus low-cadence screen capture with on-device OCR),
records it in a local journal, and, once turned on in Settings > Advanced,
shows a debug panel with what it currently thinks you are doing. The **mentor
loop** subscribes to that stream and asks Claude, in two tiers, whether there
is a genuinely more helpful way to approach what you are doing; when there is,
a small toast says so and learns from your answer. The **standing
understanding** carries what you appear to be working toward from one call to
the next, so Athina can look out for you: it calls out an approach that will
not reach your goal, one that is slower than an alternative you have, or one
that will reach it and bring a side effect you would not want. **Callouts and
voice** let a suggestion point at the spot on screen it is about and take a
spoken reply: an answer to the toast, or a question the mentor tier answers.
Reading suggestions aloud is deferred. Halt-and-redirect and learned
suppression are later phases.

## Requirements

- macOS 26 or later (developed and measured on macOS 27, Apple Silicon)
- Xcode 26 or later with its command line tools (`swift`, `codesign`)
- The app has no third-party dependencies: SwiftUI, ScreenCaptureKit, Vision, the
  accessibility API, Carbon hotkeys, AVFoundation and Speech for talking
  back, and the system SQLite
- The Xcode project alone (see The Xcode project) is generated with XcodeGen,
  which SwiftPM fetches and builds, pinned, on first use; nothing else needs it
- The UI smoke test alone (see UI snapshot smoke test) uses
  swift-snapshot-testing, which SwiftPM fetches, pinned, only when that test
  runs; the app never links it

## Build, run, test

```sh
make build            # builds build/Athina.app from the SwiftPM binary
make mark             # rebuilds the app icon and this README's copy of it from AthinaMark.svg, and the menu bar mark from AthinaOwl.svg (their outputs are committed, so a plain build never needs it)
make run              # builds and launches the app, replacing only the copy this checkout's run or record launched
make run-replay       # the same, answering every model call from recorded fixtures: no network, no key, no spend (TIME_SCALE=60 runs its clock faster)
make record           # the same, live, writing every model call to a fixture file (spends API credits)
make clear-recordings # deletes the app's own recordings directory
make fixture-status   # checks that the committed fixtures are current (fails when not), with no network
make test             # runs the unit tests (swift test), the loop included, with no network
make snapshots-approve # makes the baselines match the renders CI made of HEAD, after an intended UI change
make ui-snapshots-smoke # the UI smoke test: every snapshot drawn in process with swift-snapshot-testing and compared with the runner's references
make ui-snapshots-smoke-local # the smoke set drawn on this Mac at HEAD and at main, and every changed screen reported, as local validation runs it
make snapshots-smoke-approve # makes the smoke test's references match the set CI made of HEAD, after an intended UI change
make format           # formats every Swift file in place to Google's Swift style (see Code style)
make lint             # checks every Swift file against that style without changing it, as CI does
make measure          # samples the running app's CPU and memory for 60 seconds (PID=<pid> when several run)
make release          # builds, signs, notarizes, and packages a direct-download release into build/release (see Releasing)
make xcodeproj        # generates Athina.xcodeproj, the Xcode project for the App Store route, from project.yml (see The Xcode project)
make xcode-build      # generates it and builds its sandboxed App Store target into build/xcode
make xcode-archive    # generates it and archives that target into build/xcode/Athina.xcarchive
```

None of the launch targets quits an Athina it did not start: each one stops
only the copy its own lane launched earlier from this checkout, by the pid
`scripts/launch.sh` wrote to `build/<lane>.pid`, so other checkouts, other
replays, and an Athina started any other way keep running. `make run` and
`make record` share the lane `live`; `make run-replay` uses `replay`, or
`LANE=<name>` (see Replays side by side). Because two live Athinas would share
one journal, one settings file, and one API bill, a live launch refuses to
start while another live Athina runs and names it; a build from before the
rename, running as Mentor, counts as one. Nothing stops a person
launching a second copy from Finder, which was equally true before.

`Package.swift` defines the targets and `scripts/bundle.sh` wraps the release
binary in an app bundle with `Resources/Info.plist` and
`Resources/Athina.entitlements`, then signs it. `swift build` and `swift test`
work directly too. The one Xcode project, for the Mac App Store route, wraps
this package rather than replacing it, and nothing above uses it (see The
Xcode project). The bundle `make build` makes is a development one: it carries
the end-to-end harness's control API (the `ControlAPI` package trait, see The
control API), which a release never does.

`Athina --snapshot <dir>` renders every window with sample data to PNG files
(light and dark) without starting the pipeline or calling any model. It is how
UI changes get checked without a person at the screen; it needs no permissions
and never reads the keychain. Each view renders in a borderless window placed
below the desktop picture, where the window server still composites glass and
controls and ScreenCaptureKit still captures it, so nothing appears on screen
(the run puts no item in the menu bar either) and a tall Settings pane renders
whole. Replay mode has renders of its own. `open -n build/Athina.app --args
--replay <dir> --open debug` (or `settings`, `settings:<pane>` for `general`,
`contexts`, `models`, `capture`, `journal`, `privacy`, or `advanced`,
`permissions`, `history`) starts a replay with that window already open, which
is how a panel gets screenshotted from a shell. A replay opens the debug panel
this way whatever Settings > Advanced says; a live launch opens it only while
the switch there is on (see Debug panel). Keep the `--replay`: a bare `open -n`
goes round `scripts/launch.sh`, so nothing stops it starting a second live
Athina on the live journal, the live settings and the same API bill. The live
app's own windows open from its menu bar item, on the copy `make run` already
started; the debug panel opens there and from Settings > Advanced only once it
is turned on in that pane. `--record [<dir>]` chooses where model calls go,
`--time-scale <n>` and `--advance-clock <interval>` set a replay's clock,
`--replay-latency immediate` answers a replay's calls at once,
`--settings <path>` chooses the settings a replay starts from (see Iterating
without the network), and `--control <dir>` serves the end-to-end harness's
control API (see The control API), with `--hermetic` and `--show-windows`
shaping such a launch (see Hermetic runs).
Where a replay keeps its own files is not an argument: it makes a directory for
itself and says which on the line it writes as it starts.

### Setup: the Anthropic API key

The mentor loop needs an Anthropic API key. Open Settings > Models (the menu's
Add API Key item goes there), paste the key, press Save, then Test Connection:
it sends one tiny request on the triage model and reports the answering model
or the API's own error message. The key
goes into your login keychain (`com.ahcarpenter.athina` /
`anthropic-api-key`) and nowhere else; the app only ever shows its last four
characters. Without a key the loop stays idle and the menu says so. Remove
deletes the keychain item. A replay needs no key, and the app never reads the
keychain while replaying.

### Code signing

The bundle script signs with `$ATHINA_SIGN_IDENTITY` if set, otherwise with the
first Apple Development or Developer ID Application identity in the keychain,
otherwise ad-hoc. macOS ties Screen Recording and Accessibility grants to the
app's designated code requirement, recorded when the grant is made. An ad-hoc
signature's default requirement is the hash of the exact binary, so a plain
ad-hoc rebuild silently invalidates both grants: System Settings still shows
the switches on, toggling them does not help, and the TCC daemon logs
"Failed to match existing code requirement". The ad-hoc path therefore signs
with an explicit requirement on the bundle identifier
(`identifier "com.ahcarpenter.athina"`), which every rebuild satisfies, so a
grant made once stays valid. The trade-off is that any ad-hoc binary claiming
that identifier would inherit the grants, which is acceptable on a development
machine and is exactly what a development certificate fixes. This is the
development signature, without the hardened runtime or a timestamp; a release
is signed by `make release` instead (see Releasing).

The keychain is stricter than TCC: for an app that is not Apple-signed it
trusts a keychain item's readers by the hash of the exact binary, so the
first time a rebuilt ad-hoc Athina reads the API key, macOS can show its
"Athina wants to access key" prompt. The app reads the key off the main
thread and keeps sensing behind the prompt, but makes no live call until it
is answered. Always Allow adds that build to the item's list; Deny leaves the
loop without a key until the next launch. A replay never reads the key, so it
never shows the prompt. A development certificate makes this go away too.

If a grant was made against an older build (the app shows a permission as
missing although System Settings shows it on), remove the stale record and
grant again:

```sh
tccutil reset Accessibility com.ahcarpenter.athina
tccutil reset ScreenCapture com.ahcarpenter.athina
```

### A sandboxed build

The same binary can run in the App Sandbox, which a Mac App Store edition
needs; the Xcode project's `Athina App Store` target builds it, signed with
`Resources/Athina.app-store.entitlements` (see The Xcode project). At launch
`RuntimeEnvironment` reads the process's own `com.apple.security.app-sandbox`
entitlement, which the direct and development builds carry set to false, so
they run exactly as described everywhere else in this README. A sandboxed run
differs in three ways:

- Its files are in its container, its preferences domain and its keychain
  service are its own bundle identifier rather than `com.ahcarpenter.athina`
  (`AppPaths`), so it never shares preferences or a key with the direct build.
- It moves nothing from Mentor, neither files, preferences nor the API key
  (see Coming from Mentor), since all three are out of its reach, and says so
  once in the log.
- `--replay` and `--settings` may name only a path inside its container or its
  own bundle, and `--record`, `--snapshot` and a clock request's reply
  (`scripts/advance-clock.sh`) only one inside its container. Anything else is
  refused with one line naming the path and where it could have been.
- `--control` is refused whatever it names: a sandboxed Athina never serves
  the control API, even one built from the development bundle.

### The Xcode project

The Mac App Store route needs what only an Xcode project gives: automatic
signing with provisioning profiles, archiving, and uploading to App Store
Connect. `project.yml` is its committed spec, and `make xcodeproj` generates
`Athina.xcodeproj` from it with XcodeGen, pinned by version in
`Tools/XcodeGenTool` (its `Package.resolved` is committed), which SwiftPM
builds on first use, so nothing is installed and every Mac generates the
same project. The generated project is not committed, so no `project.pbxproj`
is ever merged by hand: change `project.yml` and regenerate. Opening the
project in Xcode starts with `make xcodeproj`, then `open Athina.xcodeproj`;
run it again after changing `project.yml` or adding or removing a source file.
The tools package is not part of the app's package, so `make build`, `make
test`, `scripts/bundle.sh`, `make release` and CI never fetch or build XcodeGen.
CI does not generate or archive the project: that check left CI until the App
Store release flow brings it back as part of that flow.

The project has one target, `Athina App Store`, and a scheme of the same name
whose Archive action builds Release. It compiles `Sources/Athina` against the
package's `AthinaCore` and `SnapshotDiff`, linking the frameworks the package's
`Athina` target does (a dependency or framework added to one goes in the other
too, except the `ControlAPI`-conditional `AthinaControl`, which the App Store
build never carries; see The control API), bundles the same icon and menu bar
marks `scripts/bundle.sh` does, and signs with
`Resources/Athina.app-store.entitlements` (the App Sandbox, `network.client`,
and the microphone keys of both the hardened runtime, `device.audio-input`,
and the sandbox, `device.microphone`). Its Info.plist is `Resources/Info.plist`
with `CFBundleIdentifier` rewritten at build time to the target's
`PRODUCT_BUNDLE_IDENTIFIER`, so the version and every other key are still set
in one place. That id is set only in `project.yml`, and is the development id
`com.ahcarpenter.athina.appstore.dev` until the permanent App Store id is
chosen, which can never change once a build is uploaded. Signing is automatic
and `DEVELOPMENT_TEAM` is left empty: until a team id is filled in there, the
target signs to run locally, which is how `make xcode-build` and `make
xcode-archive` build it; with one, Xcode signs with that
team's Apple Development certificate and Product > Archive feeds the
Organizer's App Store Connect upload. The built app is sandboxed, so it keeps
its files in its own container and runs as A sandboxed build describes. The
App Store build is archived and uploaded through this project, while the
direct Developer ID release keeps `scripts/release.sh` (see Releasing); the
earlier plan to package the App Store build from the package build with
`productbuild` and `altool` is superseded.

## Iterating without the network

Working on Athina needs no live call to Anthropic to build, test, or verify.
The app, its tests, and every verification run use **replay**: each model call
is answered from a recorded fixture, with no network, no API key, and no spend.
Replay is the default way to exercise the app, including the end-to-end checks
a change gets before it ships. Live calls are for two deliberate occasions
only: recording fixtures, including re-recording the committed set when a
change makes it stale, and the separate live check of the models' answers.

### Replay

```sh
make run-replay                                   # the committed fixtures
make run-replay REPLAY_DIR=~/Library/Application\ Support/athina/recordings
make run-replay ALLOW_STALE=1                     # also serve stale fixtures, see below
make run-replay TIME_SCALE=60                     # on a clock 60 times real time, see A faster clock
make run-replay SETTINGS=check.json LANE=a         # its own settings, in a lane of its own, see Replays side by side
open -n build/Athina.app --args --replay <dir> --open debug
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

**Replay latency.** `--replay-latency immediate` answers every replayed call
at once instead, for a scripted check that waits on what the calls bring: the
mentor call that raises the first toast in the committed set was recorded at
41 seconds, which the end-to-end harness has no use for (see End-to-end
harness). `recorded`, the default, names the usual, so `make run-replay` still
looks like a live session. The flag on a live or recording launch is refused,
like the clock flags: nothing there is replayed, and the menu's Refused line,
the Mentor card, and the log say why. A value other than `immediate` or
`recorded` is refused in the same places, and the replay keeps the recorded
latency. `ReplayLatencyMode` (`Sources/AthinaCore/System/ReplayLatencyMode.swift`)
is the rule, under test.

**A replay runs against files of its own, seeded from your live settings.** A
replay, and a replay that was refused, keeps its journal and settings in a data
directory of its own rather than beside the live ones: a new one for each
launch, `~/Library/Application Support/athina/replay/launch-<pid>-<random>`,
which it names as it starts (see Replays side by side). Every replay launch
starts from your live settings, read and never written (or from the defaults
when there are none), unless `--settings` names another file, so the apps you
excluded stay excluded, and your retention and sensing choices hold, exactly as
you set them. Nothing a replay does, a suggestion and its feedback, a Not Now
or Never for This, a changed setting, reaches the live journal, the live
settings, another replay, or the prompts of a later live run; a setting
changed during a replay lasts until the app quits. `--record` is a real session
and uses the live files.

Nothing about a replay can be mistaken for a live call:

- the menu bar shows **Replay** beside the mark, and the menu says where the
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

Replay takes away the model's cost, and its latency when asked to, not the
clock. A refresh that comes due after fifteen minutes of use, a Not now that
lasts an hour, the spend hour, and a new day all still take that long. So every
time-based behavior in Athina reads one time source, `AthinaClock`
(`Sources/AthinaCore/System/AthinaClock.swift`): the dates the journal is
stamped with and the gates compare, the time awake a refresh counts, and every
wait (a toast's countdown, the callout check, the sensing cadence and idle
threshold, the talk-back timers, a replayed call's recorded latency). The
shipped app runs on `SystemClock`, which is `ContinuousClock` and `Date`, so a
live run is exactly what it was. A replay runs on a clock of its own that a
scripted check can compress:

```sh
make run-replay TIME_SCALE=60
open -n build/Athina.app --args --replay <dir> --time-scale 60 --advance-clock 1d --open debug
```

- `--time-scale <n>` runs the replay's clock n times faster than real time,
  from 1 to 100. Everything above shrinks with it: at 60x the fifteen-minute
  refresh comes due after fifteen seconds of use and a toast expires after one.
  So does the idle threshold, so raise Settings > Capture > Idle after for the
  session, or keep input arriving, or sensing goes idle after a second. Timers
  paced for a person shrink too: at 60x a held talk-back key is cut off after
  half a second, so talk back to a scaled replay through the Talk back field.
  A capture still takes its real time, so at a high scale one is nearly always
  in flight. A change moment that lands during one is captured after it ends,
  but several that land during the same capture share that one next capture,
  so use a low scale when each window switch needs its own, and the advance
  directives below for long waits.
- `--advance-clock <interval>` starts the clock that far ahead: `90s`, `15m`,
  `2h`, `1d12h`, up to `30d`.
- `scripts/advance-clock.sh <pid> <interval>` moves a running replay's clock
  ahead from a script, exactly as the Advance field below does, with no
  accessibility and no window. It posts a distributed notification addressed
  to that pid (`ClockRemote`); only a replay listens, and only for its own pid,
  so a live or recording Athina and every other replay ignore it. The request
  names a file for the replay to answer at, and the script waits for that
  answer: a notification reaches only the observers registered when it is
  posted and says nothing about who heard it, so a request sent to a replay
  that is still starting, to a live Athina, or to a pid that is not Athina
  would otherwise look exactly like success and leave a check waiting on a
  clock that never moved. Nothing authenticates the channel, so a replay
  answers only at a file that does not exist yet, inside the system temporary
  directory and outside the live data folder, and refuses anything else into
  the log: otherwise a request would be a way for any process in the login
  session to create or replace a file the user can write, the live settings
  among them. A request it cannot answer moves nothing, so a retry after no
  answer never moves the clock twice. It exits 0 with what the clock now
  reads, 1 when no answer arrives inside `ATHINA_CLOCK_TIMEOUT` (10 seconds by
  default), naming the pid, and 3 when the replay refused the interval.
- The debug panel's Mentor card has an **Advance** field (accessibility label
  "Advance clock"): type an interval and press Return, and the clock moves
  ahead at once, as if that much time went by with the Mac awake in the mode
  Athina is in; the seconds since the last input are the system's, so moving
  ahead never makes sensing idle by itself. Every wait due in it ends: a toast
  expires, a snooze or the spend cap releases, the next capture falls due.
  While watching it counts as active use toward the next refresh; while paused
  or idle it counts nothing; and past midnight the next observation expires the
  understanding.

Every replay makes a new directory, so its journal is empty and its clock
starts at real time, `--advance-clock` ahead of it when that is given. No
replay ever reads another's journal, so a faster clock in one never moves
another's.

The menu bar and the debug panel's Replay badges read **Replay 60x** while the
clock is scaled, and the menu's Clock line and the Mentor card's Clock field
say how fast it runs, how far it was moved ahead, and, in the card, the date it
reads. A launch that asked for a replay it could not start keeps the replay's
files, and so its clock. Either flag on a live or recording launch is
refused: the app runs on real time, and the menu, the Mentor card, and the log
say why, so a live or recording run can never use a controlled clock. A replay
given a flag value it cannot use says why in the same places, and runs on its
own clock at real time with nothing added ahead, which the Advance field and
`scripts/advance-clock.sh` still move.

The tests run on the same kind of clock with no real time at all: an
`AdjustableClock` made with a start date stands still until a test advances
it, a sleep on it ends exactly when an advance reaches its deadline, and
`waitForSleepers` lets a test advance it only once the code it drives is
waiting. No test sleeps: a refresh after fifteen minutes of use across a pause
and a closed lid, a snooze running out, the spend cap releasing at the top of
the hour, a toast's paused countdown, a callout aging out, and expiry at a new
day are each proven in milliseconds.

### Replays side by side

Any number of replays can run at once, from one checkout or several, and none
of them disturbs another or the live app:

- **Each replay has its own data directory, and only the app names it.** A
  launch makes a new one, `replay/launch-<pid>-<random>` inside the support
  directory, so its journal starts empty and its clock at real time, and it
  never collides with another replay's. Nothing outside the app chooses that
  path: there is no flag for it, so there is nothing to point at the live data
  folder, at a directory someone else can read, or at one another replay is
  already using. A launch says where it put its files on the line it writes as
  it starts, `Athina started: pid <pid> in <directory>`, and everything past
  the first ` in ` is the path, so a script reads it without quoting however
  the path is spelled. `make run-replay` prints it, the debug panel's Athina
  card shows it, and the log at launch records it. A replay holds its directory
  for as long as it runs, with a lock on `athina.pid` inside it that holds its
  pid, which is what keeps a later launch's sweep off a directory still in use.
  Every replay launch sweeps the finished per-launch directories as it starts,
  and removes those past the newest 10 and those unwritten for longer than your
  `thumbnailRetention` (6 hours by default): a finished replay's journal is
  never opened again, so retention can never age the thumbnails and recognized
  text it captured from the real screen, and the whole directory goes at that
  window instead. Newest, and unwritten, are both measured from when a
  directory's journal or its `-wal` file was last modified, so a lane that ran
  all day and quit a moment ago is one of the newest and stays readable. Read a
  finished lane's journal with `sqlite3 -readonly`, which modifies neither: a
  plain `sqlite3`, or any reader that opens it read-write, runs a checkpoint as
  it closes that modifies both, and so can keep the directory up to one window
  longer. The sweep takes the directory's lock before it removes anything, so
  it never touches one a running replay holds, and it never touches a
  directory whose name is not a launch's own.
- **`--settings <path>`** (`make run-replay SETTINGS=<path>`) starts the
  replay from that settings file instead of the live one. It is read and never
  written, so a scripted check keeps its settings in a file of its own and
  never has to swap the live settings. A file that is there but is not
  settings stops the launch, naming the file and what was wrong with it: a
  check that generated its settings and got truncated JSON would otherwise run
  on your live thresholds, contexts and retention and could report a pass on
  settings it never chose. A file that is not there at all is refused more
  gently, and the replay starts from the live settings, so the apps you
  excluded stay excluded. Put every app a replayed callout must not cover in
  that file's excluded apps.
- **`--settings` applies only to a replay.** On a live or recording launch it
  is refused, like the clock flags: the app uses the live files, and the menu,
  the Mentor card, and the log say why. The live app's files never move.
- **Launching never quits another Athina.** `make run-replay` replaces only the
  replay its lane (`LANE`, default `replay`) launched from this checkout, and
  finds that instance exactly: the launch carries a unique `--launch-token`,
  an argument the app ignores, so two launches from one checkout that overlap
  can never adopt each other's process. The token is kept beside the pid, in
  `build/<lane>.token`, and the next launch in that lane stops the pid only
  while it still carries that token: a lane stopped outside make leaves its pid
  file behind, and when the Mac has since given that pid to another lane, the
  other lane keeps running. The pid is reported only once the app itself says
  it started, on the line it writes past every reason it could refuse the
  launch and past the point where it is listening for a clock request, never
  after an elapsed time that proves nothing on a busy Mac. So a
  `scripts/advance-clock.sh` sent the moment the pid file appears is heard
  rather than posted into a channel nobody is observing yet. A launch that
  quits as it starts, a replay given a `--settings` file that is not settings
  among them, is reported as the failure it is, with what the app said, and
  leaves no pid file behind. So is a lane whose journal will not open: it can
  journal no event and answer no check, so it is reported as a failed launch
  and stopped, even though the app itself stays up when you start it by hand
  so you can read the error in the menu and the debug panel. Two lanes run
  side by side:

```sh
make run-replay LANE=a SETTINGS=/tmp/a/settings.json TIME_SCALE=60
make run-replay LANE=b SETTINGS=/tmp/b/settings.json
cat build/a.pid                                   # lane a's pid
scripts/advance-clock.sh "$(cat build/a.pid)" 2h  # moves only lane a's clock, and fails if it was not heard
```

  An on-screen check drives the app through `scripts/e2e/athina-e2e` (see
  End-to-end harness) rather than launching it itself: the harness already runs
  each check in a scratch home, excludes the owner's apps, and stops only the
  pids it started. A launch outside make uses `open -n` (a plain `open` can
  bring an already running Athina forward instead of starting one) and finds
  its instance by pid: `lsof -p <pid> | grep journal.sqlite`, or `athina.pid`
  in the data directory. Stop a replay with `kill <pid>`, never by name.

### Record

```sh
make record                          # into ~/Library/Application Support/athina/recordings
make record RECORD_DIR=recordings    # into ./recordings, which git ignores
```

`--record` runs live, with the saved key and real spend, and
`RecordingClaudeClient` writes each call to its own JSON file named
`<UTC time>-<kind>-<id>.json`. A file holds the fixture format version, the
call's kind and prompt version, the time, the model, the request exactly as it
was sent (system blocks, messages with the screenshot, output format, effort),
the response as Athina decodes it or the error, usage, latency, and the
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
cost nothing, not as replays. The menu bar shows **Recording** beside the mark
while it runs. `make clear-recordings` deletes the app's own recordings
directory, `~/Library/Application Support/athina/recordings`.

A file's name starts with the time its call started, to the millisecond, and
each call is stamped in a later millisecond than the one before, even when two
start within one millisecond or the wall clock steps back, so file-name order,
the order a replay serves each kind in, is always the order the calls were made.

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

`Tests/AthinaCoreTests/Fixtures/Replay` is a small set recorded live from a
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

1. Quit the live Athina and move the journal aside (keep it to put back).
   Triage and mentor requests carry recent journal events and screens, so a
   recording made on a lived-in journal carries that history too.
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
   `understanding` kind, set Settings > Models > Refresh at most every to its
   lowest value before recording and leave the scenario in front for that whole
   interval after the last mentor call; setting Settings > Capture > Idle after
   above the interval keeps the loop watching with no input. Add Athina itself
   to the excluded apps, so opening Settings for Test Connection is never
   captured.
4. Read every file, text and screenshot, and every reply for quality (a model
   can fill a required field with an empty string), replace the fixture directory's
   recordings with the ones you keep, update its README, delete the rest, put
   the journal and settings back, and run `make fixture-status` and
   `swift test`.

`ScriptedClaudeClient` stays for unit tests that need one exact hand-written
answer, such as a refusal, an unparseable reply, or a slow call.

## End-to-end harness

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
scripts/e2e/athina-e2e run toast-menu-answers
scripts/e2e/athina-e2e doctor        # what is missing before a run
scripts/e2e/athina-e2e journal suggestions   # a named query over the last run
```

Every run is replay only: no API key is read, no network is reachable inside
the sandbox, and nothing is billed. It needs a display, so it never runs in
CI; CI runs the harness's unit tests with the rest of the suite.
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
the Mac is quiet again. `--lock-timeout <seconds>` gives up
instead; `list`, `doctor`, and `journal` never wait. An API-tier scenario is
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

### Scenarios

| name | tier | what it proves |
| --- | --- | --- |
| `real-screen` | screen | everything only macOS's own routing proves, in one scenario, each step named in its checks: (1) a toast comes up; (2) an accessibility press on the menu bar item keeps it; (3) a real click on the item keeps it, and the menu macOS draws matches the one the app built as the control API reads it; (4) Answer Suggestion > Tell Me More by hovering the submenu is recorded; (5) on a new suggestion from a relaunch, since the journal keeps only a suggestion's first answer, Show Last Suggestion, then a real click on empty menu bar space dismisses the toast, recorded as dismissed and attributed to a real mouse-down by a session tap; (6) Show Last Suggestion again, then a real click in a staged TextEdit window dismisses it; (7) the item keeps one width watching, in the excluded mode and paused, read from the real bar, with strips of the bar kept as evidence of what is drawn; (8) a real click on each Settings footer link (Contexts to Privacy, Models to Journal) changes the pane in place rather than handing the link to the system. On a quiet Mac it holds the screen for about a minute and a half |
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
for an API-tier run, every request and answer in `api.log`, the checkpoint
PNGs it took of Athina's windows, and what the harness saw of the screen in
`hermetic-windows.log` and `hermetic-bar.log`). A scenario that runs several
steps, as `real-screen` does, names each (`step`), so each check carries its
step (`step 5 a real click on empty menu bar space dismisses a new toast, and
that is recorded: the toast is gone after the click`), and a run that stops
early says at which step.

### The warm fixture home

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

### Drive helpers

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

### The control API

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
| `snapshot` | a checkpoint PNG of one of Athina's windows at `path=`, taken as `--snapshot` takes one once macOS has finished animating the window open (up to two seconds); never over an existing file |
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

### Hermetic runs

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

### Scripted sensing

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

### What the harness already handles, so a scenario need not

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

### Evidence and the data directory

Runs land in `~/Library/Caches/athina-e2e/runs/<scenario>-<stamp>/`, or under
`--out <dir>`; `--keep-home` keeps the scratch home to look inside it.
Each run has its own home, and `launch_athina` in `scripts/e2e/lib/harness.sh`
learns where that run's journal is rather than dictating it: the replay makes a
directory for each launch (see Replays side by side), which is what keeps two
replays apart when they share a home, and names it on the line it writes as it
starts. The harness waits for that line in `app.log`, matching its own pid so a
relaunch never reads the last one's, and takes the path from it.

## Permissions

Athina needs two permissions and explains each in a first-run window that
opens whenever one is missing. The window explains before it asks: no system
prompt appears when it opens. Each missing permission has one button. For the
sensing pair it is Open System Settings, which registers Athina in that
permission's System Settings list (macOS may show its own note pointing
there) and opens the matching pane; the window shows live status and re-checks
every second while open and when the app regains focus. Two more are optional
and serve only talking back; the window lists them below the required pair and
asks for them only when you press Request Access (Open System Settings once
the system has asked) or first hold the talk-back shortcut.

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

## Coming from Mentor

The app was called Mentor, with the bundle identifier
`com.ahcarpenter.mentor`. It is Athina now, `com.ahcarpenter.athina`, and
macOS keys both Screen Recording and Accessibility to that identifier, so the
grants made to Mentor do not carry over. The first launch of Athina therefore
senses nothing until they are granted again, once, by hand:

1. Open System Settings > Privacy & Security > Screen Recording, turn Athina
   on, and do the same under Accessibility. Athina's own first-run window has
   a button for each, and shows live status as they are granted.
2. Quit and reopen Athina, so it picks up both grants. Mentor can be removed
   from both lists at the same time; it is no longer built.

Nothing of yours is left behind or overwritten. On its first launch Athina
moves what Mentor kept, `~/Library/Application Support/mentor` (the journal
with its understanding, `settings.json`, and any recorded calls), to
`~/Library/Application Support/athina`. Quit Mentor first: Athina takes
SQLite's exclusive lock on the old journal for the whole move, and has SQLite
itself copy it rather than copying a live write-ahead-log database file by
file. The copy is assembled beside the new folder and checked there, the
journal by SQLite's integrity check and a row count of every table against the
original, every other file by SHA-256 digest, and only then put in place, with
the marker `migrated-from-mentor.json` written last. The move runs before the
app comes up, so on a large journal that first launch can sit quietly for a
while with nothing in the menu bar yet. The old folder is left exactly as it
was, yours to keep or remove. Per-launch replay directories are
not moved, since every replay makes its own, and a replay that ran under the
new name first does not stand in the way: its `replay` folder is the app's own,
not your data.

A move that cannot be finished stops that launch rather than starting an empty
journal in place of yours. Athina says what failed, in an alert, on stderr and
in the log, and quits:

- The old journal is still open in Mentor or another copy of the app, so the
  lock cannot be had. Quit it and open Athina again.
- A copy or a check failed (a full disk, a file that cannot be read).

Either way what Mentor kept is untouched, the attempt takes back whatever it
put in the new folder and nothing else, and the next launch simply tries
again. A move cut short by a crash is started again the same way. If the
same alert comes back launch after launch, the cause is not going away on its
own: move `~/Library/Application Support/mentor` somewhere else, and Athina
starts with an empty journal, leaving that copy intact where you put it.

If both folders already hold real data, the move is refused rather than
merged: Athina uses `athina`, leaves `mentor` untouched, and says so, naming
what it found, in Settings > Journal, in the debug panel, and in the log. Keep
the one you want and move the other away.

The Settings pane you had open and the window positions move with the
preferences domain on that same first live launch, laid over anything a replay
wrote there beforehand; after it, what Athina has written is never
overwritten.

The Anthropic API key moves the same careful way. On the first launch Athina
copies the keychain item saved under `com.ahcarpenter.mentor` to
`com.ahcarpenter.athina`, reads it back from there, and leaves the old item
exactly where it is; an item already under the new name is never overwritten,
and a key you delete in Settings is never copied back. So expect a third thing
on that first launch, after the two grants: the system's keychain prompt,
"Athina wants to use your confidential information stored in
com.ahcarpenter.mentor", since the login keychain trusts an item's readers by
the exact binary (see Code signing). Always Allow copies the key across; Deny
leaves it where it is, and you can paste the key into Settings > Models
instead. The copy runs off the main thread, so the app keeps sensing while the
prompt waits.

## Releasing

The first releases go out directly, as a download from outside the App Store:
signed with a Developer ID, notarized by Apple, with no App Sandbox and no App
Review. `make release` (`scripts/release.sh`) does all of it:

1. Builds the Release configuration for Apple silicon and Intel in one binary,
   without the end-to-end harness's control API, and fails if the binary
   carries any of it (`scripts/check-no-control-api.sh`, see The control API).
2. Signs it under the hardened runtime, which notarization requires, with a
   secure timestamp and `Resources/Athina.entitlements`, whose comments say
   why each entitlement is there (only `device.audio-input` today, for the
   talk-back microphone). Athina embeds no library yet; the libraries it will
   load from `Contents/Frameworks`, such as the local speech models' runtime
   (whisper.cpp for Whisper and Parakeet), are signed first with the same
   identity, so library validation loads them.
3. Submits the app to Apple's notary service, waits for the verdict, and
   staples the ticket to it.
4. Packages it as `Athina-<version>.dmg`, the app beside a link to
   Applications, signs the disk image, notarizes it, and staples it too; and
   as `Athina-<version>.zip` holding the stapled app.
5. Verifies what people download: `codesign --verify --deep --strict`, the
   hardened runtime flag and the exact entitlements, that the app inside the
   disk image and the zip is the one signed (the same code directory hash) and
   still verifies there, and Gatekeeper's
   `spctl` assessment of the app and the disk image as notarized Developer ID.
6. Keeps `Athina-<version>.dSYM.zip`, the debug symbols of exactly that binary,
   for reading crash reports, and Apple's notary logs.
7. Writes `Athina-<version>-notes.md`: the version and build, install steps,
   the notes written by hand in `docs/release-notes/<version>.md` as they are,
   headings included, and the SHA-256 of both downloads. Without that file it
   puts a marked placeholder in their place and names the file to create. It
   only reads `docs/`, never writes there.

Everything lands in `build/release`. The version is set in one place,
`Resources/Info.plist`: `CFBundleShortVersionString` is what people see
(1.2.3), `CFBundleVersion` a whole number that grows with every release. Every
build carries both, and the release names its files and notes from them.

### Once, before the first release

These need the owner's Apple account, so only the owner can do them. Nothing they
create goes in the repository.

1. Join the Apple Developer Program at developer.apple.com, with the Apple ID
   releases go out under.
2. Create a Developer ID Application certificate: Xcode > Settings > Accounts,
   select the team, Manage Certificates, then + > Developer ID Application
   (only the account holder can). Xcode puts it and its private key in the
   login keychain. Export a backup (.p12) and keep it somewhere safe: a lost
   private key means a new certificate. `security find-identity -v -p
   codesigning` then lists `Developer ID Application: <name> (<team ID>)`.
3. Make an app-specific password at account.apple.com > Sign-In and Security >
   App-Specific Passwords, and store it for the notary service under a profile
   name of your choosing:

   ```sh
   xcrun notarytool store-credentials athina-notary --apple-id <Apple ID> --team-id <team ID>
   ```

   It asks for the password and keeps it in the login keychain; `make release`
   names the profile, never the password.

### Each release

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in
   `Resources/Info.plist`, write what changed for the people using Athina in
   `docs/release-notes/<version>.md` (`## What's new`, say), and commit both
   (`chore(release): 0.2.0`). The notes live there, not in `build/release`,
   which every `make release` replaces.
2. From a clean checkout of that commit:

   ```sh
   ATHINA_NOTARY_PROFILE=athina-notary make release
   ```

   `ATHINA_RELEASE_IDENTITY=<name or SHA-1>` chooses the identity when the
   keychain holds more than one Developer ID Application identity; with one,
   it is found. The release refuses a worktree with changes, a version whose
   tag already points at another commit, and a build number no higher than
   the last release's.
3. Check the release build itself end to end, in replay as always:
   `ATHINA_E2E_APP=build/release/Athina.app scripts/e2e/athina-e2e run all`.
   That covers the real-screen tier; step 1's check proves the build carries
   no control API, so each API-tier scenario reports `skip`, and the API tier
   runs on the development build of the same commit
   (`scripts/e2e/athina-e2e run all` without `ATHINA_E2E_APP`).
4. Publish the disk image (and the zip, for anyone who prefers it) with
   `Athina-<version>-notes.md` as its notes, and tag the commit:
   `git tag v0.2.0 && git push origin v0.2.0`. The tag is what the next
   release's build number has to exceed and what stops a version being built
   twice.

There are no automatic updates yet: a new version is downloaded and dragged
over the old one.

Without the identity or the profile, `make release` still runs every step
that needs no Apple credentials: the hardened runtime build, signed ad-hoc
with the same bundle-identifier requirement a development build has, the disk
image and zip, and every check that needs no Apple service. (Library
validation loads only libraries signed by the app's own team, which an ad-hoc
signature lacks, so once the bundle embeds libraries, such as the local speech
models' runtime, that local build alone turns library validation off; a
Developer ID release never does.) It names each step it skipped and why (the
missing identity or profile), marks the notes "Not for distribution", and
exits 1. A profile that is set but does not work, or an identity that is named
but missing, fails before anything is built.

### A released copy and your data, grants, and key

A released copy is the same app as a development build: bundle identifier
`com.ahcarpenter.athina`, no sandbox, so the same
`~/Library/Application Support/athina`, the same preferences and the same
keychain item. It shares the live journal, settings and bill with `make run`,
so do not run both: `make run` refuses to start while a live Athina runs,
wherever it was installed.

- **Coming from Mentor.** The move of `~/Library/Application Support/mentor`,
  the preferences and the key (Coming from Mentor) runs on the first live
  launch of whichever Athina comes first, released or development, and only
  once.
- **Grants.** A grant made to a released copy is recorded against its Developer
  ID requirement, so every later release keeps it. Grants made earlier to an
  ad-hoc development build, recorded against the bundle identifier alone,
  hold for a released copy too; the reverse does not, and an ad-hoc build
  then reports the permission missing (Code signing). Once the Developer ID
  certificate is in the keychain, `make build` signs development builds with
  it as well when it is the identity `scripts/bundle.sh` picks (the first
  Apple Development or Developer ID Application one the keychain lists), or
  when `ATHINA_SIGN_IDENTITY` names it, so both meet one requirement.
- **The key.** The login keychain trusts a Developer ID app by its team rather
  than its exact binary, so a released copy asks once, Always Allow, to read a
  key a development build saved, and later releases do not ask.

The App Store is a separate route: it needs the App Sandbox, which moves the
app's data into a container, and App Review. None of that applies here, so
the data move and the grants above work as written.

## Architecture

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
                              ControlMode (whether a launch serves the control API, see The control API)
Sources/AthinaSQLiteShim      C, one function: the `sqlite3_db_config` call Swift cannot make (it is variadic),
                              so `DataMigration` can read the old journal without altering it
Sources/Athina                the app: MenuBarExtra, AppState, windows, ToastController (floating panel),
                              Overlay/CalloutController (click-through overlay), Voice/SpeechListener
                              (on-device speech recognition), HotKeyCenter (Carbon, press and release),
                              Snapshots
Tests/AthinaCoreTests         Swift Testing suites for the pure parts, with JSON fixtures under Fixtures/
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

### Journal

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
to defaults so older files keep working. A replay keeps both files in a data
directory of its own and starts from the live settings or the file `--settings`
names (see Replays side by side).

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

   Each tier has its own model and effort in Settings > Models. Effort (low,
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
   dismissed; a click on Athina's own menu bar item is not one, since it opens
   the menu that answers the toast. A timeout, or quitting the app with the
   toast still up, is journaled as expired. *Tell Me More* expands the full explanation above the
   button bar (scrolling past 300 points) and becomes *Show Less*; the three
   buttons stay pinned to the bottom edge in both states, and an expanded
   toast stays until closed. *Not Now* dismisses and snoozes that category for
   that app for `notNowSnooze` (1 h). *Never for This* records that the
   category must never be raised for that app again (the rule is listed and
   removable in Settings > General). The toast never takes keyboard focus, so
   the menu's Answer Suggestion submenu offers the same answers to the
   keyboard and VoiceOver, and VoiceOver announces a toast as it appears; while
   VoiceOver or Switch Control is on, a toast does not expire on its own. Every
   suggestion and every answer is journaled, and the history window
   (menu > Suggestions) lists them with time, app, category, feedback, and full
   text.

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
the spot and the note beside it on the same Liquid Glass as the toast, to its
right, where the rest of a line of text is usually empty (below the box, or
above it at the bottom of the display, only when there is no room). Athina's own windows are excluded from
capture, so the overlay never appears in a frame. Settings > General > "Show
callouts on screen" (on by default) turns callouts off; the history window
records for each suggestion whether one was drawn, and the debug panel's
Mentor card shows the last callout decision with the region in frame pixels
and in screen points.

### Talking back

A push-to-talk hotkey (the talk-back shortcut), recorded in Settings > General
the same way as the pause shortcut in Settings > Privacy and unset by default,
captures the microphone only while it is held. Carbon's hotkey registration
delivers both `kEventHotKeyPressed` and `kEventHotKeyReleased` for a
combination it registered, so `HotKeyCenter` hears the key go down and up
without Input Monitoring or any other permission beyond the two optional ones.
The same combination cannot be both the pause and the talk-back key; the
recorder refuses it and validation clears it. A recording is cut off after 30
seconds in case the release is missed.

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
whenever Athina is paused while one is held, it is journaled with the feedback
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

Settings > Contexts is where you say what you want
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
unique name of at most 60 characters and a description of at most 280. The pane
disables Add Context at the cap, refuses a name another context already uses,
and caps both fields as they are typed with a note at the limit, so nothing
saved is dropped or cut on the way in. With the switch on and no context
declared, nothing is inside anything: no triage call is made at all, and the
Contexts pane, the menu, and the debug panel all say so.

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
you where you were going. Athina now keeps a short record of the longer arc
and carries it from one call to the next.

**What it contains.** The model writes it, in four parts: the **goals** the
user appears to be working toward, most likely first, each with the evidence
for it and a confidence; a condensed **timeline** of what has happened; the
**mentor history**, what Athina has already said and how the user answered, so
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
goal they were judged against (shown in the history window), and Never for
This suppresses each one per app exactly like every other category.

**Size and lifetime.** `understandingTokenBudget` (1200 tokens, settable up to
3000 so a mentor reply keeps room for its thinking and a suggestion beside the
record) bounds it: the model is told the budget and the app trims to fit on
the way in, dropping the
oldest timeline entries first, then the oldest mentor history, then concerns,
then the weakest goals, always keeping the strongest goal. It expires after
`understandingIdleGap` with no activity (4 hours) and always at a new day;
expiry and reset are journaled.
**Reset Understanding…**, in Settings > Models and in the debug panel, asks
first and then forgets every revision at once. Revisions are inserted rather
than updated, so the journal keeps the trail of how the reading developed, and
the current one survives a relaunch.

**What it costs.** The common case is free: a mentor call was going to happen
anyway and the record rides along in its reply, paying only for the extra
output tokens it writes. A periodic refresh is one call on the understanding
model, text only. Measured on 2026-09-13 writing the first record from a
15-minute window: 12,899 input and 1,161 output tokens, $0.09, 70 seconds on
Claude Opus 5 at low effort. So an hour of reading and browsing with no mentor
call in it costs about $0.38 in refreshes against the $1 default cap. Raise
the interval, or pick Claude Haiku 4.5 for this tier, to spend less; both are
in Settings > Models. Like the mentor tier, a refresh holds triage while it
runs, so a long one costs a change moment or two as well. The debug panel's
Understanding card shows the revision, when it was last written, which path
wrote it, its size against the budget, and what refresh calls have cost since
this understanding began.

### Spend control

Every response's usage fields (`input_tokens`, `output_tokens`,
`cache_creation_input_tokens`, `cache_read_input_tokens`) are priced with the
table in Settings > Models (dollars per million tokens, defaults checked
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
  loop, only when an API key is saved, and only while the loop is enabled or
  when the user asks for a Test Connection. No other part
  of the app has network code.
- **Audio and transcripts stay on this Mac.** The microphone is open only
  while the talk-back key is held, and only the system's on-device recognizer
  ever hears it; audio is never stored. The one exception is deliberate: a transcript you spoke while holding
  the key (or typed into the debug panel's Talk back field), when it is not
  one of the toast's answers, is sent to the mentor tier as your follow-up
  question, together with the suggestion it is about,
  the earlier questions and answers on that suggestion, and the recognized
  text of the screen the suggestion was made from; it is journaled as a
  talk-back event too, so for up to ten minutes it is among the recent events
  that triage, mentor and understanding calls are sent. Transcripts are
  journaled locally with the answers so the history window can show the
  exchange.
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
  screenshot" in Settings > Models turns the image off, in
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
  panel and Settings > Models, whenever Athina is on and has a key.
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
  and common password managers. While one is frontmost Athina captures no frame,
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
  (`~/Library/Application Support/athina/recordings` unless another directory is
  given, mode 0700, files 0600). The API key is never written, and any
  Anthropic key visible in the screen text is redacted, though not inside the
  screenshot. `make clear-recordings` deletes them; Clear Journal does not. A
  replay (`--replay`) sends nothing anywhere, keeps its own journal and
  settings, and starts from the live settings (or a `--settings` file it never
  writes), so excluded apps stay excluded while replaying.
- **Committed fixtures** carry only staged, synthetic screen content, recorded
  for the purpose, never the captain's or any user's real work. Every recording
  is read, text and screenshot, before it is committed.
- **Pause** from the menu or with the global hotkey (default ⌃⌥⌘P) stops all
  sensing; the menu bar owl drops a lid over its eyes. Idle closes them and two
  z's drift off it, an excluded app looks away, missing permissions is a wide
  stare, and a held mentor tier winks (see Design conventions).
- Thumbnails expire after 6 hours and text after 7 days by default; the journal
  is capped at 500 MB; all three are adjustable, and the journal can be cleared
  at any time. A replay senses the real screen too, and a finished replay's
  journal is never opened again, so nothing can age it in place: the next
  replay launch removes its whole per-launch directory instead, once that
  directory has gone unwritten for longer than the thumbnail window (see
  Replays side by side).
- **Delete `~/Library/Application Support/athina/replay` yourself if you ran a
  replay on a build before this one.** Those builds kept one shared
  `journal.sqlite` there, holding thumbnails and recognized text from your real
  screen, and nothing ages it now: no launch opens it, so retention never runs
  against it, and Athina will not remove it for you. It cannot: an older build
  from another checkout may have that file open this minute, and a file's
  timestamps cannot tell that apart from one nobody has touched since the Mac
  went to sleep, so deleting it on a guess could pull the database out from
  under a running instance. Quit every Athina on the Mac and remove the
  directory. Per-launch directories, the ones this build makes, are swept for
  you, because a launch holds a lock on its own and the sweep takes that lock
  before it removes anything.
- The journal directory is created with mode 0700. Athina makes every one of
  them itself, the live one and each replay's, so there is no path someone
  else chose for a journal to land in.

## Debug panel

The debug panel is a builder's window, so it is off until the person turns it
on: Settings > Advanced > **Enable debug panel**, then **Open Debug Panel**
beside it. While the switch is on, the menu bar menu also offers a **Debug
Panel** command, in a group of its own after Settings…, the way Safari's
Advanced switch adds its Develop menu; it appears and goes the moment the switch
changes, with no relaunch. Every install starts with the switch off, an install
from before it existed included, and turning it off closes the panel and takes
the command out of the menu. No other window links to it, so while the switch
is off nothing in the app opens it. The pane and the menu read the switch
itself; which launches may open it at launch is one pure rule,
`DebugPanelAccess`, under test.
The builder's paths reach it without changing the owner's setting:

- **A replay**: `open -n build/Athina.app --args --replay <dir> --open debug`
  opens it whatever the switch says. `make run-replay` passes no `--open`, so
  there it opens from the replay's own Settings > Advanced, or from its menu
  while the switch is on: the switch starts where the live one is (or where
  `--settings` puts it), and turning it on there is saved only to the replay's
  own settings file.
- **A recording**: `make record` passes `--open debug`, which a recording
  honours whatever the switch says, for the follow-up question typed into the
  panel's Talk back field (see The committed fixtures).
- **The end-to-end harness**: a scenario that needs the panel puts
  `--open debug` in its `SCENARIO_ARGS` (`understanding-surfaces` does), and
  `athina-drive ax ... --scope "Debug Panel"` reaches its controls, or on the
  API tier `athina-drive api ... window="Debug Panel"` (`debug-timeline`).
  Capture Now is the menu's own command, not the panel's.
- **Snapshots**: `--snapshot` draws the panel's view directly
  (`debug-panel*`) and the Advanced pane with the switch off and on
  (`settings-advanced`, `settings-advanced-on`). A menu opens only on screen,
  so `--snapshot` draws none; the `debug-panel-access` scenario reads the
  menu's items as the app builds them, without and with the Debug Panel
  command, through the control API (see The control API).
- **A live launch** given `--open debug` opens the panel only while the switch
  is on.

The panel itself. Left: frontmost app, window, the Mentor loop card
(availability, the last triage gate decision and its reason, the current
mentorship context verdict, the last triage and mentor calls with tokens,
cached tokens, estimated cost and latency, spend this hour, the cadence state
with the current slowdown, the last callout decision with its region in frame
pixels and screen points, and the last transcript with what was done with it),
the Understanding card (revision, when and how it was last written, the
inferred goals with their evidence and confidence, what has been done and
said so far, open concerns, the refresh interval, when the next refresh is
due, running, or why it is held, size against the budget, what refresh calls
have cost since it began, the last refresh call, and Reset Understanding…),
focused element (role, title, description, text), cadence settings and
counters, journal size and path. Centre: the latest kept frame with OCR boxes
overlaid and the recognized text below; selecting an observation in the
timeline shows that frame instead. Right: a live timeline of observations and
events from the journal (suggestions and feedback included), or, under Model
Calls, a scrolling log of every API call with prompt size, tokens, cost,
latency, outcome, and the model's reason. The status bar shows mode, permission
state, last and next capture with reason, seconds since input, spend this hour
against the cap (for live calls), and the app's own CPU and memory. While calls
are replayed or recorded, the status bar and the Mentor card carry a Replay or
Recording badge, the card says where calls go (for a replay, the fixtures by
kind and their directory, and any stale ones), and each replayed call in the
log is tagged Replay and not billed. In a replay the Mentor card shows what the
clock reads and has the Advance field that moves it ahead, and the badge says
how much faster the clock runs when it does (Replay 60x; see A faster clock).
A replay's card also shows its own data directory and the settings it started
from, and on any launch the card says why a `--settings` or `--replay-latency`
flag was refused (see Replays side by side and Replay).

## Design conventions

Every surface follows Apple's Human Interface Guidelines for macOS, audited
against the live guidelines on 2026-09-15, so later changes keep to them
rather than re-auditing. The sections Athina leans on are Designing for macOS,
The menu bar (menu bar extras), Menus, Windows, Panels, Settings, Layout,
Typography, Color, Dark Mode, Materials (Liquid Glass), Icons, SF Symbols,
Buttons, Toggles, Pickers, Text fields, Lists and tables, Alerts, Feedback,
Writing, Onboarding, Privacy, Accessibility, Keyboards, and Motion. The choices
particular to this app:

- **The menu bar extra is the app.** Athina has no Dock icon or app menu, so
  its menu leads with dimmed status rows (a status that needs something, such
  as a missing key, is the command that fixes it), then commands, windows, and
  the app menu's About and Quit. Menu items use title case and an ellipsis only
  where more input follows, and no standard keyboard shortcut is repurposed.
  The icon is the owl as a template image, one variant per mode, with a word
  beside it only in replay or recording.
- **The mark is the artist's drawing, and every asset comes from a vector.**
  `Resources/Mark/AthinaMark.svg` is the master for the app icon: a profile in a crested
  Corinthian helmet over a flat cream circle, square and hexagon, in the
  reference bitmap's own coordinates, with the line art and the cream shapes in
  separate groups so either stands alone. Ink is `#332C2B` and cream `#F1DEB7`,
  both sampled from the drawing rather than chosen. `make mark`
  (`scripts/mark-assets.swift`) builds the app icon from it, the icon at the
  top of this README from that icon (as macOS itself draws it, masked and
  shadowed), and the menu bar mark from the second master, the owl below;
  their outputs are committed, so a plain `make build` needs nothing else, and
  `MarkAssetTests` fails when either master or the script changes without
  `make mark` being run. The script is in
  that record because most of the drawing lives there rather than in the
  masters: the menu bar inset, the eye treatments, the z's and the per-size
  thickening are all constants in it.
- **The app icon is the full artwork, full bleed.** macOS 26 masks a legacy
  `.icns` to the standard app icon shape itself and adds the shadow, in Finder,
  in the Dock and in About, scaling the artwork into the 824 of 1024 body, so
  the icon draws no rounded rectangle and no shadow of its own and keeps the
  drawing clear of the corners the mask rounds away. Each size is drawn from
  the vector and weighted for itself, which is what the `.icns` format exists
  to allow: the drawing's stroke is under a pixel by 32 px and would otherwise
  grey out.
- **The menu bar mark is the owl, at one width in every mode.**
  `Resources/Mark/AthinaOwl.svg` is a second master, for the menu bar only: a
  solid owl silhouette, so it sits among the bar's other extras instead of
  reading lighter than all of them the way a line drawing does at 16 points.
  It ships as a template PDF per mode, so macOS tints it like every other extra
  and one file serves every display scale. The states are made out of the
  drawing rather than hung off it: the owl's eyes are the boldest thing in it
  at this size and they are what watching means, so they carry the modes and
  the silhouette never changes. Idle, the state that says the user has stepped
  away, also gets two z's drifting off it, drawn in the clear upper left of the
  owl's own bounding box: with the pupils gone the eyes are the whitest thing
  in the set and read wide awake rather than shut, so the z's are what actually
  say asleep. Paused, the deliberate stop, takes the half-lidded eyes. Every
  state, the z's included, is made inside the owl's own box, which is what
  keeps the item one width throughout, so the other extras never shift
  sideways when Athina's state changes. Which variant a mode gets is
  `MenuBarMark.resolve`, a pure function with the whole table under test.
- **The toast is a non-activating panel, not a notification.** It floats under
  the menu bar on Liquid Glass and never takes keyboard focus, with corners
  concentric with its small capsule buttons. Because it cannot be focused, the
  menu's Answer Suggestion submenu carries its answers, VoiceOver announces
  it, and it does not expire while VoiceOver or Switch Control is on.
- **The callout is a click-through overlay** that draws its own accent stroke,
  since nothing in the system frames a spot in another app's window; its note
  sits on the toast's glass. It only fades in, and Increase Contrast thickens
  the stroke and drops the glow.
- **Settings is the SwiftUI `Settings` scene**: a toolbar of panes, the window
  titled by its pane, the last pane remembered, each pane a fixed-size grouped
  form that scrolls. Rows use the form's own label and subtitle styling, and a
  place elsewhere in Settings is a link, not a description. A duration row given
  its setting's range offers only what that setting accepts: its unit pop-up
  lists the units the range holds a whole amount of, and an amount typed outside
  the range settles at the nearest allowed one as the edit ends, rather than
  being clamped out of sight afterwards.
- **Tools for looking inside Athina are opted into in the Advanced pane.** The
  debug panel is offered only once Settings > Advanced > Enable debug panel
  is on, the pane last in the toolbar as Safari's is, whose Advanced pane holds
  "Show features for web developers" for the same reason: the HIG (Settings)
  asks for defaults that give the best experience to the most people and for
  panes that each group related settings, and a window of model calls and
  captured text is neither for most people nor related to any other pane.
  Its button sits in the switch's own group and is dimmed while it is off.
  While it is on, the menu bar menu adds a Debug Panel command, as Safari's
  switch adds its Develop menu between its everyday menus and Window: in a
  group of its own after the everyday windows and Settings…, before About and
  Quit, since the HIG (Menus) asks for related items grouped between
  separators. It has no keyboard shortcut: the HIG (Keyboards) keeps custom
  shortcuts for commands people use often, and in this menu only Settings…
  and Quit, whose shortcuts are standard, and Pause Watching, a hot key the
  person chooses, have one.
- **Status is never color alone.** Inline messages are `StatusLabel` and badges
  are `StatusBadge` (`Sources/Athina/Components.swift`): the symbol or capsule
  carries the color, the words stay in a label color. Text uses system text
  styles and label colors, never fixed point sizes or tertiary text for
  anything that must be read.
- **What cannot be undone asks first.** Clear Journal… and Reset
  Understanding… open a confirmation that names what is lost; the confirming
  button is plain, since it is what the person chose, and Cancel is always
  there.
- **Permissions explain before they ask.** The window never prompts on its own,
  each permission has one button, and the purpose strings in
  `Resources/Info.plist` say the same as the window in one sentence.
- **Words.** Buttons, menu items, window titles, and column headings use title
  case; labels, section headers, and status words use sentence case. The
  interface says keyboard shortcut rather than hotkey, names panes and places
  plainly, and speaks of Athina in the third person, never "we".

## Code style

Every Swift file follows [Google's Swift Style Guide](https://google.github.io/swift/),
Apple's API Design Guidelines included. The part a tool can apply is
`.swift-format`, the configuration for the swift-format that ships with
Xcode, so nothing needs installing: two-space indents, a 100-column limit,
line wrapping in one direction, and the guide's naming, documentation and
programming-practice rules that swift-format checks. `make format` rewrites
every Swift file to it, `make lint` fails on anything it would change and on
every rule it can only report, and CI runs `make lint` on every pull request
and every push to `main`.

A newer swift-format can format the same code differently, so the one CI runs
is pinned: `.xcode-version` names the Xcode every CI job runs, and so the
swift-format it ships with, as `xcodebuild -version` prints it (26.6 today:
Swift 6.3.3, swift-format 6.3.0). The `lint` job selects that Xcode by its
exact path, as every job does (see Continuous integration), and prints the
Swift and swift-format versions that ran. `make format` and `make lint` read the same file and warn when the
selected Xcode is another; `DEVELOPER_DIR=<path to that Xcode.app>`
runs either with the pinned one. Xcode 27.0's swift-format, which reports its
version as `main`, formats this code identically today.

To move the pin, once the `macos-26` image lists the new Xcode (its
[readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
names each path):

1. Write the new version into `.xcode-version`.
2. Run `make format` and `make lint` with that Xcode, and fix what the linter
   reports.
3. Commit the pin and any reformatting together as one `style` commit, so
   every commit lints clean with the swift-format it pins.

`make lint` cannot see every rule. By hand, and in review:

- Every public declaration gets a `///` comment that opens with a
  one-sentence summary; the linter asks for it, the words are yours. A
  comment that repeats the name says nothing: define the term instead.
- A parameterized attribute (`@Environment(...)`, `@Suite(...)`) goes on its
  own line above its declaration.
- A call with one closure argument, last, passes it as a trailing closure
  (except in an `if`, `guard` or `while` condition); a call with several
  closure arguments passes them all inside the parentheses, labeled, with no
  trailing closure. SwiftUI's `Button(action:label:)`,
  `Section(content:header:)` and the like are written that way; only an API
  whose body is unlabeled after a defaulted argument, such as
  `withKnownIssue`, keeps its trailing closures.
- A wrapped list, conditions included, puts every element on its own line;
  swift-format keeps those breaks but does not add them.
- Initializers, and functions that share a name, sit next to each other.
- A string that runs past 100 columns is wrapped as a multi-line string
  literal with `\` at each line end, which leaves the string itself as it was.
- Outside tests, a force unwrap, force cast or `try!` carries a comment
  saying why it cannot fail, unless the line alone makes that plain.
- Each file imports every module it uses by name (Foundation and
  CoreGraphics too, not through AppKit or SwiftUI), and nothing else.

### Rebasing a branch across the reformat

The reformat is one commit on `main` that changes nothing but formatting, the
first of the commits named in `.git-blame-ignore-revs`, which `git blame` skips
once `git config blame.ignoreRevsFile .git-blame-ignore-revs` is set (GitHub
reads it itself); the others are the style commits after it. The commit before
it adds `.swift-format` and `make format`. A branch started earlier formats
itself with them first and then crosses the reformat, so that only real
changes conflict:

```sh
git fetch origin
reformat=$(git show origin/main:.git-blame-ignore-revs | grep -v '^#' | grep . | head -n1)
# 0. Stop unless main holds that very commit and the branch forked from main
#    no later than the commit before it: an empty $reformat stops every step.
if ! git merge-base --is-ancestor "$reformat" origin/main; then
  echo "Stop: origin/main does not contain the reformat commit $reformat." >&2
  reformat=
elif ! git merge-base --is-ancestor "$(git merge-base HEAD origin/main)" "$reformat~1"; then
  echo "Stop: this branch forked from main after $reformat~1; see below." >&2
  reformat=
fi
# 1. Catch up to just before the reformat, resolving real conflicts as usual.
git rebase "${reformat:?}~1"
# 2. Format every commit of the branch where it stands.
git rebase --exec 'make format && git commit -a --amend --no-edit --allow-empty' "${reformat:?}~1"
# 3. Cross the reformat. Both sides are formatted now, so every conflict is
#    formatting the branch already has right: -X theirs keeps the branch side.
git rebase -X theirs "${reformat:?}"
# 4. Carry on to the tip of main, resolving real conflicts as usual.
: "${reformat:?}" && git rebase origin/main
: "${reformat:?}" && make lint
```

The reformat keeps its id on `main` only because the change that brought it
landed as a merge commit; a squash or rebase merge gives it a new one, and
`.git-blame-ignore-revs` would then name a commit `main` does not have, which
step 0 catches. Run the steps one at a time: each must finish cleanly before
the next begins.

Step 0 also stops a branch that forked from `main` after the commit before the
reformat: steps 1 and 2 would carry `main`'s own later commits back onto an
older base, and step 4 would replay them onto a `main` that already has them.
Such a branch takes the short way instead, resolving conflicts as usual:

```sh
git rebase origin/main
make format
git commit -a -m "style(athina): format the branch to Google's Swift style"
make lint
```

`-X theirs` in step 3 is safe only because step 1 settled every real conflict
and the reformat commit holds nothing but formatting; replaying `main`'s own
two commits before it this way reproduces the reformat's tree exactly. A branch
with a merge commit in it is flattened by a rebase; give every step
`--rebase-merges` instead.

## Continuous integration

CI runs four checks on GitHub's `macos-26` runner, which ships Xcode 26 and
the macOS 26 SDK this package targets: `build-and-test` runs `swift test`, the
bundle script, and `scripts/check-no-control-api.sh` (which must find the
control API in the development bundle and none in a build without the
`ControlAPI` trait, for which it takes the debug `Athina` the tests' build
already made rather than compiling the package again); `lint` runs `make lint` (see Code style) and fails on any
finding; `ui-snapshots-smoke`, the fast UI check, draws every
snapshot inside a test process with swift-snapshot-testing and compares each
with its reference image (see UI snapshot smoke test); and `ui-snapshots`, the
full-fidelity UI check, renders every snapshot with `Athina --snapshot`
through the window server, so Liquid Glass and materials are in them,
replay-mode renders on a scaled clock included, compares the renders with the
approved baselines, and uploads them (see UI snapshot baselines).
`ui-snapshots` is split across four runners that each take a quarter of the
snapshots, by the `SnapshotShard` table, and `ui-snapshots-smoke` draws them
all on one. Both draw the same list of snapshots, so a UI change drifts both,
and each has its own approved images:
`make snapshots-approve` approves the `ui-snapshots` baselines from HEAD's
merge-checks run and `make snapshots-smoke-approve` the `ui-snapshots-smoke`
references from HEAD's CI run, both from the runner and never from a Mac. The
Xcode project's archive check is out of CI until the App Store release flow
brings it back as part of that flow (see The Xcode project).

All four run on every push to main. On a pull request, `build-and-test`, `lint`
and `ui-snapshots-smoke` (`.github/workflows/ci.yml`) run on every push, and the
slow `ui-snapshots` (`.github/workflows/merge-checks.yml`) runs only while the
pull request carries the `merge-checks` label: adding the label runs it, and
so does every push, or any other label added, while it is on. Anyone with write access can add it,
from the pull request page or with

```sh
gh pr edit <number> --add-label merge-checks
```

All four must pass at a pull request's head before it can merge: the `main`
ruleset requires them, with no bypass, and until `ui-snapshots` has run there,
the pull request lists it as expected and cannot merge. Two traps shape this.
A job that an `if` skips still reports a check run, and a skipped check counts
as passed for a required one, so the skipped job takes another name: GitHub
names a skipped job after its unevaluated `name:` expression, which is not
`ui-snapshots`, and the expression's own answer for a skip is not either. And
a `workflow_dispatch` run of the same job does not count: its checks are on
the commit, but a pull request's required checks ignore them.

The ruleset is kept in `.github/rulesets/main.json`; after a change to it,
apply it with

```sh
gh api -X PUT "repos/ahcarpenter/athina/rulesets/$(gh api repos/ahcarpenter/athina/rulesets --jq '.[] | select(.name == "main") | .id')" --input .github/rulesets/main.json
```

(`gh api -X POST repos/ahcarpenter/athina/rulesets --input .github/rulesets/main.json`
creates it if it is gone). It requires each check from GitHub Actions itself
(integration 15368), so a commit status of the same name cannot stand in for
one, and it does not require a branch to be up to date with main, so a pull
request is not rerun each time another merges.

**One Xcode, pinned.** Every macOS job selects the Xcode that `.xcode-version`
names, as `xcodebuild -version` prints it (26.6 today), through the shared
step in `.github/actions/select-xcode`: by its exact path on the runner,
`/Applications/Xcode_<version>.app` or the image's other name for it,
`/Applications/Xcode_<version>.0.app`, never the newest there. It fails,
naming the Xcodes the runner has, when neither exists, and fails when that
Xcode reports another version. So a new runner image changes no build, render
or formatting by itself: moving the pin is one deliberate commit that
refreshes both sets of approved images and runs `make format` with the new
swift-format (see Code style and UI snapshot baselines). When GitHub's macOS
27 image leaves preview, CI moves to it in such a commit.

**Superseded runs.** A new push to a pull request cancels that pull request's
runs still going, in both workflows, and so does a label added while
merge-checks runs, so a superseded commit stops holding runners: the account
runs five macOS jobs at once. Pushes to main are never cancelled; each keeps
its own run.

Local validation, the no-mistakes pipeline a change goes through before its
pull request, never runs the Xcode project steps, the full `ui-snapshots` gate
or either approve command, which only CI proves, and compares the UI smoke set
with main's on the Mac itself (see UI snapshot smoke test);
`test.instructions` in `.no-mistakes.yaml` carries that rule to its test step.

No test waits on real time (see A faster clock). The tests
exercise the pure parts
(hashing, cadence, journal, retention and its in-place migration, settings, the
mentor scheduler and every gate, mentorship context rules and placement, spend
accounting, snooze and never-for-this rules per category, the rolling window,
the understanding's encoding, versioning, bounding and expiry, prompt assembly
with and without one, request and response coding against fixture JSON,
recording, redaction, replay matching and stale refusal, launch flags, a
replay's separate files, per-launch directories with their locks and pruning,
the replay-only `--settings` flag, the line a launch writes as it starts, the
clocks, a replay's clock flags, the clock requests a script sends and where a
replay may answer them, the toast countdown, which variant of the mark the menu
bar shows and that every variant is committed at one size, callout mapping and
every anchor rejection, a callout aging out, transcript matching, the follow-up
prompt and gate, the toast rule for voice input, the whole loop against a
scripted client, follow-ups included, and the whole loop against the committed
replay fixtures, replayed strictly, a region and a follow-up answer included,
and every time-based behavior of the loop on the test clock) and Vision OCR on a
drawn bitmap, so they need no
permissions, display, network, microphone, or API key. A committed fixture that
is stale, or a tier with no committed fixture, fails the run (see The committed
fixtures). The snapshot run covers every window and Settings pane with sample
data, their empty states (no suggestions, no frames, no contexts, contexts at
the cap), the Understanding card with a record, with none, paused, with a
refresh call in flight, and after a failed refresh, the Understanding settings
section with and without a record, the callout over the sample frame, the toast
collapsed, expanded, listening, thinking, answered, and as a note, the context
editor with a duplicate name, the transient status messages (a connection test,
a refused or recording shortcut, on-device recognition unavailable), and every
variant of the menu bar mark, at the size the bar draws it, with the word a
replay puts beside it, and enlarged.

### UI snapshot baselines

`Tests/Snapshots` holds the approved render of every snapshot, light and dark,
rendered on the CI runner, which is the one reference environment. The
`ui-snapshots` check runs on four runners at once, the `ui-snapshots shard 1`
to `4` jobs, and passes only when all four do. Each (`scripts/snapshots.sh
gate <k>/4`) builds the app, renders its own snapshots twice and fails unless
the two renders are the same picture, then compares each render with its
baseline and fails on any drift. Which shard renders a snapshot is fixed in
`SnapshotShard.assignment` (`Sources/SnapshotDiff`), which keeps the four even:
a new snapshot needs a line there, since a render fails while any snapshot has
no shard or any line names a snapshot that is gone, and a baseline whose
snapshot has no shard is compared by the first, so a removed snapshot is still
caught. `scripts/snapshots.sh gate` with no shard renders and compares them
all. A pixel counts
as changed when any of its channels moves by more than 6 of 255: that covers
the shading an anti-aliased edge can pick up and the window server's glass,
which on the runner draws a dark switch's knob one of two ways from one window
to the next (a few dozen pixels, up to 5 of 255 apart), and nothing a person
would see, since a shifted edge, a new colour or a moved line moves some
channel much further. A new snapshot fails until its baseline is approved, and
a baseline the renderer no longer produces fails until it is deleted. For
every drifted snapshot the shard lists what changed in its summary and uploads
the `ui-snapshot-report-shard-<k>` artifact: the approved image, the new render and the
difference (changed pixels in red over a faded copy), one folder each, with an
`index.html` that shows them side by side at real size. The comparison is
`snapshot-diff` (`Sources/SnapshotDiff`, with unit tests), and the renderer
uses the same rule.

A render is the same on every run because nothing in it depends on when or
where it was made:

- **A fixed clock.** Every sample stands still at one moment,
  `Snapshots.referenceDate`, so every age, clock time and date reads the same,
  and `scripts/snapshots.sh` renders in UTC and US English with scroll bars
  always shown, whatever the Mac is set to.
- **Animations off.** No SwiftUI animation runs; a pulsing symbol draws at rest
  and a readout that ticks every second draws once (`drawsStill`); and once the
  view has settled, Core Animation's clock in the window stops at a time before
  any animation began, so a spinner draws its resting state.
- **A fixed backdrop.** The render window is opaque and paints the window
  background of its appearance, so glass and materials sample that and never
  what is behind the window. Dark mode's wallpaper tinting still reads the
  desktop picture, which the runner never changes.
- **Settled, and agreed.** A window is captured until two captures in a row
  are the same picture, and each snapshot is rendered in fresh windows until
  two in a row agree, because AppKit now and then lays a text field out a
  point off in one window. Captures are kept in sRGB whatever the display's
  profile.
- **One way of capturing.** A run captures every window with ScreenCaptureKit
  when it has Screen Recording, as the runner does, and renders each window's
  layer tree when it does not, and says which on its first line. The two draw
  glass differently, so a run never mixes them: a ScreenCaptureKit capture
  that fails is taken again, never drawn the other way.

**Approving an intended change.** Push the change, with the `merge-checks`
label on its pull request (see Continuous integration), and let `ui-snapshots`
fail on the drift, look at the report, then run `make snapshots-approve` (or
`scripts/snapshots.sh approve`), which downloads the renders of all four
shards of HEAD's newest merge-checks run, the `ui-snapshots-shard-<k>`
artifacts, and makes `Tests/Snapshots` match them: a changed or new
snapshot's render replaces its baseline, a removed snapshot's baseline is
deleted, and every other file is left alone. `RUN=<id>` names another CI run.
A shard publishes its renders only once both its renders finished and agree,
and approve refuses a run unless every shard did, since a missing shard's
snapshots would read as removed; so a run that failed, timed out or was
cancelled before then has nothing to approve, and the renders name the source tree they were made from, which
approve refuses unless it is HEAD's own. A pull request's run renders the
branch merged with main, so once main has moved on since the branch, merge or
rebase onto main and push before approving. Commit the images with the change
that caused them; the pull request then shows each one before and after, and
CI passes. Baselines never come from a developer's Mac, and there is no local
comparison: a Mac on another macOS, at another display scale, renders text
edges and glass differently everywhere, so only the runner's renders are
compared or approved.

**A runner change is a deliberate refresh.** The baselines depend on the
runner's macOS image and the Xcode that `.xcode-version` pins (see Continuous
integration). Moving to a new image or a new pin changes the renders with no
change to the app; approve them from a CI run of an unchanged commit, in a
commit of their own that names the new image or Xcode, so a real UI change is
never approved under it.

**Size.** The set is a few megabytes of PNGs, rendered at the
runner's 1x scale, and an approval adds only the images that changed to the
history, so the repository keeps them as ordinary files rather than in Git LFS,
which would add a download quota and an extra step to every checkout.

### UI snapshot smoke test

`ui-snapshots-smoke` is the fast UI check, run on every push to a pull request
and to main. `make ui-snapshots-smoke` (`scripts/snapshots.sh smoke`) runs
the `UISnapshotsSmokeTests` target, which draws every snapshot `--snapshot`
renders, from the same list (`Snapshots.specs()`) and the same sample data,
light and dark, in the same kind of window, settled by the same rule, and
compares each with its reference image in
`Tests/UISnapshotsSmokeTests/__Snapshots__/UISnapshotsSmokeTests` with
[swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing).
The two gates cannot drift apart: a snapshot added to the list is in both.

In CI it runs on one runner, the `ui-snapshots-smoke` job, the check the
ruleset requires, which runs `make ui-snapshots-smoke` and draws every
snapshot. Most of that job is fetching and compiling; drawing all 76 images
takes about a minute and a half, so it ends inside `build-and-test`, where
four runners each compiled the test again for a quarter of the drawing.
`make ui-snapshots-smoke SHARD=<k>/4` still draws only the snapshots
`SnapshotShard` gives shard k (the test reads the shard from
`UI_SNAPSHOTS_SMOKE_SHARD`), should it be split again.

It draws each window inside the test process, with swift-snapshot-testing's
view strategy on the window's frame view (the view under the content that
paints the window's background), rather than capturing it from the window
server, so it builds and runs in a fraction of the time `ui-snapshots` takes.
Its pictures leave out what only the window server composites: Liquid Glass
and materials are not drawn, so a toast shows its words and controls on the
plain window background, and what sits on glass can take another colour or,
like the toast's button bezels, close button and microphone in light mode,
not show at all. Scroll bars are always shown, as on the runner, whatever the
Mac is set to. It catches a changed
layout, text, colour, control or state; how glass looks is `ui-snapshots`' to
check. A pixel matches when it is within 2 Delta E of the reference (a
perceptual precision of 98 percent), the difference the eye cannot see, which
covers anti-aliasing and nothing a person would notice. A render reads the same
on every run for the reasons a `--snapshot` render does (see UI snapshot
baselines), in UTC and the runner's US English locale, drawn at the runner's
1x scale whatever the display's: a fixed clock, animations and Core Animation's clock stopped, a window
with a fixed backdrop, and captures until two in a row agree, in fresh windows
until two agree. A window drawn in process is drawn as its layers stand, so
it skips the wait `--snapshot` gives a fade to end before its first capture.

The test never records a reference. A snapshot with no reference fails, as a
drifted one does, and a reference no snapshot produces fails until it is
deleted. The job names each drifted snapshot in its summary and uploads the
`ui-snapshots-smoke-report` artifact: one folder per snapshot with the
reference (`reference.png`), the new render (`failure.png`) and their
difference (`difference.png`), or only the render when there is no reference
yet.

The target and its one dependency sit behind the `UISnapshotsSmoke` package
trait, which only `make ui-snapshots-smoke` and `make ui-snapshots-smoke-local`
turn on. Without it the target
has no tests and no dependencies, so a plain `swift test` (what `make test`
runs), `build-and-test`, the app, `make release` and the Xcode project never
fetch, build or run it. It is pinned to one release in `Package.swift`, and
the package's `Package.resolved` is not committed, since a committed one would
have every build fetch every package it names.

**Approving an intended change.** Push the change and let
`ui-snapshots-smoke` fail on the drift, look at the report, then run `make
snapshots-smoke-approve` (or `scripts/snapshots.sh smoke-approve`), which
downloads the set HEAD's newest CI run published (`ui-snapshots-smoke-set`)
and makes the references folder match it exactly: the run's render of every
snapshot that drifted or was new, the reference of every one that matched,
which comes back unchanged, and nothing else, so a removed snapshot's
reference goes. `RUN=<id>` names another CI run. The job publishes the set
only once every snapshot has rendered, the set names the source tree it was
made from, and approving refuses any tree but HEAD's, as `make
snapshots-approve` does, and a set that names a shard, which holds only that
shard's snapshots. A UI change drifts both gates, so
approve both, each from its own run of HEAD, and commit the images together
with the change that caused them. References never come from a Mac: they are the
runner's, rendered at its 1x scale on its macOS, and a Mac on another macOS or
display scale draws differently everywhere, so `make ui-snapshots-smoke` on a
Mac only shows how it would draw. The runner's image and the pinned Xcode are a
deliberate refresh here too, approved with the baselines in a commit of their
own.

**On a Mac, against main.** Since a Mac cannot match the runner's references,
local validation compares a change with main on the same Mac instead: `make
ui-snapshots-smoke-local` (`scripts/snapshots.sh smoke-local`) draws the smoke
set at HEAD and at its merge-base with `origin/main` (or `BASE=<commit>`) and
compares each pair by the same 98 percent rule. A few details, such as a dark
switch's knob or a text field laid out a point off, settle one of two ways in
a process and keep it for every draw there, so the base is drawn in three
processes and a screen matches when it matches any of them, and a screen that
matches none is drawn again in up to two fresh processes and is changed only
when it differs every time. The base's sources come from `git archive` into a
temporary folder, never a worktree, and its renders are kept in
`~/Library/Caches/athina-snapshots-smoke/<commit>`, so later runs off the same
main draw only HEAD. It fails only when a snapshot could not be drawn (the test
failed, drew a blank picture, or ran past 30 minutes); a changed, added or
removed screen is a report, in `build/snapshots-smoke-local/summary.md` with
the base, new and difference images of each, for whoever reads the change to
judge. A base from before this mode has no set to compare, so HEAD is drawn
alone. The pixel comparison with the runner's references stays in CI.
