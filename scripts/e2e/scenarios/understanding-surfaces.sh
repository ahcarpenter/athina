# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The surfaces that show the standing understanding. The mentor call that
# raises the first suggestion also writes the first understanding, so this
# follows that record out to the menu, the debug panel's card, and Settings >
# Models, and then through Reset Understanding, which asks before it forgets
# every revision.
#
# On the API tier: the suggestion comes from scripted sensing (docs/e2e.md
# "Scripted sensing"), every control is clicked or typed into through
# Athina's own event path, and the journal is read through the app. The
# footer's link to the Journal pane is followed through the handler a click
# on it runs (`open-link`); that a real click on it reaches that handler is
# the real-screen tier's to prove.
SCENARIO_SUMMARY="the understanding a mentor call writes reaches the menu, the card, and Settings, and Reset Understanding asks first"
SCENARIO_ARGS=(--open debug)
SCENARIO_TIER=api

# The goal the newest revision puts first, as the app's journal holds it.
understanding_goal() {
	json_eval "$(api journal query=understanding)" 'r["rows"][-1]["goal"] if r["rows"] else ""'
}

revisions() { json_eval "$(api journal query=understanding)" 'len(r["rows"])'; }

reset_events() {
	json_eval "$(api journal query=events)" \
		'sum(1 for e in r["rows"] if e["kind"] == "understanding" and e["detail"].startswith("reset"))'
}

# The menu's status rows, one title per line.
menu_titles() {
	json_eval "$(api menu --field items)" '"\n".join(i["title"] for i in r if not i["separator"])' >"$RUN_DIR/$1-menu.txt"
}

# Everything a window shows, one line per element: labels, titles and values.
window_texts() {
	json_eval "$(api find window="$1")" '"\n".join(t for e in r["elements"] for t in (e["label"], e["title"], e["value"]) if t)' \
		>"$RUN_DIR/$2-texts.txt"
}

has_text() { grep -qF -- "$2" "$RUN_DIR/$1" && echo yes || echo no; }

# Pictures kept as evidence: these windows show what changes from run to run
# or move on their own, so they are not checkpoints (docs/ci.md "Checkpoints").
picture() { api snapshot window="$1" path="$RUN_DIR/$2.png" >/dev/null || log "no picture of $1"; }

# The x a duration row's amount field starts at in the Models pane. Two rows
# in one section are in line only when their fields start at the same x,
# whatever unit word each row's pop-up happens to be showing.
field_x() { api find window=Models identifier="$1" --field elements.0.frame.0; }

field_value() { api find window=Models identifier="$1" --field elements.0.value; }

# Type an amount into a duration row and end the edit with Tab, the way a
# person moves on to the next field. The field is emptied first from wherever
# the click put the insertion point. The amount the row is left showing is
# what it committed, which it can take a moment to show once the edit ends
# on a busy Mac, so it is read until it is the amount expected, `want`, or
# that moment has passed.
type_duration() {
	local field="$1" typed="$2" want="$3" clear=""
	for _ in 1 2 3 4 5 6; do clear+=$'\x7f'; done
	api scroll window=Models identifier="$field" >/dev/null || return 1
	api click window=Models identifier="$field" >/dev/null || return 1
	api type window=Models text="$clear$typed"$'\t' >/dev/null || return 1
	DURATION_FIELD="$field"
	settled "$want" duration_field_value
}

duration_field_value() { field_value "$DURATION_FIELD"; }

# The confirmation's Cancel button, once it is up over the debug panel.
cancel_button() { api find window="Debug Panel" role=AXButton label=Cancel --field elements.0.label; }

refresh_interval() { api settings key=mentor.understandingRefreshInterval --field value; }

scenario_run() {
	local goal head revisions
	api wait-window window="Debug Panel" timeout=20 >/dev/null || { log "the debug panel never opened"; return 1; }
	scripted_toast || return 1
	# The mentor call carries the understanding in its reply, so the record is
	# written just after the suggestion it came with.
	api wait-event name=status understanding=1 >/dev/null || { log "no understanding was written"; return 1; }
	goal="$(understanding_goal)"
	# Every goal check below compares against this text, and an empty one would
	# match any file, so a record with no goal to follow stops the scenario.
	[ -n "$goal" ] && [ "$goal" != "-" ] || { log "the understanding names no goal to follow"; return 1; }
	log "the understanding names \"$goal\""
	check "the mentor call wrote an understanding" "1" "$(revisions)"

	# The menu shows the goal, clipped to fit a menu item, so only its start
	# can be compared with the record.
	head="$(printf '%s' "$goal" | cut -c1-40)"
	menu_titles with-goal
	check "the menu shows the goal it worked out" "yes" "$(has_text with-goal-menu.txt "Goal: $head")"

	# The card sits under the Mentor loop card in the Now pane, below the fold.
	api scroll window="Debug Panel" identifier=understanding.reset >/dev/null || log "the card could not be scrolled to"
	window_texts "Debug Panel" card
	picture "Debug Panel" card
	check "the card shows the goal" "yes" "$(has_text card-texts.txt "$goal")"
	check "the card names the refresh interval" "yes" "$(has_text card-texts.txt "of active use")"
	check "the card offers Reset Understanding" "yes" "$(has_text card-texts.txt "Reset Understanding…")"

	check "the menu's Settings… command is chosen" "true" "$(api menu press="Settings…" --field ok)"
	api wait-window window=General timeout=10 >/dev/null || { log "Settings never opened"; return 1; }
	check "a click on the Models toolbar item lands" "true" "$(api click window=General label=Models --field ok)"
	api wait-window window=Models timeout=5 >/dev/null || { log "the Models pane never showed"; return 1; }
	window_texts Models settings
	picture Models models
	check "Settings shows the current goal" "yes" "$(has_text settings-texts.txt "$goal")"

	# The section's two duration rows show different unit words, minutes beside
	# hours with the shipped defaults, and a unit pop-up sizes to the word it is
	# showing, so this is where a row that reserves only its own word pushes its
	# field and stepper off the other row's x.
	local refresh_x idle_x
	refresh_x="$(field_x understanding.refreshInterval)"
	idle_x="$(field_x understanding.idleGap)"
	# Two empty readings would match each other, so nothing to measure is a
	# scenario failure rather than a check that passes by saying nothing.
	[ -n "$refresh_x" ] && [ -n "$idle_x" ] || { log "the Models pane showed no duration fields to measure"; return 1; }
	check "the duration rows start their fields on one x" "$refresh_x" "$idle_x"

	# The row is held to the seconds the setting itself accepts, 5 minutes to
	# 12 hours, and it commits when the edit ends, so typing an amount outside
	# that and moving on leaves the nearest one it allows rather than a figure
	# validated() would quietly clamp behind the person.
	check "a refresh below the range settles at the shortest allowed" "5" \
		"$(type_duration understanding.refreshInterval 1 5)"
	check "the setting holds the shortest refresh" "300" "$(settled 300 refresh_interval)"
	check "a refresh above the range settles at the longest allowed" "720" \
		"$(type_duration understanding.refreshInterval 1000 720)"
	check "the setting holds the longest refresh" "43200" "$(settled 43200 refresh_interval)"
	check "an allowed refresh is left as typed" "20" "$(type_duration understanding.refreshInterval 20 20)"
	check "the setting holds the refresh typed" "1200" "$(settled 1200 refresh_interval)"

	# The footer names the Journal pane by linking to it, and the link opens it
	# here rather than in a browser, so the Settings window itself changes pane.
	check "the footer's link to Journal is followed" "athina-settings:journal" \
		"$(api open-link window=Models identifier=athina-settings:journal --field url)"
	check "the footer link opens the Journal pane in place" "yes" \
		"$(api wait-window window=Journal timeout=5 >/dev/null && echo yes || echo no)"
	picture Journal journal-pane
	api click window=Journal subrole=AXCloseButton >/dev/null
	api wait-window window=Journal present=false timeout=5 >/dev/null || log "Settings would not close"

	# Asking first, and Cancel keeping every revision.
	revisions="$(revisions)"
	api scroll window="Debug Panel" identifier=understanding.reset >/dev/null
	# A destructive button takes no click into a window that is not forward,
	# and a hermetic run's never are, so it is pressed as VoiceOver presses it.
	check "Reset Understanding… is pressed" "true" \
		"$(api press window="Debug Panel" identifier=understanding.reset --field ok)"
	check "the confirmation comes up" "Cancel" "$(settled Cancel cancel_button)"
	window_texts "Debug Panel" confirmation
	picture "Debug Panel" confirmation
	check "the confirmation asks before resetting" "yes" "$(has_text confirmation-texts.txt "Reset the understanding?")"
	check "the confirmation says it cannot be undone" "yes" "$(has_text confirmation-texts.txt "You can't undo this action.")"
	check "a click on Cancel lands" "true" "$(api click window="Debug Panel" role=AXButton label=Cancel --field ok)"
	check "Cancel keeps every revision" "$revisions" "$(revisions)"
	check "Cancel journals no reset" "0" "$(reset_events)"

	check "Reset Understanding… is pressed again" "true" \
		"$(api press window="Debug Panel" identifier=understanding.reset --field ok)"
	check "a click on the confirmation's Reset Understanding lands" "true" \
		"$(api click window="Debug Panel" role=AXButton label="Reset Understanding" --field ok)"
	check "the reset is journaled" "understanding" \
		"$(api wait-event name=event kind=understanding --field event.kind)"
	check "Reset Understanding forgets every revision" "0" "$(revisions)"
	check "the reset is journaled once" "1" "$(reset_events)"
	window_texts "Debug Panel" card-after-reset
	picture "Debug Panel" card-after-reset
	check "the card says there is no understanding yet" "yes" "$(has_text card-after-reset-texts.txt "No understanding yet.")"

	menu_titles after-reset
	check "the menu says the goal is not worked out yet" "yes" "$(has_text after-reset-menu.txt "Goal: not worked out yet")"
	return 0
}
