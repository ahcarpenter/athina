# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The keyboard and VoiceOver route: pressing the menu bar item through
# accessibility, with no pointer anywhere near it, must open the menu and keep
# the suggestion up, and Not Now must be recorded.
#
# It needs no idle input and no pointer, so it is the scenario that still runs
# while someone is using the Mac.
SCENARIO_SUMMARY="pressing the menu bar item through accessibility keeps the toast, and Not Now is recorded"

scenario_run() {
	local suggestion
	stage_flip_window
	wait_toast >/dev/null || return 1
	# No idle wait here, but a click by whoever is at the Mac still dismisses
	# the toast, so it is checked, and brought back if it went, right before.
	keep_toast_up || return 1
	suggestion="$(newest_suggestion_id)"
	snapshot_state "before"

	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 0.8
	snapshot_state "after-axpress"
	check "toast still up after the accessibility press" "up" "$([ -n "$(toast_window)" ] && echo up || echo gone)"
	check "suggestion not answered by the press" "none" "$(suggestion_feedback "$suggestion")"

	"$DRIVE" ax "$ATHINA_PID" pressx AXMenuItem "Not Now" --scope extras >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 1
	snapshot_state "after-not-now"
	check "feedback recorded" "notNow" "$(suggestion_feedback "$suggestion")"
	check "toast gone after Not Now" "gone" "$([ -n "$(toast_window)" ] && echo up || echo gone)"
	return 0
}
