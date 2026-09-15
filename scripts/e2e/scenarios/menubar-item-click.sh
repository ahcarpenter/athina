# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/mentor-e2e, which sources this file.
# shellcheck disable=SC2034
# A real pointer click on Mentor's menu bar item must open the menu and leave
# the suggestion up: the item is the one place a click is not a dismissal.
# Then Answer Suggestion > Tell Me More, with the pointer, must be recorded.
SCENARIO_SUMMARY="a real click on Mentor's menu bar item keeps the toast, and Tell Me More is recorded"

scenario_run() {
	local suggestion before_feedback after_feedback
	stage_flip_window
	wait_toast >/dev/null || return 1
	suggestion="$(newest_suggestion_id)"
	wait_idle_input 15 || return 1
	require_toast || return 1
	snapshot_state "before"

	"$DRIVE" click item "$MENTOR_PID" --shot "$RUN_DIR/bar-at-click.png" >>"$RUN_DIR/transcript.log" 2>&1 || {
		log "the click was refused or the pointer moved; see transcript.log"
		return 1
	}
	sleep 0.4
	snapshot_state "after-item-click"

	before_feedback="$(suggestion_feedback "$suggestion")"
	check "toast still up after the item click" "up" "$([ -n "$(toast_window)" ] && echo up || echo gone)"
	check "suggestion not answered by the click" "none" "$before_feedback"

	"$DRIVE" menupick "$MENTOR_PID" "Answer Suggestion" "Tell Me More" >>"$RUN_DIR/transcript.log" 2>&1 || {
		log "could not reach Tell Me More; see transcript.log"
		return 1
	}
	sleep 1.2
	snapshot_state "after-tell-me-more"
	after_feedback="$(suggestion_feedback "$suggestion")"
	check "feedback recorded" "tellMeMore" "$after_feedback"
	check "the toast was announced" "yes" "$(grep -qc 'Mentor suggestion' "$RUN_DIR/announcements.log" >/dev/null 2>&1 && echo yes || echo no)"
	return 0
}
