# Contributing to Athina

## Requirements

- Xcode 26 or later with its command line tools (`swift`, `codesign`)
- For development: bash 4 or newer first on `PATH` (macOS ships 3.2; `brew
  install bash`) and python3, which the end-to-end harness runs on; `gh`,
  signed in, which `make approve` downloads CI's renders with; and, for
  the end-to-end harness's real-screen tier, Screen Recording and
  Accessibility granted to the terminal that runs it (see Permissions).
  `make doctor` names whatever is missing
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
make                         # lists every command and variable, grouped Everyday and Occasional
make build                   # builds build/Athina.app, the development bundle (make all is the same)
make run                     # builds and launches a replay: recorded fixtures, no network, no key, no spend (TIME_SCALE=60 runs its clock faster)
make test                    # runs swift test, the replayed loop and the fixture freshness check included (FILTER=<name> for some)
make test-e2e                # runs the end-to-end scenarios, replays only (SCENARIO=<name>, JOBS=<n>; see End-to-end harness)
make test-snapshots          # the smoke set drawn on this Mac at HEAD and at main, and every changed screen reported
make check                   # lint, test and test-snapshots: what local validation runs before a push
make approve                 # after an intended UI change, takes the ui-snapshots baselines, smoke references and e2e checkpoints from CI's runs of HEAD, all or none (see Continuous integration)
make lint                    # checks every Swift file against the style without changing it, as CI does
make format                  # formats every Swift file in place to Google's Swift style (see Code style)
make doctor                  # names what this Mac is missing: Xcode, bash 4, python3, gh, the grants, the warm e2e home

make run-live                # builds and launches the live app, replacing only the copy this checkout's run-live or record launched (spends API credits)
make record                  # the same, writing every model call to a fixture file (spends API credits)
make test-snapshots-ci       # the UI smoke test as CI runs it, compared with the runner's references
make icons                   # rebuilds the app icon and this README's copy of it from AthinaMark.svg, and the menu bar mark from AthinaOwl.svg (their outputs are committed, so a plain build never needs it)
make measure                 # samples the running app's CPU and memory for 60 seconds (PID=<pid> when several run)
make release                 # builds, signs, notarizes, and packages a direct-download release into build/release (see Releasing)
make xcodeproj               # generates Athina.xcodeproj, the Xcode project for the App Store route, from project.yml (see The Xcode project)
make clean                   # removes every build product and the generated Xcode project
```

None of the launch targets quits an Athina it did not start: each one stops
only the copy its own lane launched earlier from this checkout, by the pid
`scripts/launch.sh` wrote to `build/<lane>.pid`, so other checkouts, other
replays, and an Athina started any other way keep running. `make run-live`
and `make record` share the lane `live`; `make run` uses `replay`, or
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
app's own windows open from its menu bar item, on the copy `make run-live`
already started; the debug panel opens there and from Settings > Advanced only once it
is turned on in that pane. `--record [<dir>]` chooses where model calls go,
`--time-scale <n>` and `--advance-clock <interval>` set a replay's clock,
`--replay-latency immediate` answers a replay's calls at once,
`--settings <path>` chooses the settings a replay starts from (see Iterating
without the network), and `--control <dir>` serves the end-to-end harness's
control API (see The control API), with `--hermetic` and `--show-windows`
shaping such a launch (see Hermetic runs).
Where a replay keeps its own files is not an argument: it makes a directory for
itself and says which on the line it writes as it starts.
