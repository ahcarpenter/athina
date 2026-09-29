# Continuous integration

CI runs five checks on GitHub's `macos-26` runner, which ships Xcode 26 and
the macOS 26 SDK this package targets: `test` runs `make test`: `swift test`, then
`scripts/check-no-control-api.sh`, which must find no control API in a build
without the `ControlAPI` trait, for which it takes the debug `Athina` the
tests' build already made rather than compiling the package again; `lint`
runs `make lint`, which fails on any Swift style finding (see [Code
style](code-style.md)) and on a relative link or anchor in the Markdown that
does not resolve, then checks the rules GitHub enforces on main against the
committed ruleset (see below); `test-e2e` builds the development bundle with the bundle script,
checks that it carries the control API, runs every API-tier scenario of the
end-to-end harness and compares their checkpoints with approved baselines (see
[Checkpoints](#checkpoints));
`snapshots-smoke`, the fast UI check, draws every
snapshot inside a test process with swift-snapshot-testing and compares each
with its reference image (see [UI snapshot smoke test](#ui-snapshot-smoke-test)); and `snapshots`, the
full-fidelity UI check, renders every snapshot with `Athina --snapshot`
through the window server, so Liquid Glass and materials are in them,
replay-mode renders on a scaled clock included, compares the renders with the
approved baselines, and uploads them (see [UI snapshot baselines](#ui-snapshot-baselines)).
`snapshots` is split across four runners that each take a quarter of the
snapshots, by the `SnapshotShard` table, and `snapshots-smoke` draws them
all on one. Both draw the same list of snapshots, so a UI change drifts both,
and often `test-e2e`'s checkpoints too; each has its own approved images, and
`make snapshots-approve` takes all three from the runner, never from a Mac: the
`snapshots` baselines from HEAD's newest completed, non-cancelled
snapshots.yml run, and the `snapshots-smoke` references and the checkpoints
from HEAD's newest completed, non-cancelled CI run. It fetches and checks all
three before it changes any approved image, so when one has no run to take
(a run still going, a snapshots.yml run never started because the pull
request is still a draft, a job that published nothing), it changes nothing
and fails naming each one missing and why. Once all three are fetched, it
lists every image it would add, change or delete in each set before it writes
any, and on a terminal asks first. It recompresses every image it fetched
with oxipng before listing any, losslessly: an approved image takes less
room than CI's render but decodes to the same pixels, and every gate compares
decoded pixels, never file bytes. `swift scripts/png-lossless-check.swift
<before> <after>` proves a recompression lossless, pixel for pixel.
`scripts/snapshots.sh baselines-approve`,
`smoke-approve` and `checkpoints-approve` each take one alone, from HEAD's
newest run or the run id given, for a change that drifts only some, listing
theirs the same way.

All five run on every push to main and on every run the merge queue
starts (see "The merge queue", below), and every push to main also runs
`release-build` (`.github/workflows/release.yml`), which builds a snapshot of the direct-download release
with `make release`, signed and notarized when the Apple secrets exist, and
which a version tag, one release-please makes with a draft release, turns into a published GitHub Release (see
[Releasing](releasing.md#ci)); no pull request runs it or waits for it. On a
pull request, the fast lane, `test`, `lint`, `test-e2e` and
`snapshots-smoke` (`.github/workflows/ci.yml`), runs on every push, draft
or not, and the slow `snapshots` (`.github/workflows/snapshots.yml`)
runs only while the pull request is ready for review: marking a draft ready
runs it, and so does every push while it is ready, and a pull request opened
ready runs it at once. A draft never renders it, so the four runners it takes
stay free for the fast lane while a change is still moving. A pull request
goes through it in these steps, whoever opens it:

1. Open it as a draft. The no-mistakes pipeline does, since
   `.no-mistakes.yaml` sets `providers.github.draft_pull_requests`; by hand,
   `gh pr create --draft` (or `gh-axi pr create --draft`).
2. Wait for the fast lane to pass on its head. The no-mistakes pipeline's CI
   step reports `checks-passed` then, since a draft's `snapshots` passes
   without rendering.
3. Mark it ready: `gh pr ready <number>` (or `gh-axi pr ready <number>`). That
   runs `snapshots` on the same head; the fast lane does not run again.
4. Wait for `snapshots` to pass. A push after this runs both again, and
   should the change need more work first, `gh pr ready --undo <number>`
   makes it a draft again.
5. Add it to the merge queue: `gh pr merge --auto --squash <number>` (or
   `gh-axi pr merge <number> --auto --squash`), which queues it as soon as it
   is green, or the Merge when ready button once it is. The
   queue runs every required check once more on it merged with main and everything
   queued ahead of it, then squashes it onto main; nobody merges by hand.

Only the pull request's draft state decides: editing it, labelling it or
changing its title starts and cancels nothing.

All five, and `pr-title` (see "The pull request title", below), must pass at
a pull request's head before it can enter the merge queue, and again in its
merge queue run before it lands: the `main` ruleset requires them, with no
bypass. On a draft, `snapshots` keeps its one name and passes without
rendering, its job summary saying it skipped the gate. That pass is never what
lets a change land: a draft cannot merge, marking it ready runs the gate on
the same head, whose `snapshots` replaces the draft's, and the merge queue
runs the full gate again on its group whatever the head reported. A
`workflow_dispatch` run of the same job does not count: its checks are on the
commit, but a pull request's required checks ignore them. A pull request
that touches only documentation runs `lint` and `pr-title` alone and skips the other four on
purpose, with the names they are required under (see [Docs-only pull
requests](#docs-only-pull-requests)).

The ruleset is kept in `.github/rulesets/main.json`; after a change to it,
apply it with

```sh
gh api -X PUT "repos/getathina/athina/rulesets/$(gh api repos/getathina/athina/rulesets --jq '.[] | select(.name == "main") | .id')" --input .github/rulesets/main.json
```

(`gh api -X POST repos/getathina/athina/rulesets --input .github/rulesets/main.json`
creates it if it is gone). It requires each check from GitHub Actions itself
(integration 15368), so a commit status of the same name cannot stand in for
one, and it does not require a branch to be up to date with main, so a pull
request is not rerun each time another merges: the merge queue tests it
against main instead. GitHub never reads the file, so
the `lint` job ends by checking that the two still agree:
`scripts/check-ruleset.sh` reads the rules GitHub applies to main from the
public `repos/getathina/athina/rules/branches/main` endpoint and fails,
naming each one, when the required checks (each a context and its integration)
differ from the file's, even after a lint failure, so both are reported at
once. It compares nothing else: that endpoint merges the rules of every active
ruleset on main, so another ruleset, or a parameter GitHub adds to a rule, must
not fail it. A pull request that changes the file therefore
fails `lint` until the change is applied with the command above, which is the
order it goes in: apply, then run the job again, then merge.

**The merge queue.** The `main` ruleset's `merge_queue` rule makes every pull request land through
GitHub's merge queue, so a merge to main never knocks the other open pull
requests out of date. A pull request enters it once its required checks
pass at its head (step 5 above); the queue then tests it on top of main plus
every pull request queued ahead of it, on a temporary
`gh-readonly-queue/main/...` branch, and runs the three workflows there as a
`merge_group` event, where `pr-title` checks the subject of the squash commit
that would land. There is no draft there, so `snapshots` always runs in
full, and no pull request, so no drift comment is posted and no image is
approved from it: approval stays with the ready pull request's own runs. Each
queue run keeps its own concurrency group, so a push to a pull request never
cancels a queued run.

The rule's settings: squash merges, so main keeps one commit per pull request
titled with its number; one pull request per run and one run at a time
(`max_entries_to_merge` and `max_entries_to_build` both 1); and all green
(`ALLGREEN`), so each queued pull request is tested in its own run and lands in
turn once that run passes. A required check that has not reported
within 60 minutes counts as failed. A failure removes only that pull request
from the queue; the ones behind it are tested again without it and keep their
place. A removed pull request needs a fix pushed and step 5 again.

The queue runs one at a time because each run takes eight macOS jobs (four
fast-lane jobs and four `snapshots` shards), the account runs five at once,
and pull requests' own runs want the same runners: a second run alongside
would mostly wait for them, and a check still queued after 60 minutes fails
like any other failure. Testing each pull request in its own run also keeps
attribution precise, so a flaky screenshot job ejects only the pull request it
ran for. Athina lands a handful of pull requests a day, so a run of roughly ten
minutes each is fine.

**The pull request title.** `pr-title` (`.github/workflows/pr-title.yml`)
fails unless a pull request's title follows Conventional Commits 1.0.0 as
CONTRIBUTING.md's [rules](../CONTRIBUTING.md#conventional-commits) apply it,
`type(scope)!: description` with the scope and the `!` optional, and fails a
title scoped with the app's name, `athina` or `mentor`, since the title
becomes the squash commit's subject on main: the repository's squash commit
title setting, which the owner keeps in the repository's settings rather than
a file, is the pull request title. It runs again when the title is edited,
in a workflow of its own so an edit never restarts the fast lane. The
`main` ruleset requires it, so it also runs on every merge queue group, where
it checks the first line of the group's head commit, the squash commit that
lands on main, so a title edited after the pull request entered the queue
fails there. It runs on GitHub's Ubuntu runner, in seconds.

**Dependency updates.** Renovate (`.github/renovate.json5`) opens the update
pull requests, weekly on Monday morning: one for the GitHub Actions the
workflows and `.github/actions` use, and one for the packages `Package.swift`
pins. Each is a pull request like any other, checked by CI the same way. A
release is offered only once it is three days old (`minimumReleaseAge`), time
for a broken or compromised release to be pulled first; one whose registry
gives no release date waits too, and security updates come at once. The
runner images are left out, since moving CI to a new macOS image is a
deliberate commit (see One Xcode, pinned, below). The root `Package.resolved` stays uncommitted (see
[UI snapshot smoke test](#ui-snapshot-smoke-test)), which Renovate does not
need. Nothing runs until two steps in the repository's settings, which take an
admin: install the Mend Renovate GitHub App on the repository, and turn on the
dependency graph and Dependabot alerts, which Renovate's security updates read;
no Dependabot configuration is used.

**Nightly.** `.github/workflows/nightly.yml` runs every night on main, and by
hand from the Actions tab: `make test FILTER='ReplayLoopTests|ReplayInterventionTests'`,
the check that fails a pull request on a stale replay fixture (see [The
committed fixtures](replay.md#the-committed-fixtures)) and the strict replay
of the committed set through the loop. It is replay only: no key, no call to a
model, no spend. When it fails it opens one issue, "Nightly: the replay
fixtures no longer match the current prompts", or comments the failed run on
that issue while it is open; close the issue once a run passes. No check
requires it.

**Flaky tests.** Nothing in CI or the end-to-end harness runs a failed test
or scenario again to get a pass. A flaky one goes on the quarantine list,
`Tests/quarantine.json`, with an owner and the issue tracking its fix (see
[Quarantine](testing.md#quarantine)): it still runs in every job, and its
failure is reported as a warning on the run, not counted.

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
swift-format (see [Code style](code-style.md) and [UI snapshot baselines](#ui-snapshot-baselines)). When GitHub's macOS
27 image leaves preview, CI moves to it in such a commit.

**Superseded runs.** A new push to a pull request cancels that pull request's
runs still going, in both workflows, so a superseded commit stops holding runners: the account
runs five macOS jobs at once. Pushes to main are never cancelled; each keeps
its own run, and so does every merge queue run.

Local validation, the no-mistakes pipeline a change goes through before its
pull request, never runs the Xcode project steps, the full `snapshots` gate,
the checkpoint gate (`scripts/snapshots.sh checkpoints`) or `make snapshots-approve`
(or any other approve command), which only CI proves, and compares the UI smoke set
with main's on the Mac itself (see [UI snapshot smoke test](#ui-snapshot-smoke-test));
`test.instructions` in `.no-mistakes.yaml` carries that rule to its test step.

## The checks and their make targets

Each check is named for the make target that does its work on a Mac, so a
failing check says what to run:

| Check | On a Mac | In CI |
| --- | --- | --- |
| `test` | `make test` | the same |
| `lint` | `make lint` | the same, then the ruleset check above |
| `test-e2e` | `make test-e2e`, the end-to-end scenarios | the API tier twice, its checkpoints compared with their baselines (see [Checkpoints](#checkpoints)) |
| `snapshots-smoke` | `make snapshots-smoke` | the same |
| `snapshots` | `make snapshots`, the smoke set drawn at HEAD and at main | the full-fidelity gate on four runners, `snapshots (1/4)` to `snapshots (4/4)`, rolled up into `snapshots` (see [UI snapshot baselines](#ui-snapshot-baselines)) |
| `pr-title` | none | the pull request title (see "The pull request title", above) |

`make snapshots-approve` takes the images the three image checks publish.
`.github/workflows/snapshots.yml`, the Snapshots workflow, holds `snapshots`;
`.github/workflows/ci.yml` holds the others but `pr-title`, which is in
`.github/workflows/pr-title.yml`.

## Docs-only pull requests

A pull request that changes only documentation cannot change a test result
or a pixel, so it runs `lint`, whose `make lint` checks its links, and
`pr-title`, and nothing that builds: `test`, `test-e2e`,
`snapshots-smoke` and the four `snapshots` shards are skipped, and the
`snapshots` roll-up passes without them. It gets every required check in a
few minutes, as `lint` takes.

Documentation is a Markdown file at the top of the repository or anything
under `docs/`, except what a test, a script or a build step reads, which is
code: `README.md`, whose icon `MarkAssetTests` checks against
`Resources/Mark`, and `docs/release-notes/`, which `scripts/release.sh` puts in
a release's notes. A Markdown file anywhere else, beside the sources, tests,
scripts or workflows, is code as well. A pull request with any code in it runs
everything; nothing is skipped part of the way. `scripts/docs-only.sh` holds
these rules and `DocsOnlyTests` checks them, so a new doc that something
reads goes into its `case` in the same change.

A first job in each workflow, `changes`, asks `scripts/docs-only.sh` about
the diff between the pull request's merge commit and its base, its first
parent, and the jobs above read its answer in their `if`. The skip is a job's,
never the workflow's: `paths-ignore` on a workflow would leave the required
checks never reported, so the pull request would wait for them for ever. A
skipped job still reports a check run under its own name, and a skipped
required check counts as passed; the `snapshots` roll-up, which fails on
skipped shards otherwise, passes when `changes` says docs-only. When `changes`
itself fails, the jobs get no answer and run, and only a `pull_request` event
is ever docs-only: pushes to main, the nightly run, releases and a merge
queue's `merge_group` run everything. A draft is still a draft: its
`snapshots` passes without rendering until it is ready for review, as above.

The link check (`scripts/check-links.swift`), part of `make lint` and so of
`lint` on every pull request and push, reads every tracked Markdown file, not only the changed ones, so a
renamed heading or a moved doc fails wherever it was linked from. Each
relative link must name a file or folder in the checkout, and each `#anchor` a
heading of the file it points into, as GitHub slugs it, or an `id` or `name`
attribute there. A link with a scheme, such as `https:`, is not followed, so
it needs no network and adds nothing that can flake. `make check` runs it too.

## UI snapshot baselines

`Tests/Snapshots` holds the approved render of every snapshot, light and dark,
rendered on the CI runner, which is the one reference environment. The
`snapshots` check runs on four runners at once, the `snapshots (1/4)` to
`snapshots (4/4)` jobs, and passes only when all four do. Each (`scripts/snapshots.sh
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
the `snapshots-report-shard-<k>` artifact: the approved image, the new render and the
difference (changed pixels in red over a faded copy), one folder each, with an
`index.html` that shows them side by side at real size. The comparison is
`snapshot-diff` (`Sources/SnapshotDiff`, with unit tests), and the renderer
uses the same rule.

On a pull request, the `snapshots drift comment` job, which runs once
every shard has finished and is not required, puts the drift where the
reviewer already is: one comment on the pull request, updated in place by
every later run, with a row per drifted snapshot showing its approved image,
the new render and the difference inline
(`scripts/snapshot-drift-comment.sh`). A comment's image needs a public
address and an artifact needs a login to fetch, so the job pushes the report's
images in a commit of their own over `refs/ui-snapshots-drift/pr-<number>`, a
ref outside `refs/heads` that no clone fetches and no branch list shows,
replaced on each run, and the comment reads them from
`raw.githubusercontent.com` at that commit. Once a run finds no drift, it says
so in the comment and deletes the ref; with no comment yet, it posts none. A
pull request from a fork gets no comment, since its token cannot write.

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
  captured, a frame apart, until two captures in a row are identical byte for
  byte, since the end of a slow fade, such as the title bar's to a new
  appearance, changes too little per frame for a looser match to tell it is
  still moving, and each snapshot is rendered in fresh windows until two in a
  row agree,
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

**Approving an intended change.** Push the change to a pull request ready
for review (see [Continuous integration](#continuous-integration)), and let `snapshots`
fail on the drift, look at the drift comment or the report, then run `make snapshots-approve` (see
[Continuous integration](#continuous-integration); `scripts/snapshots.sh baselines-approve [<run id>]`
takes these alone), which downloads the renders of all four
shards of HEAD's newest snapshots.yml run, the `snapshots-shard-<k>`
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
runner's macOS image and the Xcode that `.xcode-version` pins (see [Continuous
integration](#continuous-integration)). Moving to a new image or a new pin changes the renders with no
change to the app; approve them from a CI run of an unchanged commit, in a
commit of their own that names the new image or Xcode, so a real UI change is
never approved under it.

**Size.** The set is a few megabytes of PNGs, rendered at the
runner's 1x scale, and an approval adds only the images that changed to the
history, so the repository keeps them as ordinary files rather than in Git LFS,
which would add a download quota and an extra step to every checkout.

## UI snapshot smoke test

`snapshots-smoke` is the fast UI check, run on every push to a pull request
and to main. `make snapshots-smoke` (`scripts/snapshots.sh smoke`) runs
the `UISnapshotsSmokeTests` target, which draws every snapshot `--snapshot`
renders, from the same list (`Snapshots.specs()`) and the same sample data,
light and dark, in the same kind of window, settled by the same rule, and
compares each with its reference image in
`Tests/UISnapshotsSmokeTests/__Snapshots__/UISnapshotsSmokeTests` with
[swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing).
The two gates cannot drift apart: a snapshot added to the list is in both.

In CI it runs on one runner, the `snapshots-smoke` job, the check the
ruleset requires, which runs `make snapshots-smoke` and draws every
snapshot. Most of that job is fetching and compiling, which the build cache
cuts to what changed (see [Continuous integration](#continuous-integration)); drawing all 76 images takes
about a minute, where four runners each compiled the test again for a quarter
of the drawing.
`make snapshots-smoke SHARD=<k>/4` still draws only the snapshots
`SnapshotShard` gives shard k (the test reads the shard from
`UI_SNAPSHOTS_SMOKE_SHARD`), should it be split again.

It draws each window inside the test process, with swift-snapshot-testing's
view strategy on the window's frame view (the view under the content that
paints the window's background), rather than capturing it from the window
server, so it builds and runs in a fraction of the time `snapshots` takes.
Its pictures leave out what only the window server composites: Liquid Glass
and materials are not drawn, so a toast shows its words and controls on the
plain window background, and what sits on glass can take another colour or,
like the toast's button bezels, close button and microphone in light mode,
not show at all. Scroll bars are always shown, as on the runner, whatever the
Mac is set to. It catches a changed
layout, text, colour, control or state; how glass looks is `snapshots`' to
check. A pixel matches when it is within 2 Delta E of the reference (a
perceptual precision of 98 percent), the difference the eye cannot see, which
covers anti-aliasing and nothing a person would notice. A render reads the same
on every run for the reasons a `--snapshot` render does (see [UI snapshot
baselines](#ui-snapshot-baselines)), in UTC and the runner's US English locale, drawn at the runner's
1x scale whatever the display's: a fixed clock, animations and Core Animation's clock stopped, a window
with a fixed backdrop, and captures until two in a row agree, in fresh windows
until two agree. A window drawn in process is drawn as its layers stand, so
it skips the frames `--snapshot` waits for before its first capture.

The test never records a reference. A snapshot with no reference fails, as a
drifted one does, and a reference no snapshot produces fails until it is
deleted. The job names each drifted snapshot in its summary and uploads the
`snapshots-smoke-report` artifact: one folder per snapshot with the
reference (`reference.png`), the new render (`failure.png`) and their
difference (`difference.png`), or only the render when there is no reference
yet.

The target and its one dependency sit behind the `UISnapshotsSmoke` package
trait, which only `make snapshots-smoke` and `make snapshots`
turn on. Without it the target
has no tests and no dependencies, so a plain `swift test` (what `make test`
runs), `test`, the app, `make release` and the Xcode project never
fetch, build or run it. It is pinned to one release in `Package.swift`, and
the package's `Package.resolved` is not committed, since a committed one would
have every build fetch every package it names.

**Approving an intended change.** Push the change and let
`snapshots-smoke` fail on the drift, look at the report, then run `make
snapshots-approve` (`scripts/snapshots.sh smoke-approve [<run id>]` takes these alone),
which downloads the set HEAD's newest CI run published (`snapshots-smoke-set`)
and makes the references folder match it exactly: the run's render of every
snapshot that drifted or was new, the reference of every one that matched,
which comes back unchanged, and nothing else, so a removed snapshot's
reference goes. The job publishes the set
only once every snapshot has rendered, the set names the source tree it was
made from, and approving refuses any tree but HEAD's, as it does for the
baselines, and a set that names a shard, which holds only that
shard's snapshots. A UI change drifts both gates, and `make snapshots-approve` takes
both, each from its own run of HEAD; commit the images together
with the change that caused them. References never come from a Mac: they are the
runner's, rendered at its 1x scale on its macOS, and a Mac on another macOS or
display scale draws differently everywhere, so `make snapshots-smoke` on a
Mac only shows how it would draw. The runner's image and the pinned Xcode are a
deliberate refresh here too, approved with the baselines in a commit of their
own.

**On a Mac, against main.** Since a Mac cannot match the runner's references,
local validation compares a change with main on the same Mac instead: `make
snapshots` (`scripts/snapshots.sh smoke-local`) draws the smoke
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
with `run.checkpoint(<window>, <step>)`, which asks the control API's
`snapshot` for the window in light and in dark and writes
`<scenario>/<step>-light.png` and `<step>-dark.png` under the run's
checkpoints folder (`checkpoints/` in its evidence, or `run --checkpoints
<dir>`). Only a window whose picture holds still from run to run is a
checkpoint, and one that did not settle is taken again, since a window still
moving from the step before can take longer to settle than the snapshot waits
on a loaded machine, and fails the scenario when it has not settled by the
third take; one that shows the
run's times, pid or journal path, such as the debug panel, or that moves on its
own, such as a suggestion's countdown, would differ every run, so a scenario
keeps its picture as plain evidence (`run.picture(<window>, <name>)`). An API-tier run draws dates, times and
numbers in UTC and US English with scroll bars always shown, as `--snapshot`
does, so a checkpoint reads the same on every machine that draws it alike.

**The gate.** `test-e2e` (`scripts/snapshots.sh checkpoints`) runs every
API-tier scenario four at a time, twice, and fails when a scenario fails, when
the two runs took different pictures (reported in its
`checkpoints-report` artifact as `determinism/`, like two `--snapshot`
renders that differ), and on any drift of a checkpoint from its approved
baseline in `Tests/Checkpoints/<scenario>/`, by the rule and in the report
`snapshots` uses (see [UI snapshot baselines](#ui-snapshot-baselines)): a changed, new or removed
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
ScreenCaptureKit, glass, title bar and toolbar included, as `snapshots`
captures a snapshot.

**Approving an intended change.** Push the change and let `test-e2e` fail on
the drift, look at the report, then run `make snapshots-approve`
(`scripts/snapshots.sh checkpoints-approve [<run id>]` takes these alone),
which downloads the `checkpoints` artifact of HEAD's newest CI run and makes
`Tests/Checkpoints` match it the way it makes `Tests/Snapshots` match the
`snapshots` renders. The job publishes the artifact only once
both runs passed and agree, it names the source tree it was taken from, and
approving refuses any tree but HEAD's. Commit the images with the change that
caused them. Baselines never come from a Mac: on a Mac a checkpoint is
evidence of a run, never compared, since a Mac draws at another scale and
often on another macOS.
