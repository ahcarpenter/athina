# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/mentor-e2e, which sources this file.
# shellcheck disable=SC2034
# A real click on empty menu bar space, beside Mentor's item, must dismiss the
# suggestion. It is the control case for the item click: the same global
# monitor sees both, and only the location tells them apart.
SCENARIO_SUMMARY="a real click on empty menu bar space dismisses the suggestion"

scenario_run() {
	local suggestion empty x y
	stage_flip_window
	wait_toast >/dev/null || return 1
	suggestion="$(newest_suggestion_id)"

	empty="$("$DRIVE" bar | sed -n 's/^empty=//p')"
	[ -n "$empty" ] && [ "$empty" != none ] || { log "no empty menu bar space to click"; return 1; }
	x="${empty%%,*}"
	y="${empty##*,}"
	log "empty menu bar space at $x,$y"

	wait_idle_input 15 || return 1
	require_toast || return 1
	snapshot_state "before"

	"$DRIVE" click at "$x" "$y" --shot "$RUN_DIR/bar-at-click.png" >>"$RUN_DIR/transcript.log" 2>&1 || {
		log "the click was refused or the pointer moved; see transcript.log"
		return 1
	}
	sleep 0.6
	snapshot_state "after"

	check "toast gone after the empty-bar click" "gone" "$([ -n "$(toast_window)" ] && echo up || echo gone)"
	check "feedback recorded" "dismissed" "$(suggestion_feedback "$suggestion")"
	# The session tap is what ties the dismissal to a real click rather than a
	# timeout: the toast timeout is ten minutes in these settings.
	check "a real mouse-down was seen" "yes" "$(grep -qc 'type=1' "$RUN_DIR/session-clicks.log" >/dev/null 2>&1 && echo yes || echo no)"
	return 0
}
