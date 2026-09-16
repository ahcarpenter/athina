# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/mentor-e2e, which sources this file.
# shellcheck disable=SC2034
# The surfaces that show the standing understanding. The mentor call that
# raises the first suggestion also writes the first understanding, so this
# follows that record out to the menu, the debug panel's card, and Settings >
# Models, and then through Reset Understanding, which asks before it forgets
# every revision.
#
# It needs no pointer: the menu is opened through accessibility and every
# button is pressed by name.
SCENARIO_SUMMARY="the understanding a mentor call writes reaches the menu, the card, and Settings, and Reset Understanding asks first"
SCENARIO_ARGS=(--open debug)

# The goal the model wrote, strongest first, as the surfaces show it.
understanding_goal() {
	sqlite3 -readonly "$JOURNAL" \
		"select json_extract(content_json, '\$.goals[0].goal') from understanding order by updated_at desc, id desc limit 1" 2>/dev/null || echo ""
}

reset_events() {
	sqlite3 -readonly "$JOURNAL" \
		"select count(*) from events where kind = 'understanding' and detail like 'reset%'" 2>/dev/null || echo 0
}

# The mentor call carries the understanding in its reply, so the record lands
# just after the suggestion it came with.
wait_understanding() {
	local limit="${1:-30}" i
	for i in $(seq 1 "$limit"); do
		[ "$(journal_count understanding)" -ge 1 ] && return 0
		sleep 1
	done
	return 1
}

menu_items() {
	local tag="$1"
	"$DRIVE" ax "$MENTOR_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 0.8
	"$DRIVE" ax "$MENTOR_PID" menuitems >"$RUN_DIR/$tag-menu-items.txt" 2>&1 || true
	snapshot_state "$tag"
	"$DRIVE" ax "$MENTOR_PID" cancelmenu >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.4
}

# The window's text as VoiceOver reads it, which is also where a label that is
# only a description rather than a title still shows up.
window_texts() {
	local scope="$1" tag="$2"
	"$DRIVE" ax "$MENTOR_PID" texts --scope "$scope" >"$RUN_DIR/$tag-texts.txt" 2>&1 || true
	local id
	id="$("$DRIVE" windows "$MENTOR_PID" | awk -v want="$scope" 'index($0, "name=\"" want) {sub("id=", "", $1); print $1; exit}')"
	[ -n "$id" ] && "$DRIVE" shot window "$id" "$RUN_DIR/$tag.png" >/dev/null 2>&1
	return 0
}

has_text() {
	grep -qF "$2" "$RUN_DIR/$1" && echo yes || echo no
}

scenario_run() {
	local goal head
	stage_flip_window
	wait_toast >/dev/null || return 1
	wait_understanding || { log "no understanding was written"; return 1; }
	goal="$(understanding_goal)"
	# Every goal check below compares against this text, and an empty one would
	# match any file, so a record with no goal to follow stops the scenario.
	[ -n "$goal" ] || { log "the understanding names no goal to follow"; return 1; }
	log "the understanding names \"$goal\""
	check "the mentor call wrote an understanding" "1" "$(journal_count understanding)"

	# The menu shows the goal, clipped to fit a menu item, so only its start
	# can be compared with the record.
	head="$(printf '%s' "$goal" | cut -c1-40)"
	menu_items "menu-with-goal"
	check "the menu shows the goal it worked out" "yes" "$(has_text menu-with-goal-menu-items.txt "title=\"Goal: $head")"

	# The card sits under the Mentor loop card in the Now pane, so the pane is
	# scrolled to the end before the shot; AXScrollToVisible does nothing here.
	"$DRIVE" ax "$MENTOR_PID" set AXScrollBar "" 1 --scope "Debug Panel" >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5
	window_texts "Debug Panel" "card"
	check "the card shows the goal" "yes" "$(has_text card-texts.txt "$goal")"
	check "the card names the refresh interval" "yes" "$(has_text card-texts.txt "of active use")"
	check "the card offers Reset Understanding" "yes" "$(has_text card-texts.txt "Reset Understanding…")"

	# Settings opens on the pane it last showed, and accessibility offers no
	# way to change panes, so the pane is chosen before the window opens. The
	# harness puts the owner's preferences back whatever happens.
	defaults write "$PREFS_DOMAIN" SettingsPane models >>"$RUN_DIR/transcript.log" 2>&1 || true
	"$DRIVE" ax "$MENTOR_PID" pressx AXMenuItem "Settings…" --scope extras >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 2
	window_texts "Models" "settings"
	check "Settings shows the current goal" "yes" "$(has_text settings-texts.txt "$goal")"
	"$DRIVE" close "$MENTOR_PID" Models >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5

	# Asking first, and Cancel keeping every revision.
	"$DRIVE" ax "$MENTOR_PID" pressx AXButton "Reset Understanding…" --scope "Debug Panel" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 1.5
	window_texts "Debug Panel" "confirmation"
	check "the confirmation asks before resetting" "yes" "$(has_text confirmation-texts.txt "Reset the understanding?")"
	check "the confirmation says it cannot be undone" "yes" "$(has_text confirmation-texts.txt "You can't undo this action.")"
	check "the confirmation offers Cancel" "yes" "$(has_text confirmation-texts.txt "Cancel")"
	"$DRIVE" ax "$MENTOR_PID" pressx AXButton "Cancel" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 1
	check "Cancel keeps the understanding" "1" "$(journal_count understanding)"
	check "Cancel journals no reset" "0" "$(reset_events)"

	"$DRIVE" ax "$MENTOR_PID" pressx AXButton "Reset Understanding…" --scope "Debug Panel" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 1.5
	"$DRIVE" ax "$MENTOR_PID" pressx AXButton "Reset Understanding" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 2
	check "Reset Understanding forgets every revision" "0" "$(journal_count understanding)"
	check "the reset is journaled" "1" "$(reset_events)"
	window_texts "Debug Panel" "card-after-reset"
	check "the card says there is no understanding yet" "yes" "$(has_text card-after-reset-texts.txt "No understanding yet.")"

	menu_items "menu-after-reset"
	check "the menu says the goal is not worked out yet" "yes" \
		"$(has_text menu-after-reset-menu-items.txt 'title="Goal: not worked out yet"')"
	return 0
}
