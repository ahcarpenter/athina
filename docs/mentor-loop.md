# Mentor loop

`MentorLoop` is an actor with one consumer task over the sensing stream. For
each kept observation it runs, in order:

1. **Triage gate** (`MentorScheduler.triageGate`). The triage tier runs only on
   change moments: a kept observation whose reason is a focus change, settled
   input, or a manual capture, never a floor-cadence frame. It is debounced to
   one call per `triageMinInterval` (20 s by default) and skipped when the
   screen text is near-identical to the last triaged screen of the same window
   (line-set overlap of at least `triageSimilarityThreshold`, 0.9). Nothing
   runs while paused, idle, on an excluded app, without permissions, without an
   API key, while another call is in flight, or while the spend cap holds.
2. **Triage call** on the cheap model (`claude-haiku-4-5-20251001` by default;
   Sonnet 5, Opus 5, and Fable 5.1 are offered too) with structured output:
   `{"worth_a_look": bool, "reason": string}`, plus `context` while
   mentorship contexts are enforced.
3. **Mentor gate** (`MentorScheduler.mentorGate`), the single yes-or-no between
   triage and the strong model: the activity is inside a declared mentorship
   context (see below), triage said yes, the spend cap is not reached, and at
   least `mentorMinInterval` (2 min) has passed since the last mentor call.
4. **Mentor call** on the strong model (`claude-opus-5` at medium effort by
   default; Sonnet 5 and Fable 5.1 are offered too) with a rolling window of
   recent observations' text (bounded by `mentorWindowDuration` and
   `mentorWindowTokenBudget`), a compact event summary, the categories
   currently suppressed for the app, the standing understanding as its own
   system block, and, when `sendThumbnail` is on, the latest kept thumbnail as
   an image. While mentorship contexts are enforced the message also names the
   declared context the moment was placed in, with its description, so the
   suggestion stays useful for that work. The reply is `{"reason": string,
   "suggestion": null | {title, body, explanation, category, confidence,
   judged_goal, region}, "updated_understanding": {...}}`. A null suggestion is
   the normal outcome, and a null region is the normal suggestion; the region is
   filled only when the suggestion is about one specific spot visible in the
   attached screenshot (see [Callouts](#callouts)). The understanding comes back on every
   call.

   Each tier has its own model and effort in Settings > Models. Effort (low,
   medium, high, extra high) goes out as `output_config.effort` only to models
   that accept it; Haiku 4.5 rejects the parameter, so its effort control is
   disabled and nothing is sent. Thinking is left at each model's default
   (adaptive on Sonnet 5, Opus 5, and Fable 5.1); no thinking configuration is
   sent.

5. **Delivery.** A suggestion under `minimumConfidence`, in a snoozed or
   never-for-this category, with an empty title or body, or in a goal category
   with no goal to judge against (see [Standing understanding](#standing-understanding)) is logged and
   dropped. Otherwise it is journaled and shown as a toast: a floating,
   non-activating panel under the menu bar that never takes keyboard focus and
   auto-dismisses after `toastTimeout` (60 s;
   the countdown pauses while the pointer is over it). Closing it with the x,
   or a mouse-down in any other window or on the desktop, is journaled as
   dismissed; a click on Athina's own menu bar item is not one, since it opens
   the menu that answers the toast. A timeout, or quitting the app with the
   toast still up, is journaled as expired. *Tell Me More* expands the full explanation above the
   button bar (scrolling past 300 points) and becomes *Show Less*; the three
   buttons stay pinned to the bottom edge in both states, and an expanded
   toast stays until closed. *Not Now* dismisses and snoozes that category for
   that app for `notNowSnooze` (1 h). *Never for This* records that the
   category must never be raised for that app again (the rule is listed and
   removable in Settings > General). The toast never takes keyboard focus, so
   the menu's Answer Suggestion submenu offers the same answers to the
   keyboard and VoiceOver, and VoiceOver announces a toast as it appears; while
   VoiceOver or Switch Control is on, a toast does not expire on its own. Every
   suggestion and every answer is journaled, and the history window
   (menu > Suggestions) lists them with time, app, category, feedback, and full
   text.

The system prompts and output schemas of every tier live in
`Prompts.swift` under a version number that is stored with every call and
suggestion. Each system prompt carries a `cache_control` marker, and the
request encoder sorts keys so the cached prefix is byte identical between
calls. Caching only engages above
a model's minimum cacheable prefix (512 tokens on Claude Fable 5.1 and Opus 5,
1024 on Sonnet 5, 4096 on Haiku 4.5), so in practice the mentor prompt is
served from cache within its five-minute window and the small triage prompt
is not; the marker stays so a triage model with a lower minimum benefits.
Menu > Show Last Suggestion brings a missed toast back; a toast asked for
that way never expires on its own, and a non-answer never overwrites an
answer already given. The API key is read from the Keychain inside the loop
and passed per request; it is never journaled or logged.

## Callouts

A suggestion that is about one specific spot on screen can point at it. The
mentor output schema carries an optional `region`: a bounding box in the
pixel coordinates of the frame the model saw (the message states the frame's
size) plus a note of a few words, such as "this flag". The prompt tells the
model to leave it null when no screenshot is attached, when the suggestion is
about the work as a whole, or when it is not sure where the spot is, because
a box on the wrong thing is worse than no box. The loop keeps a region only
when an image was actually sent and the box lies inside the frame; anything
else is dropped before the suggestion is journaled.

Placing the callout is `CalloutAnchor`'s job, a pure function the app feeds
live readings to. The region is mapped through the observation's `FrameInfo`
into global display points with the same scale OCR blocks use, so a region
that covers a recognized line lands exactly on that line's `screenRect`. The
callout is then drawn only when every check passes, and the first failure is
the recorded reason:

- the region is inside the frame and at least a few pixels in each dimension;
- the display the frame came from is still attached with the same bounds;
- the screen under the spot was last confirmed unchanged no more than two
  minutes ago (`CalloutAnchor.maxFrameAge`; see below for what confirms it);
- the observation recorded the window's frame, which needs Accessibility;
- the same process is frontmost and a fresh accessibility read shows the same
  window (bundle identifier and title) with its frame within two points of
  where it was captured;
- the spot's centre lies inside that window.

While a callout is up the app repeats the check once a second, and takes the
callout down the moment a check fails: the window moved, another window or app
came to the front, the display configuration changed, or the frame aged out.
A window can also change without moving: a terminal scrolls, a document is
edited. `CalloutWitness` watches for that. Every frame the sensing pipeline
keeps of the same window must still show the recognized text the region
framed within a few pixels (`CalloutAnchor.contentStillMatches`), or the
callout comes down with "content under the spot changed". Such a frame also
confirms the screen, and so does each capture the pipeline then drops as a
near duplicate of it, because it drops one only when the picture, the window,
and the focused text are all unchanged. Staleness counts from the latest
confirmation, so a callout over a screen nobody touches stays up with its
toast, through a follow-up question, while one that nothing has confirmed for
two minutes comes down. The callout also goes
away whenever the toast does, for any reason. Menu > Show Last Suggestion
re-shows the callout only when its anchor still passes.

The overlay itself is `CalloutController`: a transparent, borderless,
non-activating panel above normal windows on the display the frame came from,
with `ignoresMouseEvents` set, so it never takes focus and never intercepts a
click, key, or scroll. It draws a tinted rounded box with a soft glow around
the spot and the note beside it on the same Liquid Glass as the toast, to its
right, where the rest of a line of text is usually empty (below the box, or
above it at the bottom of the display, only when there is no room). Athina's own windows are excluded from
capture, so the overlay never appears in a frame. Settings > General > "Show
callouts on screen" (on by default) turns callouts off; the history window
records for each suggestion whether one was drawn, and the debug panel's
Mentor card shows the last callout decision with the region in frame pixels
and in screen points.

## Talking back

A push-to-talk hotkey (the talk-back shortcut), recorded in Settings > General
the same way as the pause shortcut in Settings > Privacy and unset by default,
captures the microphone only while it is held. Carbon's hotkey registration
delivers both `kEventHotKeyPressed` and `kEventHotKeyReleased` for a
combination it registered, so `HotKeyCenter` hears the key go down and up
without Input Monitoring or any other permission beyond the two optional ones.
The same combination cannot be both the pause and the talk-back key; the
recorder refuses it and validation clears it. A recording is cut off after 30
seconds in case the release is missed.

Audio goes to `SFSpeechRecognizer` for the current locale with
`requiresOnDeviceRecognition` set, so nothing is sent to Apple's servers. When
the locale has no on-device recognizer, Settings and the menu say so plainly
and the feature stays off rather than falling back to server recognition.
While the key is held the toast shows a listening indicator and the live
transcript. The toast being talked to is never hidden while voice input is
active: from the key going down until the transcript is handled or the answer
is shown, it does not expire, a click elsewhere does not dismiss it, and it is
kept in front of other windows; afterwards it stays up until it is closed,
like an expanded one, and no new suggestion replaces it until then (see
below). Each recording is its own session: a recognizer result or timeout left
over from an earlier one is ignored, so a re-press never hears the previous
question again.

When the key is released, `TranscriptMatcher` reads the whole utterance,
lowercased, without punctuation, and with filler words such as "please"
trimmed from the ends. "Tell me more", "not now", and "never for this" (and
close variants: "more", "later", "no thanks", "never again", "don't show this
again") perform that answer; "never mind", "close it", and "got it" close the
toast. Anything else becomes one follow-up question to the mentor tier: the
suggestion (title, body, explanation), the exchange so far on that suggestion,
the recognized text of the screen the suggestion was made from when the
journal still has it, and the transcript, on the mentor model and effort,
with structured output `{"answer": string}`. The answer appears in the toast's
exchange area; an empty answer is journaled as an error and the toast says
so. The call is
journaled in the model call log with the `followUp` tier and counted against
the hourly spend cap like every other call; the same gates that hold both
tiers (off, paused, idle, excluded app, no key, the cap) hold a follow-up,
which is then journaled with the reason and never sent
(`MentorScheduler.followUpGate`). A question released while another call is
in flight is not refused: the toast says it is waiting, and it is asked as
soon as that call returns. At most one question waits; pressing the key again
withdraws it and the new question takes its place, and closing the toast or
pausing withdraws it too, in neither case journaling anything. The key does
nothing with no suggestion to talk back to except a brief note in the toast
area, and with no toast up it brings the most recent suggestion back to talk
to. The history window shows the full exchange under each suggestion, and the
debug panel's Mentor card shows the last transcript and what was done with it.

A suggestion the mentor tier finishes while a talked-to toast is up never
replaces it. `MentorScheduler.publishGate` holds it, leaving the toast, the
recording, the pending answer, and the answer on screen untouched; the
exchange ends only when that toast is closed, by the user answering or
dismissing it. A press that hears nothing, or a recording cut short by
pausing, is not an exchange (`TalkBackPress`): the toast gets back whatever
countdown it had (still paused while the pointer is over it), and anything
held in the meantime is shown at once. Show Last Suggestion during a recording
on a different toast ends it the same way; on the toast already on screen it
only brings that toast to the front and does not end its own exchange. The
toast it brings back stays up until closed, as it always does. Otherwise the
held suggestion is shown normally if it is at most 30 s old (the same staleness
bound as a queued observation); otherwise, and
whenever Athina is paused while one is held, it is journaled with the feedback
"Expired, never shown" and never put on screen, since the screen it describes
is gone. Such a suggestion still appears in the history window but is skipped
by Show Last Suggestion and by a key press with no toast up, which bring back
the most recent suggestion that was actually shown.

The Mentor card also has a **Talk back** field. Words typed there and sent take
exactly the path a released key does, from transcript matching to the
follow-up call and the answer in the toast, so the whole path can be
checked, in a replay or while recording a follow-up fixture, on a Mac where
Microphone and Speech Recognition are not granted.

## Mentorship contexts

Settings > Contexts is where you say what you want
mentoring in, in your own words: a short name such as "building web apps" and
an optional sentence saying what counts. **Only mentor inside these contexts**
turns that list into a hard boundary; it is off by default, and while it is off
the contexts change nothing.

While it is on, the declared names and descriptions are appended to the triage
system prompt and triage answers `context` (one of the declared names, or null)
alongside its usual verdict, so placing the moment costs no extra call. Null is
the one way the model declines to place a snapshot, and the prompt tells it to
answer null whenever it is unsure rather than guessing. A moment triage leaves
at null never reaches the mentor tier and never becomes a suggestion; the
triage call is logged with the `outOfContext` outcome and the reason. The
standing understanding (below) stands behind the same boundary: a moment
outside every context neither reaches the mentor tier that rewrites it nor
buys a refresh of its own. The schema offers only the declared names, so the
model cannot answer with a context that does not exist. The declared list is part of the triage system
prompt's single cached block, so an edit changes that prefix once; whether the
triage prompt is served from cache at all is the per-model question answered
above.

Up to `ContextRules.maxContexts` (12) contexts may be declared, each with a
unique name of at most 60 characters and a description of at most 280. The pane
disables Add Context at the cap, refuses a name another context already uses,
and caps both fields as they are typed with a note at the limit, so nothing
saved is dropped or cut on the way in. With the switch on and no context
declared, nothing is inside anything: no triage call is made at all, and the
Contexts pane, the menu, and the debug panel all say so.

To keep an app from being looked at at all, exclude it in Settings > Privacy >
Excluded apps: while an excluded app is frontmost nothing is captured, so
nothing about it can reach any tier.

The menu bar menu shows the current verdict (`Context: inside "writing Swift"`,
or why it is out) while it is still about the frontmost app, and
`Context: not yet judged in <app>` otherwise; the debug panel's Mentor card
shows it with the app it was made for and its age, and the model call log marks
a held call with the `outOfContext` outcome.

## Standing understanding

A mentor call used to see only the last ten minutes, so it could tell you a
faster way to do the thing on screen but never whether that thing would get
you where you were going. Athina now keeps a short record of the longer arc
and carries it from one call to the next.

**What it contains.** The model writes it, in four parts: the **goals** the
user appears to be working toward, most likely first, each with the evidence
for it and a confidence; a condensed **timeline** of what has happened; the
**mentor history**, what Athina has already said and how the user answered, so
it never repeats itself or re-raises something dismissed; and **open
concerns** worth watching but not worth an interruption. `Understanding.swift`
holds the type and the pure functions for bounding, rendering, and expiry.

**How it is refreshed.** Every mentor call returns `updated_understanding`
alongside its verdict, so the record is rewritten on the way past and that
refresh costs nothing beyond the call that was made anyway; its screen window
takes every observation journaled after the ones the record's last write read,
so the rewrite folds in everything since. Each revision stores the highest
observation id its call read as that cursor rather than a time, because a
screen is stamped when its capture starts and journaled only after OCR, so one
captured before a call read the journal can land in it after. A **periodic
refresh** (`understandingRefreshInterval`, 15 minutes by default) runs only
when a whole interval of active use has passed with no mentor call to carry
it. Active use is time spent capturing the screen: a break, a pause, a
sleeping Mac, an excluded app, missing permissions, or a closed app counts for
nothing, so coming back never buys a call over the few screens since. The count is kept
in the journal, so a relaunch carries on from it. It is a third tier with its own model and effort picker (`claude-opus-5`
at low effort by default; Haiku 4.5, Sonnet 5, and Fable 5.1 are offered too), its own versioned prompt and
schema, and no screenshot: summarising does not need one. `refreshGate` in
`MentorScheduler` is the single decision, and it holds while the loop is off,
paused, idle, on an excluded app, waiting for permissions, without a key, over
the spend cap, mid-call, not yet due, or before anything has been observed.
While mentorship contexts are enforced it also holds until triage has placed
the frontmost app inside a declared context, and for as long as the last
placement was outside every one, so activity outside the contexts never buys
a refresh; the mentor tier never runs for such a moment either, so neither
path that writes the record is reached from outside them. A refresh attempt
starts the interval over whatever came of it, so a failed call waits a whole
interval like the other tiers rather than retrying on the next observation. Refresh calls appear in the model call log and count
against the hourly spend cap like every other call.

**How it is used.** The record goes to the mentor tier as its own uncached
system block after the cached prompt: every mentor call rewrites it, so the
block changes on every call and a cache marker on it would never be read,
while the prompt before it keeps its marker. Triage receives the same record
as one compact paragraph in its user message, enough to notice an action that
conflicts with the goal without paying for the whole thing. Three suggestion
categories judge the current action against the inferred goal:
`wont_achieve_goal`, `less_efficient`, and `unwanted_side_effect`. They are
raised only when there is an understanding to judge against, they carry the
goal they were judged against (shown in the history window), and Never for
This suppresses each one per app exactly like every other category.

**Size and lifetime.** `understandingTokenBudget` (1200 tokens, settable up to
3000 so a mentor reply keeps room for its thinking and a suggestion beside the
record) bounds it: the model is told the budget and the app trims to fit on
the way in, dropping the
oldest timeline entries first, then the oldest mentor history, then concerns,
then the weakest goals, always keeping the strongest goal. It expires after
`understandingIdleGap` with no activity (4 hours) and always at a new day;
expiry and reset are journaled.
**Reset Understanding…**, in Settings > Models and in the debug panel, asks
first and then forgets every revision at once. Revisions are inserted rather
than updated, so the journal keeps the trail of how the reading developed, and
the current one survives a relaunch.

**What it costs.** The common case is free: a mentor call was going to happen
anyway and the record rides along in its reply, paying only for the extra
output tokens it writes. A periodic refresh is one call on the understanding
model, text only. Measured on 2026-09-13 writing the first record from a
15-minute window: 12,899 input and 1,161 output tokens, $0.09, 70 seconds on
Claude Opus 5 at low effort. So an hour of reading and browsing with no mentor
call in it costs about $0.38 in refreshes against the $1 default cap. Raise
the interval, or pick Claude Haiku 4.5 for this tier, to spend less; both are
in Settings > Models. Like the mentor tier, a refresh holds triage while it
runs, so a long one costs a change moment or two as well. The debug panel's
Understanding card shows the revision, when it was last written, which path
wrote it, its size against the budget, and what refresh calls have cost since
this understanding began.

## Spend control

Every response's usage fields (`input_tokens`, `output_tokens`,
`cache_creation_input_tokens`, `cache_read_input_tokens`) are priced with the
table in Settings > Models (dollars per million tokens, defaults checked
against Anthropic's pricing page on the date shown there, editable) and added
to a per-clock-hour total. As the total approaches `hourlySpendCap` ($1 by
default) both minimum intervals and the refresh interval stretch by
`1 / (1 - spent / cap)`, capped at 8x: 2x at half the cap, 4x at three
quarters. At the cap no call is made until the next clock hour. The hour's total is seeded from the journal at launch, so
relaunching does not reset it. Spend this hour shows in the menu, the debug
panel status bar, and the Mentor card. Replayed calls cost nothing and are never
counted (see [Iterating without the network](replay.md)).
