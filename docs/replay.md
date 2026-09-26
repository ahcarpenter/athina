# Iterating without the network

Working on Athina needs no live call to Anthropic to build, test, or verify.
The app, its tests, and every verification run use **replay**: each model call
is answered from a recorded fixture, with no network, no API key, and no spend.
Replay is the default way to exercise the app, including the end-to-end checks
a change gets before it ships. Live calls are for two deliberate occasions
only: recording fixtures, including re-recording the committed set when a
change makes it stale, and the separate live check of the models' answers.

## Replay

```sh
make run                            # the committed fixtures
make run REPLAY_DIR=~/Library/Application\ Support/athina/recordings
make run ALLOW_STALE=1              # also serve stale fixtures, see below
make run TIME_SCALE=60              # on a clock 60 times real time, see A faster clock
make run SETTINGS=check.json LANE=a # its own settings, in a lane of its own, see Replays side by side
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
harness). `recorded`, the default, names the usual, so `make run` still
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
committed fixtures). `--allow-stale-fixtures` (`make run ALLOW_STALE=1`)
serves stale fixtures anyway, and is only for replaying locally while
iterating on prompts.

## A faster clock

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
make run TIME_SCALE=60
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

## Replays side by side

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
  the path is spelled. `make run` prints it, the debug panel's Athina
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
- **`--settings <path>`** (`make run SETTINGS=<path>`) starts the
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
- **Launching never quits another Athina.** `make run` replaces only the
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
make run LANE=a SETTINGS=/tmp/a/settings.json TIME_SCALE=60
make run LANE=b SETTINGS=/tmp/b/settings.json
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

## Record

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
while it runs. Deleting the app's own recordings directory,
`~/Library/Application Support/athina/recordings`, deletes every recording.

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

## The committed fixtures

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
`make test FILTER=theCommittedFixturesAreCurrent` runs that check on its own,
with no network.

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
   the journal and settings back, and run `make test`.

`ScriptedClaudeClient` stays for unit tests that need one exact hand-written
answer, such as a refusal, an unparseable reply, or a slow call.
