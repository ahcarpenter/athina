# Replay fixtures

Recorded model calls that `ReplayClaudeClient` serves in the loop tests and in
`make run`. See docs/replay.md for the format and the rules.

The set is current at prompt version 10. It was recorded live on 2026-09-15 in
one `Mentor --record` session from a staged scenario and nothing else: the two
documents in `scenario/` open in TextEdit, each window filling the built-in
display with its text enlarged through Format > Font > Bigger (so TextEdit marks
both windows Edited, which the recognized text shows), on an empty journal,
with every other running app excluded, Mentor itself included. Triage, the
understanding refresh, and Test Connection ran on Claude Haiku 4.5, the
cheapest model offered for each. The mentor tier, and with it the follow-up,
ran on Claude Sonnet 5 at medium effort. For the session the mentor tier's
minimum interval was at its highest, so no second mentor call restarted the
refresh count; the refresh interval was at its lowest, five minutes of active
use; and the idle threshold was an hour. The session was driven without
keystrokes: windows were raised through the accessibility API, the follow-up was
typed into the debug panel's Talk back field, and Test Connection was pressed
in Settings > Mentor. Every file was read, text and screenshot, before it was
committed.

While the refresh count ran, TextEdit briefly lost the front to the recording
machine's terminal app three times. It was excluded, so no screen of it was
captured, but the refresh request's recent events name those switches, and the
refresh answer reads them as the user going to the terminal.

| File | Kind | Model | Moment | Answer |
| --- | --- | --- | --- | --- |
| `20260915T073335.338Z-triage-35be2973.json` | triage | Claude Haiku 4.5 | reading-notes.txt in front at launch | not worth a look |
| `20260915T073407.244Z-triage-5250ca2f.json` | triage | Claude Haiku 4.5 | switch to cleanup-script.txt | worth a look |
| `20260915T073409.003Z-mentor-2acd5cb1.json` | mentor | Claude Sonnet 5, medium effort | the same moment, with the screenshot and no understanding yet | risk, confidence 0.92, with a region on `rm -rf $BUILD_ROOT/*`; the first understanding |
| `20260915T073507.287Z-followUp-bc130c04.json` | followUp | Claude Sonnet 5, medium effort | "which line do you mean, and what should I change it to", typed into Talk back | names the line and gives the guard and the quoted replacement |
| `20260915T073545.678Z-test-14607ebe.json` | test | Claude Haiku 4.5 | Settings > Mentor > Test Connection | OK |
| `20260915T074108.202Z-triage-6852515a.json` | triage | Claude Haiku 4.5 | switch back to reading-notes.txt, with the understanding paragraph | not worth a look |
| `20260915T074110.856Z-understanding-d4773524.json` | understanding | Claude Haiku 4.5 | periodic refresh, after five minutes of active use with no mentor call | a rewritten understanding with two goals |

The recordings cost an estimated $0.0365, and the session made no other call.
