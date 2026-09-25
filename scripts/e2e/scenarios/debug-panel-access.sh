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
# On the API tier: every click is simulated inside Athina, through AppKit's own
# event path, on the control its own accessibility tree names, so a click that
# lands proves the control is hit-testable and wired; a click on the dimmed
# button is refused, and one forced onto it does nothing. The menu is read and
# its command chosen through the menu's own action; that macOS draws and opens
# it is the real-screen tier's to prove.
SCENARIO_SUMMARY="the debug panel opens from Settings > Advanced and the menu's Debug Panel command only once it is enabled, and closes when it is turned off"
SCENARIO_ARGS=(--open settings:advanced)
SCENARIO_TIER=api

switch_value() { api find window=Advanced identifier=advanced.enableDebugPanel --field elements.0.value; }
button_enabled() { api find window=Advanced identifier=advanced.openDebugPanel --field elements.0.enabled; }
panel_open() { api wait-window window="Debug Panel" timeout="${1:-5}" >/dev/null && echo yes || echo no; }
panel_gone() { api wait-window window="Debug Panel" present=false timeout=5 >/dev/null && echo yes || echo no; }

# The menu's titles, one per line, a separator as "-", as the app builds it.
menu_titles() {
	json_eval "$(api menu --field items)" '"\n".join("-" if i["separator"] else i["title"] for i in r)' >"$RUN_DIR/$1-menu-items.txt"
}

has_menu_item() { grep -qxF "$2" "$RUN_DIR/$1-menu-items.txt" && echo yes || echo no; }

# Whether Debug Panel sits in a group of its own right after the group that
# ends with Settings…: Settings…, a separator, Debug Panel, a separator.
own_group_after_settings() {
	awk '{ line[NR] = $0 } END {
		for (i = 1; i <= NR; i++) if (line[i] == "Debug Panel") {
			print ((line[i - 2] == "Settings…" && line[i - 1] == "-" && line[i + 1] == "-") ? "yes" : "no"); exit
		}
		print "no"
	}' "$RUN_DIR/$1-menu-items.txt"
}

checkpoint() { api snapshot window="$1" path="$RUN_DIR/$2.png" >/dev/null || log "no checkpoint of $1"; }

scenario_run() {
	api wait-window window=Advanced timeout=20 >/dev/null || { log "Settings never opened on the Advanced pane"; return 1; }
	checkpoint Advanced off
	menu_titles off
	check "the menu was read" "yes" "$(has_menu_item off "Settings…")"
	check "the menu offers no Debug Panel while the switch is off" "no" "$(has_menu_item off "Debug Panel")"
	check "the switch starts off" "0" "$(switch_value)"
	check "Open Debug Panel is dimmed while the switch is off" "false" "$(button_enabled)"
	check "no debug panel is open" "yes" "$(api wait-window window="Debug Panel" present=false timeout=0 >/dev/null && echo yes || echo no)"

	# Refused while dimmed, and forced through AppKit anyway it does nothing:
	# the event path itself honours the disabled state.
	check "a click on the dimmed button is refused" "disabled" \
		"$(api click window=Advanced identifier=advanced.openDebugPanel --field refused)"
	api click window=Advanced identifier=advanced.openDebugPanel force=true >/dev/null
	check "a click forced onto the dimmed button opens nothing" "no" "$(panel_open 1)"

	check "the click on the switch lands" "true" "$(api click window=Advanced identifier=advanced.enableDebugPanel --field ok)"
	check "the setting follows the switch" "true" "$(api wait-setting key=showDebugPanel equals=true --field ok)"
	check "the switch turns on" "1" "$(settled 1 switch_value)"
	check "Open Debug Panel is live once the switch is on" "true" "$(settled true button_enabled)"
	checkpoint Advanced on
	menu_titles on
	check "the menu was read with the switch on" "yes" "$(has_menu_item on "Settings…")"
	check "the menu offers Debug Panel once the switch is on" "yes" "$(has_menu_item on "Debug Panel")"
	check "Debug Panel is in a group of its own after Settings…" "yes" "$(own_group_after_settings on)"

	api menu press="Debug Panel" >/dev/null
	check "the menu's Debug Panel command opens the debug panel" "yes" "$(panel_open)"
	checkpoint "Debug Panel" panel-from-menu
	check "the panel's close button closes it" "true" "$(api click window="Debug Panel" subrole=AXCloseButton --field ok)"
	[ "$(panel_gone)" = yes ] || { log "the debug panel would not close"; return 1; }

	check "the click on Open Debug Panel lands" "true" "$(api click window=Advanced identifier=advanced.openDebugPanel --field ok)"
	check "Open Debug Panel opens the debug panel" "yes" "$(panel_open)"
	checkpoint "Debug Panel" panel

	api click window=Advanced identifier=advanced.enableDebugPanel >/dev/null
	check "the setting follows the switch off" "true" "$(api wait-setting key=showDebugPanel equals=false --field ok)"
	check "the switch turns off" "0" "$(settled 0 switch_value)"
	check "turning the switch off closes the debug panel" "yes" "$(panel_gone)"
	check "Open Debug Panel is dimmed again" "false" "$(settled false button_enabled)"
	menu_titles off-again
	check "the menu was read with the switch off again" "yes" "$(has_menu_item off-again "Settings…")"
	check "turning the switch off takes Debug Panel out of the menu" "no" "$(has_menu_item off-again "Debug Panel")"
	return 0
}
