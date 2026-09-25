# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The suggestion toast never takes keyboard focus, so the menu offers its
# answers too, where the keyboard and VoiceOver reach them: Answer Suggestion
# holds them, live while a suggestion is up and dimmed otherwise. Tell Me More
# from there opens the toast's explanation and keeps it up, and Not Now
# answers it and takes it down.
#
# On the API tier, with the toast brought up by scripted sensing (README
# "Scripted sensing") and each answer chosen through the handler the menu runs.
# That an accessibility press on the menu bar item opens the menu and keeps
# the toast up is macOS's routing, which the real-screen tier proves.
SCENARIO_SUMMARY="a suggestion is answered from the menu with no pointer: Answer Suggestion is live while it is up, Tell Me More keeps it up, and Not Now is recorded and takes it down"
SCENARIO_TIER=api

# The Answer Suggestion submenu's items as "title=enabled", one per line.
answers() {
	json_eval "$(api menu --field items)" \
		'"\n".join(c["title"] + "=" + str(c["enabled"]).lower() for i in r if i["title"] == "Answer Suggestion" for c in i.get("items", []) if not c["separator"])'
}

answer_enabled() { answers | sed -n "s/^$1=//p"; }

toast_up() { api wait-window window="Athina suggestion" present="$1" timeout=5 >/dev/null && echo yes || echo no; }

checkpoint() { api snapshot window="$1" path="$RUN_DIR/$2.png" >/dev/null || log "no checkpoint of $1"; }

scenario_run() {
	scripted_toast || return 1
	local suggestion="$SUGGESTION_ID"
	checkpoint "Athina suggestion" toast
	answers >"$RUN_DIR/answers-up.txt"
	check "the menu offers Tell Me More while the suggestion is up" "true" "$(answer_enabled "Tell Me More")"
	check "the menu offers Not Now while the suggestion is up" "true" "$(answer_enabled "Not Now")"
	check "the menu offers Never for This while the suggestion is up" "true" "$(answer_enabled "Never for This")"
	check "the menu offers Close Suggestion while the suggestion is up" "true" "$(answer_enabled "Close Suggestion")"

	check "Tell Me More is chosen from the menu" "true" \
		"$(api menu press="Answer Suggestion > Tell Me More" --field ok)"
	check "Tell Me More is recorded" "tellMeMore" \
		"$(api wait-event name=feedback id="$suggestion" feedback=tellMeMore --field event.feedback)"
	check "the toast stays up after Tell Me More" "yes" "$(toast_up true)"
	check "the toast shows its explanation" "Show Less" \
		"$(api find window="Athina suggestion" identifier=toast.tellMeMore --field elements.0.label)"
	checkpoint "Athina suggestion" toast-told-more

	check "Not Now is chosen from the menu" "true" "$(api menu press="Answer Suggestion > Not Now" --field ok)"
	check "Not Now is recorded" "notNow" \
		"$(api wait-event name=feedback id="$suggestion" feedback=notNow --field event.feedback)"
	check "the toast goes after Not Now" "yes" "$(toast_up false)"
	check "the journal holds Not Now" "notNow" "$(api_feedback "$suggestion")"
	answers >"$RUN_DIR/answers-after.txt"
	check "the menu's answers are dimmed once none is up" "false" "$(answer_enabled "Not Now")"
	check "an answer from the menu with none up is refused" "disabled" \
		"$(api menu press="Answer Suggestion > Never for This" --field refused)"
	return 0
}
