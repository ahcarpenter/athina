#!/usr/bin/env bash
# `make test`, which CI's build-and-test runs as it stands: swift test, the
# replayed loop and the fixture freshness check included, then the check that
# a build without the ControlAPI trait carries no control API (docs/e2e.md "The
# control API"). The debug Athina the tests' build already made is such a
# build, so it checks that one rather than compiling the package again; `swift
# build` only confirms it is current. Ends in one summary line; the whole
# output is in build/logs (scripts/quietly.sh).
#
# The tests on the quarantine list, Tests/quarantine.json, run on their own
# after the rest, and their failure is reported, not counted; nothing runs
# again (docs/testing.md "Quarantine"). A filter runs exactly the tests it
# matches, quarantined or not, and counts every one.
#
# Usage: scripts/test.sh [<filter>]
#   <filter> runs only the tests matching it, as swift test --filter takes it
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
# Swift Testing ends each test binary's run with "Test run with <n> tests in
# <m> suites passed after ..." or "... failed after ... with <k> issues", and
# swift test runs several binaries, so the counts are summed.
runs() { grep -E 'Test run with [0-9]+ tests? ' "build/logs/$1.log" 2>/dev/null; }
tests() { runs "$1" | sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/' | awk '{ n += $1 } END { print n + 0 }'; }
issues() { runs "$1" | grep ' failed after ' | sed -nE 's/.* with ([0-9]+) issues?.*/\1/p' | awk '{ n += $1 } END { print n + 0 }'; }

quarantined=""
if [ -n "${1:-}" ]; then
	scripts/quietly.sh test swift test --filter "$1"
else
	quarantined="$(scripts/quarantine.sh tests)" || exit 2
	scripts/quietly.sh test swift test ${quarantined:+--skip "$quarantined"}
fi
status=$?
if [ "$status" -ne 0 ]; then
	if [ -n "$(runs test)" ]; then
		echo "test: failed, $(issues test) issues in $(tests test) tests; rerun one with make test FILTER=<name>, log build/logs/test.log" >&2
	else
		echo "test: failed before any test ran; log build/logs/test.log, and make doctor names a missing tool" >&2
	fi
	exit 1
fi
count="$(tests test)"
aside=""
if [ -n "$quarantined" ]; then
	if scripts/quietly.sh test-quarantined swift test --filter "$quarantined"; then
		aside=", and the $(tests test-quarantined) quarantined passed"
	else
		scripts/quarantine.sh report tests
		aside=", and the $(tests test-quarantined) quarantined failed, not counted (log build/logs/test-quarantined.log)"
	fi
fi
if ! scripts/quietly.sh test-build swift build --product Athina; then
	echo "test: failed, swift build --product Athina did not build; log build/logs/test-build.log" >&2
	exit 1
fi
if ! scripts/check-no-control-api.sh "$(swift build --show-bin-path)/Athina" >/dev/null; then
	echo "test: failed, a build without the ControlAPI trait carries the control API" >&2
	exit 1
fi
echo "test: passed, ${count:-0} tests${aside} and no control API in a build without the trait; log build/logs/test.log"
