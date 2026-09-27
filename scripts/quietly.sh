#!/usr/bin/env bash
# Runs a noisy command, such as swift build or swift test, keeping its whole
# output in build/logs/<name>.log and showing none of it, so a make target ends
# in the one summary line its script prints rather than in pages of compiler
# output a person or an agent has to read through. On a failure it shows the
# lines that say what failed (or the last lines, when none says) and where the
# whole log is.
#
# VERBOSE=1 shows the output as it comes as well, and so does CI (GitHub
# Actions sets CI=true), whose job log is the only place a run's output is kept.
#
# Usage: scripts/quietly.sh <name> <command> [<argument> ...]
# Exit: the command's own.
set -uo pipefail

[ "$#" -ge 2 ] || { echo "usage: scripts/quietly.sh <name> <command> [<argument> ...]" >&2; exit 2; }
name="$1"
shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
log="$ROOT/build/logs/$name.log"
mkdir -p "$(dirname "$log")"

if [ -n "${VERBOSE:-}" ] || [ -n "${CI:-}" ]; then
	"$@" 2>&1 | tee "$log"
	status="${PIPESTATUS[0]}"
else
	"$@" >"$log" 2>&1
	status=$?
fi

if [ "$status" -ne 0 ] && [ -z "${VERBOSE:-}" ] && [ -z "${CI:-}" ]; then
	# What swift build, swift test (XCTest and Swift Testing) and the scripts
	# here say when something fails, each line once and in order.
	said="$(grep -E 'error:|✘|failed|Fatal error|FAIL|missing:' "$log" | awk '!seen[$0]++' | head -n 40)"
	if [ -n "$said" ]; then
		printf '%s\n' "$said" >&2
	else
		tail -n 20 "$log" >&2
	fi
	echo "whole log: build/logs/$name.log" >&2
fi
exit "$status"
