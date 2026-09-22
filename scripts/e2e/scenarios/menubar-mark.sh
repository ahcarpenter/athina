# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# Athina's mark must keep one width as Athina changes state: an item that grows
# or shrinks pushes every extra to its left sideways, which is the one thing a
# menu bar extra must never do. The width is read from the real bar through
# accessibility rather than from the asset, so it is the width the bar actually
# gave the item, and a variant drawn at a different size from the others fails
# the comparison.
#
# It does not prove the drawing is Athina's own. The harness runs the app in
# replay, where the mode word sits beside the mark, so an item whose mark did
# not load is still an item with a width and every comparison here still holds.
# The bar-*.png strips this writes are the evidence of what is really drawn.
SCENARIO_SUMMARY="Athina's item keeps one width in the real menu bar across modes"

# Athina's ordinary windows, ids only and sorted: the menu bar extra and any
# open menu sit above them at layer 101 and are left out.
ordinary_windows() {
	"$DRIVE" windows "$ATHINA_PID" 2>/dev/null \
		| awk '/layer=0 / {sub("id=", "", $1); print $1}' | sort -u
}

scenario_run() {
	local watching paused resumed bar_x bar_y
	wait_first_observation || return 1
	wait_idle_input 10 || return 1

	watching="$(athina_item_width)"
	check "Athina has an item in the bar while watching" "yes" "$([ -n "$watching" ] && echo yes || echo no)"
	[ -n "$watching" ] || { log "Athina has no menu bar extra; see transcript.log"; return 1; }
	# A strip of the real bar around the item, as evidence of what it looks like.
	# The item is known to be in the bar by here, so its line carries an x.
	bar_x=$(($(athina_extra | sed -n 's/.* x=\([0-9]*\)[0-9.]* .*/\1/p') - 60))
	bar_y=0
	"$DRIVE" shot region "$bar_x" "$bar_y" 260 44 "$RUN_DIR/bar-watching.png" >/dev/null 2>&1 || true
	log "mark width while watching: $watching pt"

	# Pause Watching, which is the mode change a person can make from the menu.
	"$DRIVE" menupick "$ATHINA_PID" "Pause Watching" "" >>"$RUN_DIR/transcript.log" 2>&1 \
		|| "$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1
	sleep 0.3
	"$DRIVE" ax "$ATHINA_PID" press AXMenuItem "Pause Watching" >>"$RUN_DIR/transcript.log" 2>&1 || true
	"$DRIVE" ax "$ATHINA_PID" cancelmenu >/dev/null 2>&1 || true
	sleep 0.8
	paused="$(athina_item_width)"
	"$DRIVE" shot region "$bar_x" "$bar_y" 260 44 "$RUN_DIR/bar-paused.png" >/dev/null 2>&1 || true
	log "mark width while paused: $paused pt"
	check "paused is drawn at the same width as watching" "$watching" "$paused"
	check "Athina is paused" "paused" "$(sqlite3 -readonly "$JOURNAL" \
		"select coalesce((select kind from events order by id desc limit 1), 'none')" 2>/dev/null || echo unknown)"

	# And back, so the run leaves Athina as it found it.
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.3
	"$DRIVE" ax "$ATHINA_PID" press AXMenuItem "Resume Watching" >>"$RUN_DIR/transcript.log" 2>&1 || true
	"$DRIVE" ax "$ATHINA_PID" cancelmenu >/dev/null 2>&1 || true
	sleep 0.8
	resumed="$(athina_item_width)"
	"$DRIVE" shot region "$bar_x" "$bar_y" 260 44 "$RUN_DIR/bar-resumed.png" >/dev/null 2>&1 || true
	check "resuming is drawn at the same width again" "$watching" "$resumed"

	# About Athina, which showed the macOS placeholder while the app had no
	# icon at all. The standard About panel reports no window name, so it is
	# found as the ordinary window that was not there before rather than by
	# its title.
	local before about i
	before="$(ordinary_windows)"
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.3
	"$DRIVE" ax "$ATHINA_PID" press AXMenuItem "About Athina" >>"$RUN_DIR/transcript.log" 2>&1 || true
	# The panel is built the first time it is asked for, so wait for it rather
	# than guessing how long that takes.
	for i in $(seq 1 20); do
		about="$(comm -13 <(printf '%s\n' "$before") <(ordinary_windows) | head -1)"
		[ -n "$about" ] && break
		sleep 0.4
	done
	if [ -n "$about" ]; then
		"$DRIVE" shot window "$about" "$RUN_DIR/about-athina.png" >/dev/null 2>&1 || true
		"$DRIVE" close "$ATHINA_PID" About >/dev/null 2>&1 || true
	fi
	check "About Athina opened" "yes" "$([ -n "$about" ] && echo yes || echo no)"
	snapshot_state "mark"
	return 0
}
