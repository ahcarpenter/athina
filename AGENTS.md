# Project agent memory

Mentor: a macOS menu-bar app (Swift 6, SwiftUI, SwiftPM, no Xcode project) that senses what the user is doing and journals it. README.md is the authoritative description of architecture, permissions, and the privacy model.

- Build, run, test: `make build`, `make run`, `make test` (see `Makefile`, `scripts/bundle.sh`). CI: `.github/workflows/ci.yml` on `macos-26`.
- UI checks without a person at the screen: `build/Mentor.app/Contents/MacOS/Mentor --snapshot <dir>` renders every window to PNG (see `Sources/Mentor/Snapshots.swift`); needs no permissions.
- Performance numbers: `make measure` while the app runs.
- Permissions: Screen Recording and Accessibility are user-granted in System Settings and cannot be granted from a shell; the app degrades to the modes listed in README.md when they are missing. Idle time needs no permission.
- Signing: no identity on the captain's machine, so `scripts/bundle.sh` signs ad-hoc; macOS may re-prompt for permissions after a rebuild (README.md, "Code signing"). Set `MENTOR_SIGN_IDENTITY` to override.
- The core type is `ActivityObservation`, not `Observation`: that name collides with Apple's Observation module inside `@Observable` macro expansions.
- Never use the em dash character anywhere in this repository; use a plain dash.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
