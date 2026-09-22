# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The debug panel's Timeline lists each journal row once. At launch sensing
# journals its first events, Started among them, before the panel reads the
# journal back, and the live stream carries the same rows, so a timeline that
# took both as they came showed every startup row twice. The panel is open from
# launch here, which is where a person saw it.
SCENARIO_SUMMARY="the debug panel's Timeline shows each startup row once"
SCENARIO_ARGS=(--open debug)

# Every row the Timeline can show: observations and events together.
journal_rows() {
	echo $(($(journal_count observations) + $(journal_count events)))
}

# Events of one kind with no detail, the rows the Timeline shows as the label
# alone, and for one app when a second argument names it. Only the startup app
# switch has no detail, since every later one names the app it came from.
journal_events() {
	sqlite3 -readonly "$JOURNAL" \
		"select count(*) from events where kind = '$1' and detail is null and ('${2:-}' = '' or app_name = '${2:-}')" 2>/dev/null || echo 0
}

# The count the Timeline's header shows, "7 entries", as a number.
header_count() {
	sed -n 's/.*value="\([0-9][0-9]*\) entr[a-z]*".*/\1/p' "$RUN_DIR/$1" | head -1
}

# Rows whose text starts with the given label, at any time of day.
rows_named() {
	grep -c "value=\"[0-9:]*, $2\"" "$RUN_DIR/$1" || true
}

scenario_run() {
	local id before after shown="" i
	wait_first_observation || return 1
	# Sensing keeps journaling, so the header is compared with a journal that
	# held still across the read; a row can reach the panel a moment after the
	# journal, so a few reads are allowed before the two are compared.
	for i in $(seq 1 10); do
		before="$(journal_rows)"
		"$DRIVE" ax "$ATHINA_PID" dump --scope "Debug Panel" >"$RUN_DIR/timeline-dump.txt" 2>&1 || true
		after="$(journal_rows)"
		shown="$(header_count timeline-dump.txt)"
		[ "$before" = "$after" ] && [ "$shown" = "$after" ] && break
		sleep 0.5
	done
	id="$(window_id "Debug Panel")"
	[ -n "$id" ] && "$DRIVE" shot window "$id" "$RUN_DIR/timeline.png" >/dev/null 2>&1
	[ -n "$shown" ] || { log "the Debug Panel showed no Timeline header to read"; return 1; }

	check "the Timeline lists each journaled row once" "$after" "$shown"
	check "Started is listed once for each launch journaled" "$(journal_events started)" \
		"$(rows_named timeline-dump.txt Started)"
	check "the startup app switch is listed once" "$(journal_events appSwitch TextEdit)" \
		"$(rows_named timeline-dump.txt "App switch · TextEdit")"
	return 0
}
