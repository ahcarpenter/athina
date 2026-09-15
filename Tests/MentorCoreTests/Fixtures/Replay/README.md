# Replay fixtures

Recorded model calls that `ReplayClaudeClient` serves in the loop tests and in
`make run-replay`. See README.md, "Iterating without the network", for the format
and the rules.

Recorded live once on 2026-09-14 with `Mentor --record`, prompt version 5, from a
staged scenario and nothing else: the two documents in `scenario/` open in
TextEdit at 20 point, each window filling the built-in display, on a fresh
journal, with every other running app and Mentor itself excluded and the idle
threshold raised so sensing kept running while nothing was typed. The session
was driven without keystrokes, through TextEdit scripting and accessibility
actions, so no other app reached any request's event history. Triage and Test
Connection ran on Claude Haiku 4.5. The mentor tier and the follow-up ran on
Claude Opus 5 at medium effort, the shipped default: a first attempt on Claude
Sonnet 5 at medium effort answered this same moment with a risk suggestion whose
title, body, and explanation were empty, so it was discarded. Every file was
read, text and screenshot, before it was committed.

| File | Kind | Moment | Answer |
| --- | --- | --- | --- |
| `20260915T000123.857Z-triage-de93ea15.json` | triage | cleanup-script.txt is in front | not worth a look |
| `20260915T000428.773Z-triage-5966b261.json` | triage | switch to reading-notes.txt | not worth a look |
| `20260915T000453.449Z-triage-0c9d3914.json` | triage | back to cleanup-script.txt | worth a look |
| `20260915T000454.682Z-mentor-fb968013.json` | mentor | the same moment, with the screenshot (1280 by 827 pixels) | risk suggestion, confidence 0.93, region x 4, y 205, 260 by 30 around `rm -rf $BUILD_ROOT/*`, note "empty var means rm -rf /*" |
| `20260915T000720.703Z-followUp-45fa3e98.json` | followUp | "which line do you mean, and what should I change it to", typed into the debug panel's Talk back field | names the line by its text and gives the quoted, guarded replacement |
| `20260915T000815.151Z-test-fe31b22a.json` | test | Settings > Mentor > Test Connection | OK |

Two imperfections are kept as the models gave them, because the fixtures record
real answers: OCR read the first `echo` line without its opening quote, so the
mentor reply and the follow-up both suggest adding one, and the follow-up counts
the `rm` line as line 6, although it quotes the line exactly.

The live mentor region, drawn on the real screen during the recording, framed
the `rm -rf $BUILD_ROOT/*` line exactly.

The six kept calls cost an estimated $0.056277; the whole session, the
discarded Sonnet 5 attempt included, cost $0.067693.
