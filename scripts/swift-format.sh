#!/usr/bin/env bash
# `make format`, and the Swift style half of `make lint` (scripts/lint.sh):
# swift-format over every Swift file in the checkout, tracked or new, that git
# does not ignore, with the .swift-format configuration (docs/code-style.md).
# `lint` changes nothing and fails on any finding, as CI's lint job does;
# `format` rewrites the files in place. Either first warns when the selected
# Xcode is not the one CI lints with, and ends in one summary line.
#
# Usage: scripts/swift-format.sh lint|format
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
mode="${1:-}"
case "$mode" in
lint | format) ;;
*) echo "usage: scripts/swift-format.sh lint|format" >&2; exit 2 ;;
esac
scripts/swift-format-version.sh "$(cat .xcode-version)"

files() { git ls-files -z --cached --others --exclude-standard '*.swift'; }
total="$(files | tr -cd '\0' | wc -c | tr -d ' ')"

if [ "$mode" = lint ]; then
	findings="$(files | xargs -0 xcrun swift-format lint --strict --parallel 2>&1)"
	status=$?
	if [ "$status" -eq 0 ]; then
		echo "lint: passed, $total files"
		exit 0
	fi
	printf '%s\n' "$findings" >&2
	count="$(printf '%s\n' "$findings" | grep -cE '^[^:]+:[0-9]+:[0-9]+: ')"
	in="$(printf '%s\n' "$findings" | grep -E '^[^:]+:[0-9]+:[0-9]+: ' | cut -d: -f1 | sort -u | wc -l | tr -d ' ')"
	echo "lint: failed, $count findings in $in of $total files; make format fixes most" >&2
	exit 1
fi

before="$(files | xargs -0 shasum)"
files | xargs -0 xcrun swift-format format --in-place --parallel || { echo "format: failed; see swift-format's output above" >&2; exit 1; }
changed="$(diff <(printf '%s\n' "$before") <(files | xargs -0 shasum) | grep -c '^>')"
echo "format: $changed of $total files changed; git diff shows them"
