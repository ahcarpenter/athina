CONFIG ?= release
## Fixtures `make run-replay` answers from: the committed set unless given
REPLAY_DIR ?= Tests/MentorCoreTests/Fixtures/Replay
## Where `make record` writes: the app's recordings directory unless given
RECORD_DIR ?=
## Set to 1 to replay fixtures recorded with an older prompt version
ALLOW_STALE ?=

.PHONY: build run run-replay record test clean measure

## Build the .app bundle into build/Mentor.app
build:
	scripts/bundle.sh $(CONFIG)

## Build and launch the app (quits a running copy first)
run: build
	@pkill -x Mentor 2>/dev/null || true
	open build/Mentor.app

## Build and launch the app answering every model call from recorded fixtures:
## no network, no API key, no spend (see README, "Iterating without the network")
run-replay: build
	@pkill -x Mentor 2>/dev/null || true
	@test -d "$(REPLAY_DIR)" || { echo "run-replay: no fixture directory at $(REPLAY_DIR)" >&2; exit 1; }
	open build/Mentor.app --args --replay "$$(cd "$(REPLAY_DIR)" && pwd)" $(if $(ALLOW_STALE),--allow-stale-fixtures)

## Build and launch the app live, writing every model call to a fixture file.
## This spends API credits: use it only to record fixtures on purpose.
record: build
	@pkill -x Mentor 2>/dev/null || true
	open build/Mentor.app --args --record $(if $(RECORD_DIR),"$$(mkdir -p "$(RECORD_DIR)" && cd "$(RECORD_DIR)" && pwd)")

## Run the unit tests
test:
	swift test

## Sample the running app's CPU and memory for a while (see scripts/measure.sh)
measure:
	scripts/measure.sh

clean:
	rm -rf .build build
