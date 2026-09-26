# Athina's one front door: plain `make` lists every command. The `##` text after
# a target is its help, a line starting `## ` is printed as it stands, and `##@`
# starts a group; scripts/make-help.awk reads all three.
# Each recipe is one line calling a script, where the logic lives.

.DEFAULT_GOAL := help

.PHONY: help build run test check lint format test-e2e doctor test-snapshots \
	all run-live record snapshots-approve snapshots-smoke-approve test-snapshots-ci \
	icons measure release xcodeproj clean swift-format-version

##@ Everyday

help: ## this list
	@awk -f scripts/make-help.awk $(MAKEFILE_LIST)

build: ## the development bundle, build/Athina.app (it carries the control API)
	scripts/bundle.sh $(CONFIG)

run: build ## build and launch a replay: recorded fixtures, no key, no spend
	@scripts/launch.sh replay --lane "$(LANE)" $(if $(REPLAY_DIR),--fixtures "$(REPLAY_DIR)") $(if $(SETTINGS),--settings "$(SETTINGS)") $(if $(TIME_SCALE),--time-scale "$(TIME_SCALE)") $(if $(ALLOW_STALE),--allow-stale)

test: ## swift test, the replayed loop and the fixture freshness check included
	swift test $(if $(FILTER),--filter "$(FILTER)")

test-e2e: ## run end-to-end scenarios on the app, replays only (SCENARIO=, JOBS=)
	scripts/e2e/athina-e2e run $(SCENARIO) --jobs $(JOBS)

test-snapshots: ## draw the UI smoke set here at HEAD and at BASE; report every change
	scripts/snapshots.sh smoke-local $(BASE)

check: ## lint, test and test-snapshots: what local validation runs
	$(MAKE) --no-print-directory lint && $(MAKE) --no-print-directory test && $(MAKE) --no-print-directory test-snapshots

lint: swift-format-version ## check every Swift file against .swift-format, as CI does
	$(SWIFT_FILES) | xargs -0 xcrun swift-format lint --strict --parallel

format: swift-format-version ## format every Swift file in place (README "Code style")
	$(SWIFT_FILES) | xargs -0 xcrun swift-format format --in-place --parallel

doctor: ## what this Mac is missing: tools, grants, the e2e harness's needs
	scripts/doctor.sh

##@ Occasional

all: build ## the same as build, the GNU standard name

run-live: build ## the live app: reads the real key and SPENDS API CREDITS
	@scripts/launch.sh live

record: build ## the live app writing every model call to a fixture: SPENDS API CREDITS
	@scripts/launch.sh record "$(RECORD_DIR)"

snapshots-approve: ## take Tests/Snapshots from CI's merge-checks renders of HEAD
	scripts/snapshots.sh approve $(RUN_ID)

snapshots-smoke-approve: ## take the smoke references from CI's renders of HEAD
	scripts/snapshots.sh smoke-approve $(RUN_ID)

test-snapshots-ci: ## the UI smoke test as CI runs it; drifts on a Mac unlike the runner
	scripts/snapshots.sh smoke $(SHARD)

icons: ## rebuild the app icon, menu bar mark and README icon from Resources/Mark
	swift scripts/mark-assets.swift .

measure: ## sample the running app's CPU and memory for 60 seconds
	ATHINA_PID="$(PID)" scripts/measure.sh

release: ## the notarized direct-download release (README "Releasing")
	scripts/release.sh

xcodeproj: ## generate Athina.xcodeproj, for the App Store route, from project.yml
	swift run --package-path Tools/XcodeGenTool xcodegen generate --spec project.yml

clean: ## remove every build product and the generated Xcode project
	rm -rf .build build Athina.xcodeproj Tools/XcodeGenTool/.build

##@ Variables

## CONFIG       build: the SwiftPM configuration
CONFIG ?= release
## FILTER       test: only the tests matching this, as swift test --filter takes it
FILTER ?=
## REPLAY_DIR   run: the fixtures to answer from; the committed set when empty
REPLAY_DIR ?=
## SETTINGS     run: a settings file to start from, read and never written
SETTINGS ?=
## TIME_SCALE   run: the replay's clock runs that many times faster (README "A faster clock")
TIME_SCALE ?=
## ALLOW_STALE  run: 1 also serves fixtures of an older prompt version, to iterate on prompts
ALLOW_STALE ?=
## LANE         run: names build/<LANE>.pid, so replays in other lanes keep running
LANE ?= replay
## RECORD_DIR   record: where fixtures go; the app's recordings directory when empty
RECORD_DIR ?=
## SCENARIO     test-e2e: the scenario to run (scripts/e2e/athina-e2e list names them)
SCENARIO ?= all
## JOBS         test-e2e: API-tier scenarios run at once
JOBS ?= 1
## BASE         test-snapshots: the commit to compare with; the fork from origin/main
BASE ?=
## SHARD        test-snapshots-ci: the shard to draw, k/n, by the full gate's table; all when empty
SHARD ?=
## RUN_ID       snapshots-approve, snapshots-smoke-approve: the CI run to take; HEAD's newest
RUN_ID ?=
## PID          measure: the Athina to sample when several run
PID ?=

# Every Swift file in the checkout, tracked or new, that git does not ignore
SWIFT_FILES = git ls-files -z --cached --others --exclude-standard '*.swift'

# The Xcode every CI job runs, whose swift-format CI lints with (README "Code
# style" and "Continuous integration")
SWIFT_FORMAT_XCODE := $(shell cat .xcode-version)

# Warns when the selected Xcode is not the one CI lints with, whose swift-format
# may format differently
swift-format-version:
	@scripts/swift-format-version.sh "$(SWIFT_FORMAT_XCODE)"
