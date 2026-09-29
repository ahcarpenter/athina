# Setup

Installing Athina, giving it an API key, what its calls cost, and the
permissions it asks for. The [README](../README.md) is the short version;
[CONTRIBUTING.md](../CONTRIBUTING.md) builds it from source.

## Requirements

- macOS 26 or later (developed and measured on macOS 27, Apple Silicon)

## Install

A release is a download from the repository's
[GitHub Releases](https://github.com/getathina/athina/releases): open
`Athina-<version>.dmg` and drag Athina onto Applications, or unzip
`Athina-<version>.zip` into Applications. Releases are not notarized yet, so
macOS refuses the first launch: choose Done, then Open Anyway next to Athina in
System Settings > Privacy & Security, and confirm; each update asks again, and
asks once to read the saved key (see
[Unsigned releases](releasing.md#unsigned-releases)). There are no
automatic updates yet: a new version is downloaded and dragged over the old
one. A released copy uses the same journal, settings and keychain item as a
development build (see
[A released copy and your data, grants, and key](releasing.md#a-released-copy-and-your-data-grants-and-key)).
To build Athina from source instead, see [CONTRIBUTING.md](../CONTRIBUTING.md).

**Try it without a key.** From a source checkout, `make run` starts a replay:
Athina watches your real screen but answers from model calls recorded in the
repository, so it needs no API key and spends nothing. It takes Xcode 26 or
later, your Allow in the consent window and the two permissions below;
[CONTRIBUTING.md](../CONTRIBUTING.md) has the setup.

## An API key

The mentor loop needs an API key for the provider chosen at the top of
Settings > Models: Anthropic, the default; OpenAI, for the GPT models Codex
uses; or OpenCode, through its Zen gateway, for its Claude and GPT models
([Providers](mentor-loop.md#providers)). Choosing a provider other than
Anthropic asks for your Allow again, since what is sent goes to another company.
Open Settings > Models (the menu's Add API Key item goes there), paste the key,
press Save, then Test Connection: it sends one tiny request on the triage model
and reports the answering model or the API's own error message. Each provider's
key goes into your login keychain (`com.ahcarpenter.athina` /
`anthropic-api-key`, `openai-api-key` or `opencode-api-key`) and nowhere else;
the app only ever shows its last four characters, and never reads or changes
another tool's setup, such as Claude Code's, Codex's or OpenCode's. Without a
key for the chosen provider the loop stays idle and the menu says so. Remove
deletes the keychain item. A replay needs no key, and the app never reads the
keychain while replaying.

## What it costs

Every call is billed to your own account with the chosen
provider at the prices in Settings > Models. Settings > Models > Spend at most caps each clock
hour, $1 by default: calls slow down as the hour's spend nears the cap and stop
at it until the next hour begins ([spend control](mentor-loop.md#spend-control)).
The menu shows the spend so far this hour against the cap. For a receipt,
these are the calls of one short session, made live on 2026-09-15 and
committed as the [replay fixtures](../Tests/AthinaCoreTests/Fixtures/Replay/README.md):

| Call | Model | Tokens in / out | Cost |
| --- | --- | --- | --- |
| Quick look at a screen, 3 calls | Claude Haiku 4.5 | 1,036 to 1,303 / 40 to 45 | $0.0013 to $0.0015 each |
| The suggestion, with a screenshot | Claude Sonnet 5, medium effort | 5,238 / 1,212 | $0.0240 |
| A question asked back about it | Claude Sonnet 5, medium effort | 1,231 / 225 | $0.0047 |
| Rewriting its notes on your goal | Claude Haiku 4.5 | 1,800 / 373 | $0.0037 |
| Test Connection | Claude Haiku 4.5 | 14 / 4 | under $0.0001 |
| **Session total** | | | **$0.0365** |

Out of the box, with Anthropic, the suggestion and the notes rewrite run on Claude Opus 5, at
2.5 times Sonnet 5's price per token. A rewrite on Opus 5 was measured at
$0.09, so an hour of reading with no suggestion in it costs about $0.38 in
rewrites (see [What it costs](mentor-loop.md#standing-understanding)).
What a typical hour of everyday use costs is not measured yet; the cap bounds
it.

## Permissions

A first launch asks before anything else whether Athina may watch the screen
and send what it reads to the chosen provider, Anthropic by default; nothing is
sensed or sent until you choose
Allow ([Consent](privacy.md#consent)). Athina then needs two permissions
and asks for neither until you press its button in the permissions window; the
other two are optional and serve only talking back
([how it asks](privacy.md#permissions)).

| Permission | Used for | Without it |
| --- | --- | --- |
| Screen Recording | ScreenCaptureKit capture of the display containing the focused window, then Vision OCR | Accessibility-only mode: app, window, and focused element are still sensed; no frames |
| Accessibility | Focused app, window title, focused element role and text, via the AX API; the live window frame a callout is checked against | Screen-only mode: frames and OCR only; app identity comes from NSWorkspace; no callouts, since the window cannot be verified |
| Microphone (optional) | Hearing you while the talk-back key is held | Talking back is off; a key press says so |
| Speech Recognition (optional) | Turning that audio into text on this Mac with the system recognizer, on-device only | Talking back is off; a key press says so |
