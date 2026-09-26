# Debug panel

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
  opens it whatever the switch says. `make run` passes no `--open`, so
  there it opens from the replay's own Settings > Advanced, or from its menu
  while the switch is on: the switch starts where the live one is (or where
  `--settings` puts it), and turning it on there is saved only to the replay's
  own settings file.
- **A recording**: `make record` passes `--open debug`, which a recording
  honours whatever the switch says, for the follow-up question typed into the
  panel's Talk back field (see [The committed fixtures](replay.md#the-committed-fixtures)).
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
  command, through the control API (see [The control API](e2e.md#the-control-api)).
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
how much faster the clock runs when it does (Replay 60x; see [A faster clock](replay.md#a-faster-clock)).
A replay's card also shows its own data directory and the settings it started
from, and on any launch the card says why a `--settings` or `--replay-latency`
flag was refused (see [Replays side by side](replay.md#replays-side-by-side) and [Replay](replay.md#replay)).
