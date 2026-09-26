# Continuous integration

CI runs five checks on GitHub's `macos-26` runner, which ships Xcode 26 and
the macOS 26 SDK this package targets: `build-and-test` runs `swift test` and
`scripts/check-no-control-api.sh`, which must find no control API in a build
without the `ControlAPI` trait, for which it takes the debug `Athina` the
tests' build already made rather than compiling the package again; `lint` runs `make lint` (see Code style) and fails on any
finding; `e2e-api` builds the development bundle with the bundle script,
checks that it carries the control API, runs every API-tier scenario of the
end-to-end harness and compares their checkpoints with approved baselines (see
Checkpoints);
`ui-snapshots-smoke`, the fast UI check, draws every
snapshot inside a test process with swift-snapshot-testing and compares each
with its reference image (see UI snapshot smoke test); and `ui-snapshots`, the
full-fidelity UI check, renders every snapshot with `Athina --snapshot`
through the window server, so Liquid Glass and materials are in them,
replay-mode renders on a scaled clock included, compares the renders with the
approved baselines, and uploads them (see UI snapshot baselines).
`ui-snapshots` is split across four runners that each take a quarter of the
snapshots, by the `SnapshotShard` table, and `ui-snapshots-smoke` draws them
all on one. Both draw the same list of snapshots, so a UI change drifts both,
and often `e2e-api`'s checkpoints too; each has its own approved images, and
`make approve` takes all three from the runner, never from a Mac: the
`ui-snapshots` baselines from HEAD's newest completed, non-cancelled
merge-checks run, and the `ui-snapshots-smoke` references and the checkpoints
from HEAD's newest completed, non-cancelled CI run. It fetches and checks all
three before it changes any approved image, so when one has no run to take
(a run still going, a merge-checks run never started for want of the label, a
job that published nothing), it changes nothing and fails naming each one
missing and why. `scripts/snapshots.sh baselines-approve`, `smoke-approve`
and `checkpoints-approve` each take one alone, from HEAD's newest run or the
run id given, for a change that drifts only some. The
Xcode project's archive check is out of CI until the App Store release flow
brings it back as part of that flow (see The Xcode project).

All five run on every push to main. On a pull request, `build-and-test`, `lint`,
`e2e-api` and `ui-snapshots-smoke` (`.github/workflows/ci.yml`) run on every push, and the
slow `ui-snapshots` (`.github/workflows/merge-checks.yml`) runs only while the
pull request carries the `merge-checks` label: adding the label runs it, and
so does every push, or any other label added, while it is on. Anyone with write access can add it,
from the pull request page or with

```sh
gh pr edit <number> --add-label merge-checks
```

All five must pass at a pull request's head before it can merge: the `main`
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

**A build cache.** Every macOS job that compiles the package restores
`.build` from an earlier run of the same job through
`.github/actions/swiftpm-cache`, so SwiftPM compiles only what changed. A
checkout stamps every file with the time it was checked out, which would make
every source look changed, so the action first sets each tracked file's time
from its git blob id: the same content has the same time in every checkout,
and different content a different one. SwiftPM still decides what is up to
date, from each source's time and size, so a restored cache only saves work
and never hides a change; a miss is a full build. The key names the job (which
fixes the configurations and traits it builds), the Xcode and Swift versions,
`Package.swift`, and the sources: a run of sources already cached restores
that cache and saves none, and otherwise the newest cache of the same job,
toolchain and manifest is restored, a pull request's own before main's, and a
successful run saves its own. GitHub evicts the least recently used caches
beyond the repository's 10 GB.

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
pull request, never runs the Xcode project steps, the full `ui-snapshots` gate,
the checkpoint gate (`scripts/snapshots.sh checkpoints`) or `make approve`
(or any other approve command), which only CI proves, and compares the UI smoke set
with main's on the Mac itself (see UI snapshot smoke test);
`test.instructions` in `.no-mistakes.yaml` carries that rule to its test step.

## UI snapshot baselines

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
- **Settled, and agreed.** A window opens with no animation and is first
  captured once three of the display's frames in a row changed nothing in it:
  no view waiting for layout or to be drawn, no Core Animation animation
  running, and no layer moved, resized, faded or recoloured since the frame
  before, as a switch's knob is while it springs across, so a task that loads
  what a view shows, or an image fading in, is waited for as long as it takes
  and no longer (`DisplayFrames`). It is then
  captured, a frame apart, until two captures in a row are the same picture,
  and each snapshot is rendered in fresh windows until two in a row agree,
  because AppKit now and then lays a text field out a point off in one window;
  a new window whose first capture is already the picture the last settled on
  agrees with it at once. Four snapshots render at a time, each in windows of
  its own, since most of a render is waiting on the display and on
  ScreenCaptureKit: every snapshot renders in about 20 seconds on a Mac, where
  a fixed wait before each window's first capture took 176. Captures are kept
  in sRGB whatever the display's profile.
- **One way of capturing.** A run captures every window with ScreenCaptureKit
  when it has Screen Recording, as the runner does, and renders each window's
  layer tree when it does not, and says which on its first line. The two draw
  glass differently, so a run never mixes them: a ScreenCaptureKit capture
  that fails is taken again, never drawn the other way.

**Approving an intended change.** Push the change, with the `merge-checks`
label on its pull request (see Continuous integration), and let `ui-snapshots`
fail on the drift, look at the report, then run `make approve` (see
Continuous integration; `scripts/snapshots.sh baselines-approve [<run id>]`
takes these alone), which downloads the renders of all four
shards of HEAD's newest merge-checks run, the `ui-snapshots-shard-<k>`
artifacts, and makes `Tests/Snapshots` match them: a changed or new
snapshot's render replaces its baseline, a removed snapshot's baseline is
deleted, and every other file is left alone.
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

## UI snapshot smoke test

`ui-snapshots-smoke` is the fast UI check, run on every push to a pull request
and to main. `make test-snapshots-ci` (`scripts/snapshots.sh smoke`) runs
the `UISnapshotsSmokeTests` target, which draws every snapshot `--snapshot`
renders, from the same list (`Snapshots.specs()`) and the same sample data,
light and dark, in the same kind of window, settled by the same rule, and
compares each with its reference image in
`Tests/UISnapshotsSmokeTests/__Snapshots__/UISnapshotsSmokeTests` with
[swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing).
The two gates cannot drift apart: a snapshot added to the list is in both.

In CI it runs on one runner, the `ui-snapshots-smoke` job, the check the
ruleset requires, which runs `make test-snapshots-ci` and draws every
snapshot. Most of that job is fetching and compiling, which the build cache
cuts to what changed (see Continuous integration); drawing all 76 images takes
about a minute, where four runners each compiled the test again for a quarter
of the drawing.
`make test-snapshots-ci SHARD=<k>/4` still draws only the snapshots
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
it skips the frames `--snapshot` waits for before its first capture.

The test never records a reference. A snapshot with no reference fails, as a
drifted one does, and a reference no snapshot produces fails until it is
deleted. The job names each drifted snapshot in its summary and uploads the
`ui-snapshots-smoke-report` artifact: one folder per snapshot with the
reference (`reference.png`), the new render (`failure.png`) and their
difference (`difference.png`), or only the render when there is no reference
yet.

The target and its one dependency sit behind the `UISnapshotsSmoke` package
trait, which only `make test-snapshots-ci` and `make test-snapshots`
turn on. Without it the target
has no tests and no dependencies, so a plain `swift test` (what `make test`
runs), `build-and-test`, the app, `make release` and the Xcode project never
fetch, build or run it. It is pinned to one release in `Package.swift`, and
the package's `Package.resolved` is not committed, since a committed one would
have every build fetch every package it names.

**Approving an intended change.** Push the change and let
`ui-snapshots-smoke` fail on the drift, look at the report, then run `make
approve` (`scripts/snapshots.sh smoke-approve [<run id>]` takes these alone),
which downloads the set HEAD's newest CI run published (`ui-snapshots-smoke-set`)
and makes the references folder match it exactly: the run's render of every
snapshot that drifted or was new, the reference of every one that matched,
which comes back unchanged, and nothing else, so a removed snapshot's
reference goes. The job publishes the set
only once every snapshot has rendered, the set names the source tree it was
made from, and approving refuses any tree but HEAD's, as it does for the
baselines, and a set that names a shard, which holds only that
shard's snapshots. A UI change drifts both gates, and `make approve` takes
both, each from its own run of HEAD; commit the images together
with the change that caused them. References never come from a Mac: they are the
runner's, rendered at its 1x scale on its macOS, and a Mac on another macOS or
display scale draws differently everywhere, so `make test-snapshots-ci` on a
Mac only shows how it would draw. The runner's image and the pinned Xcode are a
deliberate refresh here too, approved with the baselines in a commit of their
own.

**On a Mac, against main.** Since a Mac cannot match the runner's references,
local validation compares a change with main on the same Mac instead: `make
test-snapshots` (`scripts/snapshots.sh smoke-local`) draws the smoke
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

## Checkpoints

A checkpoint is a picture of one of Athina's windows at a step of an API-tier
scenario, in a state `--snapshot`'s sample data cannot show: a pane after its
switch was pressed, a sheet with a name typed into it. A scenario takes one
with the harness's `checkpoint <window> <step>`, which asks the control API's
`snapshot` for the window in light and in dark and writes
`<scenario>/<step>-light.png` and `<step>-dark.png` under the run's
checkpoints folder (`checkpoints/` in its evidence, or `run --checkpoints
<dir>`). Only a window whose picture holds still from run to run is a
checkpoint, and one that did not settle fails the scenario; one that shows the
run's times, pid or journal path, such as the debug panel, or that moves on its
own, such as a suggestion's countdown, would differ every run, so a scenario
keeps its picture as plain evidence (`api snapshot path=`). An API-tier run draws dates, times and
numbers in UTC and US English with scroll bars always shown, as `--snapshot`
does, so a checkpoint reads the same on every machine that draws it alike.

**The gate.** `e2e-api` (`scripts/snapshots.sh checkpoints`) runs every
API-tier scenario four at a time, twice, and fails when a scenario fails, when
the two runs took different pictures (reported in its
`checkpoints-report` artifact as `determinism/`, like two `--snapshot`
renders that differ), and on any drift of a checkpoint from its approved
baseline in `Tests/Checkpoints/<scenario>/`, by the rule and in the report
`ui-snapshots` uses (see UI snapshot baselines): a changed, new or removed
checkpoint fails until approved. The job, from a clean runner to the answer,
takes about four minutes with the build cache, so it runs on every push to a
pull request. On the runner, whose display is 1024 by 768, it hides the Dock
first, through System Events: with it showing, the tallest Settings panes are taller than the room
left, macOS cuts the Settings window off above their end, and their last rows
cannot be scrolled into view.

It launches the app through LaunchServices (`run --launch open`) rather than
under `sandbox-exec`: the runner image grants Accessibility to the job's
shell, and an app exec'd from it inherits that grant, so the run could never
catch a change that made the API tier need one; opened, the app is as
untrusted as the hermetic copy is on a Mac. `--launch open` runs the app
outside the sandbox, so the harness refuses it on a Mac that holds Athina
data. The job does grant the hermetic copy's identifier Screen Recording, and
only that, in the runner's TCC database, so a checkpoint is captured with
ScreenCaptureKit, glass, title bar and toolbar included, as `ui-snapshots`
captures a snapshot.

**Approving an intended change.** Push the change and let `e2e-api` fail on
the drift, look at the report, then run `make approve`
(`scripts/snapshots.sh checkpoints-approve [<run id>]` takes these alone),
which downloads the `checkpoints` artifact of HEAD's newest CI run and makes
`Tests/Checkpoints` match it the way it makes `Tests/Snapshots` match the
`ui-snapshots` renders. The job publishes the artifact only once
both runs passed and agree, it names the source tree it was taken from, and
approving refuses any tree but HEAD's. Commit the images with the change that
caused them. Baselines never come from a Mac: on a Mac a checkpoint is
evidence of a run, never compared, since a Mac draws at another scale and
often on another macOS.
