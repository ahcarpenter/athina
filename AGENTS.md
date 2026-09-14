# Project agent memory

Mentor: a macOS menu-bar app (Swift 6, SwiftUI, SwiftPM, no Xcode project) that senses what the user is doing and journals it. README.md is the authoritative description of architecture, permissions, and the privacy model.

- Build, run, test: `make build`, `make run`, `make test` (see `Makefile`, `scripts/bundle.sh`). CI: `.github/workflows/ci.yml` on `macos-26`.
- UI checks without a person at the screen: `build/Mentor.app/Contents/MacOS/Mentor --snapshot <dir>` renders every window to PNG (see `Sources/Mentor/Snapshots.swift`); needs no permissions or API key. A render is clamped to the screen height, so a tab taller than that needs its own section preview. `open build/Mentor.app --args --open debug` (or `settings:mentor`, `history`) launches with that window open for real screenshots (`screencapture -l <window id>`).
- Model calls cost the captain API credits, so never make a live one to build, test, or verify: exercise the app with `make run-replay` (or `open build/Mentor.app --args --replay <dir>`), which answers every call from recorded fixtures with no key, network, or spend, keeps its own journal and settings in `~/Library/Application Support/mentor/replay`, and is marked Replay in the menu bar, debug panel, and journal (README "Iterating without the network"). Live calls are only for deliberate recording (`make record`) and the separate live-quality check. Tests replay `Tests/MentorCoreTests/Fixtures/Replay` or use `ScriptedClaudeClient`, never the network. Only `MentorLoop.perform` reaches the `ClaudeClient` seam, only to `api.anthropic.com`, only with a key the user pasted into Settings > Mentor (login keychain; never search for one). Prompts and schemas are versioned in `Sources/MentorCore/Mentor/Prompts.swift`; bump the version when they change. That makes the committed fixtures stale, which never fails CI: the tests replay them as they are and `make fixture-status` reports it, and they are recorded again only in the live quality round. Model ids and prices live in `ModelCatalog.swift` with the date they were checked.
- Both trigger decisions are pure functions in `MentorScheduler` (`triageGate`, `mentorGate`); add new gating conditions there, not in the loop or the UI. The mentorship contexts (README "Mentorship contexts") are enforced in those two functions only.
- Settings editors must not bind a control straight to a field `validated()` normalizes: `AppState.settings.didSet` re-validates on every keystroke, so a name would be trimmed and an empty new row dropped mid-edit. Edit a local copy and commit it (see `MentorshipContextsSection.swift`).
- Performance numbers: `make measure` while the app runs.
- Permissions: Screen Recording and Accessibility are user-granted in System Settings and cannot be granted from a shell; the app degrades to the modes listed in README.md when they are missing. Idle time needs no permission.
- Signing: no identity on the captain's machine, so `scripts/bundle.sh` signs ad-hoc with a bundle-identifier designated requirement so grants survive rebuilds; if the app reports a permission missing that System Settings shows on, the grant is bound to an old build (README.md, "Code signing"). Set `MENTOR_SIGN_IDENTITY` to override.
- The core type is `ActivityObservation`, not `Observation`: that name collides with Apple's Observation module inside `@Observable` macro expansions.
- Never use the em dash character anywhere in this repository; use a plain dash.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
