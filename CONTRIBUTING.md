# Contributing to Athina

This file owns the development loop: setup, the everyday commands, the rules,
and how a change reaches `main`. The [README](README.md) introduces Athina,
`docs/` holds the reference (listed under [The docs](#the-docs)), and
[AGENTS.md](AGENTS.md) holds the rules for coding agents, with pointers into
these docs.

## Requirements

- macOS 26 or later
- Xcode 26 or later with its command line tools (`swift`, `codesign`)
- For development: bash 4 or newer first on `PATH` (macOS ships 3.2; `brew
  install bash`), which the end-to-end harness runs on; `gh`,
  signed in, which `make snapshots-approve` downloads CI's renders with; and, for
  the end-to-end harness's real-screen tier, Screen Recording and
  Accessibility granted to the terminal that runs it (see [Permissions](docs/setup.md#permissions)).
  `make doctor` names whatever is missing
- The app has two third-party dependencies, which SwiftPM fetches, pinned:
  KeyboardShortcuts, for its global keyboard shortcuts and their recorder
  (see [Keyboard shortcuts](docs/mentor-loop.md#keyboard-shortcuts)), and
  GRDB, through which the journal reaches the system SQLite (see
  [Journal](docs/architecture.md#journal)); the rest is the system's:
  SwiftUI, ScreenCaptureKit, Vision, the accessibility API, and AVFoundation
  and Speech for talking back
- The UI smoke test alone (see [UI snapshot smoke test](docs/ci.md#ui-snapshot-smoke-test)) uses
  swift-snapshot-testing, which SwiftPM fetches, pinned, only when that test
  runs; the app never links it
- The developer tools `athina-drive` and `snapshot-diff` alone take their
  command lines with swift-argument-parser, which SwiftPM fetches, pinned,
  with any build of the package; the app never links it

Run `make doctor` after cloning: it names each missing tool, then runs the
end-to-end harness's own doctor for the grants, the drive tool and the warm
home, which `scripts/e2e/athina-e2e warm` makes once per machine and again
with `--force` after a macOS upgrade (see
[The warm fixture home](docs/e2e.md#the-warm-fixture-home)).

## The docs

| Doc | Covers |
| --- | --- |
| [setup.md](docs/setup.md) | installing, the API key, what calls cost, the permissions |
| [architecture.md](docs/architecture.md) | the source layout, the sensing loop, the journal, the subscription point |
| [mentor-loop.md](docs/mentor-loop.md) | triage and mentor calls, callouts, keyboard shortcuts, talking back, mentorship contexts, the standing understanding, spend control |
| [privacy.md](docs/privacy.md) | what leaves the Mac, what is kept, and for how long |
| [debug-panel.md](docs/debug-panel.md) | the debug panel |
| [design.md](docs/design.md) | the design conventions, the app icon and the menu bar mark |
| [code-style.md](docs/code-style.md) | the Swift style, the pinned swift-format, rebasing across the reformat |
| [testing.md](docs/testing.md) | each test layer's job, where it runs, and what the tests and snapshots cover |
| [replay.md](docs/replay.md) | replay, the faster clock, replays side by side, recording, the committed fixtures |
| [e2e.md](docs/e2e.md) | the end-to-end harness, its scenarios and tiers, the control API, hermetic runs |
| [ci.md](docs/ci.md) | the CI checks, the ready-for-review snapshot gate, checkpoints |
| [releasing.md](docs/releasing.md) | releases, unsigned releases, code signing |

## Build, run, test

```sh
make doctor                  # start here: names what this Mac is missing (Xcode, bash 4, gh, the grants, the warm e2e home) and how to get each
make                         # lists every command with its variables under it, grouped Everyday and Occasional
make build                   # builds build/Athina.app, the development bundle (make all is the same)
make run                     # builds and launches a replay: recorded fixtures, no network, no key, no spend (TIME_SCALE=60 runs its clock faster)
make test                    # runs swift test, the replayed loop and the fixture freshness check included (FILTER=<name> for some), then checks a build without the ControlAPI trait carries no control API, as CI's test check does
make test-e2e                # runs the end-to-end scenarios, replays only (SCENARIO=<name>, JOBS=<n>; see docs/e2e.md)
make snapshots               # the smoke set drawn on this Mac at HEAD and at main, and every changed screen reported
make check                   # lint, test and snapshots: the one command to run before a push, and what local validation runs
make snapshots-approve       # after an intended UI change, takes the snapshots baselines, smoke references and e2e checkpoints from CI's runs of HEAD, all or none, listing each image before it writes it (see docs/ci.md)
make lint                    # checks every Swift file against the style without changing it, then that every relative link and anchor in the Markdown resolves, offline, as CI does
make format                  # formats every Swift file in place to Google's Swift style (see docs/code-style.md)

make run-live SPEND=1        # builds and launches the live app, replacing only the copy this checkout's run-live or record launched (spends API credits, up to the spend cap it prints first; refused without SPEND=1)
make record SPEND=1          # the same, writing every model call to a fixture file (spends API credits; refused without SPEND=1)
make snapshots-smoke         # the UI smoke test as CI runs it, compared with the runner's references, which a Mac unlike the runner drifts from
make icons                   # rebuilds the app icon and the README's copy of it from AthinaMark.svg, and the menu bar mark from AthinaGaze.svg (their outputs are committed, so a plain build never needs it)
make measure                 # samples the running app's CPU and memory for 60 seconds (PID=<pid> when several run)
make release                 # builds, signs, notarizes, and packages a direct-download release into build/release (see docs/releasing.md)
make clean                   # removes every build product
```

Each target ends in one summary line, saying whether it passed, what it
counted and where its evidence is, and on a failure the command to run next;
swift's own output goes to `build/logs/<name>.log` unless `VERBOSE=1` is set,
or `CI` is, as it is in GitHub Actions (`scripts/quietly.sh`).

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
work directly too. The bundle `make build` makes is a development one: it carries
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
`consent`, `permissions`, `history`) starts a replay with that window already open, which
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
  that spend API credits, and each refuses to start without `SPEND=1`; a
  recording is deliberate: a change that bumps the prompt version in
  `Prompts.swift` or adds a call kind re-records the committed fixtures in the
  same change (see
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
  bar mark and the README icon come from `make icons`.
- **A make recipe stays one line**; logic beyond one command goes in a script
  in `scripts/`.
- **[Conventional Commits](#conventional-commits)** for every commit and
  pull request title.
- **No em dash** anywhere in the repository; use a plain dash.

## Conventional Commits

Every commit and every pull request title follows
[Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/#specification),
strictly:

- **The header** is `type(scope)!: description`, all lowercase up to the
  colon, with one space after it; the scope and the `!` are optional.
- **`feat`** is only a new feature of the Athina app, and **`fix`** only a
  bug fix in the app. Everything else takes `build`, `chore`, `ci`, `docs`,
  `perf`, `refactor`, `revert`, `style` or `test`: a new test harness or
  scenario is `test`, developer tooling is `build` or `chore`.
- **A scope**, when given, is a noun naming one section of the codebase,
  such as `e2e`, `ci`, `settings`, `debug-panel`, `consent`, `replay`,
  `history`, `menu`, `snapshots` or `release`; never the app's name,
  `athina` or `mentor`. A change that spans the app has no scope.
- **A breaking change**, such as removing or changing behaviour a person
  relies on, carries `!` before the colon and a `BREAKING CHANGE: ...`
  footer saying what breaks.
- **A revert** is `revert: ...` and names the commits it reverts in a
  `Refs: <sha>, ...` footer.
- **The pull request title** becomes the squash commit's subject on main,
  since the repository squashes under the pull request title (a repository
  setting the owner keeps, not a file), so it follows the same rules, and
  `pr-title`, a required check, fails a title that does not or that uses the
  scope `athina` or `mentor`. The squash commit's body is free-form under the
  spec, whatever GitHub fills it with; a breaking change's footer goes at its
  end.

For example `feat(history): search past suggestions`,
`fix(consent): keep Allow enabled after a relaunch`,
`test(e2e): cover the Talk back field`, `ci: cache the Swift build`, and
`refactor!: drop the Mentor data move`, whose body ends with
`BREAKING CHANGE: a journal from before the rename is no longer moved`.

## How a change reaches main

1. **Before the push**, `make check` runs `make lint`, `make test` and
   `make snapshots`, which draws the UI smoke set on this Mac at HEAD and at
   main and reports every screen the change altered, added or removed.
   Local validation never runs the full `snapshots` gate, the checkpoint gate
   or `make snapshots-approve`, which only CI proves, nor the Xcode project steps.
2. **On the pull request**, opened as a draft, CI runs the fast lane,
   `test`, `lint`, `test-e2e` and `snapshots-smoke`, each named for its make
   target, on every push, and a newer push cancels the runs still going.
3. **Ready for review**: once the fast lane passes, mark the pull request
   ready (`gh pr ready <number>`), which runs `snapshots`, the full-fidelity
   gate, on four runners, and runs it on every push after; on a draft it
   passes without rendering and its job summary says it skipped. The
   `main` ruleset requires all five checks at the pull request's head, and
   `pr-title`, which checks the title on every push and every edit of it. A
   pull request that changes only documentation runs `lint` and `pr-title`
   alone and reports the other four as skipped, which passes them (see [Docs-only pull
   requests](docs/ci.md#docs-only-pull-requests)).
4. **An intended UI change** fails the image gates until it is approved: read
   each report, then `make snapshots-approve` takes the `snapshots`
   baselines, the smoke references and the e2e checkpoints from CI's runs of
   HEAD, all or none, naming any run it is missing. Commit the images with the change.
   Approve only a drift the change meant.
5. **The merge queue** lands it: once the pull request is green,
   `gh pr merge --auto --squash <number>`, or the Merge when ready button,
   queues it. The queue runs every required check again on it merged with main and
   everything queued ahead of it, one run at a time, then squashes it onto
   main in turn. A failure removes only that pull request; the others stay
   queued.

[Continuous integration](docs/ci.md) has the detail, and
[Testing](docs/testing.md) says what each layer proves.
