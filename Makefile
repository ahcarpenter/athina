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
## The app's own recordings directory, where `make record` writes by default
RECORDINGS := $(HOME)/Library/Application Support/athina/recordings

.PHONY: build mark run run-replay record clear-recordings fixture-status test clean measure release

## Build the .app bundle into build/Athina.app
build:
	scripts/bundle.sh $(CONFIG)

## Build, sign, notarize, and package a direct-download release into
## build/release: the universal app under the hardened runtime, a disk image,
## a zip, the debug symbols, and draft release notes (see README, "Releasing").
## ATHINA_RELEASE_IDENTITY names the Developer ID Application identity and
## ATHINA_NOTARY_PROFILE the notarytool keychain profile. Without them it runs
## every step that needs no Apple credentials, names each one it skipped, and
## fails, since that build is not one to distribute.
release:
	scripts/release.sh

## Rebuild the app icon from Resources/Mark/AthinaMark.svg and the menu bar mark
## from Resources/Mark/AthinaOwl.svg. Its outputs are committed, so a plain
## `make build` never needs this; run it after changing either master or the
## variant set (see scripts/mark-assets.swift).
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
## before, and refuses to start while another live Athina is running.
record: build
	@dir="$(RECORD_DIR)"; case "$$dir" in "~"|"~/"*) dir="$$HOME$${dir#\~}";; esac; \
	if [ -n "$$dir" ]; then mkdir -p -m 700 "$$dir" && dir="$$(cd "$$dir" && pwd)" || exit 1; fi; \
	set -- --record; \
	if [ -n "$$dir" ]; then set -- "$$@" "$$dir"; fi; \
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

## Sample the running app's CPU and memory for a while (see scripts/measure.sh);
## PID=<pid> names the Athina to sample when several are running
measure:
	ATHINA_PID="$(PID)" scripts/measure.sh

clean:
	rm -rf .build build
