#!/usr/bin/env bash
# `make test`, which CI's build-and-test runs as it stands: swift test, the
# replayed loop and the fixture freshness check included, then the check that
# a build without the ControlAPI trait carries no control API (docs/e2e.md "The
# control API"). The debug Athina the tests' build already made is such a
# build, so it checks that one rather than compiling the package again; `swift
# build` only confirms it is current.
#
# The tests on the quarantine list, Tests/quarantine.json, run on their own
# after the rest, and their failure is reported, not counted; nothing runs
# again (docs/testing.md "Quarantine"). A filter runs exactly the tests it
# matches, quarantined or not, and counts every one.
#
# Usage: scripts/test.sh [<filter>]
#   <filter> runs only the tests matching it, as swift test --filter takes it
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -n "${1:-}" ]; then
	swift test --filter "$1"
else
	quarantined="$(scripts/quarantine.sh tests)"
	if [ -z "$quarantined" ]; then
		swift test
	else
		swift test --skip "$quarantined"
		swift test --filter "$quarantined" || scripts/quarantine.sh report tests
	fi
fi
swift build --product Athina
scripts/check-no-control-api.sh "$(swift build --show-bin-path)/Athina"
