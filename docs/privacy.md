# Privacy model

- **Nothing is sensed or sent before Allow** in the consent window, and
  withdrawing in Settings > Privacy stops both at once (see Consent below).
- Sensing stays on this Mac: the journal, thumbnails, and settings never leave
  it. The only network peer is `api.anthropic.com`, reached only by the mentor
  loop, only when an API key is saved, and only while the loop is enabled or
  when the user asks for a Test Connection. No other part
  of the app has network code.
- **Audio and transcripts stay on this Mac.** The microphone is open only
  while the talk-back key is held, and only the system's on-device recognizer
  ever hears it; audio is never stored. The one exception is deliberate: a transcript you spoke while holding
  the key (or typed into the debug panel's Talk back field), when it is not
  one of the toast's answers, is sent to the mentor tier as your follow-up
  question, together with the suggestion it is about,
  the earlier questions and answers on that suggestion, and the recognized
  text of the screen the suggestion was made from; it is journaled as a
  talk-back event too, so for up to ten minutes it is among the recent events
  that triage, mentor and understanding calls are sent. Transcripts are
  journaled locally with the answers so the history window can show the
  exchange.
- **What leaves the machine.** The triage tier receives text only: the
  frontmost app and window title, the accessibility summary (focused element
  role and an excerpt of its text), the OCR text of the latest kept
  observation (cut at 6000 characters), and a compact summary of recent
  journal events. The mentor tier receives the rolling window of recent
  observations' text (app, window, accessibility summary, and OCR text of
  each, reaching back to the window duration in Settings and taking every
  screen journaled since the standing record's last write read the journal,
  bounded by the token budget with the oldest left out and said so when the
  record does not already cover them) and, by
  default, the latest kept thumbnail as a JPEG image. "Send the latest
  screenshot" in Settings > Models turns the image off, in
  which case the mentor tier receives text only. While mentorship contexts
  are enforced, the mentor tier also receives the name and description of the
  declared context the moment was placed in. The understanding refresh tier
  receives the current record, every screen journaled since its last write
  read the journal (the oldest left out, and said so, when they exceed the
  window's token budget), the event summary, and the app, title, and category
  of recent suggestions with the user's answers; never an image. The triage,
  mentor, and refresh tiers also receive the standing understanding itself, which is the model's own prose about the
  work, never raw screen text. Nothing else is sent: no file names, no
  keystrokes, no earlier thumbnails, no key.
- **The understanding is model-written prose about the work**, kept in the
  journal on this Mac like everything else, readable in full in the debug
  panel, bounded by its token budget, expiring with the idle gap and at a new
  day, and removable at any time with Reset Understanding or Clear Journal.
  The menu bar menu shows its strongest goal, clipped, alongside the debug
  panel and Settings > Models, whenever Athina is on and has a key.
  Both prompts that write it, the mentor prompt and the refresh prompt, tell
  the model to leave out anything private, financial, medical, or personal,
  and anything about other people on screen.
- The API key lives in the login keychain, is passed per request, and is never
  written to the journal, the logs, or the debug panel, which show at most its
  last four characters.
- With **only mentor inside these contexts** on, the declared context names and
  descriptions are part of the triage system prompt, so they do leave the
  machine with every triage call. When triage places a moment inside one of
  them, the mentor call carries that one context's name and description so the
  suggestion stays useful for that work. A moment placed outside never reaches
  the mentor tier, so no context information is sent for it; the placement
  itself is decided here from the model's answer, not there.
- **Excluded apps** (Settings > Privacy) default to Keychain Access, Passwords,
  and common password managers. While one is frontmost Athina captures no frame,
  reads no window title or element, runs no OCR, and journals only that the app
  was excluded, so nothing from them can reach any tier.
- Secure text fields are never read, even in non-excluded apps, so their
  contents never reach any tier.
- Model calls are journaled as counts (tokens, cost, latency, outcome) with the
  model's one-line reason, or the first line of a follow-up answer, never with
  the prompt or the screen text that was sent.
- **Recordings** are the one exception, and only when the app is launched with
  `--record`: each call's whole request, screen text and screenshot included,
  and its answer are written to a file on this Mac
  (`~/Library/Application Support/athina/recordings` unless another directory is
  given, mode 0700, files 0600). The API key is never written, and any
  Anthropic key visible in the screen text is redacted, though not inside the
  screenshot. Deleting that directory deletes them; Clear Journal does not. A
  replay (`--replay`) sends nothing anywhere, keeps its own journal and
  settings, and starts from the live settings (or a `--settings` file it never
  writes), so excluded apps stay excluded while replaying.
- **Committed fixtures** carry only staged, synthetic screen content, recorded
  for the purpose, never the captain's or any user's real work. Every recording
  is read, text and screenshot, before it is committed.
- **Pause** from the menu or with the global hotkey (⌃⌥⌘P unless changed or
  cleared) stops all sensing; the menu bar owl drops a lid over its eyes. Idle
  closes them and two z's drift off it, an excluded app looks away, missing
  permissions is a wide stare, and a held mentor tier winks (see [Design
  conventions](design.md)).
- Thumbnails expire after 6 hours and text after 7 days by default; the journal
  is capped at 500 MB; all three are adjustable, and the journal can be cleared
  at any time. A replay senses the real screen too, and a finished replay's
  journal is never opened again, so nothing can age it in place: the next
  replay launch removes its whole per-launch directory instead, once that
  directory has gone unwritten for longer than the thumbnail window (see
  [Replays side by side](replay.md#replays-side-by-side)).
- **Delete `~/Library/Application Support/athina/replay` yourself if you ran a
  replay on a build before this one.** Those builds kept one shared
  `journal.sqlite` there, holding thumbnails and recognized text from your real
  screen, and nothing ages it now: no launch opens it, so retention never runs
  against it, and Athina will not remove it for you. It cannot: an older build
  from another checkout may have that file open this minute, and a file's
  timestamps cannot tell that apart from one nobody has touched since the Mac
  went to sleep, so deleting it on a guess could pull the database out from
  under a running instance. Quit every Athina on the Mac and remove the
  directory. Per-launch directories, the ones this build makes, are swept for
  you, because a launch holds a lock on its own and the sweep takes that lock
  before it removes anything.
- The journal directory is created with mode 0700. Athina makes every one of
  them itself, the live one and each replay's, so there is no path someone
  else chose for a journal to land in.

## Consent

Nothing is sensed and nothing is sent until the person allows it. The consent
window, "Athina and Your Privacy", is the first thing a launch shows while
there is no Allow on record: a first launch, an install from before the window
existed, and a launch after Not Now or a withdrawal. It comes before the
Permissions window, which opens only after Allow and only when a permission is
missing, so no permission is asked about first. It names Anthropic as who
receives what is sent, lists what leaves the Mac (see above), says what the
journal keeps and for how long from the settings in force, and shows the menu
bar owl with its eyes open, the sign that Athina is watching, and lidded, the
sign that it is not. Allow and Not Now are its only answers; closing it
answers nothing.

The answer is kept in `settings.json` under `consent` (`Consent`): Allow or
Not Now, when, and the version of the disclosure it answered. An Allow counts
only for `Consent.disclosureVersion` or later, so a change to what is sent
that the person would want to hear about bumps the version and the window
asks again. A settings file that cannot be read loads as the defaults, which
hold no answer, so the window asks again then too.

Without an Allow the sensing pipeline stays in the `waitingForConsent` mode
(`SensingMode.resolve`, which checks consent before anything else): focus
tracking is not started, and no input, idle, permission, focus, window, or
frame is read or journaled; only retention runs, so what an earlier Allow let
in still ages out. The mentor loop holds every call: `MentorScheduler.callGate`
is asked by every gate and once more on the one path to the network, Test
Connection included. The owl shows its lidded, paused eyes, the menu reads
"Not watching until you allow it" with Allow Watching… as its command, and
talking back says it is not listening.

Settings > Privacy shows the answer and when it was given. Withdraw Consent
stops capturing and calling at once: the pipeline stops tracking focus and
drops a capture in flight before it is journaled, the loop drops a waiting
question and takes down the toast and callout, and a call already on the
network finishes but its suggestion is never shown. What the journal already
holds stays until it expires or is cleared. Review and Allow… opens the window
again. Both the consent window and Settings > Privacy link to the privacy
policy, this document on the repository's main branch
(`Consent.privacyPolicyURL`).

The end-to-end harness seeds an Allow ([e2e](e2e.md) "The warm fixture home"),
so its scenarios start sensing as the owner's own Athina does.

## Permissions

The [README](../README.md#permissions) lists each permission, what it is used
for, and how Athina works without it. Athina explains each in a window that opens
at launch whenever one is missing, once consent is given. The window explains before it asks: no
system prompt appears when it opens. Each missing permission has one button. For
the sensing pair it is Open System Settings, which registers Athina in that
permission's System Settings list (macOS may show its own note pointing there)
and opens the matching pane; the window shows live status and re-checks every
second while open and when the app regains focus. The two optional permissions
serve only talking back; the window lists them below the required pair and asks
for them only when you press Request Access (Open System Settings once the
system has asked) or first hold the talk-back shortcut.

Idle detection uses `CGEventSource.secondsSinceLastEventType`, which needs no
permission. Input Monitoring is never requested.
