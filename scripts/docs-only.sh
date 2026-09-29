#!/usr/bin/env bash
# Prints true when a change touches only documentation that nothing builds,
# tests or runs, and false otherwise, which CI's changes job asks of every pull
# request to skip test, test-e2e, snapshots-smoke and the snapshots shards on
# one that cannot change a test result or a pixel
# (docs/ci.md "Docs-only pull requests").
#
# Documentation is a Markdown file at the top of the repository or anything
# under docs/, except what a test, script or build step reads, which counts as
# code:
#   README.md            MarkAssetTests checks the icon at its top
#   docs/release-notes/  scripts/release.sh puts it in the release's notes
# and a Markdown file anywhere else (Sources, Tests, Resources, scripts,
# .github) is code too, such as the replay fixtures' README the test bundle
# copies. A change with no files, or one that cannot be read, is not docs-only,
# so when in doubt everything runs. DocsOnlyTests checks these rules.
#
# Usage: scripts/docs-only.sh <base> <head>   the change from <base> to <head>
#        scripts/docs-only.sh -                the paths on standard input, one a line
# Exit: 0 with true or false printed, 2 the change could not be read.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

is_docs() {
	case "$1" in
	README.md | docs/release-notes/*) return 1 ;;
	docs/*) return 0 ;;
	*/*) return 1 ;;
	*.md) return 0 ;;
	*) return 1 ;;
	esac
}

if [ "$#" -eq 1 ] && [ "$1" = - ]; then
	paths="$(cat)"
elif [ "$#" -eq 2 ]; then
	# Both sides of a rename, so moving code under docs/ is a change to code.
	paths="$(git -c core.quotePath=false diff --name-only --no-renames "$1" "$2")" || {
		echo "docs-only: could not read the change from $1 to $2" >&2
		exit 2
	}
else
	echo "usage: scripts/docs-only.sh <base> <head> | -" >&2
	exit 2
fi

if [ -z "$paths" ]; then
	echo false
	exit 0
fi
while IFS= read -r path; do
	if ! is_docs "$path"; then
		echo false
		exit 0
	fi
done <<<"$paths"
echo true
