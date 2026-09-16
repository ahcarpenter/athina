# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/mentor-e2e, which sources this file.
# shellcheck disable=SC2034
# Mentor's item must be the same width in every sensing mode. Status items are
# anchored at the right of the bar, so an item that changed width with its mode
# moved every extra to its left each time someone switched into an excluded app
# (HIG: Motion, "generally avoid adding motion to UI interactions that occur
# frequently"; Layout, consistent spacing; SF Symbols, a set stays aligned).
SCENARIO_SUMMARY="the menu bar item keeps one width when an excluded app comes forward, so no extra moves"

scenario_stage() {
	stage_text_document || return 1
	stage_excluded_app || return 1
	# The watched app goes in front before Mentor starts: the terminal a run is
	# started from is excluded, so sensing would capture nothing and the run
	# would spend its first ninety seconds waiting for an observation.
	"$DRIVE" activate "$TEXTEDIT_PID" >>"$RUN_DIR/transcript.log" 2>&1
}

# Brings one app forward, waits for the item's name to catch up with the mode,
# and prints the item's width.
#
# The Mac is shared: bringing an app forward under someone's hands would land
# their keystrokes in it, so every activation waits for a quiet keyboard and
# mouse first, the way the click scenarios do.
measure_bar() {
	local tag="$1" pid="$2" want="$3" width x
	wait_idle_input 15 || return 1
	"$DRIVE" activate "$pid" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	wait_item_title "$want" || {
		log "the item never said \"$want\" (it says \"$(mentor_item_title)\")"
		return 1
	}
	wake_input
	{
		printf '=== bar %s at %s: item "%s"\n' "$tag" "$(date '+%H:%M:%S')" "$(mentor_item_title)"
		"$DRIVE" bar "$MENTOR_PID"
	} >>"$RUN_DIR/transcript.log" 2>&1
	x="$(mentor_extra | sed -n 's/.* x=\([0-9]*\)[0-9.]* .*/\1/p')"
	[ -n "$x" ] && "$DRIVE" shot region "$((x - 160))" 0 420 33 "$RUN_DIR/bar-$tag.png" \
		>>"$RUN_DIR/transcript.log" 2>&1
	width="$(mentor_item_width)"
	[ -n "$width" ] || {
		log "the bar report had no width for Mentor's item at the $tag measurement"
		return 1
	}
	printf '%s\n' "$width"
}

scenario_run() {
	local watching excluded again
	watching="$(measure_bar watching "$TEXTEDIT_PID" "Watching TextEdit")" || return 1
	check "the item names the app it watches" "Watching TextEdit" "$(mentor_item_mode)"

	excluded="$(measure_bar excluded "$EXCLUDED_PID" "Not watching Calculator")" || return 1
	again="$(measure_bar watching-again "$TEXTEDIT_PID" "Watching TextEdit")" || return 1

	# The width, never the neighbours' positions: in a right-anchored bar the
	# clock ticking past the hour moves those exactly as Mentor widening would.
	check "the item is the same width in the excluded mode" "$watching" "$excluded"
	check "the item is the same width back in the watching mode" "$watching" "$again"
	log "item $watching pt watching, $excluded pt excluded, $again pt watching again"
	return 0
}
