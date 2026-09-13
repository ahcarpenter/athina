CONFIG ?= release

.PHONY: build run test clean measure

## Build the .app bundle into build/Mentor.app
build:
	scripts/bundle.sh $(CONFIG)

## Build and launch the app (quits a running copy first)
run: build
	@pkill -x Mentor 2>/dev/null || true
	open build/Mentor.app

## Run the unit tests
test:
	swift test

## Sample the running app's CPU and memory for a while (see scripts/measure.sh)
measure:
	scripts/measure.sh

clean:
	rm -rf .build build
