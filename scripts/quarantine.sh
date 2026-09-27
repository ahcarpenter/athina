#!/usr/bin/env bash
# The quarantine list, Tests/quarantine.json: the flaky tests and end-to-end
# scenarios that still run everywhere, but whose failures are reported rather
# than counted, each with an owner and the issue that tracks its fix
# (docs/testing.md "Quarantine"). Nothing is ever run again to get a pass.
# scripts/test.sh and the end-to-end harness read the list through this
# script, and QuarantineTests runs it on lists good and bad.
#
# Usage: scripts/quarantine.sh [--list <file>] <command>
#   check              fail naming every entry that is not well formed
#   tests              one pattern, as swift test --filter and --skip take it,
#                      matching every quarantined test; nothing when none is
#   scenario <name>    succeed when the end-to-end scenario is quarantined
#   report tests       report the quarantined tests' run as failed
#   report <name>      report the quarantined scenario's run as failed
# Exit: 0 done (or quarantined), 1 not (or a bad entry), 2 misuse.
set -euo pipefail

LIST="$(cd "$(dirname "$0")/.." && pwd)/Tests/quarantine.json"
if [ "${1:-}" = --list ]; then
	[ "$#" -ge 2 ] || { echo "usage: scripts/quarantine.sh [--list <file>] <command>" >&2; exit 2; }
	LIST="$2"
	shift 2
fi

# Each entry that is not well formed, as its index and what is wrong with it:
# exactly one of test (a swift test pattern) and scenario (an athina-e2e
# scenario's name), an owner, and the issue as its GitHub URL.
# shellcheck disable=SC2016 # jq's variables, not the shell's
PROBLEMS='if type != "array" then "the list is not a JSON array" else
  to_entries[] | .key as $at | .value
  | if type != "object" then "entry \($at) is not an object" else
      ([.test, .scenario] | map(select(type == "string" and . != "")) | length) as $names
      | (if $names != 1 then "entry \($at) names \($names) of test and scenario, not exactly one" else empty end),
        (if (.owner | type) != "string" or .owner == "" then "entry \($at) has no owner" else empty end),
        (if (.issue | type) != "string" or (.issue | test("^https://github\\.com/[^/]+/[^/]+/issues/[0-9]+$") | not)
         then "entry \($at) has no issue URL" else empty end),
        ((keys - ["test", "scenario", "owner", "issue", "reason"])[] | "entry \($at) has an unknown key, \(.)")
    end
end'

check() {
	local problems line
	problems="$(jq -r "$PROBLEMS" "$LIST")" || { echo "quarantine: $LIST is not JSON" >&2; return 1; }
	[ -z "$problems" ] && return 0
	while IFS= read -r line; do echo "quarantine: $LIST: $line" >&2; done <<<"$problems"
	return 1
}

# One report line, and a warning annotation on a GitHub Actions run, where it
# shows on the run's summary.
report() {
	echo "quarantine: $1" >&2
	if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::warning title=Quarantined failure::$1" >&2; fi
}

case "${1:-}" in
check)
	check
	;;
tests)
	check
	jq -r '[.[] | select(.test) | "(\(.test))"] | join("|")' "$LIST"
	;;
scenario)
	[ "$#" -eq 2 ] || { echo "usage: scripts/quarantine.sh scenario <name>" >&2; exit 2; }
	check
	jq -e --arg name "$2" 'any(.[]; .scenario == $name)' "$LIST" >/dev/null
	;;
report)
	[ "$#" -eq 2 ] || { echo "usage: scripts/quarantine.sh report <tests|name>" >&2; exit 2; }
	check
	if [ "$2" = tests ]; then
		while IFS= read -r line; do report "$line"; done < <(jq -r '.[] | select(.test)
			| "the quarantined tests failed, not counted; one of them may be \(.test) (owner \(.owner), \(.issue))"' "$LIST")
	else
		while IFS= read -r line; do report "$line"; done < <(jq -r --arg name "$2" '.[] | select(.scenario == $name)
			| "the quarantined scenario \(.scenario) failed; not counted (owner \(.owner), \(.issue))"' "$LIST")
	fi
	;;
*)
	sed -n '9,16p' "$0" >&2
	exit 2
	;;
esac
