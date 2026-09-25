# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# About Athina, from the menu, opens the standard About panel, which showed the
# macOS placeholder while the app had no icon at all. Athina has no app menu,
# so its own menu carries About. The panel reports no title of its own, so it
# is found as the window that was not open before.
#
# On the API tier: the menu item is chosen through its own action, as the open
# menu chooses it. That the mark keeps one width in the real menu bar is
# real-screen's, on the real screen.
SCENARIO_SUMMARY="About Athina, from the menu, opens the About panel"
SCENARIO_TIER=api

window_numbers() { json_eval "$(api windows)" '"\n".join(str(int(w["number"])) for w in r["windows"])' | sort -u; }

scenario_run() {
	local before about="" i
	before="$(window_numbers)"
	check "the menu's About Athina is chosen" "true" "$(api menu press="About Athina" --field ok)"
	# The panel is built the first time it is asked for, so wait for it rather
	# than guessing how long that takes.
	for i in $(seq 1 20); do
		about="$(comm -13 <(printf '%s\n' "$before") <(window_numbers) | head -1)"
		[ -n "$about" ] && break
		sleep 0.2
	done
	check "About Athina opens a window" "yes" "$([ -n "$about" ] && echo yes || echo no)"
	[ -n "$about" ] || return 0
	json_eval "$(api windows)" '[w for w in r["windows"] if int(w["number"]) == int(a[0])]' "$about" >>"$RUN_DIR/api.log"
	check "the panel shows the app's name" "yes" \
		"$(json_eval "$(api find role=AXStaticText)" '"yes" if any("Athina" in (e["label"], e["title"], e["value"]) for e in r["elements"]) else "no"')"
	return 0
}
