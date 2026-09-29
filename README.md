<p align="center">
  <img src="Resources/Mark/ReadmeIcon.png" width="96" alt="Athina's app icon: two eyes drawn as one line, with gold irises, on a grey-green field">
</p>
<h1 align="center">Athina</h1>
<p align="center">
  <a href="#install"
    ><img
      alt="Platform: macOS 26 or later"
      src="https://img.shields.io/badge/platform-macOS%2026%2B-blue?style=flat-square"
  /></a>
</p>

<h3 align="center">A live mentor for your Mac.</h3>

Athina sits in your menu bar, reads what you are working on, and tells you in a small note when it sees a better way to do it.
It asks a model with your own API key, and nothing but those calls leaves your Mac.

- **Read on your Mac** - the app in front, its window and the text on screen are read and kept here.
- **Quiet** - a cheap model picks the moments worth a look, and the strong model most often has nothing to say.
- **Points at the spot** - a note about one place on screen can outline it.
- **Keeps your goal in mind** - it can tell you when an approach will not get you where you are going.
- **Your key, your cap** - Anthropic, OpenAI or OpenCode, billed to you and capped at $1 an hour by default.

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
 │ at most once every 20 s, and     ├──┼──▶ is the latest screen's         │
 │ only when the screen changed     ◀──┼──┤ text worth a look?             │
 └─────────────────┬────────────────┘ ┆  └────────────────────────────────┘
   no: back to     │ yes              ┆
   watching        ▼                  ┆
 ┌──────────────────────────────────┐ ┆  ┌────────────────────────────────┐
 │ mentor                           │ ┆  │ the strong model               │
 │ 2 min since the last mentor      ├──┼──▶ reads the recent screens'      │
 │ call, and under the hourly       │ ┆  │ text, a thumbnail and what     │
 │ spend cap                        ◀──┼──┤ you seem to be after           │
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
   Tell Me More, Not Now (that kind   ┆
   of note waits an hour) or Never    ┆
   for This (it stops for this app)   ┆
```

By default the cheap model is Claude Haiku 4.5 and the strong one Claude Opus 5, or GPT-6 Luna and GPT-6 Sol on OpenAI.
The thumbnail can be turned off in Settings > Models, and a **callout** comes down as soon as its window moves or changes.

What you seem to be after is the **standing understanding**, a short note each mentor call rewrites.
After 15 minutes of use with no mentor call, a refresh rewrites it on its own.

Every call counts against one **hourly cap**, $1 by default: calls slow down as the hour's spend nears it and stop at it until the next hour.
Change it in [Settings > Models > Spend at most](docs/mentor-loop.md#spend-control), and see [the mentor loop](docs/mentor-loop.md) for every gate.

## Install

Athina runs on macOS 26 or later.
Download `Athina-<version>.dmg` from [GitHub Releases](https://github.com/getathina/athina/releases) and drag Athina onto Applications.
Releases are not notarized yet, so allow the first launch in System Settings > Privacy & Security ([Install](docs/setup.md#install) has the steps).

## Quick start

1. Open Athina and choose **Allow** in the consent window; nothing is sensed or sent before it.
2. Grant **Screen Recording** and **Accessibility** from its permissions window ([Permissions](docs/setup.md#permissions)).
3. Paste an API key in Settings > Models, press Save, then Test Connection ([An API key](docs/setup.md#an-api-key)).

## Development

```sh
make        # list every command
make run    # the app on recorded answers: no key, nothing spent
make check  # lint, test and snapshots: what a change passes before a push
```

[Contributing](CONTRIBUTING.md) has the setup, the rules and the docs.

## Learn more

- [Privacy](docs/privacy.md): what each call carries and what stays on your Mac.
- [Setup](docs/setup.md): install, API keys, what calls cost, permissions.
- [The mentor loop](docs/mentor-loop.md): every gate, tier and setting.

Athina is early, and [issues](https://github.com/getathina/athina/issues) are welcome.
It is open source under the [MIT License](LICENSE).
