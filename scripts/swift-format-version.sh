#!/usr/bin/env bash
# Warns when the selected Xcode is not the one CI lints with, <version>, whose
# swift-format may format differently (README "Code style"). Never fails: the
# lint or format that follows still runs.
#
# Usage: scripts/swift-format-version.sh <version>
set -uo pipefail

want="${1:?usage: scripts/swift-format-version.sh <version>}"
xcode="$(xcodebuild -version 2>/dev/null | head -n1)"
if [ "$xcode" != "Xcode $want" ]; then
	echo "warning: CI lints with the swift-format in Xcode $want, but this runs the one in ${xcode:-no selected Xcode} (swift-format $(xcrun swift-format --version 2>/dev/null)), which may format differently; see README, \"Code style\"" >&2
fi
