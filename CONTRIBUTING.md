# Contributing to Athina

This file owns the development loop: setup, the everyday commands, the rules,
and how a change reaches `main`. The [README](README.md) introduces Athina,
`docs/` holds the reference (listed under the README's
[Develop](README.md#develop)), and [AGENTS.md](AGENTS.md) holds the rules for
coding agents, with pointers into these docs.

## Requirements

- macOS 26 or later
- Xcode 26 or later with its command line tools (`swift`, `codesign`)
- For development: bash 4 or newer first on `PATH` (macOS ships 3.2; `brew
  install bash`) and python3, which the end-to-end harness runs on; `gh`,
  signed in, which `make approve` downloads CI's renders with; and, for
  the end-to-end harness's real-screen tier, Screen Recording and
  Accessibility granted to the terminal that runs it (see [Permissions](README.md#permissions)).
  `make doctor` names whatever is missing
- The app has no third-party dependencies: SwiftUI, ScreenCaptureKit, Vision, the
  accessibility API, Carbon hotkeys, AVFoundation and Speech for talking
  back, and the system SQLite
- The Xcode project alone (see [The Xcode project](docs/releasing.md#the-xcode-project)) is generated with XcodeGen,
  which SwiftPM fetches and builds, pinned, on first use; nothing else needs it
- The UI smoke test alone (see [UI snapshot smoke test](docs/ci.md#ui-snapshot-smoke-test)) uses
  swift-snapshot-testing, which SwiftPM fetches, pinned, only when that test
  runs; the app never links it

Run `make doctor` after cloning: it names each missing tool, then runs the
end-to-end harness's own doctor for the grants, the drive tool and the warm
home, which `scripts/e2e/athina-e2e warm` makes once per machine and again
with `--force` after a macOS upgrade (see
[The warm fixture home](docs/e2e.md#the-warm-fixture-home)).

## Build, run, test

```sh
make                         # lists every command and variable, grouped Everyday and Occasional
make build                   # builds build/Athina.app, the development bundle (make all is the same)
make run                     # builds and launches a replay: recorded fixtures, no network, no key, no spend (TIME_SCALE=60 runs its clock faster)
make test                    # runs swift test, the replayed loop and the fixture freshness check included (FILTER=<name> for some)
make test-e2e                # runs the end-to-end scenarios, replays only (SCENARIO=<name>, JOBS=<n>; see docs/e2e.md)
make test-snapshots          # the smoke set drawn on this Mac at HEAD and at main, and every changed screen reported
make check                   # lint, test and test-snapshots: what local validation runs before a push
make approve                 # after an intended UI change, takes the ui-snapshots baselines, smoke references and e2e checkpoints from CI's runs of HEAD, all or none (see docs/ci.md)
make lint                    # checks every Swift file against the style without changing it, as CI does
make format                  # formats every Swift file in place to Google's Swift style (see docs/code-style.md)
make doctor                  # names what this Mac is missing: Xcode, bash 4, python3, gh, the grants, the warm e2e home

make run-live                # builds and launches the live app, replacing only the copy this checkout's run-live or record launched (spends API credits)
make record                  # the same, writing every model call to a fixture file (spends API credits)
make test-snapshots-ci       # the UI smoke test as CI runs it, compared with the runner's references
make icons                   # rebuilds the app icon and the README's copy of it from AthinaMark.svg, and the menu bar mark from AthinaOwl.svg (their outputs are committed, so a plain build never needs it)
make measure                 # samples the running app's CPU and memory for 60 seconds (PID=<pid> when several run)
make release                 # builds, signs, notarizes, and packages a direct-download release into build/release (see docs/releasing.md)
make xcodeproj               # generates Athina.xcodeproj, the Xcode project for the App Store route, from project.yml (see docs/releasing.md)
make clean                   # removes every build product and the generated Xcode project
```

None of the launch targets quits an Athina it did not start: each one stops
only the copy its own lane launched earlier from this checkout, by the pid
`scripts/launch.sh` wrote to `build/<lane>.pid`, so other checkouts, other
replays, and an Athina started any other way keep running. `make run-live`
and `make record` share the lane `live`; `make run` uses `replay`, or
`LANE=<name>` (see [Replays side by side](docs/replay.md#replays-side-by-side)). Because two live Athinas would share
one journal, one settings file, and one API bill, a live launch refuses to
start while another live Athina runs and names it; a build from before the
rename, running as Mentor, counts as one. Nothing stops a person
launching a second copy from Finder, which was equally true before.

`Package.swift` defines the targets and `scripts/bundle.sh` wraps the release
binary in an app bundle with `Resources/Info.plist` and
`Resources/Athina.entitlements`, then signs it. `swift build` and `swift test`
work directly too. The one Xcode project, for the Mac App Store route, wraps
this package rather than replacing it, and nothing above uses it (see [The
Xcode project](docs/releasing.md#the-xcode-project)). The bundle `make build` makes is a development one: it carries
the end-to-end harness's control API (the `ControlAPI` package trait, see [The
control API](docs/e2e.md#the-control-api)), which a release never does.

`Athina --snapshot <dir>` (`Sources/Athina/Snapshots.swift`) renders every
window with sample data to PNG files (light and dark) without starting the
pipeline or calling any model. It is how UI changes get checked without a
person at the screen; it needs no permissions and never reads the keychain.
Each view renders in a borderless window placed
below the desktop picture, where the window server still composites glass and
controls and ScreenCaptureKit still captures it, so nothing appears on screen
(the run puts no item in the menu bar either) and a tall Settings pane renders
whole. Replay mode has renders of its own. `open -n build/Athina.app --args
--replay <dir> --open debug` (or `settings`, `settings:<pane>` for `general`,
`contexts`, `models`, `capture`, `journal`, `privacy`, or `advanced`,
`permissions`, `history`) starts a replay with that window already open, which
is how a panel gets screenshotted from a shell
(`screencapture -l <window id>`). A replay opens the debug panel this way
whatever Settings > Advanced says; a live launch opens it only while
the switch there is on (see [Debug panel](docs/debug-panel.md)). Keep the `--replay`: a bare `open -n`
goes round `scripts/launch.sh`, so nothing stops it starting a second live
Athina on the live journal, the live settings and the same API bill. The live
app's own windows open from its menu bar item, on the copy `make run-live`
already started; the debug panel opens there and from Settings > Advanced only once it
is turned on in that pane. `--record [<dir>]` chooses where model calls go,
`--time-scale <n>` and `--advance-clock <interval>` set a replay's clock,
`--replay-latency immediate` answers a replay's calls at once,
`--settings <path>` chooses the settings a replay starts from (see [Iterating
without the network](docs/replay.md)), and `--control <dir>` serves the end-to-end harness's
control API (see [The control API](docs/e2e.md#the-control-api)), with `--hermetic` and `--show-windows`
shaping such a launch (see [Hermetic runs](docs/e2e.md#hermetic-runs)).
Where a replay keeps its own files is not an argument: it makes a directory for
itself and says which on the line it writes as it starts.

## Rules

- **Replay, never a live call.** Build, test and verify against recorded
  fixtures: `make run`, the tests and the end-to-end harness all replay, with
  no key and no spend. `make run-live` and `make record` are the only targets
  that spend API credits, and a recording is deliberate: a change that bumps
  the prompt version in `Prompts.swift` or adds a call kind re-records the
  committed fixtures in the same change (see
  [The committed fixtures](docs/replay.md#the-committed-fixtures)).
- **The end-to-end harness, never hand-written driving.** Check the running
  app with `scripts/e2e/athina-e2e`, called bare. A change's evidence runs the
  API tier for anything in Athina's own windows, and the real-screen tier only
  for a change to the menu bar item, toast dismissal, the Settings links or
  sensing (see [End-to-end harness](docs/e2e.md)).
- **Google's Swift style.** `make format` applies it and `make lint` must
  pass; [Code style](docs/code-style.md) lists the rules the linter cannot see.
- **Apple's Human Interface Guidelines**, as
  [Design conventions](docs/design.md) applies them.
- **Approved images come from CI, never from a Mac** (below).
- **Generated files are regenerated, never edited**: the app icon, the menu
  bar mark and the README icon come from `make icons`, and `Athina.xcodeproj`
  from `make xcodeproj`.
- **A make recipe stays one line**; logic beyond one command goes in a script
  in `scripts/`.
- **Conventional Commits**: `feat(athina): ...`, `fix(e2e): ...`,
  `docs(athina): ...`, `ci: ...`.
- **No em dash** anywhere in the repository; use a plain dash.

## How a change reaches main

1. **Before the push**, `make check` runs `make lint`, `make test` and
   `make test-snapshots`, which draws the UI smoke set on this Mac at HEAD and
   at main and reports every screen the change altered, added or removed.
   Local validation never runs the full `ui-snapshots` gate, the checkpoint
   gate or `make approve`, which only CI proves, nor the Xcode project steps.
2. **On the pull request**, CI runs `build-and-test`, `lint`, `e2e-api` and
   `ui-snapshots-smoke` on every push, and a newer push cancels the runs still
   going.
3. **At merge**, the `merge-checks` label
   (`gh pr edit <number> --add-label merge-checks`) runs `ui-snapshots`, the
   full-fidelity gate, on four runners. The `main` ruleset requires all five
   checks at the pull request's head.
4. **An intended UI change** fails the image gates until it is approved: read
   each report, then `make approve` takes the `ui-snapshots` baselines, the
   smoke references and the e2e checkpoints from CI's runs of HEAD, all or
   none, naming any run it is missing. Commit the images with the change.
   Approve only a drift the change meant.

[Continuous integration](docs/ci.md) has the detail, and
[Testing](docs/testing.md) says what each layer proves.
