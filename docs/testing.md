# Testing

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
