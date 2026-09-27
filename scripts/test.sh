#!/usr/bin/env bash
# `make test`, which CI's build-and-test runs as it stands: swift test, the
# replayed loop and the fixture freshness check included, then the check that
# a build without the ControlAPI trait carries no control API (docs/e2e.md "The
# control API"). The debug Athina the tests' build already made is such a
# build, so it checks that one rather than compiling the package again; `swift
# build` only confirms it is current.
#
# Usage: scripts/test.sh [<filter>]
#   <filter> runs only the tests matching it, as swift test --filter takes it
set -euo pipefail

cd "$(dirname "$0")/.."
swift test ${1:+--filter "$1"}
swift build --product Athina
scripts/check-no-control-api.sh "$(swift build --show-bin-path)/Athina"
