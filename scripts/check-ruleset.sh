#!/usr/bin/env bash
# Fails when the checks GitHub requires on main differ from those
# .github/rulesets/main.json requires, which CI's lint job runs on every push.
#
# GitHub never reads that file: docs/ci.md applies it by
# hand, so the two can drift apart unseen, as they once did for a day in which
# lint was not required. This reads the rules GitHub applies to main from the
# repository's public rules/branches/main endpoint, which needs no admin
# rights, and compares only the required status checks, each as its context
# and integration, in any order. That answer merges the rules of every active
# ruleset that applies to main, so the checks of every required_status_checks
# rule in it count, and any other rule or parameter, which a second ruleset or
# GitHub itself may add, does not; a ruleset that is not active has no rules in
# it, so requires no checks.
# RulesetCheckTests runs this on answers that match and on answers that drift.
#
# Usage: scripts/check-ruleset.sh [<answer.json>]
#   <answer.json>  compare with this saved answer of the endpoint instead of
#                  asking GitHub
# Exit: 0 they match, 1 they differ, 2 the rules could not be read.
set -euo pipefail

cd "$(dirname "$0")/.."

RULESET=".github/rulesets/main.json"
# The required checks of a list of rules, each as its context and integration,
# without repeats and sorted, so only a difference in what is required tells.
CHECKS='map(select(.type == "required_status_checks")
    | .parameters.required_status_checks[]
    | {context, integration_id})
  | unique_by([.context, .integration_id])
  | sort_by(.context, .integration_id)'
# A check as one line, for naming it.
NAME='"\(.context) (integration \(.integration_id // "any"))"'

if [ "$#" -gt 1 ]; then
	echo "usage: scripts/check-ruleset.sh [<answer.json>]" >&2
	exit 2
fi
if [ "$#" -eq 1 ]; then
	live_json="$(cat "$1")" || exit 2
else
	repository="${GITHUB_REPOSITORY:-getathina/athina}"
	live_json="$(gh api "repos/$repository/rules/branches/main")" || {
		echo "check-ruleset: could not read the rules GitHub enforces on main" >&2
		exit 2
	}
fi

committed="$(jq -c "(.rules) | $CHECKS" "$RULESET")" || exit 2
live="$(jq -c "if type == \"array\" then $CHECKS else error end" <<<"$live_json" 2>/dev/null)" || {
	echo "check-ruleset: GitHub's answer is not a list of rules" >&2
	exit 2
}

if [ "$committed" = "$live" ]; then
	echo "the checks GitHub requires on main match $RULESET"
	exit 0
fi
{
	echo "check-ruleset: the checks GitHub requires on main differ from $RULESET"
	jq -rn --argjson file "$committed" --argjson github "$live" "
		((\$file - \$github)[] | \"  required by the file, not by GitHub: \" + $NAME),
		((\$github - \$file)[] | \"  required by GitHub, not by the file: \" + $NAME)"
	echo
	echo "Apply the file with the command in docs/ci.md (it needs"
	echo "admin rights on the repository), then run this job again. A pull request that"
	echo "changes $RULESET fails here until its ruleset is applied."
} >&2
exit 1
