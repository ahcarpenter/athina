# Testing

Each layer proves one thing, and a change is checked by the layers that can
see it. The unit tests are Swift Testing, run by `swift test`; the end-to-end
layers are the harness in `scripts/e2e` ([End-to-end harness](e2e.md)); the
pixel layers compare the one list of snapshots, `Snapshots.specs()`, and the
API tier's checkpoints with images CI approved ([Continuous integration](ci.md)).

| Layer | Proves | Runs |
| --- | --- | --- |
| Lint, `make lint` | one Swift style, public declarations' doc comments included ([Code style](code-style.md)) | `make check`; CI's `lint` on every push |
| Unit tests, `make test` | the pure logic, the whole loop against the committed replay fixtures, and that those fixtures are current ([below](#what-the-tests-and-snapshots-cover)) | `make check`; CI's `build-and-test` on every push |
| API-tier end-to-end, `athina-e2e run --tier api` | what a person does in Athina's own windows works, driven through the control API in a hermetic replay; in CI, also that its checkpoints did not drift | a change's evidence, where checkpoints are pictures only; CI's `e2e-api` on every push |
| UI smoke pixels, `make test-snapshots` and `make test-snapshots-ci` | layout, text, colour and state did not drift, every snapshot drawn in a test process | `make check` draws them at HEAD and at main on this Mac and reports each change; CI's `ui-snapshots-smoke` (`make test-snapshots-ci`) fails on a drift from its approved references, on every push |
| Full pixels, `ui-snapshots` | the same snapshots as the window server draws them, glass and materials included | CI, on four runners, at merge (the `merge-checks` label) and on every push to main |
| Real-screen end-to-end, `athina-e2e run --tier screen` | what only macOS's own routing decides (the menu bar item and the menu the system runs for it, clicks in other apps, the item's width), and sensing on the real screen (`capture-race`) | on a Mac, for a change to the menu bar item, toast dismissal, the Settings links or sensing |
| Live model, `make record` | recordings for new committed fixtures, after a prompt version bump or a new call kind, and the separate live check of the models' answers | by hand, deliberately, spending API credits; never a gate |

## What the tests and snapshots cover

No test waits on real time (see [A faster clock](replay.md#a-faster-clock)). The tests
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
is stale, or a tier with no committed fixture, fails the run (see [The committed
fixtures](replay.md#the-committed-fixtures)). The snapshot run covers every window and Settings pane with sample
data, their empty states (no suggestions, no frames, no contexts, contexts at
the cap), the Understanding card with a record, with none, paused, with a
refresh call in flight, and after a failed refresh, the Understanding settings
section with and without a record, the callout over the sample frame, the toast
collapsed, expanded, listening, thinking, answered, and as a note, the context
editor with a duplicate name, the transient status messages (a connection test,
a refused or recording shortcut, on-device recognition unavailable), and every
variant of the menu bar mark, at the size the bar draws it, with the word a
replay puts beside it, and enlarged.
