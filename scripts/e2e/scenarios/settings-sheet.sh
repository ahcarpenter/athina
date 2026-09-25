# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# A sheet is a window of its own, attached to the window it covers, though it
# shows in that window's accessibility tree. Settings > Contexts' Add Context…
# brings up the New Context sheet: while it is up, a click on Add Context…
# under it is refused as covered, and the sheet's own Cancel is clicked in the
# sheet and takes it down, after which Add Context… is in reach again.
#
# On the API tier: every click is simulated inside Athina, through AppKit's own
# event path, on the control its own accessibility tree names.
SCENARIO_SUMMARY="a control inside a Settings sheet is clicked in the sheet, and one under the sheet is refused as covered while it is up"
SCENARIO_ARGS=(--open settings:contexts)
SCENARIO_TIER=api

sheet_count() { json_eval "$(api find window=Contexts role=AXSheet)" 'len(r["elements"])'; }

checkpoint() { api snapshot window="$1" path="$RUN_DIR/$2.png" >/dev/null || log "no checkpoint of $1"; }

scenario_run() {
	api wait-window window=Contexts timeout=20 >/dev/null || { log "Settings never opened on the Contexts pane"; return 1; }
	check "no sheet is up at first" "0" "$(sheet_count)"
	check "a click on Add Context… lands" "true" "$(api click window=Contexts identifier=contexts.addContext --field ok)"
	check "the New Context sheet comes up" "1" "$(settled 1 sheet_count)"
	checkpoint Contexts sheet-up

	check "with the sheet up, a click on Add Context… under it is refused" "covered" \
		"$(api click window=Contexts identifier=contexts.addContext --field refused)"
	check "a click on the sheet's own Cancel lands" "true" \
		"$(api click window=Contexts identifier=contextEditor.cancel --field ok)"
	check "the sheet goes" "0" "$(settled 0 sheet_count)"
	check "with the sheet gone, a click on Add Context… lands again" "true" \
		"$(api click window=Contexts identifier=contexts.addContext --field ok)"
	check "the New Context sheet comes up again" "1" "$(settled 1 sheet_count)"
	return 0
}
