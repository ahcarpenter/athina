# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# What only macOS's own routing can prove, in one scenario, so the screen is
# held once for all of it rather than once a check:
#
#   1 One toast comes up.
#   2 An accessibility press on the menu bar item, the keyboard and VoiceOver
#     route with no pointer, opens the menu and keeps the toast.
#   3 A real click on the item keeps it too: the system's menu bar window takes
#     that click, and it reaches Athina only through its global monitor, which
#     must tell the item from anywhere else. The menu macOS draws is the one
#     the app built, as the control API reads it.
#   4 Answer Suggestion > Tell Me More, by hovering the submenu open after the
#     system's delay and clicking with the pointer, is recorded.
#   5 On a new suggestion, since the journal keeps only a suggestion's first
#     answer and step 4 gave one, Show Last Suggestion brings the toast
#     forward, and a real click on empty menu bar space dismisses it, which is
#     recorded.
#   6 Show Last Suggestion brings it back, and a real click in a staged TextEdit
#     window, another app's, dismisses it. The suggestion is step 5's, so the
#     journal can only show that the answer already given stays.
#   7 The item keeps one width watching, in the excluded mode, and paused, so no
#     extra to its left moves when the mode changes (HIG: Motion, "generally
#     avoid adding motion to UI interactions that occur frequently"). The width
#     is the one the real bar gave the item, read through accessibility, so a
#     mark variant drawn at another size fails it; the bar-*.png strips are the
#     evidence of what is drawn.
#   8 A real click on each Settings footer link, Contexts to Privacy and Models
#     to Journal, changes the pane in place rather than handing the link to the
#     system. A link inside a Text follows neither accessibility's press nor a
#     click the app simulates in its own window, so only a real click proves it;
#     that each shows as a link is settings-pane-text's, on the API tier.
#
# SCENARIO_IDLE_FIRST has the harness take the screen only once the keyboard
# and mouse have been quiet for 15 seconds, so the steps run straight on: each
# pointer step or change of the front app waits only for a short quiet moment
# after the run's own input, and every click aborts if the pointer is moved off
# its target.
SCENARIO_SUMMARY="what only macOS routing proves, in one scenario: the item keeps the toast on an accessibility press and a real click and draws the menu the app built, Tell Me More by hover, real clicks on empty bar space and in another app dismiss it, the item keeps one width across modes, and Settings footer links change the pane in place"
SCENARIO_CONTROL=yes
SCENARIO_IDLE_FIRST=yes

# The watched app goes in front before Athina starts: the terminal a run is
# started from is excluded, so sensing would capture nothing and the toast
# would wait for the first capture. The excluded app is for step 7.
scenario_stage() {
	stage_text_document || return 1
	stage_excluded_app || return 1
	stage_flip_window
	"$DRIVE" activate "$TEXTEDIT_PID" >>"$RUN_DIR/transcript.log" 2>&1
}

# The run's own pointer moves and key presses count as input too, so a step
# waits only this long after them; longer than that means nobody is at the Mac.
QUIET_MOMENT=2

quiet_moment() { wait_idle_input "$QUIET_MOMENT" 120; }

toast_state() { [ -n "$(toast_window)" ] && echo up || echo gone; }

# The toast can take a moment to go after the click that dismisses it.
toast_gone() {
	local i
	for i in $(seq 1 10); do
		[ -z "$(toast_window)" ] && { echo gone; return 0; }
		sleep 0.2
	done
	echo up
}

# A real click through athina-drive, which aborts before posting anything when
# the pointer is moved off its target (exit 4): someone at the Mac, or the
# system moving it. Nothing was clicked then, so the click is aimed again after
# a quiet moment, three times at most. Any other refusal is final.
real_click() {
	local attempt status
	for attempt in 1 2 3; do
		status=0
		"$DRIVE" click "$@" >>"$RUN_DIR/transcript.log" 2>&1 || status=$?
		[ "$status" = 4 ] || return "$status"
		log "the pointer moved before the click (attempt $attempt); aiming again after a quiet moment"
		quiet_moment || return 1
	done
	return 4
}

mouse_downs() { grep -c 'type=1 ' "$RUN_DIR/session-clicks.log" 2>/dev/null || true; }

# Presses one of the menu's items through accessibility, which chooses it and
# closes the menu.
menu_press() {
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 0.5
	"$DRIVE" ax "$ATHINA_PID" pressx AXMenuItem "$1" --scope extras >>"$RUN_DIR/transcript.log" 2>&1
}

# The menu as the app builds it, from the control API, in the shape `ax menu`
# prints the menu macOS shows.
built_menu() {
	json_eval "$(api menu --field items)" \
		'"\n".join("-" if i["separator"] else i["title"] + "\t" + ("enabled" if i["enabled"] else "dimmed") for i in r)'
}

# --- Steps 5 and 6: Show Last Suggestion, then a real click elsewhere ---------

# Brings the last suggestion forward from the menu, then clicks where $1 says
# (empty-bar, or other-app) and checks the toast went with a real mouse-down.
dismiss_by_click() {
	local where="$1" before target x y frame
	menu_press "Show Last Suggestion" || { log "the menu offered no Show Last Suggestion to press"; return 1; }
	sleep 0.6
	check "Show Last Suggestion brings the toast up" "up" "$(toast_state)"
	snapshot_state "$where-before"
	quiet_moment || return 1
	before="$(mouse_downs)"
	if [ "$where" = empty-bar ]; then
		# Read now: the bar's empty space depends on the front app's menus.
		target="$("$DRIVE" bar | sed -n 's/^empty=//p')"
		[ -n "$target" ] && [ "$target" != none ] || { log "no empty menu bar space to click"; return 1; }
		x="${target%%,*}"
		y="${target##*,}"
		log "empty menu bar space at $x,$y"
		real_click at "$x" "$y" --shot "$RUN_DIR/$where-click.png" \
			|| { log "the click on empty menu bar space was refused or the pointer moved; see transcript.log"; return 1; }
	else
		frame="$("$DRIVE" windows "$TEXTEDIT_PID" | awk '/layer=0/ {print; exit}')"
		[ -n "$frame" ] || { log "TextEdit has no window on screen"; return 1; }
		x=$(($(sed -n 's/.* x=\([0-9-]*\) .*/\1/p' <<<"$frame") + 120))
		y=$(($(sed -n 's/.* y=\([0-9-]*\) .*/\1/p' <<<"$frame") + 120))
		log "clicking inside TextEdit at $x,$y"
		real_click window "$TEXTEDIT_PID" "$x" "$y" --shot "$RUN_DIR/$where-click.png" \
			|| { log "the click in TextEdit was refused or the pointer moved; see transcript.log"; return 1; }
	fi
	check "the toast is gone after the click" "gone" "$(toast_gone)"
	# The session tap ties the dismissal to a real click rather than a timeout.
	check "a real mouse-down was seen" "yes" "$([ "$(mouse_downs)" -gt "$before" ] && echo yes || echo no)"
	snapshot_state "$where-after"
	return 0
}

# --- Step 7: the item's width -------------------------------------------------

# Reads the bar until the item's name says $1, for up to 15 seconds, leaving
# the last report in BAR_REPORT and the item's line in BAR_EXTRA. The bar is
# read once for each look at it, since a read walks every app's menu bar
# extras and takes about two seconds on a busy Mac.
BAR_REPORT=""
BAR_EXTRA=""
read_bar_until() {
	local want="$1" started=$SECONDS
	while :; do
		BAR_REPORT="$("$DRIVE" bar "$ATHINA_PID")"
		BAR_EXTRA="$(grep "^extra .*pid=$ATHINA_PID " <<<"$BAR_REPORT" || true)"
		case "$BAR_EXTRA" in *"title=\""*"$want"*) return 0 ;; esac
		[ $((SECONDS - started)) -lt 15 ] || return 1
		sleep 0.5
	done
}

# Brings $3 (a pid) to the front, runs the command after it if one is given,
# waits for the item's name to say $2, and prints the item's width, keeping a
# strip of the bar as $1. Whoever is at the Mac may bring another app forward
# meanwhile, which changes the mode under the measurement, so the app is
# brought forward again after a quiet moment, three times at most.
measure_bar() {
	local tag="$1" want="$2" front="$3" attempt width x title
	shift 3
	quiet_moment || return 1
	"$DRIVE" activate "$front" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	if [ $# -gt 0 ]; then "$@" >>"$RUN_DIR/transcript.log" 2>&1 || return 1; fi
	for attempt in 1 2 3; do
		read_bar_until "$want" && break
		title="$(sed -n 's/.*title="\([^"]*\)".*/\1/p' <<<"$BAR_EXTRA")"
		[ "$attempt" = 3 ] && { log "the item never said \"$want\" (it says \"$title\")"; return 1; }
		log "the item says \"$title\", not \"$want\"; bringing pid $front forward again after a quiet moment"
		quiet_moment || return 1
		"$DRIVE" activate "$front" >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	done
	printf '=== bar %s at %s\n%s\n' "$tag" "$(date '+%H:%M:%S')" "$BAR_REPORT" >>"$RUN_DIR/transcript.log"
	x="$(sed -n 's/.* x=\([0-9]*\)[0-9.]* .*/\1/p' <<<"$BAR_EXTRA")"
	[ -n "$x" ] && "$DRIVE" shot region "$((x - 160))" 0 420 33 "$RUN_DIR/bar-$tag.png" \
		>>"$RUN_DIR/transcript.log" 2>&1
	width="$(sed -n 's/.* w=\([0-9.]*\) .*/\1/p' <<<"$BAR_EXTRA")"
	[ -n "$width" ] || {
		log "the bar report had no width for Athina's item at the $tag measurement"
		return 1
	}
	printf '%s\n' "$width"
}

# --- Step 8: the Settings footer links ----------------------------------------

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

# The title of the Settings window now open, whichever pane it shows, or
# nothing: the window takes its title from its pane.
SETTINGS_PANES="General Contexts Models Capture Journal Privacy Advanced"
settings_window() {
	local pane
	for pane in $SETTINGS_PANES; do
		[ -n "$(window_id "$pane")" ] && { echo "$pane"; return 0; }
	done
	return 1
}

# Opens Settings from the menu and brings it to the pane titled $1 with a real
# click on that pane's toolbar tab, as a person would. Settings opens on the
# pane it last showed, which the app keeps to itself once it is running, so the
# pane is chosen in the window rather than in the preferences beforehand.
open_settings_on() {
	local pane="$1" shown="" tab="" i
	menu_press "Settings…" || { log "the menu offered no Settings… item to press"; return 1; }
	for i in $(seq 1 40); do
		shown="$(settings_window)" && break
		sleep 0.5
	done
	[ -n "$shown" ] || { log "Settings never opened"; return 1; }
	[ "$shown" = "$pane" ] && return 0
	"$DRIVE" ax "$ATHINA_PID" dump --scope "$shown" >"$RUN_DIR/tabs-$pane-dump.txt" 2>&1 || true
	tab="$(element_centre "tabs-$pane-dump.txt" AXButton "$pane")"
	[ -n "$tab" ] || { log "the $shown window showed no $pane tab to click"; return 1; }
	quiet_moment || return 1
	"$DRIVE" raise "$ATHINA_PID" "$shown" >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5
	# shellcheck disable=SC2086
	real_click window "$ATHINA_PID" $tab --shot "$RUN_DIR/tabs-$pane-click.png" \
		|| { log "the click on the $pane tab would not land"; return 1; }
	wait_window "$pane" 10 || { log "Settings never showed the $pane pane"; return 1; }
}

# Click the link named $2 in the Settings pane titled $1, and check the window
# changes to the pane titled $3.
follow_link() {
	local pane="$1" name="$2" target="$3" tag="$4" link="" id
	link="$(locate_link "$pane" "$name" "$tag")"
	id="$(window_id "$pane")"
	[ -n "$id" ] && "$DRIVE" shot window "$id" "$RUN_DIR/$tag-before.png" >/dev/null 2>&1
	check "the $pane footer shows $name as a link" "yes" "$([ -n "$link" ] && echo yes || echo no)"
	[ -n "$link" ] || { log "the $pane footer showed no $name link to aim at"; return 1; }
	quiet_moment || return 1
	# A click into a window that is not key only makes it key, so the Settings
	# window is brought forward before the pointer aims at anything inside it.
	"$DRIVE" raise "$ATHINA_PID" "$pane" >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5
	# Found again just before the pointer aims at it: raising the window can
	# move it, and the pane can lay out again meanwhile.
	link="$(locate_link "$pane" "$name" "$tag-aim")"
	# shellcheck disable=SC2086
	{ [ -n "$link" ] && inside_window "$tag-aim-dump.txt" $link; } \
		|| { log "the $name link left the $pane window before the click"; return 1; }
	# shellcheck disable=SC2086
	real_click window "$ATHINA_PID" $link --shot "$RUN_DIR/$tag-click.png" \
		|| { log "the click on the $name link would not land"; return 1; }
	wait_window "$target" 6 || true
	check "$name opens the $target pane" "yes" "$([ -n "$(window_id "$target")" ] && echo yes || echo no)"
	check "$name changes the pane in place" "no" "$([ -n "$(window_id "$pane")" ] && echo yes || echo no)"
	id="$(window_id "$target")"
	[ -n "$id" ] && "$DRIVE" shot window "$id" "$RUN_DIR/$tag-after.png" >/dev/null 2>&1
	"$DRIVE" close "$ATHINA_PID" "$target" >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5
	return 0
}

scenario_run() {
	local suggestion before built watching excluded again paused resumed

	step "1 one toast"
	wait_toast >/dev/null || return 1
	# A click by whoever is at the Mac dismisses the toast; brought back if so.
	keep_toast_up || return 1
	suggestion="$(newest_suggestion_id)"
	snapshot_state "toast"
	check "a toast is up for an unanswered suggestion" "none" "$(suggestion_feedback "$suggestion")"

	step "2 an accessibility press on the item keeps the toast"
	before="$(mouse_downs)"
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || { log "the item would not take an accessibility press"; return 1; }
	sleep 0.8
	snapshot_state "after-accessibility-press"
	check "the toast is still up" "up" "$(toast_state)"
	check "the suggestion is not answered by the press" "none" "$(suggestion_feedback "$suggestion")"
	check "the press is no mouse-down" "$before" "$(mouse_downs)"
	"$DRIVE" ax "$ATHINA_PID" cancelmenu >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.4

	step "3 a real click on the item keeps the toast, and macOS draws the menu the app built"
	quiet_moment || return 1
	keep_toast_up || return 1
	suggestion="$(newest_suggestion_id)"
	# Read just before the click, in the state the click finds.
	[ -n "$CONTROL_DIR" ] && built="$(built_menu)" && printf '%s\n' "$built" >"$RUN_DIR/menu-built.txt"
	before="$(mouse_downs)"
	real_click item "$ATHINA_PID" --shot "$RUN_DIR/item-click.png" \
		|| { log "the click on the item was refused or the pointer moved; see transcript.log"; return 1; }
	sleep 0.4
	snapshot_state "after-item-click"
	check "the toast is still up" "up" "$(toast_state)"
	check "the suggestion is not answered by the click" "none" "$(suggestion_feedback "$suggestion")"
	check "a real mouse-down was seen" "yes" "$([ "$(mouse_downs)" -gt "$before" ] && echo yes || echo no)"
	"$DRIVE" ax "$ATHINA_PID" menu >"$RUN_DIR/menu-drawn.txt" 2>>"$RUN_DIR/transcript.log"
	check "the click opens the menu" "yes" "$(grep -q '^Answer Suggestion' "$RUN_DIR/menu-drawn.txt" && echo yes || echo no)"
	if [ -n "$CONTROL_DIR" ]; then
		diff "$RUN_DIR/menu-built.txt" "$RUN_DIR/menu-drawn.txt" >"$RUN_DIR/menu-diff.txt" 2>&1 || true
		check "the menu macOS draws is the one the app built" "same" \
			"$([ -s "$RUN_DIR/menu-built.txt" ] && [ ! -s "$RUN_DIR/menu-diff.txt" ] && echo same || echo "different, see menu-diff.txt")"
	else
		log "not compared with the menu the app built: $APP carries no control API"
	fi

	step "4 Tell Me More by hover is recorded"
	quiet_moment || return 1
	"$DRIVE" menupick "$ATHINA_PID" "Answer Suggestion" "Tell Me More" >>"$RUN_DIR/transcript.log" 2>&1 \
		|| { log "could not reach Tell Me More; see transcript.log"; return 1; }
	sleep 1.2
	snapshot_state "after-tell-me-more"
	check "feedback recorded" "tellMeMore" "$(suggestion_feedback "$suggestion")"
	check "the toast was announced" "yes" "$(grep -q 'Athina suggestion' "$RUN_DIR/announcements.log" 2>/dev/null && echo yes || echo no)"

	step "5 a real click on empty menu bar space dismisses a new toast, and that is recorded"
	relaunch_athina
	wait_toast >/dev/null || return 1
	keep_toast_up || return 1
	suggestion="$(newest_suggestion_id)"
	check "a new toast is up for an unanswered suggestion" "none" "$(suggestion_feedback "$suggestion")"
	dismiss_by_click empty-bar || return 1
	check "feedback recorded" "dismissed" "$(suggestion_feedback "$suggestion")"

	step "6 a real click in another app's window dismisses the toast"
	dismiss_by_click other-app || return 1
	check "the answer already given stays" "dismissed" "$(suggestion_feedback "$suggestion")"

	step "7 the item keeps one width watching, excluded and paused"
	watching="$(measure_bar watching "Watching TextEdit" "$TEXTEDIT_PID")" || return 1
	excluded="$(measure_bar excluded "Not watching Calculator" "$EXCLUDED_PID")" || return 1
	again="$(measure_bar watching-again "Watching TextEdit" "$TEXTEDIT_PID")" || return 1
	paused="$(measure_bar paused "Paused" "$TEXTEDIT_PID" menu_press "Pause Watching")" || return 1
	resumed="$(measure_bar resumed "Watching TextEdit" "$TEXTEDIT_PID" menu_press "Resume Watching")" || return 1
	# The width, never the neighbours' positions: in a right-anchored bar the
	# clock ticking past the hour moves those exactly as Athina widening would.
	check "the item is the same width excluded" "$watching" "$excluded"
	check "the item is the same width watching again" "$watching" "$again"
	check "the item is the same width paused" "$watching" "$paused"
	check "the item is the same width resumed" "$watching" "$resumed"
	log "item $watching pt watching, $excluded excluded, $again watching again, $paused paused, $resumed resumed"

	step "8 a real click on each Settings footer link changes the pane in place"
	open_settings_on Contexts contexts || return 1
	follow_link Contexts "Privacy settings" Privacy contexts || return 1
	open_settings_on Models models || return 1
	follow_link Models "Journal settings" Journal models || return 1
	return 0
}
