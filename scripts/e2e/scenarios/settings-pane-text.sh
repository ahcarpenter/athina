# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# Settings text names another pane by linking to it: the Contexts footer to
# Privacy, and the Understanding footer in Models to Journal. Each link has to
# show as a link, to the pane it names, rather than as the Markdown it is built
# from. The Models footer sits below the fold, so a click on its link is
# refused as out of sight until the pane is scrolled to it.
#
# On the API tier, reading each pane through Athina's own accessibility tree
# and changing panes with a click the app simulates on its own toolbar. Whether
# a click on a link opens its pane is settings-pane-links', on the real screen.
SCENARIO_SUMMARY="every link from one Settings pane's text to another shows as a link rather than Markdown, and one below the fold is out of reach until scrolled to"
SCENARIO_ARGS=(--open settings:contexts)
SCENARIO_TIER=api

# Everything a pane shows, one line per element: labels, titles and values.
pane_texts() {
	json_eval "$(api find window="$1")" '"\n".join(t for e in r["elements"] for t in (e["label"], e["title"], e["value"]) if t)' \
		>"$RUN_DIR/$2-texts.txt"
}

has_text() { grep -qF "$2" "$RUN_DIR/$1-texts.txt" && echo yes || echo no; }

# The link named $2 in the pane titled $1, as one field of it.
link_field() { api find window="$1" role=AXLink label="$2" --field "elements.0.$3"; }

checkpoint() { api snapshot window="$1" path="$RUN_DIR/$2.png" >/dev/null || log "no checkpoint of $1"; }

scenario_run() {
	api wait-window window=Contexts timeout=20 >/dev/null || { log "Settings never opened on the Contexts pane"; return 1; }
	pane_texts Contexts contexts
	checkpoint Contexts contexts
	# Markdown that did not parse would show its brackets and the scheme.
	check "the Contexts footer shows no raw link Markdown" "no" "$(has_text contexts "](athina-settings:")"
	check "the Contexts footer shows Privacy settings as a link" "athina-settings:privacy" "$(link_field Contexts "Privacy settings" identifier)"

	# Settings opens on the pane it last showed; the toolbar changes it.
	check "a click on the Models toolbar item lands" "true" "$(api click window=Contexts label=Models --field ok)"
	api wait-window window=Models timeout=5 >/dev/null || { log "the Models pane never showed"; return 1; }
	pane_texts Models models
	check "the Models footer shows no raw link Markdown" "no" "$(has_text models "](athina-settings:")"
	check "the Models footer shows Journal settings as a link" "athina-settings:journal" "$(link_field Models "Journal settings" identifier)"

	check "a click on the link below the fold is refused" "offscreen" \
		"$(api click window=Models role=AXLink label="Journal settings" dry=true --field refused)"
	check "the pane scrolls to the link" "true" "$(api scroll window=Models role=AXLink label="Journal settings" --field ok)"
	check "scrolled into view, a click on the link would land" "true" \
		"$(api click window=Models role=AXLink label="Journal settings" dry=true --field ok)"
	checkpoint Models models-footer
	return 0
}
