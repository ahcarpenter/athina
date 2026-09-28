# Testing

Each layer proves one thing, and a change is checked by the layers that can
see it. The unit tests are Swift Testing, run by `swift test`; the end-to-end
layers are the harness in `scripts/e2e` ([End-to-end harness](e2e.md)), whose
API-tier scenarios are Swift Testing tests too, in `Tests/E2EAPITests`, built
only with the `E2EAPI` package trait and run through the harness; the
pixel layers compare the one list of snapshots, `Snapshots.specs()`, and the
API tier's checkpoints with images CI approved ([Continuous integration](ci.md)).

| Layer | Proves | Runs |
| --- | --- | --- |
| Lint, `make lint` | one Swift style, public declarations' doc comments included ([Code style](code-style.md)) | `make check`; CI's `lint` on every push |
| Unit tests, `make test` | the pure logic, the whole loop against the committed replay fixtures, and that those fixtures are current ([below](#what-the-tests-and-snapshots-cover)); then that a build without the `ControlAPI` trait carries no control API | `make check`; CI's `build-and-test` on every push |
| API-tier end-to-end, `athina-e2e run --tier api` | what a person does in Athina's own windows works, driven through the control API in a hermetic replay; in CI, also that its checkpoints did not drift | a change's evidence, where checkpoints are pictures only; CI's `e2e-api` on every push |
| UI smoke pixels, `make snapshots` and `make snapshots-ci` | layout, text, colour and state did not drift, every snapshot drawn in a test process | `make check` draws them at HEAD and at main on this Mac and reports each change; CI's `ui-snapshots-smoke` (`make snapshots-ci`) fails on a drift from its approved references, on every push |
| Full pixels, `ui-snapshots` | the same snapshots as the window server draws them, glass and materials included | CI, on four runners, on a pull request once it is ready for review and on every push to main |
| Real-screen end-to-end, `athina-e2e run --tier screen` | what only macOS's own routing decides (the menu bar item and the menu the system runs for it, clicks in other apps, the item's width), and sensing on the real screen (`capture-race`) | on a Mac, for a change to the menu bar item, toast dismissal, the Settings links or sensing |
| Live model, `make record` | recordings for new committed fixtures, after a prompt version bump or a new call kind, and the separate live check of the models' answers | by hand, deliberately, spending API credits; never a gate |

## What the tests and snapshots cover

No test of the suite waits on real time (see [A faster clock](replay.md#a-faster-clock)); the API tier's
end-to-end tests, which `swift test` builds only with the `E2EAPI` trait, poll
the app they launch in real time, as UI polling does. The tests
exercise the pure parts
(hashing, cadence, journal, retention and its in-place migration, Clear
Journal and retention reaching every table, a journal made from every table's
oldest shape opening with a new journal's columns and indexes, settings and
an older settings file keeping every value, the ruleset drift check, the
quarantine list's shape, the
mentor scheduler and every gate, mentorship context rules and placement, spend
accounting, snooze and never-for-this rules per category, the rolling window,
the understanding's encoding, versioning, bounding and expiry, prompt assembly
with and without one, every tier's output schema asking for exactly the keys
its reply type decodes, request and response coding against fixture JSON,
recording, redaction, replay matching and stale refusal, launch flags, a
replay's separate files, per-launch directories with their locks and pruning,
the replay-only `--settings` flag, the line a launch writes as it starts, the
clocks, a replay's clock flags, the toast countdown, which variant of the mark
the menu bar shows and that every variant is committed at one size, callout mapping and
every anchor rejection, a callout aging out, transcript matching, the follow-up
prompt and gate, the toast rule for voice input, the whole loop against a
scripted client, follow-ups included, and the whole loop against the committed
replay fixtures, replayed strictly, a region and a follow-up answer included,
and every time-based behavior of the loop on the test clock) and Vision OCR on a
drawn bitmap, so they need no
permissions, display, network, microphone, or API key. A committed fixture that
is stale, or a tier with no committed fixture, fails the run (see [The committed
fixtures](replay.md#the-committed-fixtures)). The snapshot run covers every window and Settings pane with sample
data, their empty states (no suggestions, no frames, no contexts, contexts at
the cap), the Understanding card with a record, with none, paused, with a
refresh call in flight, and after a failed refresh, the Understanding settings
section with and without a record, the callout over the sample frame, the toast
collapsed, expanded, listening, thinking, answered, and as a note, the context
editor with a duplicate name, the transient status messages (a connection test,
a shortcut another app holds, on-device recognition unavailable), and every
variant of the menu bar mark, at the size the bar draws it, with the word a
replay puts beside it, and enlarged.

## Quarantine

A flaky test is quarantined rather than run again until it passes: nothing in
CI or the end-to-end harness reruns a failure. `Tests/quarantine.json` lists
each one, and is empty when none is; a test leaves it with the fix its issue
tracks. It is a JSON array of entries like

```json
[
  {
    "test": "AthinaCoreTests.ToastCountdownTests/aToastRunsForItsTimeout",
    "owner": "ahcarpenter",
    "issue": "https://github.com/getathina/athina/issues/123",
    "reason": "misses the last tick about once in twenty runs on a loaded runner"
  },
  {
    "scenario": "toast-buttons",
    "owner": "ahcarpenter",
    "issue": "https://github.com/getathina/athina/issues/124"
  }
]
```

Each entry names exactly one of `test`, a pattern as `swift test --filter`
takes it (a regular expression over `<target>.<suite>/<test>()`), and
`scenario`, an `athina-e2e` scenario's name; `owner` is who fixes it, `issue`
is the GitHub issue tracking the fix, and `reason` is optional.
`scripts/quarantine.sh check` refuses any other shape, and `make test` and
`athina-e2e run` fail on a list it refuses.

A quarantined test still runs: `make test` runs the rest with `swift test
--skip`, then the quarantined ones on their own, and when those fail it
reports each entry, as a warning on a GitHub Actions run, and passes. `make
test FILTER=...` runs exactly what the filter matches and counts every
failure. A quarantined scenario runs with the others, prints its `fail` line,
and is reported and tallied as quarantined rather than failed. The harness
does repeat a step whose input someone at the Mac got in the way of, such as
a click the pointer moved off, a toast they dismissed, or an app they brought
forward during a measurement (see [What the harness already
handles](e2e.md#what-the-harness-already-handles-so-a-scenario-need-not)), and
the API tier takes a checkpoint again while its window has not settled; each
such repeat is a `note` line in the scenario's result, so it is seen, and none
repeats a check that failed.
