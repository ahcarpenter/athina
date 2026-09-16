## Changes next to behavior

- Reset Understanding… asks before it resets, in Settings > Models and in the debug panel [Alerts].
- `MentorStatus.refreshStanding` reports `.refreshing` while a refresh call is in flight. Only the card's readout reads it; no gate does. Covered by `aRefreshCallInFlightIsTheStanding`.
- Countdowns across the debug panel read in minutes past sixty seconds (`Formatting.countdown` uses `ClockInterval.description`).
- The duration unit pop-up is a fixed width, so duration rows in one section line up; this also moves the Journal pane's retention rows into line.

- The debug panel's combined rows now say they are text, so VoiceOver names their role as it does for the panel's other rows.
- In the end-to-end harness's own tool: `mentor-drive ax texts` also reports a row SwiftUI combined into one element (role AXUnknown), which it skipped before, and `ax set` sends a number as a number, so a scenario can scroll a SwiftUI pane to what it wants to see.

No prompt, schema, fixture, gating, or sensing change; no live model call.

## Evidence

`scripts/e2e/mentor-e2e run understanding-surfaces` passes on this branch in 102 seconds: the mentor call that raises the first suggestion writes the first understanding, that goal reaches the menu clipped, the debug panel's card, and Settings > Models, and Reset Understanding… asks first, keeps every revision on Cancel with nothing journaled, and on Reset forgets them all and journals "reset after revision 1", after which the card reads "No understanding yet." and the menu "Goal: not worked out yet". Fifteen checks, all pass; the run's own screenshots and log are in `e2e/`.


On-screen captures on the captain's Mac in replay (`--replay Tests/MentorCoreTests/Fixtures/Replay`), one instance tracked by pid, under a scratch `CFFIXED_USER_HOME` with `sandbox-exec` denying the network and the real support directory, and every running app excluded. The captain was at the Mac, so nothing took focus: the scratch replay journal was seeded with the understanding the committed refresh fixture recorded, the status menu was opened and closed through accessibility, buttons were pressed by their accessibility description, and windows were captured by id. Light only: dark on screen would have meant switching the whole Mac's appearance; every state is rendered in light and dark below.

- Menu goal line with an understanding, then after Reset Understanding: "Goal: not worked out yet".
- Settings > Models > Understanding with a real 82-character goal, which showed the trailing-value layout breaking and is the capture of the fix.
- The confirmation from Settings (captured before the Current goal row was reworked, so the row behind the dialog is the older layout) and from the debug panel; Cancel kept both revisions, Reset Understanding removed them and journaled "reset after revision 2".
- The debug panel card with the recorded understanding, and after the reset.

VoiceOver: checked through the accessibility tree VoiceOver reads (role, title, description, value, help), not with VoiceOver switched on, because the captain was at the Mac. The card reads "Revision 2, 1m ago, periodic refresh", each goal as one stop ending "35% confidence", headings "Done so far", "Said so far", "Open concerns", each field as "Next, not counting: excluded app", and "Reset Understanding…, button"; the Settings row reads "Current goal, Prepare and safely run a disk-cleanup script on a build machine before the nightly build, 381 tokens, $0.00 in refresh calls, Revision 2"; the dialog reads its title, message, Reset Understanding, and Cancel. The surfaces post no announcements, so an announcement observer had nothing to catch.

Afterwards: no instance of mine running; the captain's live `settings.json` and journal unchanged by SHA-256. Launching with `--open settings:models` wrote `SettingsPane = models` into the real `com.ahcarpenter.mentor` defaults domain despite the scratch home; it was restored to `general` and the domain matches its starting contents.

## Not done

- **Follow-ups seen while auditing, outside this scope:** in Model Calls, "Out of context" wraps onto two lines beside a truncated model name at the panel's default width; an API error line splits "HTTP 529" across two lines (Last refresh here, Last triage and Last mentor in the Mentor loop card); the frame pane's "Waiting for the First Capture" says Screen Recording must be granted while the real reason is an excluded app in front.
- **AGENTS.md:** unchanged. This change added no knowledge every session needs, and running `fm-ensure-agents-md.sh` would add the "Maintaining this file" section this repository keeps out.
- **Accessibility Inspector audit, menu bar audit with the bar always visible, the redesign proposal:** their own phases.
