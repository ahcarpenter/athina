# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The debug panel is something the person enables. While Settings > Advanced >
# Enable debug panel is off, as every install starts, the menu offers no command
# for it and the pane's Open Debug Panel button is dimmed; turned on, the menu
# gains a Debug Panel command in a group of its own after Settings…, as
# Safari's Advanced switch adds its Develop menu, and that command and the
# button both open the panel; turned off again, the panel goes and so does the
# command, with no relaunch.
#
# The switch, the button and the menu item are pressed through accessibility,
# with no pointer, so the run needs no idle input.
SCENARIO_SUMMARY="the debug panel opens from Settings > Advanced and the menu's Debug Panel command only once it is enabled, and closes when it is turned off"
SCENARIO_ARGS=(--open settings:advanced)

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

wait_no_window() {
	local want="$1" limit="${2:-10}" i
	for i in $(seq 1 "$limit"); do
		[ -z "$(window_id "$want")" ] && return 0
		sleep 0.5
	done
	return 1
}

# The menu's item titles, one per line, read with the menu open.
menu_items() {
	local tag="$1"
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 0.8
	"$DRIVE" ax "$ATHINA_PID" menuitems >"$RUN_DIR/$tag-menu-items.txt" 2>&1 || true
	# The open menu is the app's window at the pop-up menu level.
	local menu
	menu="$("$DRIVE" windows "$ATHINA_PID" | awk '/ layer=101 / {sub("id=", "", $1); print $1; exit}')"
	[ -n "$menu" ] && "$DRIVE" shot window "$menu" "$RUN_DIR/$tag-menu.png" >/dev/null 2>&1
	"$DRIVE" ax "$ATHINA_PID" cancelmenu >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.4
}

has_menu_item() {
	grep -qF "title=\"$2\"" "$RUN_DIR/$1-menu-items.txt" && echo yes || echo no
}

# Whether Debug Panel sits in a group of its own right after the group that
# ends with Settings…: Settings…, a separator, Debug Panel, a separator.
own_group_after_settings() {
	awk '
		{ line[NR] = $0 }
		END {
			for (i = 1; i <= NR; i++) if (index(line[i], "title=\"Debug Panel\"")) {
				ok = index(line[i - 2], "title=\"Settings…\"") && line[i - 1] ~ /separator|title=""/ && line[i + 1] ~ /separator|title=""/
				print (ok ? "yes" : "no"); exit
			}
			print "no"
		}' "$RUN_DIR/$1-menu-items.txt"
}

# Whether the Advanced pane's Open Debug Panel button is enabled: yes or no,
# empty when the pane shows no such button.
button_enabled() {
	"$DRIVE" ax "$ATHINA_PID" get AXButton "Open Debug Panel" --scope Advanced 2>>"$RUN_DIR/transcript.log" \
		| awk '{ if (match($0, / en=[01]/)) { print (substr($0, RSTART + 4, 1) == "1" ? "yes" : "no"); exit } }'
}

# A Form's switch carries no name of its own in the accessibility tree (its
# label is the row's text beside it), so it is found as the pane's only one.
switch_on() {
	"$DRIVE" ax "$ATHINA_PID" get AXCheckBox "" --scope Advanced 2>>"$RUN_DIR/transcript.log" \
		| awk '{ if (match($0, /value="[01]"/)) { print (substr($0, RSTART + 7, 1) == "1" ? "yes" : "no"); exit } }'
}

press_switch() {
	"$DRIVE" ax "$ATHINA_PID" press AXCheckBox "" --scope Advanced >>"$RUN_DIR/transcript.log" 2>&1
	sleep 0.8
}

shoot() {
	local title="$1" tag="$2" id
	id="$(window_id "$title")"
	[ -n "$id" ] && "$DRIVE" shot window "$id" "$RUN_DIR/$tag.png" >/dev/null 2>&1
	return 0
}

scenario_run() {
	wait_window "Advanced" 20 || { log "Settings never opened on the Advanced pane"; return 1; }
	"$DRIVE" ax "$ATHINA_PID" dump --scope Advanced >"$RUN_DIR/off-dump.txt" 2>&1 || true
	shoot Advanced off

	menu_items off || { log "the menu bar extra would not open"; return 1; }
	check "the menu was read" "yes" "$(has_menu_item off "Settings…")"
	check "the menu offers no Debug Panel while the switch is off" "no" "$(has_menu_item off "Debug Panel")"
	check "the switch starts off" "no" "$(switch_on)"
	check "Open Debug Panel is dimmed while the switch is off" "no" "$(button_enabled)"
	check "no debug panel is open" "no" "$([ -n "$(window_id "Debug Panel")" ] && echo yes || echo no)"

	press_switch || { log "the Enable debug panel switch would not press"; return 1; }
	shoot Advanced on
	check "the switch turns on" "yes" "$(switch_on)"
	check "Open Debug Panel is live once the switch is on" "yes" "$(button_enabled)"
	menu_items on || { log "the menu bar extra would not open"; return 1; }
	check "the menu offers Debug Panel once the switch is on" "yes" "$(has_menu_item on "Debug Panel")"
	check "Debug Panel is in a group of its own after Settings…" "yes" "$(own_group_after_settings on)"

	# A menu item is only in the tree while the menu is open, so the extra is
	# pressed right before it, and closed again in case the press left it up.
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || { log "the menu bar extra would not open"; return 1; }
	sleep 0.8
	"$DRIVE" ax "$ATHINA_PID" pressx AXMenuItem "Debug Panel" --scope extras >>"$RUN_DIR/transcript.log" 2>&1 \
		|| { log "the menu offered no Debug Panel item to press"; return 1; }
	"$DRIVE" ax "$ATHINA_PID" cancelmenu >>"$RUN_DIR/transcript.log" 2>&1 || true
	wait_window "Debug Panel" 10 || true
	check "the menu's Debug Panel command opens the debug panel" "yes" "$([ -n "$(window_id "Debug Panel")" ] && echo yes || echo no)"
	shoot "Debug Panel" panel-from-menu
	"$DRIVE" close "$ATHINA_PID" "Debug Panel" >>"$RUN_DIR/transcript.log" 2>&1 || true
	wait_no_window "Debug Panel" 10 || { log "the debug panel would not close"; return 1; }

	"$DRIVE" ax "$ATHINA_PID" pressx AXButton "Open Debug Panel" --scope Advanced >>"$RUN_DIR/transcript.log" 2>&1 \
		|| { log "Open Debug Panel would not press"; return 1; }
	wait_window "Debug Panel" 10 || true
	check "Open Debug Panel opens the debug panel" "yes" "$([ -n "$(window_id "Debug Panel")" ] && echo yes || echo no)"
	shoot "Debug Panel" panel

	press_switch || { log "the Enable debug panel switch would not press"; return 1; }
	wait_no_window "Debug Panel" 10 || true
	check "the switch turns off" "no" "$(switch_on)"
	check "turning the switch off closes the debug panel" "no" "$([ -n "$(window_id "Debug Panel")" ] && echo yes || echo no)"
	check "Open Debug Panel is dimmed again" "no" "$(button_enabled)"
	menu_items off-again || { log "the menu bar extra would not open"; return 1; }
	check "turning the switch off takes Debug Panel out of the menu" "no" "$(has_menu_item off-again "Debug Panel")"
	return 0
}
