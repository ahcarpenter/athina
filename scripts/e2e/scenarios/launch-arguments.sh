# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# --open opens its window whatever comes before it on the command line. AppKit
# pairs each argument that starts with a dash with the one after it, so a flag
# that takes no value, such as --allow-stale-fixtures, used to pair with
# --open and leave the pane's name over as a document to open, and an app
# asked to open a document at launch opens none of its windows.
SCENARIO_SUMMARY="--open opens Settings on its pane with a flag that takes no value before it"
SCENARIO_ARGS=(--allow-stale-fixtures --open settings:advanced)
SCENARIO_TIER=api

scenario_run() {
	check "Settings opens on the Advanced pane" "yes" \
		"$(api wait-window window=Advanced timeout=20 >/dev/null && echo yes || echo no)"
	return 0
}
