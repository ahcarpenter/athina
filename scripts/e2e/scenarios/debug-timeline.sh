# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The debug panel's Timeline lists each journal row once. A timeline that read
# the journal back after sensing had journaled its first events, Started among
# them, while the live stream carried the same rows, showed every startup row
# twice. AppState loads the timeline before pipeline.start(), so the startup
# rows arrive on the stream alone, and the timeline merges rows by journal id
# for any later load that overlaps the stream, such as the reload after Clear
# Journal, and for ids the journal reuses. The panel is open from launch here,
# which is where a person saw it.
#
# On the API tier, reading the Timeline through Athina's own accessibility
# tree. The run is hermetic, so it senses nothing: Started is the startup row
# counted, and the rows of a real app switch or capture are not there to be.
SCENARIO_SUMMARY="the debug panel's Timeline shows each startup row once"
SCENARIO_ARGS=(--open debug)
SCENARIO_TIER=api

# Every row the Timeline can show: observations and events together.
journal_rows() {
	echo $(($(journal_count observations) + $(journal_count events)))
}

# Events of one kind with no detail, the rows the Timeline shows as the label
# alone.
journal_events() {
	sqlite3 -readonly "$JOURNAL" "select count(*) from events where kind = '$1' and detail is null" 2>/dev/null || echo 0
}

# The count the Timeline's header shows, "7 entries", as a number.
header_count() {
	api find window="Debug Panel" identifier=debugPanel.sideCount --field elements.0.value | sed -n 's/^\([0-9][0-9]*\) entr.*/\1/p'
}

# Rows whose text is the given label alone, at any time of day: "12:00:00, Started".
rows_named() {
	json_eval "$(cat "$RUN_DIR/timeline-rows.json")" \
		'sum(1 for e in r["elements"] if any(re.fullmatch(r"[0-9:]+, " + re.escape(a[0]), t) for t in (e["value"], e["label"])))' "$1"
}

scenario_run() {
	local before after shown="" started i
	api wait-window window="Debug Panel" timeout=20 >/dev/null || { log "the debug panel never opened"; return 1; }
	for i in $(seq 1 50); do
		[ "$(journal_events started)" -ge 1 ] && break
		sleep 0.1
	done
	# The journal can still gain a row, so the header is compared with a
	# journal that held still across the read; a row can reach the panel a
	# moment after the journal, so a few reads are allowed before the two are
	# compared.
	for i in $(seq 1 10); do
		before="$(journal_rows)"
		shown="$(header_count)"
		api find window="Debug Panel" identifier=debugPanel.timelineRow >"$RUN_DIR/timeline-rows.json"
		after="$(journal_rows)"
		[ "$before" = "$after" ] && [ "$shown" = "$after" ] && break
		sleep 0.5
	done
	api snapshot window="Debug Panel" path="$RUN_DIR/timeline.png" >/dev/null || true
	[ -n "$shown" ] || { log "the Debug Panel showed no Timeline header to read"; return 1; }
	# No Started row would match no row of it, so a launch that journaled none
	# is a scenario failure rather than a check that passes by saying nothing.
	started="$(journal_events started)"
	[ "$started" -ge 1 ] || { log "the launch journaled no Started row to count"; return 1; }

	check "the Timeline lists each journaled row once" "$after" "$shown"
	check "Started is listed once for each launch journaled" "$started" "$(rows_named Started)"
	return 0
}
