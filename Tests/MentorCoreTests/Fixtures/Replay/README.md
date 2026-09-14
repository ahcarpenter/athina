# Replay fixtures

Recorded model calls that `ReplayClaudeClient` serves in the loop tests and in
`make run-replay`. See README.md, "Iterating without the network", for the format
and the rules.

Recorded live once on 2026-09-14 with `Mentor --record`, prompt version 4, from a
staged scenario and nothing else: the two documents in `scenario/` open in
TextEdit, each window filling the display, on a fresh journal, with every other
running app excluded. Triage ran on Claude Haiku 4.5 and the mentor tier on
Claude Sonnet 5 at low effort, the cheapest models offered for each tier. Every
file was read, text and screenshot, before it was committed.

| File | Kind | Moment | Answer |
| --- | --- | --- | --- |
| `20260914T204445.044Z-triage-a977d8a1.json` | triage | photo-renames.txt comes to the front | worth a look |
| `20260914T204446.954Z-mentor-dc5c6fe1.json` | mentor | the same moment, with the screenshot | suggestion, shortcut, confidence 0.9 |
| `20260914T204522.945Z-triage-cc379796.json` | triage | switch to reading-notes.txt | not worth a look |
| `20260914T204552.235Z-triage-0a52ee15.json` | triage | back to photo-renames.txt | not worth a look, already suggested |
| `20260914T204943.004Z-test-600405ea.json` | test | Settings > Mentor > Test Connection | OK |

Recording them cost an estimated $0.013 in total.
