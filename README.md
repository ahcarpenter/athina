# mentor

Live mentor for macOS: watches what you are doing and offers timely guidance.

This repository holds the **foundation phase**: a menu-bar app that senses what
you are doing (accessibility context plus low-cadence screen capture with
on-device OCR), records it in a local journal, and shows a debug panel with what
it currently thinks you are doing. It makes **no model calls and no network
requests**. Suggestions, toasts, callouts, voice, and halt-and-redirect are
later phases that subscribe to the observation stream this phase provides.

## Requirements

- macOS 26 or later (developed and measured on macOS 27, Apple Silicon)
- Xcode 26 or later with its command line tools (`swift`, `codesign`)
- No third-party dependencies: SwiftUI, ScreenCaptureKit, Vision, the
  accessibility API, Carbon hotkeys, and the system SQLite

## Build, run, test

```sh
make build   # builds build/Mentor.app from the SwiftPM binary
make run     # builds, quits a running copy, and launches the app
make test    # runs the unit tests (swift test)
make measure # samples the running app's CPU and memory for 60 seconds
```

There is no Xcode project. `Package.swift` defines the targets and
`scripts/bundle.sh` wraps the release binary in an app bundle with
`Resources/Info.plist` and `Resources/Mentor.entitlements`, then signs it.
`swift build` and `swift test` work directly too.

`Mentor --snapshot <dir>` renders every window with sample data to PNG files
(light and dark) without starting the pipeline. It is how UI changes get checked
without a person at the screen; it needs no permissions.
`open build/Mentor.app --args --open debug` (or `settings`, `permissions`) launches the
app with that window already open, which is how the live panel gets screenshotted
from a shell.

### Code signing

The bundle script signs with `$MENTOR_SIGN_IDENTITY` if set, otherwise with the
first Apple Development or Developer ID Application identity in the keychain,
otherwise ad-hoc. macOS ties Screen Recording and Accessibility grants to the
app's designated code requirement, recorded when the grant is made. An ad-hoc
signature's default requirement is the hash of the exact binary, so a plain
ad-hoc rebuild silently invalidates both grants: System Settings still shows
the switches on, toggling them does not help, and the TCC daemon logs
"Failed to match existing code requirement". The ad-hoc path therefore signs
with an explicit requirement on the bundle identifier
(`identifier "com.ahcarpenter.mentor"`), which every rebuild satisfies, so a
grant made once stays valid. The trade-off is that any ad-hoc binary claiming
that identifier would inherit the grants, which is acceptable on a development
machine and is exactly what a development certificate fixes.

If a grant was made against an older build (the app shows a permission as
missing although System Settings shows it on), remove the stale record and
grant again:

```sh
tccutil reset Accessibility com.ahcarpenter.mentor
tccutil reset ScreenCapture com.ahcarpenter.mentor
```

## Permissions

Mentor asks for two permissions and explains each in a first-run window that
opens whenever one is missing. The window triggers each missing permission's
system prompt once when it opens, so Mentor appears in both System Settings
lists, shows live status, deep-links to the matching System Settings pane, and
re-checks every second while open and when the app regains focus.

| Permission | Used for | Without it |
| --- | --- | --- |
| Screen Recording | ScreenCaptureKit capture of the display containing the focused window, then Vision OCR | Accessibility-only mode: app, window, and focused element are still sensed; no frames |
| Accessibility | Focused app, window title, focused element role and text, via the AX API | Screen-only mode: frames and OCR only; app identity comes from NSWorkspace |

Idle detection uses `CGEventSource.secondsSinceLastEventType`, which needs no
permission. Input Monitoring is never requested. Nothing in this phase opens a
network connection.

## Architecture

```
Sources/MentorCore            library, fully testable
  Settings/                   SensingSettings (every threshold and cadence), SettingsStore (JSON),
                              ExcludedApps (defaults and matching), HotKey
  Model/ActivityObservation   FocusContext, FrameInfo, TextBlock, ActivityObservation, JournalEvent,
                              SensingEvent (the stream later phases consume), SensingMode, CadenceStatus
  Scheduling/                 CaptureScheduler (pure trigger and cadence state machine),
                              FrameKeepPolicy (near-duplicate drop rule)
  Imaging/                    PerceptualHash (256-bit dHash), FrameImaging (downscale, hash, JPEG)
  Journal/                    Journal actor over the system SQLite, RetentionPolicy
  Sensing/                    AXActor (run-loop thread for the AX API), FocusTracker (NSWorkspace + AXObserver),
                              ScreenCapturer (ScreenCaptureKit), TextRecognizer (Vision),
                              SensingPipeline (orchestration), EventBroadcaster (fan-out AsyncStream)
  System/                     PermissionProbe, InputActivity (idle seconds), ProcessResources (CPU, memory)
Sources/Mentor                the app: MenuBarExtra, AppState, windows, HotKeyCenter (Carbon), Snapshots
Tests/MentorCoreTests         Swift Testing suites for the pure parts
```

### Sensing loop

`SensingPipeline` is an actor with one loop. Each turn it:

1. re-reads permissions (every 2 s) and runs journal retention (every 10 min by default),
2. polls seconds-since-last-input and marks idle after `idleThreshold`,
3. computes the mode (`paused` > `waitingForPermissions` > `excluded` > `idle` > `watching` / `accessibilityOnly` / `screenOnly`),
4. asks `CaptureScheduler` whether a capture is due, and
5. sleeps until the next due time or the poll interval, or until a focus change wakes it.

Captures are triggered by app or window switches (after `focusSettleDelay`), by
input bursts settling (`inputSettleDelay`), by a slow floor cadence
(`floorInterval`) while active, or manually. Nothing runs while paused, idle,
on an excluded app, or without permissions. `minCaptureInterval` bounds the rate.

A capture reads the fresh accessibility context, grabs the display containing
the focused window with `SCScreenshotManager` (Mentor's own windows excluded,
downscaled to `maxFrameDimension`), hashes it, and drops it if the hash is
within `hashDistanceThreshold` of the previous kept frame **and** neither the
window nor the focused text changed. Kept frames go through Vision OCR (text
blocks with bounding boxes in frame pixels and in global display points), are
JPEG-encoded, written to the journal, and published as `SensingEvent.observation`.
Because the user can switch apps while the screenshot or OCR is in flight, the
pipeline asks NSWorkspace for the live frontmost app after each of those steps
and discards the frame, without OCR or journaling, when that app is not the one
the frame was captured for or is excluded.

### Journal

`~/Library/Application Support/mentor/journal.sqlite`, WAL mode, incremental
vacuum. Tables: `observations` (timestamp, app, window, accessibility summary
and JSON, OCR text and blocks, frame hash, frame geometry, reason), `thumbnails`
(JPEG blob per observation, separate so it can expire first), `events`
(start/stop, app and window switches, idle, pause, exclusion, permissions,
retention, clear). Retention deletes thumbnails older than `thumbnailRetention`,
then text and events older than `textRetention`, which settings clamp to at
least `thumbnailRetention` so text and events never expire before their
thumbnails, and then, if the file is still over `journalSizeCapBytes`, the
oldest thumbnails and finally the oldest observations and events until it fits.
"Clear Journal" in settings deletes everything.

Settings live next to it in `settings.json`; missing or unknown keys fall back
to defaults so older files keep working.

### Subscription point for later phases

`SensingPipeline.events()` returns an `AsyncStream<SensingEvent>`; every
subscriber sees every event from the moment it subscribes. The mentor loop will
consume `.observation(ActivityObservation)` (already journaled, with id) plus
the focus, mode, and cadence events, and can read history from `Journal`.

## Privacy model

- Everything stays on this Mac. There is no network code in the app.
- **Excluded apps** (Settings > Privacy) default to Keychain Access, Passwords,
  and common password managers. While one is frontmost Mentor captures no frame,
  reads no window title or element, runs no OCR, and journals only that the app
  was excluded.
- Secure text fields are never read, even in non-excluded apps.
- **Pause** from the menu or with the global hotkey (default ⌃⌥⌘P) stops all
  sensing; the menu bar icon switches from a filled eye to a crossed eye. Idle
  shows an outlined eye, an excluded app a raised hand, and missing permissions
  an eye with a warning badge.
- Thumbnails expire after 6 hours and text after 7 days by default; the journal
  is capped at 500 MB; all three are adjustable, and the journal can be cleared
  at any time.
- The journal directory is created with mode 0700.

## Debug panel

Menu bar > Debug Panel. Left: frontmost app, window, focused element (role,
title, description, text), cadence settings and counters, journal size and path.
Centre: the latest kept frame with OCR boxes overlaid and the recognized text
below; selecting an observation in the timeline shows that frame instead. Right:
a live timeline of observations and events from the journal. The status bar
shows mode, permission state, last and next capture with reason, seconds since
input, and the app's own CPU and memory.

## Continuous integration

`.github/workflows/ci.yml` runs `swift test`, the bundle script, and
`Mentor --snapshot` on GitHub's `macos-26` runner, which ships Xcode 26 and the
macOS 26 SDK this package targets, and uploads the rendered PNGs as the
`ui-snapshots` artifact. The tests exercise the pure parts (hashing, cadence,
journal, retention, settings) and Vision OCR on a drawn bitmap, so they need no
permissions or display.
