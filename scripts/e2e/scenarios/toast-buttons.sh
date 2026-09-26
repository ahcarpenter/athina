# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The suggestion toast's own buttons. Tell Me More opens the explanation and
# is recorded once, however often the toast is folded and opened again; Show
# Less folds it and keeps it up; Close takes it down and, once the suggestion
# is answered, records nothing over the answer. Show Last Suggestion brings it
# back, Not Now answers it and snoozes the kind of suggestion in that app,
# Never for This answers it and stops that kind there, and a click outside
# Athina's windows takes it down.
#
# On the API tier: each button is clicked through AppKit's own event path in
# the toast's panel, parked below the desktop picture, so a click that lands
# proves the button can be hit and is wired. The toast comes from scripted
# sensing (docs/e2e.md "Scripted sensing"); that a real click in another app
# reaches it is the real-screen tier's to prove.
SCENARIO_SUMMARY="the toast's Tell Me More, Show Less, Close, Not Now and Never for This buttons each do what they say when clicked, and a click outside Athina takes it down"
SCENARIO_TIER=api

toast_up() { api wait-window window="Athina suggestion" present="$1" timeout=5 >/dev/null && echo yes || echo no; }

press() { api click window="Athina suggestion" identifier="$1" --field ok; }

show_last() {
	api menu press="Show Last Suggestion" >/dev/null
	[ "$(toast_up true)" = yes ] || { log "Show Last Suggestion brought no toast back"; return 1; }
}

# How many of the rules in settings key $1 name TextEdit.
rules_for_textedit() {
	json_eval "$(api settings key="$1")" 'sum(1 for rule in r["value"] if rule.get("appName") == "TextEdit")'
}

# Pictures kept as evidence: these windows show what changes from run to run
# or move on their own, so they are not checkpoints (docs/ci.md "Checkpoints").
picture() { api snapshot window="$1" path="$RUN_DIR/$2.png" >/dev/null || log "no picture of $1"; }

scenario_run() {
	scripted_toast || return 1
	local suggestion="$SUGGESTION_ID"
	picture "Athina suggestion" toast

	check "a click on Tell Me More lands" "true" "$(press toast.tellMeMore)"
	check "Tell Me More is recorded" "tellMeMore" \
		"$(api wait-event name=feedback id="$suggestion" feedback=tellMeMore --field event.feedback)"
	check "the toast stays up to show the explanation" "yes" "$(toast_up true)"
	check "the button now folds it" "Show Less" "$(settled "Show Less" more_label)"
	picture "Athina suggestion" told-more

	check "a click on Show Less lands" "true" "$(press toast.tellMeMore)"
	check "the toast folds and stays up" "Tell Me More" "$(settled "Tell Me More" more_label)"
	check "a click on Tell Me More again lands" "true" "$(press toast.tellMeMore)"
	check "the toast opens again" "Show Less" "$(settled "Show Less" more_label)"
	check "Tell Me More is recorded once" "1" \
		"$(json_eval "$(api journal query=events)" 'sum(1 for e in r["rows"] if e["kind"] == "feedback" and e["detail"].startswith("Tell me more"))')"

	check "a click on Close lands" "true" "$(press toast.close)"
	check "Close takes the toast down" "yes" "$(toast_up false)"
	check "Close records nothing over the answer" "tellMeMore" "$(api_feedback "$suggestion")"

	show_last || return 1
	check "a click on Not Now lands" "true" "$(press toast.notNow)"
	check "Not Now is recorded" "notNow" \
		"$(api wait-event name=feedback id="$suggestion" feedback=notNow --field event.feedback)"
	check "Not Now takes the toast down" "yes" "$(toast_up false)"
	check "Not Now snoozes this kind of suggestion in TextEdit" "1" "$(rules_for_textedit mentor.snoozes)"

	show_last || return 1
	check "a click on Never for This lands" "true" "$(press toast.never)"
	check "Never for This is recorded" "never" \
		"$(api wait-event name=feedback id="$suggestion" feedback=never --field event.feedback)"
	check "Never for This takes the toast down" "yes" "$(toast_up false)"
	check "Never for This stops this kind of suggestion in TextEdit" "1" "$(rules_for_textedit mentor.neverRules)"

	# Well away from the toast, at the top right of the main display, and from
	# the menu bar item a hermetic run does not have.
	show_last || return 1
	check "a click outside Athina's windows reaches the toast" "true" "$(api outside-click x=40 y=400 --field heard)"
	check "a click outside Athina's windows takes the toast down" "yes" "$(toast_up false)"
	check "the answer stands after the click outside" "never" "$(api_feedback "$suggestion")"
	return 0
}

more_label() { api find window="Athina suggestion" identifier=toast.tellMeMore --field elements.0.label; }
