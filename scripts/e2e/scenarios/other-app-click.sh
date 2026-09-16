# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/mentor-e2e, which sources this file.
# shellcheck disable=SC2034
# A real click inside another app's window must dismiss the suggestion: the
# person went back to their work, so the toast gets out of the way.
SCENARIO_SUMMARY="a real click in another app's window dismisses the suggestion"

scenario_run() {
	local suggestion frame x y
	stage_flip_window
	wait_toast >/dev/null || return 1
	suggestion="$(newest_suggestion_id)"

	frame="$("$DRIVE" windows "$TEXTEDIT_PID" | awk '/layer=0/ {print; exit}')"
	[ -n "$frame" ] || { log "TextEdit has no window on screen"; return 1; }
	x=$(( $(sed -n 's/.* x=\([0-9-]*\) .*/\1/p' <<<"$frame") + 120 ))
	y=$(( $(sed -n 's/.* y=\([0-9-]*\) .*/\1/p' <<<"$frame") + 120 ))
	log "clicking inside TextEdit at $x,$y"

	wait_idle_input 15 || return 1
	require_toast || return 1
	snapshot_state "before"

	"$DRIVE" click window "$TEXTEDIT_PID" "$x" "$y" --shot "$RUN_DIR/window-at-click.png" >>"$RUN_DIR/transcript.log" 2>&1 || {
		log "the click was refused or the pointer moved; see transcript.log"
		return 1
	}
	sleep 0.6
	snapshot_state "after"

	check "toast gone after the other-app click" "gone" "$([ -n "$(toast_window)" ] && echo up || echo gone)"
	check "feedback recorded" "dismissed" "$(suggestion_feedback "$suggestion")"
	return 0
}
