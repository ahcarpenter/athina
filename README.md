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
        what you are doing on your Mac
            │  the app in front, its window, the text on screen
            ▼
   ┌───────────────────────────────────────────────────┐
   │  sensing → journal → triage → mentor              │
   │  the first two on your Mac, the last two with     │
   │  your provider, on your key, under the hourly cap │
   └───────────────────────────────────────────────────┘
            │  a better way, when there is one
            ▼
        a note under the menu bar, outlining the spot it is about
```

**Sensing** reads the screen on your Mac and keeps what it reads in a local **journal**.
Nothing is sensed before you choose **Allow**, while you **pause**, or while an **excluded app** is in front.

**Triage** runs when you switch apps or windows or stop typing or clicking, and asks the cheap model whether the moment is **worth a look**.
It sends the latest screen's text, runs at most once every 20 seconds, and skips a screen that has barely changed.

**Mentor** runs only when triage says yes and 2 minutes have passed since its last call.
It sends the strong model the recent screens' text and, by default, a thumbnail of the latest one, and most of the time the answer is nothing.
When there is something, a **note** appears under the menu bar and learns from your answer: **Tell Me More**, **Not Now** or **Never for This**.
A note about one spot on screen can outline it with a **callout**, which comes down as soon as that window moves or changes.

Each mentor call also rewrites the **standing understanding**, a short note of what you appear to be working toward, and after 15 minutes of use with no mentor call a refresh rewrites it on its own.
By default Claude Haiku 4.5 triages and Claude Opus 5 does the rest, or GPT-6 Luna and GPT-6 Sol on OpenAI.
Every call counts against one hourly cap, $1 by default: calls slow down as the hour's spend nears it and stop at it until the next hour.
Change it in [Settings > Models > Spend at most](docs/mentor-loop.md#spend-control).

## Install

Athina runs on macOS 26 or later.
Download `Athina-<version>.dmg` from [GitHub Releases](https://github.com/getathina/athina/releases) and drag Athina onto Applications.
Releases are not notarized yet, so allow the first launch in System Settings > Privacy & Security ([Install](docs/setup.md#install) has the steps).

## Quick start

1. Open Athina and choose **Allow** in the consent window; nothing is sensed or sent before it.
2. Grant **Screen Recording** and **Accessibility** from its permissions window ([Permissions](docs/setup.md#permissions)).
3. Paste an API key in Settings > Models, press Save, then Test Connection ([An API key](docs/setup.md#an-api-key)).

No key yet? From a source checkout, `make run` starts a replay that answers from recorded calls and spends nothing.

## Learn more

- [Privacy](docs/privacy.md): what each call carries and what stays on your Mac.
- [Setup](docs/setup.md): install, API keys, what calls cost, permissions.
- [The mentor loop](docs/mentor-loop.md): every gate, tier and setting.
- [Contributing](CONTRIBUTING.md): building from source, the daily loop and the docs.

Athina is early, and [issues](https://github.com/getathina/athina/issues) are welcome.
It is open source under the [MIT License](LICENSE).
