CONFIG ?= release
## Fixtures `make run-replay` answers from: the committed set unless given
REPLAY_DIR ?= Tests/MentorCoreTests/Fixtures/Replay
## Where `make record` writes: the app's recordings directory unless given
RECORD_DIR ?=
## Set to 1 to replay fixtures recorded with an older prompt version, only while iterating on prompts locally
ALLOW_STALE ?=
## Set to run a replay's clock that many times faster than real time (see README, "A faster clock")
TIME_SCALE ?=
## The app's own recordings directory, where `make record` writes by default
RECORDINGS := $(HOME)/Library/Application Support/mentor/recordings

.PHONY: build run run-replay record clear-recordings fixture-status test clean measure

## Build the .app bundle into build/Mentor.app
build:
	scripts/bundle.sh $(CONFIG)

## Build and launch the app (quits a running copy first)
run: build
	@pkill -x Mentor 2>/dev/null || true
	open build/Mentor.app

## Build and launch the app answering every model call from recorded fixtures:
## no network, no API key, no spend (see README, "Iterating without the network").
## A leading ~ in REPLAY_DIR or RECORD_DIR is expanded here, because zsh leaves it after `=`.
run-replay: build
	@pkill -x Mentor 2>/dev/null || true
	@dir="$(REPLAY_DIR)"; case "$$dir" in "~"|"~/"*) dir="$$HOME$${dir#\~}";; esac; \
	test -d "$$dir" || { echo "run-replay: no fixture directory at $$dir" >&2; exit 1; }; \
	open build/Mentor.app --args --replay "$$(cd "$$dir" && pwd)" $(if $(ALLOW_STALE),--allow-stale-fixtures) $(if $(TIME_SCALE),--time-scale $(TIME_SCALE))

## Build and launch the app live, writing every model call to a fixture file.
## This spends API credits: use it only to record fixtures on purpose.
record: build
	@pkill -x Mentor 2>/dev/null || true
	@dir="$(RECORD_DIR)"; case "$$dir" in "~"|"~/"*) dir="$$HOME$${dir#\~}";; esac; \
	if [ -n "$$dir" ]; then mkdir -p -m 700 "$$dir" && dir="$$(cd "$$dir" && pwd)" || exit 1; fi; \
	open build/Mentor.app --args --record $${dir:+"$$dir"}

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

## Sample the running app's CPU and memory for a while (see scripts/measure.sh)
measure:
	scripts/measure.sh

clean:
	rm -rf .build build
