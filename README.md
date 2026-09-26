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
when a key is saved (see Privacy model).
