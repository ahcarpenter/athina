CONFIG ?= release
## Fixtures `make run-replay` answers from: the committed set unless given
REPLAY_DIR ?= Tests/AthinaCoreTests/Fixtures/Replay
## Where `make record` writes: the app's recordings directory unless given
RECORD_DIR ?=
## Set to 1 to replay fixtures recorded with an older prompt version, only while iterating on prompts locally
ALLOW_STALE ?=
## Set to run a replay's clock that many times faster than real time (see README, "A faster clock")
TIME_SCALE ?=
## A settings file a replay starts from instead of the live settings, read and never written
SETTINGS ?=
## Names the replay's pid file, build/<LANE>.pid: `make run-replay` replaces only the replay its own lane launched
LANE ?= replay
## The pid `make measure` samples when several Athinas are running
PID ?=
## The CI run whose renders `make snapshots-approve` approves, the newest merge-checks run of HEAD when empty, or whose set `make snapshots-smoke-approve` approves, the newest CI run of HEAD when empty
RUN ?=
## The shard `make ui-snapshots-smoke` draws, k/n, as each of CI's runners passes it; every snapshot when empty
SHARD ?=
## The commit `make ui-snapshots-smoke-local` compares HEAD with; HEAD's merge-base with origin/main when empty
BASE ?=
## The app's own recordings directory, where `make record` writes by default
RECORDINGS := $(HOME)/Library/Application Support/athina/recordings

.PHONY: build mark run run-replay record clear-recordings fixture-status test format lint swift-format-version clean measure release xcodeproj xcode-build xcode-archive snapshots-approve ui-snapshots-smoke ui-snapshots-smoke-local snapshots-smoke-approve

## Build the .app bundle into build/Athina.app
build:
	scripts/bundle.sh $(CONFIG)

## Build, sign, notarize, and package a direct-download release into
## build/release: the universal app under the hardened runtime, a disk image,
## a zip, the debug symbols, and the release notes, which set the notes written
## by hand in docs/release-notes/<version>.md among this build's version and
## checksums (see README, "Releasing").
## ATHINA_RELEASE_IDENTITY names the Developer ID Application identity and
## ATHINA_NOTARY_PROFILE the notarytool keychain profile. Without them it runs
## every step that needs no Apple credentials, names each one it skipped, and
## fails, since that build is not one to distribute.
release:
	scripts/release.sh

## Generate Athina.xcodeproj, the Xcode project for the Mac App Store route,
## from project.yml with the XcodeGen pinned in Tools/XcodeGenTool (built on
## first use). The project is not committed: run this after changing project.yml,
## after adding or removing a source file, and before opening it in Xcode (see
## README, "The Xcode project"). The package build never needs it.
xcodeproj:
	swift run --package-path Tools/XcodeGenTool xcodegen generate --spec project.yml

## Build the App Store target, sandboxed, into build/xcode, signed to run
## locally until project.yml names a development team
xcode-build: xcodeproj
	xcodebuild -quiet -project Athina.xcodeproj -scheme "Athina App Store" -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath build/xcode build

## Archive the App Store target into build/xcode/Athina.xcarchive, as Xcode's
## Product > Archive does
xcode-archive: xcodeproj
	xcodebuild -quiet -project Athina.xcodeproj -scheme "Athina App Store" \
		-destination 'generic/platform=macOS' -derivedDataPath build/xcode \
		-archivePath build/xcode/Athina.xcarchive archive

## Rebuild the app icon and the README's copy of it from Resources/Mark/AthinaMark.svg,
## and the menu bar mark from Resources/Mark/AthinaOwl.svg. Its
## outputs are committed, so a plain `make build` never needs this; run it after
## changing either master or the variant set (see scripts/mark-assets.swift).
mark:
	swift scripts/mark-assets.swift .

## Build and launch the app, replacing only the copy this checkout's `make run`
## or `make record` launched before (scripts/launch.sh); every other Athina keeps
## running. Refuses to start while another live Athina is running, since two of
## them share the live journal, settings, and API spend.
run: build
	@scripts/launch.sh live --live

## Build and launch the app answering every model call from recorded fixtures:
## no network, no API key, no spend (see README, "Iterating without the network").
## Replaces only the replay this checkout's lane launched before, in a data directory
## of its own, which it names on the line it prints as it starts. A leading ~
## in REPLAY_DIR, RECORD_DIR, or SETTINGS is
## expanded here, because zsh leaves it after `=`. Each path is added to the
## argument list on its own, so one with a space in it stays one argument
## whatever shell runs the recipe.
run-replay: build
	@dir="$(REPLAY_DIR)"; case "$$dir" in "~"|"~/"*) dir="$$HOME$${dir#\~}";; esac; \
	test -d "$$dir" || { echo "run-replay: no fixture directory at $$dir" >&2; exit 1; }; \
	settings="$(SETTINGS)"; case "$$settings" in "~"|"~/"*) settings="$$HOME$${settings#\~}";; esac; \
	if [ -n "$$settings" ]; then test -f "$$settings" || { echo "run-replay: no settings file at $$settings" >&2; exit 1; }; \
		settings="$$(cd "$$(dirname "$$settings")" && pwd)/$$(basename "$$settings")"; fi; \
	set -- --replay "$$(cd "$$dir" && pwd)" $(if $(ALLOW_STALE),--allow-stale-fixtures) $(if $(TIME_SCALE),--time-scale $(TIME_SCALE)); \
	if [ -n "$$settings" ]; then set -- "$$@" --settings "$$settings"; fi; \
	scripts/launch.sh "$(LANE)" -- "$$@"

## Build and launch the app live, writing every model call to a fixture file.
## This spends API credits: use it only to record fixtures on purpose.
## Replaces only the copy this checkout's `make run` or `make record` launched
## before, and refuses to start while another live Athina is running. Opens the
## debug panel, whose Talk back field a recording session types into, whatever
## Settings > Advanced > Enable debug panel says (DebugPanelAccess).
record: build
	@dir="$(RECORD_DIR)"; case "$$dir" in "~"|"~/"*) dir="$$HOME$${dir#\~}";; esac; \
	if [ -n "$$dir" ]; then mkdir -p -m 700 "$$dir" && dir="$$(cd "$$dir" && pwd)" || exit 1; fi; \
	set -- --record; \
	if [ -n "$$dir" ]; then set -- "$$@" "$$dir"; fi; \
	set -- "$$@" --open debug; \
	scripts/launch.sh live --live -- "$$@"

## Delete the app's own recordings directory and every recorded call in it
clear-recordings:
	rm -rf "$(RECORDINGS)"

## Check that the committed fixtures are current: fails naming each fixture
## recorded with another prompt version and each tier with no fixture (the same
## check `make test` runs). Makes no network call.
fixture-status:
	swift test --filter theCommittedFixturesAreCurrent

## Run the unit tests
test:
	swift test

## Approve a UI change: make Tests/Snapshots match the renders the CI runner
## made of HEAD's source tree (in HEAD's newest CI run, or CI run RUN=<id>),
## never renders from this Mac, then commit the changed images with the change
## that caused them.
snapshots-approve:
	scripts/snapshots.sh approve $(RUN)

## Run the UI smoke test, as CI's ui-snapshots-smoke job does: draw every
## snapshot in the test process with swift-snapshot-testing and fail on any
## drift from its reference image. The references are the CI runner's, so a Mac
## on another macOS or display scale drifts everywhere; the output is in
## build/snapshots-smoke.
ui-snapshots-smoke:
	scripts/snapshots.sh smoke $(SHARD)

## Draw the UI smoke set on this Mac at HEAD and at its merge-base with
## origin/main (or BASE=<commit>) and report every screen that changed, was
## added or was removed, as local validation does; fails only on a snapshot
## that could not be drawn. The output is in build/snapshots-smoke-local.
ui-snapshots-smoke-local:
	scripts/snapshots.sh smoke-local $(BASE)

## Approve a UI change for the smoke test: make its references match the set
## the CI runner published for HEAD (in HEAD's newest CI run, or CI run
## RUN=<id>), never renders from this Mac, then commit the changed images with
## the change that caused them.
snapshots-smoke-approve:
	scripts/snapshots.sh smoke-approve $(RUN)

## Every Swift file in the checkout, tracked or new, that git does not ignore
SWIFT_FILES = git ls-files -z --cached --others --exclude-standard '*.swift'

## The Xcode whose swift-format CI lints with (see README, "Code style")
SWIFT_FORMAT_XCODE := $(shell cat .swift-format-xcode-version)

## Format every Swift file in place to Google's Swift style with the toolchain's
## swift-format and the committed .swift-format (see README, "Code style")
format: swift-format-version
	$(SWIFT_FILES) | xargs -0 xcrun swift-format format --in-place --parallel

## Check every Swift file against .swift-format without changing it, failing on
## any finding, as CI does; `make format` fixes all but the documentation ones
lint: swift-format-version
	$(SWIFT_FILES) | xargs -0 xcrun swift-format lint --strict --parallel

## Warn when the selected Xcode is not the one CI lints with, whose swift-format
## may format differently
swift-format-version:
	@xcode="$$(xcodebuild -version 2>/dev/null | head -n1)"; \
	if [ "$$xcode" != "Xcode $(SWIFT_FORMAT_XCODE)" ]; then \
	  echo "warning: CI lints with the swift-format in Xcode $(SWIFT_FORMAT_XCODE), but this runs the one in $${xcode:-no selected Xcode} (swift-format $$(xcrun swift-format --version 2>/dev/null)), which may format differently; see README, \"Code style\"" >&2; \
	fi

## Sample the running app's CPU and memory for a while (see scripts/measure.sh);
## PID=<pid> names the Athina to sample when several are running
measure:
	ATHINA_PID="$(PID)" scripts/measure.sh

clean:
	rm -rf .build build Athina.xcodeproj Tools/XcodeGenTool/.build
