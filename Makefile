# Athina's one front door: plain `make` lists every command. The `##` text after
# a target is its help, a `##= NAME=value text` line under it is one of its
# variables, a line starting `## ` is printed as it stands, and `##@` starts a
# group; scripts/make-help.awk reads all four.
# Each recipe is one line calling a script, where the logic lives, and each
# ends in one summary line; VERBOSE=1 shows the whole output too
# (scripts/quietly.sh).

.DEFAULT_GOAL := help

.PHONY: help doctor build all run test test-e2e snapshots check snapshots-approve \
	lint format run-live record snapshots-smoke icons diagram measure release clean

help:
	@awk -f scripts/make-help.awk $(MAKEFILE_LIST)

## Start with make doctor. Any target takes VERBOSE=1 to show its whole output.

##@ Everyday

doctor: ## what this Mac is missing to build, test and check, and how to get each
	@scripts/doctor.sh

build: ## the app, build/Athina.app
	@scripts/bundle.sh $(CONFIG)
##= CONFIG=debug a debug build; release by default
CONFIG ?= release

# The same as build, the GNU standard name, left out of the list.
all: build

run: build ## the app on recorded model answers: no key, nothing spent
	@scripts/launch.sh replay --lane "$(LANE)" $(if $(REPLAY_DIR),--fixtures "$(REPLAY_DIR)") $(if $(SETTINGS),--settings "$(SETTINGS)") $(if $(TIME_SCALE),--time-scale "$(TIME_SCALE)") $(if $(ALLOW_STALE),--allow-stale)
##= REPLAY_DIR=<dir> answer from these fixtures, not the committed ones
##= SETTINGS=<file> start from these settings, never written to
##= TIME_SCALE=<n> run the clock n times faster (docs/replay.md)
##= ALLOW_STALE=1 answer from an older prompt version's fixtures too
##= LANE=<name> run beside other replays, one app per lane
LANE ?= replay

test: ## unit tests, as CI runs them
	@scripts/test.sh "$(FILTER)"
##= FILTER=<name> only the tests matching it

test-e2e: ## end-to-end scenarios driving the app, replays only (docs/e2e.md)
	scripts/e2e/athina-e2e run $(SCENARIO) --jobs $(JOBS)
##= SCENARIO=<name> just this one (scripts/e2e/athina-e2e list); all by default
SCENARIO ?= all
##= JOBS=<n> scenarios at once; 1 by default
JOBS ?= 1

snapshots: ## screenshots of your change vs main, drawn here, listing every difference
	@scripts/snapshots.sh smoke-local $(BASE)
##= BASE=<commit> compare with this commit rather than main

check: ## lint, test and snapshots: the one command to run before a push
	@scripts/check.sh

snapshots-approve: ## accept CI's new screenshots of HEAD, listing each before writing it
	@scripts/snapshots.sh approve

lint: ## the Swift style check and every Markdown link, offline, as CI runs them
	@scripts/lint.sh

format: ## fix the Swift style of every file in place
	@scripts/swift-format.sh format

##@ Occasional

run-live: $(if $(filter 1,$(SPEND)),build) ## the app on your API key: SPENDS CREDITS, so it needs SPEND=1
	@scripts/launch.sh live $(if $(filter 1,$(SPEND)),--spend)
##= SPEND=1 spend, up to the hourly cap in Settings > Models

record: $(if $(filter 1,$(SPEND)),build) ## the app on your API key, saving each call as a fixture: SPENDS CREDITS
	@scripts/launch.sh record $(if $(filter 1,$(SPEND)),--spend) "$(RECORD_DIR)"
##= SPEND=1 spend, up to the hourly cap in Settings > Models
##= RECORD_DIR=<dir> save the fixtures here; the app's recordings folder by default

snapshots-smoke: ## CI's snapshots-smoke check reproduced; drifts on a Mac unlike CI's
	@scripts/snapshots.sh smoke $(SHARD)
##= SHARD=<k>/<n> only the screenshots CI's shard k of n draws

icons: ## redraw the app icon, menu bar mark and README icon from Resources/Mark
	swift scripts/mark-assets.swift .

diagram: ## redraw the README's How it works diagram in docs/images
	swift scripts/how-it-works-diagram.swift .

measure: ## the running app's CPU and memory over 60 seconds
	ATHINA_PID="$(PID)" scripts/measure.sh
##= PID=<pid> the Athina to measure when several run

release: ## the notarized download (docs/releasing.md)
	scripts/release.sh

clean: ## delete every build product
	rm -rf .build build
