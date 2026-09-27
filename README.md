<h1 align="center">Athina</h1>
<p align="center">
  <a href="#requirements"
    ><img
      alt="Platform: macOS"
      src="https://img.shields.io/badge/platform-macOS-blue?style=flat-square"
  /></a>
</p>

<h3 align="center"><strong>A live mentor for your Mac.</strong> It watches how you work and shows you a better way when there is one.</h3>

<p align="center">
  <img src="Resources/Mark/ReadmeIcon.png" width="224" alt="Athina's app icon: Athena in a crested helmet, drawn in dark ink over cream shapes">
</p>

## Overview

The **foundation** is a menu-bar app that senses what you are doing
(accessibility context plus low-cadence screen capture with on-device OCR),
records it in a local journal, and, once turned on in Settings > Advanced,
shows a debug panel with what it currently thinks you are doing. The **mentor
loop** subscribes to that stream and asks Claude, in two tiers, whether there
is a genuinely more helpful way to approach what you are doing; when there is,
a small toast says so and learns from your answer. The **standing
understanding** carries what you appear to be working toward from one call to
the next, so Athina can look out for you: it calls out an approach that will
not reach your goal, one that is slower than an alternative you have, or one
that will reach it and bring a side effect you would not want. **Callouts and
voice** let a suggestion point at the spot on screen it is about and take a
spoken reply: an answer to the toast, or a question the mentor tier answers.
Reading suggestions aloud is deferred. Halt-and-redirect and learned
suppression are later phases.

## Requirements

- macOS 26 or later (developed and measured on macOS 27, Apple Silicon)

## Install

A release is a notarized download from outside the App Store: open
`Athina-<version>.dmg` and drag Athina onto Applications, or unzip
`Athina-<version>.zip` into Applications. There are no automatic updates yet:
a new version is downloaded and dragged over the old one. A released copy
uses the same journal, settings and keychain item as a development build (see
[A released copy and your data, grants, and key](docs/releasing.md#a-released-copy-and-your-data-grants-and-key)),
and the first live launch of either moves what an earlier Mentor kept (see
[Coming from Mentor](docs/coming-from-mentor.md)). To build Athina from source
instead, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Setup: the Anthropic API key

The mentor loop needs an Anthropic API key. Open Settings > Models (the menu's
Add API Key item goes there), paste the key, press Save, then Test Connection:
it sends one tiny request on the triage model and reports the answering model
or the API's own error message. The key
goes into your login keychain (`com.ahcarpenter.athina` /
`anthropic-api-key`) and nowhere else; the app only ever shows its last four
characters. Without a key the loop stays idle and the menu says so. Remove
deletes the keychain item. A replay needs no key, and the app never reads the
keychain while replaying.

## Permissions

Athina needs two permissions and explains each in a first-run window that
opens whenever one is missing. The window explains before it asks: no system
prompt appears when it opens. Each missing permission has one button. For the
sensing pair it is Open System Settings, which registers Athina in that
permission's System Settings list (macOS may show its own note pointing
there) and opens the matching pane; the window shows live status and re-checks
every second while open and when the app regains focus. Two more are optional
and serve only talking back; the window lists them below the required pair and
asks for them only when you press Request Access (Open System Settings once
the system has asked) or first hold the talk-back shortcut.

| Permission | Used for | Without it |
| --- | --- | --- |
| Screen Recording | ScreenCaptureKit capture of the display containing the focused window, then Vision OCR | Accessibility-only mode: app, window, and focused element are still sensed; no frames |
| Accessibility | Focused app, window title, focused element role and text, via the AX API; the live window frame a callout is checked against | Screen-only mode: frames and OCR only; app identity comes from NSWorkspace; no callouts, since the window cannot be verified |
| Microphone (optional) | Hearing you while the talk-back key is held | Talking back is off; a key press says so |
| Speech Recognition (optional) | Turning that audio into text on this Mac with the system recognizer, on-device only | Talking back is off; a key press says so |

Idle detection uses `CGEventSource.secondsSinceLastEventType`, which needs no
permission. Input Monitoring is never requested. The only network connection
the app ever opens is to `api.anthropic.com`, from the mentor loop, and only
when a key is saved (see [Privacy model](docs/privacy.md)).

## Privacy

- The journal, settings and audio stay on this Mac; the only network peer is
  `api.anthropic.com`, and only the mentor loop reaches it.
- A model call carries text read from the screen (the app, the window title,
  the focused element, the recognized text), a summary of recent events and
  the standing understanding the model wrote about your work. The mentor tier
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

## Develop

Athina builds with SwiftPM, and the app has no third-party dependencies. Plain
`make` lists every command, `make run` starts a replay that needs no key and
spends nothing, and `make check` is what a change passes before it is pushed.
[CONTRIBUTING.md](CONTRIBUTING.md) covers setup, the daily loop, the rules and
how a change reaches `main`; `docs/` holds the reference:

| Doc | Covers |
| --- | --- |
| [architecture.md](docs/architecture.md) | the source layout, the sensing loop, the journal, the subscription point |
| [mentor-loop.md](docs/mentor-loop.md) | triage and mentor calls, callouts, talking back, mentorship contexts, the standing understanding, spend control |
| [privacy.md](docs/privacy.md) | what leaves the Mac, what is kept, and for how long |
| [debug-panel.md](docs/debug-panel.md) | the debug panel |
| [design.md](docs/design.md) | the design conventions, the app icon and the menu bar mark |
| [code-style.md](docs/code-style.md) | the Swift style, the pinned swift-format, rebasing across the reformat |
| [testing.md](docs/testing.md) | each test layer's job, where it runs, and what the tests and snapshots cover |
| [replay.md](docs/replay.md) | replay, the faster clock, replays side by side, recording, the committed fixtures |
| [e2e.md](docs/e2e.md) | the end-to-end harness, its scenarios and tiers, the control API, hermetic runs |
| [ci.md](docs/ci.md) | the CI checks, the merge-checks label, the UI snapshot gates, checkpoints |
| [releasing.md](docs/releasing.md) | releases, code signing, the sandboxed build, the Xcode project |
| [coming-from-mentor.md](docs/coming-from-mentor.md) | what moves from Mentor on the first launch |
