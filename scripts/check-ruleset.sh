#!/usr/bin/env bash
# Fails when the rules GitHub enforces on main differ from
# .github/rulesets/main.json, which CI's lint job runs on every push.
#
# GitHub never reads that file: README "Continuous integration" applies it by
# hand, so the two can drift apart unseen, as they once did for a day in which
# lint was not required. This reads the rules GitHub applies to main from the
# repository's public rules/branches/main endpoint, which needs no admin
# rights, and compares each rule's type and parameters with the file's, the
# required checks in any order; the ruleset's name, target and conditions are
# not in that answer, and a ruleset that is not active has no rules in it.
# RulesetCheckTests runs this on answers that match and on answers that drift.
#
# Usage: scripts/check-ruleset.sh [<answer.json>]
#   <answer.json>  compare with this saved answer of the endpoint instead of
#                  asking GitHub
# Exit: 0 they match, 1 they differ, 2 the rules could not be read.
set -euo pipefail

cd "$(dirname "$0")/.."

RULESET=".github/rulesets/main.json"
# Each rule as its type and parameters, with the required checks and the rules
# sorted, so only a difference in what is enforced tells.
NORMALIZE='map({type, parameters})
  | map(if .parameters.required_status_checks
    then .parameters.required_status_checks |= sort_by(.context) else . end)
  | sort_by(.type)'

if [ "$#" -gt 1 ]; then
	echo "usage: scripts/check-ruleset.sh [<answer.json>]" >&2
	exit 2
fi
if [ "$#" -eq 1 ]; then
	live_json="$(cat "$1")" || exit 2
else
	repository="${GITHUB_REPOSITORY:-ahcarpenter/athina}"
	live_json="$(gh api "repos/$repository/rules/branches/main")" || {
		echo "check-ruleset: could not read the rules GitHub enforces on main" >&2
		exit 2
	}
fi

committed="$(jq -S "(.rules) | $NORMALIZE" "$RULESET")" || exit 2
live="$(jq -S "$NORMALIZE" <<<"$live_json")" || {
	echo "check-ruleset: GitHub's answer is not a list of rules" >&2
	exit 2
}

if [ "$committed" = "$live" ]; then
	echo "the rules GitHub enforces on main match $RULESET"
	exit 0
fi
{
	echo "check-ruleset: the rules GitHub enforces on main differ from $RULESET"
	echo "(- the file, + GitHub):"
	diff -u --label "$RULESET" --label "GitHub" <(echo "$committed") <(echo "$live") || true
	echo
	echo "Apply the file with the command in README \"Continuous integration\" (it needs"
	echo "admin rights on the repository), then run this job again. A pull request that"
	echo "changes $RULESET fails here until its ruleset is applied."
} >&2
exit 1
