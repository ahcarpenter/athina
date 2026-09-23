# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# What the debug panel says right after Clear Journal. Clearing deletes every
# observation, so the Latest frame pane is empty until the next capture, and
# the pane says that is why rather than blaming a permission the header shows
# granted. The Mentor loop card stops naming an observation or a model call that
# no longer exists, and the callout and transcript from before the clear. The
# next capture then fills the pane again.
#
# Settings opens from the menu and both confirmation buttons are pressed by
# name through accessibility, so the run needs no pointer.
SCENARIO_SUMMARY="after Clear Journal the debug panel says the journal was cleared and names no deleted observation or call"
SCENARIO_ARGS=(--open debug)

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

# The window's text as VoiceOver reads it, and a shot of it.
window_texts() {
	local scope="$1" tag="$2" id
	"$DRIVE" ax "$ATHINA_PID" texts --scope "$scope" >"$RUN_DIR/$tag-texts.txt" 2>&1 || true
	id="$(window_id "$scope")"
	[ -n "$id" ] && "$DRIVE" shot window "$id" "$RUN_DIR/$tag.png" >/dev/null 2>&1
	return 0
}

has_text() {
	grep -qF "$2" "$RUN_DIR/$1" && echo yes || echo no
}

# Re-reads the panel until its text matches the extended regular expression
# $1, or $3 tries a second apart pass.
wait_panel_text() {
	local want="$1" tag="$2" limit="${3:-20}" i
	for i in $(seq 1 "$limit"); do
		window_texts "Debug Panel" "$tag"
		grep -qE "$want" "$RUN_DIR/$tag-texts.txt" && return 0
		[ $((i % 3)) = 0 ] && wake_input
		sleep 1
	done
	return 1
}

# Whether the Triage gate line names an observation the journal no longer
# holds: yes or no. A capture that lands after the clear is a real row, so a
# line naming that one is right.
names_deleted_observation() {
	local id
	id="$(sed -n 's/.*Triage gate, ran .* on observation #\([0-9]*\).*/\1/p' "$RUN_DIR/$1" | head -1)"
	[ -n "$id" ] || { echo no; return 0; }
	[ "$(sqlite3 -readonly "$JOURNAL" "select count(*) from observations where id = $id" 2>/dev/null || echo 0)" = 0 ] \
		&& echo yes || echo no
}

# Presses Clear Journal… on the open Journal pane and confirms it.
clear_journal() {
	"$DRIVE" ax "$ATHINA_PID" pressx AXButton "Clear Journal…" --scope Journal >>"$RUN_DIR/transcript.log" 2>&1 \
		|| { log "the Journal pane offered no Clear Journal… button"; return 1; }
	sleep 1.5
	"$DRIVE" ax "$ATHINA_PID" pressx AXButton "Clear Journal" >>"$RUN_DIR/transcript.log" 2>&1 \
		|| { log "the confirmation offered no Clear Journal button"; return 1; }
	sleep 0.5
}

scenario_run() {
	wait_window "Debug Panel" 20 || { log "the debug panel never opened"; return 1; }
	wait_first_observation || { log "nothing was captured"; return 1; }
	wait_panel_text "on observation #" before \
		|| { log "the triage gate never ran on an observation"; return 1; }
	wait_panel_text 'value="Last triage, [^"]+ ago, ' before \
		|| { log "the card never listed the triage call"; return 1; }
	check "the panel shows a frame before clearing" "yes" "$(has_text before-texts.txt "Latest frame")"

	# Settings opens on the pane it last showed, so the Journal pane is chosen
	# before the window opens. The harness puts the owner's preferences back.
	defaults write "$PREFS_DOMAIN" SettingsPane journal >>"$RUN_DIR/transcript.log" 2>&1 || true
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || { log "the menu bar extra would not open"; return 1; }
	sleep 0.8
	"$DRIVE" ax "$ATHINA_PID" pressx AXMenuItem "Settings…" --scope extras >>"$RUN_DIR/transcript.log" 2>&1 \
		|| { log "the menu offered no Settings… item to press"; return 1; }
	"$DRIVE" ax "$ATHINA_PID" cancelmenu >>"$RUN_DIR/transcript.log" 2>&1 || true
	wait_window "Journal" 20 || { log "Settings never opened on the Journal pane"; return 1; }
	# Clearing moves focus, and a focus change brings a capture that fills the
	# pane again within a second or so, and a call in flight can land after the
	# clear. A reading counts only when the journal still holds no observation
	# and no model call after it, so the panel was read before any new row
	# reached it; otherwise the journal is cleared again.
	local attempt read=no
	for attempt in 1 2 3 4 5; do
		clear_journal || return 1
		window_texts "Debug Panel" cleared
		if [ "$(journal_count observations)" = 0 ] && [ "$(journal_count model_calls)" = 0 ]; then
			read=yes
			break
		fi
		log "a capture or a call landed before the panel was read (attempt $attempt), clearing again"
	done
	check "the panel was read before any new row" "yes" "$read"
	"$DRIVE" close "$ATHINA_PID" Journal >>"$RUN_DIR/transcript.log" 2>&1 || true
	check "the frame pane says the journal was cleared" "yes" "$(has_text cleared-texts.txt "Journal Cleared")"
	check "the frame pane does not blame Screen Recording" "no" "$(has_text cleared-texts.txt "once Screen Recording is granted")"
	check "the card names no deleted observation" "no" "$(names_deleted_observation cleared-texts.txt)"
	local field
	for field in "Last triage, none yet" "Mentor gate, not reached yet" "Last mentor, none yet" \
		"Last refresh, none yet" "Callout, none yet" "Transcript, none yet"; do
		check "the panel reads $field" "yes" "$(has_text cleared-texts.txt "value=\"$field\"")"
	done

	# The next capture fills the pane again, and the gate runs on the new row.
	wait_first_observation || { log "nothing was captured after clearing"; return 1; }
	wait_panel_text "Latest frame" refilled || { log "the next capture never reached the frame pane"; return 1; }
	check "the next capture fills the frame pane" "yes" "$(has_text refilled-texts.txt "Latest frame")"
	return 0
}
