#!/usr/bin/env bash
# `make check`, the one command to run before a push: `make lint`, `make test`
# and `make snapshots`, in that order, stopping at the first that fails, which
# is what local validation runs (docs/ci.md). Each prints its own summary line;
# this ends with one for the three.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
for step in lint test snapshots; do
	if ! make --no-print-directory "$step"; then
		echo "check: failed at make $step; its line above says what to do, then make check again" >&2
		exit 1
	fi
done
echo "check: passed, lint, test and snapshots"
