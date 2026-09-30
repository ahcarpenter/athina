<p align="center">
  <img src="Resources/Mark/ReadmeIcon.png" width="96" alt="Athina's app icon: two eyes drawn as one line, with gold irises, on a grey-green field">
</p>
<h1 align="center">Athina</h1>
<p align="center">
  <a href="#requirements"
    ><img
      alt="Platform: macOS 26 or later"
      src="https://img.shields.io/badge/platform-macOS%2026%2B-blue?style=flat-square"
  /></a>
</p>

<h3 align="center"><strong>A live mentor for your Mac.</strong> It watches how you work and shows you a better way when there is one.</h3>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Tests/Snapshots/toast-dark.png">
    <img src="Tests/Snapshots/toast-light.png" width="382" alt="An Athina note under the menu bar: its kind tile and the app, a short title, a sentence saying why, and the buttons Tell Me More, Not Now and Never for This">
  </picture>
</p>

**Status:** early. Athina runs on macOS 26 or later, and feedback is wanted:
[issues](https://github.com/getathina/athina/issues) are welcome. It is
open source under the [MIT License](LICENSE).

## Overview

Athina sits in your menu bar and notices what you are working on: the app in
front, its window, and the text on your screen, read on your Mac. When it sees
a faster way to do what you are doing, a risk you may have missed, or a step
that will not get you where you are going, it tells you in a small note under
the menu bar and can outline the spot on screen it means. It asks a model
with your own API key for Anthropic, OpenAI or OpenCode, so you pay for those
calls under an hourly cap (see [spend control](docs/mentor-loop.md#spend-control)), and nothing
else leaves your Mac (see [Privacy](#privacy)).

## How it works

```
 ON YOUR MAC                          ┆  AT YOUR MODEL PROVIDER, ON YOUR KEY
                                      ┆
   what you are doing: the app in     ┆
   front, its window, the screen text ┆
                   │                  ┆
                   ▼                  ┆
 ┌──────────────────────────────────┐ ┆
 │ sensing                          │ ┆
 │ nothing before Allow, while      │ ┆
 │ paused, or on an excluded app    │ ┆
 └─────────────────┬────────────────┘ ┆
                   ▼                  ┆
 ┌──────────────────────────────────┐ ┆
 │ journal                          │ ┆
 │ what was read, kept on this Mac  │ ┆
 └─────────────────┬────────────────┘ ┆
                   │ you switch apps  ┆
                   │ or stop typing   ┆
                   ▼                  ┆
 ┌──────────────────────────────────┐ ┆  ┌────────────────────────────────┐
 │ triage                           │ ┆  │ the cheap model                │
 │ at most once every 20 s, and     ├─┼──▶ is the latest screen's         │
 │ only when the screen changed     ◀─┼──┤ text worth a look?             │
 └─────────────────┬────────────────┘ ┆  └────────────────────────────────┘
   no: back to     │ yes              ┆
   watching        ▼                  ┆
 ┌──────────────────────────────────┐ ┆  ┌────────────────────────────────┐
 │ mentor                           │ ┆  │ the strong model               │
 │ 2 min since the last mentor      ├─┼──▶ reads the recent screens'      │
 │ call, and under the hourly       │ ┆  │ text, a thumbnail and what     │
 │ spend cap                        ◀─┼──┤ you seem to be after           │
 └─────────────────┬────────────────┘ ┆  └────────────────────────────────┘
   most often      │ a suggestion     ┆
   nothing         ▼                  ┆
 ┌──────────────────────────────────┐ ┆
 │ a note under the menu bar, and   │ ┆
 │ a callout on the spot it means,  │ ┆
 │ when it means one                │ ┆
 └─────────────────┬────────────────┘ ┆
                   ▼                  ┆
   your answer, kept in the journal:  ┆
   Tell Me More, Not Now (that        ┆
   category of note waits an hour)    ┆
   or Never for This (that category   ┆
   stops for this app)                ┆
```

By default Claude Haiku 4.5 triages and Claude Opus 5 mentors, on Anthropic and on OpenCode; on OpenAI they are GPT-6 Luna and GPT-6 Sol.
Each tier's model and effort can be changed in Settings > Models.

What you seem to be after is the **standing understanding**, a short note the model writes and every triage and mentor call carries, so Athina can tell you when an approach will not get you where you are going.
Each mentor call rewrites it, and after 15 minutes of active use with no mentor call a **refresh** rewrites it on its own, by default on Claude Opus 5 or GPT-6 Sol.
It expires after 4 hours without activity and at the start of a new day.

Every call counts against one **hourly cap**, $1 by default: the gaps between calls stretch as the hour's spend nears it, and at the cap no call is made until the next hour.
Change it in [Settings > Models > Spend at most](docs/mentor-loop.md#spend-control).

[Privacy](#privacy) says what each call carries and what stays on your Mac, and the [mentor loop](docs/mentor-loop.md) has every gate, tier and setting.

## Privacy

- Nothing is captured or sent until you choose Allow on the Setup window's
  consent page that opens first, and Settings > Privacy withdraws it at once.
- The journal, settings and audio stay on this Mac; the only network peer is
  the host of the provider chosen in Settings > Models (`api.anthropic.com`,
  `api.openai.com` or `opencode.ai`), and only the mentor loop reaches it.
- A model call carries text read from the screen (the app, the window title,
  the focused element, the recognized text), a summary of recent events and
  the note the model keeps of what you appear to be working toward. The mentor tier
  also gets, by default, the latest screenshot thumbnail; a question you talk
  back is sent as a follow-up; and while mentorship contexts are enforced,
  their names and descriptions go too. File names, keystrokes and the key are
  never sent.
- Excluded apps (Keychain Access, Passwords and common password managers by
  default) and secure text fields are never read.
- Pause stops all sensing. Thumbnails expire after 6 hours and text after 7
  days by default, and the journal can be cleared at any time.

The [privacy model](docs/privacy.md) says exactly what each tier receives and
what is kept.

## Requirements

- macOS 26 or later (developed and measured on macOS 27, Apple Silicon)

## Install

1. Download `Athina-<version>.dmg` or `Athina-<version>.zip` from the
   repository's [GitHub Releases](https://github.com/getathina/athina/releases).
2. Open the `.dmg` and drag Athina onto Applications, or unzip the `.zip` into
   Applications.
3. Open Athina. Releases are not notarized yet, so macOS refuses the first
   launch: choose **Done**.
4. In System Settings > Privacy & Security, choose **Open Anyway** next to
   Athina, and confirm.

Each update asks again, and asks once to read the saved key (see
[Unsigned releases](docs/releasing.md#unsigned-releases)). There are no
automatic updates yet: a new version is downloaded and dragged over the old
one. A released copy uses the same journal, settings and keychain item as a
development build (see
[A released copy and your data, grants, and key](docs/releasing.md#a-released-copy-and-your-data-grants-and-key)).
To build Athina from source instead, see [CONTRIBUTING.md](CONTRIBUTING.md).

**Try it without a key.** From a source checkout, `make run` starts a replay:
Athina watches your real screen but answers from model calls recorded in the
repository, so it needs no API key and spends nothing. It takes Xcode 26 or
later, your Allow on the Setup window's first page and the two permissions
below;
[CONTRIBUTING.md](CONTRIBUTING.md) has the setup.

## Setup: an API key

The mentor loop needs an API key for the provider chosen at the top of
Settings > Models: Anthropic, the default; OpenAI, for the GPT models Codex
uses; or OpenCode, through its Zen gateway, for its Claude and GPT models
([Providers](docs/mentor-loop.md#providers)). Choosing a provider other than
Anthropic asks for your Allow again, since what is sent goes to another company.
Open Settings > Models (the menu's Add API Key item goes there), paste the key,
press Save, then Test Connection: it sends one tiny request on the triage model
and reports the answering model or the API's own error message. Each provider's
key goes into your login keychain (`com.ahcarpenter.athina` /
`anthropic-api-key`, `openai-api-key` or `opencode-api-key`) and nowhere else;
the app only ever shows its last four characters, and never reads or changes
another tool's setup, such as Claude Code's, Codex's or OpenCode's. Without a
key for the chosen provider the loop stays idle and the menu says so. Remove
asks first, then deletes the keychain item. A replay needs no key, and the app never reads the
keychain while replaying.

## Permissions

A first launch opens the Setup window, which asks before anything else whether
Athina may watch the screen and send what it reads to the chosen provider,
Anthropic by default; nothing is sensed or sent until you choose
Allow ([Consent](docs/privacy.md#consent)). It then walks on through the two
permissions Athina needs, asking for neither until you press its button on the
permissions page, the model and its key, and what to expect; the other two
permissions are optional and serve only talking back
([how it asks](docs/privacy.md#permissions)).

| Permission | Used for | Without it |
| --- | --- | --- |
| Screen Recording | ScreenCaptureKit capture of the display containing the focused window, then Vision OCR | Accessibility-only mode: app, window, and focused element are still sensed; no frames |
| Accessibility | Focused app, window title, focused element role and text, via the AX API; the live window frame a callout is checked against | Screen-only mode: frames and OCR only; app identity comes from NSWorkspace; no callouts, since the window cannot be verified |
| Microphone (optional) | Hearing you while the talk-back key is held | Talking back is off; a key press says so |
| Speech Recognition (optional) | Turning that audio into text on this Mac with the system recognizer, on-device only | Talking back is off; a key press says so |

## Develop

Athina builds with SwiftPM. Plain `make` lists every command, `make run`
starts a replay that needs no key and spends nothing, and `make check` is what
a change passes before it is pushed.
[CONTRIBUTING.md](CONTRIBUTING.md) covers setup, the daily loop, the rules and
how a change reaches `main`; `docs/` holds the reference:

| Doc | Covers |
| --- | --- |
| [architecture.md](docs/architecture.md) | the source layout, the sensing loop, the journal, the subscription point |
| [mentor-loop.md](docs/mentor-loop.md) | triage and mentor calls, callouts, keyboard shortcuts, talking back, mentorship contexts, the standing understanding, spend control |
| [privacy.md](docs/privacy.md) | what leaves the Mac, what is kept, and for how long |
| [debug-panel.md](docs/debug-panel.md) | the debug panel |
| [design.md](docs/design.md) | the design conventions, the app icon and the menu bar mark |
| [code-style.md](docs/code-style.md) | the Swift style, the pinned swift-format, rebasing across the reformat |
| [testing.md](docs/testing.md) | each test layer's job, where it runs, and what the tests and snapshots cover |
| [replay.md](docs/replay.md) | replay, the faster clock, replays side by side, recording, the committed fixtures |
| [e2e.md](docs/e2e.md) | the end-to-end harness, its scenarios and tiers, the control API, hermetic runs |
| [ci.md](docs/ci.md) | the CI checks, the ready-for-review snapshot gate, checkpoints |
| [releasing.md](docs/releasing.md) | releases, unsigned releases, code signing |
