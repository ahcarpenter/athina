# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The debug panel's timeline shows each journaled entry once. Sensing starts,
# and journals its first events, before the panel's timeline is first read
# from the journal, so an event that is both in that first read and still on
# its way to the panel must not be listed twice.
SCENARIO_SUMMARY="the debug panel's timeline lists each startup event once, as the journal holds it"
SCENARIO_ARGS=(--open debug)

# The id of the first window whose name starts with $1, empty when none is open.
window_id() {
	"$DRIVE" windows "$ATHINA_PID" \
		| awk -v want="$1" 'index($0, "name=\"" want) {sub("id=", "", $1); print $1; exit}' || echo ""
}

# How many timeline rows in a texts dump are the event labelled $2. A row reads
# as its time, its label, and any detail: "12:00:00, Started".
timeline_rows() {
	grep -cE "value=\"[0-9:]+, $2(\"|, )" "$RUN_DIR/$1" || true
}

journal_events() {
	sqlite3 -readonly "$JOURNAL" "select count(*) from events where kind = '$1'" 2>/dev/null || echo 0
}

scenario_run() {
	local id
	for _ in $(seq 1 20); do
		[ -n "$(window_id "Debug Panel")" ] && break
		sleep 0.5
	done
	id="$(window_id "Debug Panel")"
	[ -n "$id" ] || { log "the debug panel never opened"; return 1; }
	sleep 1
	"$DRIVE" ax "$ATHINA_PID" texts --scope "Debug Panel" >"$RUN_DIR/timeline-texts.txt" 2>&1 || true
	"$DRIVE" shot window "$id" "$RUN_DIR/timeline.png" >/dev/null 2>&1 || true
	check "the journal holds one Started event" "1" "$(journal_events started)"
	check "the timeline lists Started once" "1" "$(timeline_rows timeline-texts.txt Started)"
	return 0
}
