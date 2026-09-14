# Replay fixtures

Recorded model calls that `ReplayClaudeClient` serves in the loop tests and in
`make run-replay`. See README.md, "Iterating without the network", for the format
and the rules.

These recordings are stale. They come from two live sessions made on separate
branches before the standing understanding and the callouts and follow-ups were
combined: the understanding session at prompt version 9 and the follow-up at
prompt version 5. The combined prompts are a new version, so a strict replay
refuses every file and `swift test` fails until the whole set is recorded again
live, in one session, as README.md "The committed fixtures" describes.

Recorded live on 2026-09-14 with `Mentor --record`, prompt version 9, from a
staged scenario and nothing else: the two documents in `scenario/` open in
TextEdit, each window filling the built-in display, on a fresh journal, with
every other running app excluded, Mentor itself included. Triage, the
understanding refresh, and Test Connection ran on Claude Haiku 4.5, the
cheapest model offered for each. The mentor tier ran on Claude Sonnet 5 at
medium effort: at low effort it answered the current schema with a placeholder
suggestion and an empty understanding, so that recording was discarded. For the
session the mentor tier's minimum interval was raised, so the return to the
renames did not buy a second mentor call that would have restarted the refresh
period; the refresh interval was at its lowest, five minutes; and the idle
threshold was above it, with rename lines added to the document through
TextEdit's scripting interface to keep observations arriving. Test Connection
was recorded in a second launch on the same settings and an empty journal.
Every file was read, text and screenshot, before it was committed.

The screens were read by OCR from a small font, so their recognized text is
rough, and the answers mention it. The refresh request's recent events include
two switches to the recording machine's terminal app, which was excluded, so
no screen of it was captured.

| File | Kind | Model | Moment | Answer |
| --- | --- | --- | --- | --- |
| `20260914T232400.022Z-triage-6b921354.json` | triage | Claude Haiku 4.5 | photo-renames.txt in front at launch | worth a look |
| `20260914T232402.975Z-mentor-df6a368d.json` | mentor | Claude Sonnet 5, medium effort | the same moment, with the screenshot and no understanding yet | suggestion, shortcut, confidence 0.9; the first understanding |
| `20260914T232504.059Z-triage-3c6f2eca.json` | triage | Claude Haiku 4.5 | switch to reading-notes.txt, with the understanding paragraph | not worth a look |
| `20260914T232533.749Z-triage-80820899.json` | triage | Claude Haiku 4.5 | back to photo-renames.txt, with the understanding paragraph | worth a look (the mentor tier was held for the session) |
| `20260914T233023.775Z-understanding-09fb8644.json` | understanding | Claude Haiku 4.5 | periodic refresh, five minutes after the mentor call, while rename lines were added | a rewritten understanding with two goals |
| `20260914T233454.034Z-test-46364b5e.json` | test | Claude Haiku 4.5 | Settings > Mentor > Test Connection | OK |
| `20260915T000720.703Z-followUp-45fa3e98.json` | followUp | Claude Opus 5, medium effort | from the follow-up session below | names the line by its text and gives the quoted, guarded replacement |

The kept recordings cost an estimated $0.0280. The whole recording effort,
including the discarded sessions, cost an estimated $0.0674. `photo-renames.txt`
has since been replaced in `scenario/` by `cleanup-script.txt`.

The follow-up was recorded live on 2026-09-14 with `Mentor --record`, prompt
version 5, from `cleanup-script.txt` and `reading-notes.txt` open in TextEdit at
20 point on a fresh journal, driven without keystrokes. It answers "which line do
you mean, and what should I change it to", typed into the debug panel's Talk back
field, about a risk suggestion around `rm -rf $BUILD_ROOT/*`.
