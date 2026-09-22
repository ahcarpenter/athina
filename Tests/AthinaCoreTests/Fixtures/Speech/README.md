# Speech fixtures

Three short phrases for exercising talking back without a microphone: the
tests read them, the end-to-end harness plays them into a running replay with
`scripts/talk-back.sh`, and the debug panel's Speak Audio File action plays
any of them by hand. See README.md, "Talking back".

Each was spoken by the macOS system voice Samantha (English (US)) on
2026-09-22, with nothing recorded from a person:

```sh
say -v Samantha -o tell-me-more.wav --data-format=LEI16@22050 "Tell me more."
say -v Samantha -o not-now.wav --data-format=LEI16@22050 "Not now."
say -v Samantha -o which-line.wav --data-format=LEI16@22050 "Which line do you mean, and what should I change it to?"
```

They are 16-bit mono WAV at 22,050 Hz, `say`'s own rate, so every recognizer
hears them only after the same conversion a microphone's audio goes through.

| File | Words | Length | What it does in a replay |
| --- | --- | --- | --- |
| `tell-me-more.wav` | Tell me more. | 0.9 s | answers the toast with Tell Me More |
| `not-now.wav` | Not now. | 0.8 s | answers the toast with Not Now |
| `which-line.wav` | Which line do you mean, and what should I change it to? | 3.3 s | asks a follow-up question, which the committed replay fixtures answer (`../Replay`) |

The last is the question the committed follow-up fixture was recorded with, so
the answer a replay gives to it reads as an answer to it.
