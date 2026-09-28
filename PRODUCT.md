# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

Athina's real target is a native macOS 26+ menu bar app built with SwiftUI. `ios` is recorded only so Impeccable loads its Apple-native guidance; the macOS-specific design choices live in docs/design.md, which follows Apple's Human Interface Guidelines for macOS.

## Users

Any Mac knowledge worker doing focused work at their Mac, technical or not: terminals and editors, documents, spreadsheets, design tools, email. They want to get their work done well without stopping to ask for help, and to hear about a better way when there is one.

## Product Purpose

Athina is a live mentor for the Mac. It notices what the user is working on (the app in front, its window, and the text on screen, read on the Mac), and when it sees a faster way, a risk the user may have missed, or a step that will not get them where they are going, it tells them in a small note under the menu bar and can outline the spot on screen it means.

Success means:

- People get the information they want as quickly as possible, and also get guidance they did not realize they needed: Athina accounts for the user's blind spots.
- People get better: they learn the faster way and need the nudge less over time.
- Earned trust: no surprise bills and no privacy surprises, so people keep it running all day.
- The product itself is something users want.

## Positioning

It speaks up unprompted. Athina watches the user's real screen live and offers guidance without being asked, only when it sees a better way, a risk, or a dead end; the user never has to stop and ask.

## Operating Context

- Lives in the macOS menu bar all day, beside whatever the user is working in. Notes appear under the menu bar, and callouts outline a spot on the real screen.
- Reads the front app, its window, the focused element and the text on screen through Screen Recording and Accessibility, which the user grants in System Settings. Microphone and Speech Recognition are optional, for talking back.
- Model calls use the user's own API key (Anthropic today, with OpenAI and OpenCode being added), capped at $1 an hour by default.
- Installed as a direct download from GitHub Releases; there is no App Store edition.

## Capabilities and Constraints

- Notes under the menu bar, on-screen callouts, talking back by voice with a push-to-talk shortcut, a History of past suggestions, mentorship contexts, and a standing understanding of what the user appears to be working toward (docs/mentor-loop.md).
- Consent comes first: nothing is captured or sent until the user chooses Allow, and Settings > Privacy withdraws it. Pause stops all sensing, excluded apps and secure text fields are never read, and the journal stays on the Mac (docs/privacy.md).
- A replay mode answers from recorded model calls, with no key and no spend.
- A debug panel exists for development, in Settings, off by default.
- Requires macOS 26 or later. Releases are not notarized yet.

## Brand Commitments

- Apple's Human Interface Guidelines for macOS are the bar: every surface follows them, and conformance is an acceptance criterion, with the guideline cited (docs/design.md).
- The menu bar is the app: no Dock icon or app window by default. It lives in the menu bar, notes appear under it, and the debug panel sits in Settings, off by default.
- Mentor voice: calm, short, specific, never nagging, and it says why.
- Minimalistic.

## Evidence on Hand

- Recorded real model calls in Tests/AthinaCoreTests/Fixtures/Replay, and UI snapshot baselines in Tests/Snapshots.
- The README's cost receipt of a short session.
- No testimonials, customers, usage numbers or press exist yet; do not fabricate them.

## Product Principles

1. Speak up only when it matters: few, worthwhile interruptions, including the blind spots the user did not know to ask about.
2. Get the user to what they want fast, then get out of the way.
3. Teach, not just tell: say why, so the user gets better and needs Athina less over time.
4. Earn trust continuously: consent first, visible spend, and nothing that surprises.

## Accessibility & Inclusion

Follow Apple's Human Interface Guidelines for accessibility (VoiceOver labels, full keyboard access, Reduce Motion and the like). There is no further product-specific standard.
