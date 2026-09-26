# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The keyboard shortcut recorders in Settings (README "Keyboard shortcuts"):
# Settings > General's talk-back recorder takes a combination pressed while it
# records into the settings, refuses the pause shortcut's combination with an
# alert that says why, keeping what it had, and clears on Delete; Settings >
# Privacy's pause recorder keeps its combination on Delete, since the pause
# shortcut is always set.
#
# On the API tier: every click is simulated inside Athina, through AppKit's own
# event path, and every key press is posted to its event queue (`key`), where
# the recorder's own event monitor takes it as it takes a person's. A hermetic
# run registers no shortcut with the system, so what a press of one does
# outside the recorder is not this scenario's to prove.
SCENARIO_SUMMARY="the Settings shortcut recorders record, refuse the other shortcut with an alert, and clear on Delete, the pause shortcut excepted"
SCENARIO_ARGS=(--open settings:general)
SCENARIO_TIER=api

# Virtual key codes: T, P, Delete, Escape.
KEY_T=17
KEY_P=35
KEY_DELETE=51
KEY_ESCAPE=53
CONTROL_OPTION_COMMAND=control,option,command
# Control-Option-Command-T and -P as settings.json holds them.
TALK_BACK='{"keyCode": 17, "modifiers": 11}'
PAUSE='{"keyCode": 35, "modifiers": 11}'

field() { api find window="$1" identifier="$2" --field elements.0.value; }
talk_back_field() { field General voice.talkBackShortcut; }
pause_field() { field Privacy privacy.pauseShortcut; }
sheet_count() { json_eval "$(api find window=General role=AXSheet)" 'len(r["elements"])'; }
setting() { json_eval "$(api settings key="$1")" 'json.dumps(r["value"], sort_keys=True)'; }

scenario_run() {
	api wait-window window=General timeout=20 >/dev/null || { log "Settings never opened on the General pane"; return 1; }

	step "1 the talk-back recorder records a combination"
	check "the talk-back shortcut starts unset" "null" "$(setting mentor.pushToTalkHotKey)"
	check "a click on the talk-back recorder lands" "true" \
		"$(api click window=General identifier=voice.talkBackShortcut --field ok)"
	check "Control-Option-Command-T is pressed" "true" \
		"$(api key window=General code=$KEY_T modifiers=$CONTROL_OPTION_COMMAND --field dispatched)"
	check "the settings hold it" "true" \
		"$(api wait-setting key=mentor.pushToTalkHotKey equals="$TALK_BACK" timeout=5 --field ok)"
	check "the recorder shows it" "⌃⌥⌘T" "$(settled "⌃⌥⌘T" talk_back_field)"

	step "2 the pause shortcut's combination is refused with an alert"
	check "a click on the talk-back recorder lands" "true" \
		"$(api click window=General identifier=voice.talkBackShortcut --field ok)"
	api key window=General code=$KEY_P modifiers=$CONTROL_OPTION_COMMAND >/dev/null
	check "an alert comes up over the pane" "1" "$(settled 1 sheet_count)"
	check "the alert says the pause shortcut has it" "True" \
		"$(json_eval "$(api find window=General role=AXStaticText)" \
			'any(e["value"] == "This keyboard shortcut is already the pause shortcut." for e in r["elements"])')"
	checkpoint General talk-back-refused
	check "a click on the alert's OK lands" "true" "$(api click window=General role=AXButton label=OK --field ok)"
	check "the alert goes" "0" "$(settled 0 sheet_count)"
	check "the settings keep the talk-back shortcut" "$TALK_BACK" "$(setting mentor.pushToTalkHotKey)"
	check "the recorder still shows it" "⌃⌥⌘T" "$(talk_back_field)"

	step "3 Delete clears the talk-back shortcut"
	check "a click on the talk-back recorder lands" "true" \
		"$(api click window=General identifier=voice.talkBackShortcut --field ok)"
	check "Delete is pressed" "true" "$(api key window=General code=$KEY_DELETE --field dispatched)"
	check "the settings hold no talk-back shortcut" "true" \
		"$(api wait-setting key=mentor.pushToTalkHotKey equals=null timeout=5 --field ok)"
	check "the recorder is empty" "" "$(settled "" talk_back_field)"
	api key window=General code=$KEY_ESCAPE >/dev/null

	step "4 the pause shortcut stays set"
	check "a click on the Privacy toolbar item lands" "true" "$(api click window=General label=Privacy --field ok)"
	api wait-window window=Privacy timeout=5 >/dev/null || { log "the Privacy pane never opened"; return 1; }
	check "the pause recorder shows its combination" "⌃⌥⌘P" "$(settled "⌃⌥⌘P" pause_field)"
	check "a click on the pause recorder lands" "true" \
		"$(api click window=Privacy identifier=privacy.pauseShortcut --field ok)"
	check "Delete is pressed" "true" "$(api key window=Privacy code=$KEY_DELETE --field dispatched)"
	check "the recorder keeps the combination" "⌃⌥⌘P" "$(settled "⌃⌥⌘P" pause_field)"
	check "the settings keep the pause shortcut" "$PAUSE" "$(setting pauseHotKey)"
	api key window=Privacy code=$KEY_ESCAPE >/dev/null
	return 0
}
