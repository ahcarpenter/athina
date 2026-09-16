# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/mentor-e2e, which sources this file.
# shellcheck disable=SC2034
# Mentor's own mark must be what the real menu bar draws, and it must keep one
# width as Mentor changes state: an item that grows or shrinks pushes every
# extra to its left sideways, which is the one thing a menu bar extra must
# never do. The width is read from the real bar through accessibility, not from
# the asset, so this catches a mark the app failed to load as well as one drawn
# at the wrong size.
SCENARIO_SUMMARY="the real menu bar draws Mentor's mark, at one width across modes"

# The item's width in the real bar, to a tenth of a point.
mark_width() {
	"$DRIVE" bar "$MENTOR_PID" 2>/dev/null \
		| awk -v pid="$MENTOR_PID" '$0 ~ "pid=" pid " " {
			for (i = 1; i <= NF; i++) if ($i ~ /^w=/) { sub("w=", "", $i); printf "%.1f\n", $i; exit }
		}'
}

# Mentor's ordinary windows, ids only and sorted: the menu bar extra and any
# open menu sit above them at layer 101 and are left out.
ordinary_windows() {
	"$DRIVE" windows "$MENTOR_PID" 2>/dev/null \
		| awk '/layer=0 / {sub("id=", "", $1); print $1}' | sort -u
}

scenario_run() {
	local watching paused resumed bar_x bar_y
	wait_first_observation || return 1
	wait_idle_input 10 || return 1

	watching="$(mark_width)"
	check "the mark is in the bar while watching" "yes" "$([ -n "$watching" ] && echo yes || echo no)"
	[ -n "$watching" ] || { log "Mentor has no menu bar extra; see transcript.log"; return 1; }
	# A strip of the real bar around the item, as evidence of what it looks like.
	bar_x="$("$DRIVE" bar "$MENTOR_PID" | awk -v pid="$MENTOR_PID" '$0 ~ "pid=" pid " " {
		for (i = 1; i <= NF; i++) if ($i ~ /^x=/) { sub("x=", "", $i); printf "%d\n", $i - 60; exit } }')"
	bar_y=0
	"$DRIVE" shot region "$bar_x" "$bar_y" 260 44 "$RUN_DIR/bar-watching.png" >/dev/null 2>&1 || true
	log "mark width while watching: $watching pt"

	# Pause Watching, which is the mode change a person can make from the menu.
	"$DRIVE" menupick "$MENTOR_PID" "Pause Watching" "" >>"$RUN_DIR/transcript.log" 2>&1 \
		|| "$DRIVE" ax "$MENTOR_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1
	sleep 0.3
	"$DRIVE" ax "$MENTOR_PID" press AXMenuItem "Pause Watching" >>"$RUN_DIR/transcript.log" 2>&1 || true
	"$DRIVE" ax "$MENTOR_PID" cancelmenu >/dev/null 2>&1 || true
	sleep 0.8
	paused="$(mark_width)"
	"$DRIVE" shot region "$bar_x" "$bar_y" 260 44 "$RUN_DIR/bar-paused.png" >/dev/null 2>&1 || true
	log "mark width while paused: $paused pt"
	check "paused is drawn at the same width as watching" "$watching" "$paused"
	check "Mentor is paused" "paused" "$(sqlite3 -readonly "$JOURNAL" \
		"select coalesce((select kind from events order by id desc limit 1), 'none')" 2>/dev/null || echo unknown)"

	# And back, so the run leaves Mentor as it found it.
	"$DRIVE" ax "$MENTOR_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.3
	"$DRIVE" ax "$MENTOR_PID" press AXMenuItem "Resume Watching" >>"$RUN_DIR/transcript.log" 2>&1 || true
	"$DRIVE" ax "$MENTOR_PID" cancelmenu >/dev/null 2>&1 || true
	sleep 0.8
	resumed="$(mark_width)"
	"$DRIVE" shot region "$bar_x" "$bar_y" 260 44 "$RUN_DIR/bar-resumed.png" >/dev/null 2>&1 || true
	check "resuming is drawn at the same width again" "$watching" "$resumed"

	# About Mentor, which showed the macOS placeholder while the app had no
	# icon at all. The standard About panel reports no window name, so it is
	# found as the ordinary window that was not there before rather than by
	# its title.
	local before about i
	before="$(ordinary_windows)"
	"$DRIVE" ax "$MENTOR_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.3
	"$DRIVE" ax "$MENTOR_PID" press AXMenuItem "About Mentor" >>"$RUN_DIR/transcript.log" 2>&1 || true
	# The panel is built the first time it is asked for, so wait for it rather
	# than guessing how long that takes.
	for i in $(seq 1 20); do
		about="$(comm -13 <(printf '%s\n' "$before") <(ordinary_windows) | head -1)"
		[ -n "$about" ] && break
		sleep 0.4
	done
	if [ -n "$about" ]; then
		"$DRIVE" shot window "$about" "$RUN_DIR/about-mentor.png" >/dev/null 2>&1 || true
		"$DRIVE" close "$MENTOR_PID" About >/dev/null 2>&1 || true
	fi
	check "About Mentor opened" "yes" "$([ -n "$about" ] && echo yes || echo no)"
	snapshot_state "mark"
	return 0
}
