# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The surfaces that show the standing understanding. The mentor call that
# raises the first suggestion also writes the first understanding, so this
# follows that record out to the menu, the debug panel's card, and Settings >
# Models, and then through Reset Understanding, which asks before it forgets
# every revision.
#
# Every button is pressed by name through accessibility; only the footer's
# link, which accessibility offers no press for, needs the real pointer.
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
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 0.8
	"$DRIVE" ax "$ATHINA_PID" menuitems >"$RUN_DIR/$tag-menu-items.txt" 2>&1 || true
	snapshot_state "$tag"
	"$DRIVE" ax "$ATHINA_PID" cancelmenu >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.4
}

# The id of the first window whose name starts with $1, empty when none is open.
window_id() {
	"$DRIVE" windows "$ATHINA_PID" \
		| awk -v want="$1" 'index($0, "name=\"" want) {sub("id=", "", $1); print $1; exit}' || echo ""
}

wait_window() {
	local want="$1" limit="${2:-10}" i
	for i in $(seq 1 "$limit"); do
		[ -n "$(window_id "$want")" ] && return 0
		sleep 0.5
	done
	return 1
}

# The window's text as VoiceOver reads it, which is also where a label that is
# only a description rather than a title still shows up.
window_texts() {
	local scope="$1" tag="$2" id
	"$DRIVE" ax "$ATHINA_PID" texts --scope "$scope" >"$RUN_DIR/$tag-texts.txt" 2>&1 || true
	id="$(window_id "$scope")"
	[ -n "$id" ] && "$DRIVE" shot window "$id" "$RUN_DIR/$tag.png" >/dev/null 2>&1
	return 0
}

# The x a duration row's amount field starts at, read from the live
# accessibility geometry of a window. Two duration rows in one section are in
# line only when their fields start at the same x, whatever unit word each
# row's pop-up happens to be showing. The field is named "<row title>, in
# <unit>", which is how each row's field is told from the other's.
row_field_x() {
	awk -v want="desc=\"$2, in " '
		$1 == "AXTextField" && index($0, want) && match($0, /pos=\([-0-9]+,/) {
			print substr($0, RSTART + 5, RLENGTH - 6)
			exit
		}
	' "$RUN_DIR/$1"
}

# The screen point at the centre of an element, from a dump: "<x> <y>", empty
# when the dump holds no such element. This is what a pointer step aims at.
element_centre() {
	awk -v role="$2" -v want="desc=\"$3\"" '
		$1 == role && index($0, want) && match($0, /pos=\(-?[0-9]+,-?[0-9]+\) size=[0-9]+x[0-9]+/) {
			split(substr($0, RSTART, RLENGTH), a, /[(,)x= ]+/)
			printf "%d %d\n", a[2] + a[5] / 2, a[3] + a[6] / 2
			exit
		}
	' "$RUN_DIR/$1"
}

# The amount a duration row's field is showing, read the same way.
row_field_value() {
	awk -v want="desc=\"$2, in " '
		$1 == "AXTextField" && index($0, want) && match($0, /value="[^"]*"/) {
			print substr($0, RSTART + 7, RLENGTH - 8)
			exit
		}
	' "$RUN_DIR/$1"
}

# Type an amount into a duration row and end the edit by moving focus, the way
# a person does who types and then clicks elsewhere rather than pressing
# Return. The amount the row is left showing is what the row committed.
type_duration() {
	local row="$1" unit="$2" typed="$3" tag="$4"
	"$DRIVE" ax "$ATHINA_PID" set AXTextField "$row, in $unit" "$typed" --scope Models >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	"$DRIVE" ax "$ATHINA_PID" focus AXTextField "Size limit, in tokens" --scope Models >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 0.6
	"$DRIVE" ax "$ATHINA_PID" dump --scope Models >"$RUN_DIR/$tag.txt" 2>&1 || true
	row_field_value "$tag.txt" "$row"
}

has_text() {
	grep -qF "$2" "$RUN_DIR/$1" && echo yes || echo no
}

scenario_run() {
	local goal head revisions refresh_x idle_x link
	stage_flip_window
	wait_toast >/dev/null || return 1
	wait_understanding || { log "no understanding was written"; return 1; }
	goal="$(understanding_goal)"
	# Every goal check below compares against this text, and an empty one would
	# match any file, so a record with no goal to follow stops the scenario.
	[ -n "$goal" ] || { log "the understanding names no goal to follow"; return 1; }
	log "the understanding names \"$goal\""
	# Revisions are inserted, never updated, so a second mentor call before the
	# toast leaves two rows; what matters here is that a revision was written.
	check "the mentor call wrote an understanding" "yes" \
		"$([ "$(journal_count understanding)" -ge 1 ] && echo yes || echo no)"

	# The menu shows the goal, clipped to fit a menu item, so only its start
	# can be compared with the record.
	head="$(printf '%s' "$goal" | cut -c1-40)"
	menu_items "menu-with-goal"
	check "the menu shows the goal it worked out" "yes" "$(has_text menu-with-goal-menu-items.txt "title=\"Goal: $head")"

	# The card sits under the Mentor loop card in the Now pane, so the pane is
	# scrolled to the end before the shot; AXScrollToVisible does nothing here.
	"$DRIVE" ax "$ATHINA_PID" set AXScrollBar "" 1 --scope "Debug Panel" >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5
	window_texts "Debug Panel" "card"
	check "the card shows the goal" "yes" "$(has_text card-texts.txt "$goal")"
	check "the card names the refresh interval" "yes" "$(has_text card-texts.txt "of active use")"
	check "the card offers Reset Understanding" "yes" "$(has_text card-texts.txt "Reset Understanding…")"

	# Settings opens on the pane it last showed, and accessibility offers no
	# way to change panes, so the pane is chosen before the window opens. The
	# harness puts the owner's preferences back whatever happens.
	defaults write "$PREFS_DOMAIN" SettingsPane models >>"$RUN_DIR/transcript.log" 2>&1 || true
	# A menu item is only in the tree while the menu is open, so the extra is
	# pressed right before it, and closed again in case the press left it up.
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || { log "the menu bar extra would not open"; return 1; }
	sleep 0.8
	"$DRIVE" ax "$ATHINA_PID" pressx AXMenuItem "Settings…" --scope extras >>"$RUN_DIR/transcript.log" 2>&1 \
		|| { log "the menu offered no Settings… item to press"; return 1; }
	"$DRIVE" ax "$ATHINA_PID" cancelmenu >>"$RUN_DIR/transcript.log" 2>&1 || true
	wait_window "Models" || { log "Settings never opened on the Models pane"; return 1; }
	window_texts "Models" "settings"
	check "Settings shows the current goal" "yes" "$(has_text settings-texts.txt "$goal")"

	# The section's two duration rows show different unit words, minutes beside
	# hours with the shipped defaults, and a unit pop-up sizes to the word it is
	# showing, so this is where a row that reserves only its own word pushes its
	# field and stepper off the other row's x.
	"$DRIVE" ax "$ATHINA_PID" dump --scope Models >"$RUN_DIR/models-dump.txt" 2>&1 || true
	refresh_x="$(row_field_x models-dump.txt "Refresh at most every")"
	idle_x="$(row_field_x models-dump.txt "Forget after no activity for")"
	# Two empty readings would match each other, so nothing to measure is a
	# scenario failure rather than a check that passes by saying nothing.
	[ -n "$refresh_x" ] && [ -n "$idle_x" ] || { log "the Models pane showed no duration fields to measure"; return 1; }
	check "the duration rows start their fields on one x" "$refresh_x" "$idle_x"

	# The row is held to the seconds the setting itself accepts, 5 minutes to
	# 12 hours, and it commits when the edit ends however it ends, so typing an
	# amount outside that and clicking away leaves the nearest one it allows
	# rather than a figure validated() would quietly clamp behind the person.
	check "a refresh below the range settles at the shortest allowed" "5" \
		"$(type_duration "Refresh at most every" minutes 1 refresh-too-short)"
	check "a refresh above the range settles at the longest allowed" "720" \
		"$(type_duration "Refresh at most every" minutes 1000 refresh-too-long)"
	check "an allowed refresh is left as typed" "20" \
		"$(type_duration "Refresh at most every" minutes 20 refresh-in-range)"

	# The footer names the Journal pane by linking to it, and the link opens it
	# here rather than in a browser, so the Settings window itself changes pane.
	# A link inside a Text offers accessibility nothing to press, so this is the
	# one step that needs the real pointer; the footer is below the fold, so the
	# pane is scrolled to the end and the link found again before it is aimed at.
	"$DRIVE" ax "$ATHINA_PID" set AXScrollBar "" 1 --scope Models >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.6
	"$DRIVE" ax "$ATHINA_PID" dump --scope Models >"$RUN_DIR/footer-dump.txt" 2>&1 || true
	link="$(element_centre footer-dump.txt AXLink "Journal settings")"
	[ -n "$link" ] || { log "the footer showed no Journal settings link to aim at"; return 1; }
	# The flipping helper floats above the Settings window and has already
	# earned the mentor call this scenario follows, so it is stopped rather
	# than left over the point the pointer is about to aim at.
	stop_pid "$FLIP_PID"
	sleep 0.5
	wait_idle_input || return 1
	# A click into a window that is not key only makes it key, so the Settings
	# window is brought forward before the pointer aims at anything inside it.
	"$DRIVE" raise "$ATHINA_PID" Models >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5
	# shellcheck disable=SC2086
	"$DRIVE" click window "$ATHINA_PID" $link --shot "$RUN_DIR/footer-link.png" >>"$RUN_DIR/transcript.log" 2>&1 \
		|| { log "the click on the Journal settings link would not land"; return 1; }
	sleep 1
	check "the footer link opens the Journal pane in place" "yes" \
		"$([ -n "$(window_id "Journal")" ] && echo yes || echo no)"
	window_texts "Journal" "journal-pane"

	"$DRIVE" close "$ATHINA_PID" Journal >>"$RUN_DIR/transcript.log" 2>&1 || true
	"$DRIVE" close "$ATHINA_PID" Models >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5

	# Asking first, and Cancel keeping every revision.
	revisions="$(journal_count understanding)"
	"$DRIVE" ax "$ATHINA_PID" pressx AXButton "Reset Understanding…" --scope "Debug Panel" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 1.5
	window_texts "Debug Panel" "confirmation"
	check "the confirmation asks before resetting" "yes" "$(has_text confirmation-texts.txt "Reset the understanding?")"
	check "the confirmation says it cannot be undone" "yes" "$(has_text confirmation-texts.txt "You can't undo this action.")"
	check "the confirmation offers Cancel" "yes" "$(has_text confirmation-texts.txt "Cancel")"
	"$DRIVE" ax "$ATHINA_PID" pressx AXButton "Cancel" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 1
	check "Cancel keeps every revision" "$revisions" "$(journal_count understanding)"
	check "Cancel journals no reset" "0" "$(reset_events)"

	"$DRIVE" ax "$ATHINA_PID" pressx AXButton "Reset Understanding…" --scope "Debug Panel" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 1.5
	"$DRIVE" ax "$ATHINA_PID" pressx AXButton "Reset Understanding" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
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
