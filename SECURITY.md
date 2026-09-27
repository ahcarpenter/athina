# Security policy

Athina watches the screen: it captures frames, reads the focused window
through Accessibility, keeps a journal of what it saw on this Mac, and sends
text (and by default one screenshot) to `api.anthropic.com` with a key the
user pasted in. A flaw in any of that can expose someone's work, so reports
are welcome and taken seriously. [Privacy model](docs/privacy.md) says what
Athina promises; a way to break one of those promises is a security issue.

## Reporting a vulnerability

Report privately through GitHub's private vulnerability reporting: open the
repository's **Security** tab and choose **Report a vulnerability**
(<https://github.com/ahcarpenter/athina/security/advisories/new>). Only the
maintainer sees the report. Please do not open a public issue, pull request or
discussion for a vulnerability until a fix has shipped.

Include what you did, what you expected, what happened, the Athina version
(About Athina in the menu bar menu) and the macOS version. Leave out real
screen content, journals and API keys; a staged example is enough.

Expect an acknowledgement within a week. The fix is worked out privately in
the advisory, released, and then the advisory is published, crediting you
unless you ask otherwise.

## What counts

Anything that sends, stores or shows what Athina sensed beyond what
[Privacy model](docs/privacy.md) describes, for example:

- Screen content, window titles, accessibility text, transcripts or the
  understanding reaching any network peer other than `api.anthropic.com`, or
  reaching it outside the mentor loop and Test Connection.
- An excluded app or a secure text field being captured, read, recognized or
  sent.
- The API key leaving the login keychain other than in a request to
  `api.anthropic.com`: in the journal, a log, the debug panel, a recording or
  a crash report.
- The journal, thumbnails, recordings or settings becoming readable by another
  user, or landing somewhere their permissions (0700 directories, 0600
  recordings) do not hold.
- Sensing that keeps running while paused or idle, or the microphone open
  when the talk-back key is not held.
- The control API reachable in a release build, or any other way for another
  process to drive Athina or read its state.
- A way for screen content to make Athina act beyond showing a suggestion,
  such as prompt injection that reaches a tool, a file or the network.

Out of scope: what the model says in a suggestion (report that as a bug),
what Anthropic does with requests it receives (its own policies cover it),
and anything that needs an attacker who already controls the user's account
or has root on the Mac.

## Supported versions

Only the latest release and `main` receive fixes.
