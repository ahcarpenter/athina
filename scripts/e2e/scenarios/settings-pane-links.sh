# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# Settings text names another pane by linking to it: the Contexts footer to
# Privacy, and the Understanding footer in Models to Journal. A click on each
# link has to change the Settings window's pane in place rather than hand the
# link to the system, which knows no app for it and opens nothing.
#
# A link inside a Text follows neither accessibility's press nor a click the
# app simulates in its own window, so this stays on the real-screen tier: each
# click is a real pointer click at the link's place in the live accessibility
# tree. That the links show as links rather than Markdown is checked on the API
# tier, by settings-pane-text.
SCENARIO_SUMMARY="a link in one Settings pane's text opens the pane it names, in place"
SCENARIO_ARGS=(--open settings:contexts)

wait_window() {
	local want="$1" limit="${2:-10}" i
	for i in $(seq 1 "$limit"); do
		[ -n "$(window_id "$want")" ] && return 0
		sleep 0.5
	done
	return 1
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

# Whether the point $2,$3 is inside the window a dump is of, the dump's first line.
inside_window() {
	awk -v x="$2" -v y="$3" '
		NR == 1 && match($0, /pos=\(-?[0-9]+,-?[0-9]+\) size=[0-9]+x[0-9]+/) {
			split(substr($0, RSTART, RLENGTH), a, /[(,)x= ]+/)
			found = 1
			exit !(x >= a[2] && x < a[2] + a[5] && y >= a[3] && y < a[3] + a[6])
		}
		END { if (!found) exit 1 }
	' "$RUN_DIR/$1"
}

# The centre of the link named $2 in the Settings pane titled $1, dumping the
# pane to $3-dump.txt: "<x> <y>", empty when the pane shows no such link. The
# footer sits below the fold on a short screen, and a pane that has only just
# opened can refuse the scroll until it is laid out, so the pane is scrolled
# to the end until the link is inside the window.
locate_link() {
	local pane="$1" name="$2" tag="$3" link="" attempt
	for attempt in 1 2 3 4 5; do
		"$DRIVE" ax "$ATHINA_PID" set AXScrollBar "" 1 --scope "$pane" >>"$RUN_DIR/transcript.log" 2>&1 || true
		sleep 0.6
		"$DRIVE" ax "$ATHINA_PID" dump --scope "$pane" >"$RUN_DIR/$tag-dump.txt" 2>&1 || true
		link="$(element_centre "$tag-dump.txt" AXLink "$name")"
		# shellcheck disable=SC2086
		[ -n "$link" ] && inside_window "$tag-dump.txt" $link && break
		log "the $name link is not inside the $pane window yet (attempt $attempt)"
	done
	echo "$link"
}

# Click the link named $2 in the Settings pane titled $1, and check the window
# changes to the pane titled $3.
follow_link() {
	local pane="$1" name="$2" target="$3" tag="$4" link="" id
	link="$(locate_link "$pane" "$name" "$tag")"
	"$DRIVE" ax "$ATHINA_PID" texts --scope "$pane" >"$RUN_DIR/$tag-texts.txt" 2>&1 || true
	id="$(window_id "$pane")"
	[ -n "$id" ] && "$DRIVE" shot window "$id" "$RUN_DIR/$tag-before.png" >/dev/null 2>&1
	check "the $pane footer shows $name as a link" "yes" "$([ -n "$link" ] && echo yes || echo no)"
	[ -n "$link" ] || { log "the $pane footer showed no $name link to aim at"; return 1; }
	# shellcheck disable=SC2086
	inside_window "$tag-dump.txt" $link || { log "the $name link never scrolled into the $pane window"; return 1; }
	wait_idle_input || return 1
	# A click into a window that is not key only makes it key, so the Settings
	# window is brought forward before the pointer aims at anything inside it.
	"$DRIVE" raise "$ATHINA_PID" "$pane" >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5
	# The wait for idle input can last minutes, and the pane can move under
	# the link meanwhile: a replayed mentor call writes the understanding the
	# Models pane shows above its footer. So the link is found again just
	# before the pointer aims at it.
	link="$(locate_link "$pane" "$name" "$tag-aim")"
	# shellcheck disable=SC2086
	{ [ -n "$link" ] && inside_window "$tag-aim-dump.txt" $link; } \
		|| { log "the $name link left the $pane window before the click"; return 1; }
	# shellcheck disable=SC2086
	"$DRIVE" click window "$ATHINA_PID" $link --shot "$RUN_DIR/$tag-click.png" >>"$RUN_DIR/transcript.log" 2>&1 \
		|| { log "the click on the $name link would not land"; return 1; }
	wait_window "$target" 6 || true
	check "$name opens the $target pane" "yes" "$([ -n "$(window_id "$target")" ] && echo yes || echo no)"
	check "$name changes the pane in place" "no" "$([ -n "$(window_id "$pane")" ] && echo yes || echo no)"
	id="$(window_id "$target")"
	[ -n "$id" ] && "$DRIVE" shot window "$id" "$RUN_DIR/$tag-after.png" >/dev/null 2>&1
	return 0
}

scenario_run() {
	wait_window "Contexts" 20 || { log "Settings never opened on the Contexts pane"; return 1; }
	follow_link Contexts "Privacy settings" Privacy contexts || return 1
	"$DRIVE" close "$ATHINA_PID" Privacy >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5

	# Settings opens on the pane it last showed, and accessibility offers no
	# way to change panes, so the pane is chosen before the window opens. The
	# harness puts the owner's preferences back whatever happens.
	defaults write "$PREFS_DOMAIN" SettingsPane models >>"$RUN_DIR/transcript.log" 2>&1 || true
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || { log "the menu bar extra would not open"; return 1; }
	sleep 0.8
	"$DRIVE" ax "$ATHINA_PID" pressx AXMenuItem "Settings…" --scope extras >>"$RUN_DIR/transcript.log" 2>&1 \
		|| { log "the menu offered no Settings… item to press"; return 1; }
	"$DRIVE" ax "$ATHINA_PID" cancelmenu >>"$RUN_DIR/transcript.log" 2>&1 || true
	wait_window "Models" || { log "Settings never opened on the Models pane"; return 1; }
	follow_link Models "Journal settings" Journal models || return 1
	"$DRIVE" close "$ATHINA_PID" Journal >>"$RUN_DIR/transcript.log" 2>&1 || true
	return 0
}
