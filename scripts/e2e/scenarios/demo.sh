# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# The README's demo, recorded from the real screen: the committed fixtures'
# own scene (harness.sh stage_scenario_documents), replayed as `make run`
# replays it, with the top of the screen recorded from the moment before the
# window switch that brings the note to the moment after Tell Me More.
#
#   1 The first triage call, on reading-notes.txt, has been answered (the
#     replay's first triage fixture: not worth a look), and the triage gate's
#     floor has passed, so the switch below is the moment the second triage
#     fixture and the mentor fixture answer.
#   2 The recording starts; the notes sit on screen for a moment; the switch
#     to cleanup-script.txt is the change moment; its capture, triage and
#     mentor call raise the note under the menu bar and the callout on the
#     script's `rm -rf $BUILD_ROOT/*` line; after a pause to read the note,
#     Tell Me More, clicked through the control API so no pointer enters the
#     picture, opens the explanation, which the recording holds until it ends.
#
# Nothing nudges sensing while it records: no helper window, no window switch
# beyond the one the demo is about, so what the recording shows is what a
# person would see. The GIF is cut from the recording afterwards by
# scripts/demo-gif.swift (docs/replay.md "The committed fixtures").
SCENARIO_SUMMARY="records the README's demo from the real screen: the fixtures' scene in TextEdit, the switch to the script, the note under the menu bar with the callout on the script's line, and Tell Me More opening the explanation; the recording is demo.mov in the run's evidence"
SCENARIO_CONTROL=yes
SCENARIO_IDLE_FIRST=yes
# Only when named: a run of every scenario is a check, and this is a recording.
SCENARIO_ON_REQUEST=yes

# The recording, in seconds, and the pauses inside it: enough for the notes to
# be seen before the switch, the note to be read before Tell Me More, and the
# explanation to be read before the recording ends.
DEMO_SECONDS=18
# The top of the screen, down past the note as Tell Me More opens it.
DEMO_HEIGHT=520
DEMO_BEFORE_SWITCH=2.5
DEMO_BEFORE_TELL_ME_MORE=5

scenario_stage() {
	stage_scenario_documents || return 1
	"$DRIVE" activate "$TEXTEDIT_PID" >>"$RUN_DIR/transcript.log" 2>&1
}

# Waits for the toast without nudging sensing, unlike wait_toast: a nudge is
# a window switch, which the recording would show. Prints the toast's window.
wait_toast_still() {
	local limit="${1:-30}" started toast
	started=$(date +%s)
	while [ $(($(date +%s) - started)) -lt "$limit" ]; do
		kill -0 "$ATHINA_PID" 2>/dev/null || die "Athina exited while waiting for the toast"
		toast="$(toast_window)"
		if [ -n "$toast" ] && [ "$(newest_suggestion_open)" = 1 ]; then
			log "toast window $toast up after $(($(date +%s) - started))s"
			printf '%s\n' "$toast"
			return 0
		fi
		sleep 0.25
	done
	log "no toast within ${limit}s"
	return 1
}

# Whether the newest suggestion's callout was drawn, from the journal.
callout_drawn() {
	"$DRIVE" journal "$JOURNAL" suggestions 2>/dev/null | awk -F '\t' 'NR > 1 { last = $NF } END { print (last == "" ? "none" : last) }'
}

scenario_run() {
	local suggestion video_pid

	[ -n "$CONTROL_DIR" ] || { log "the demo drives Tell Me More through the control API, which $APP carries no"; return 1; }

	step "1 the first triage call is answered before the moment"
	api wait-event name=call tier=triage timeout=60 >/dev/null \
		|| { log "no triage call on the notes within 60s; see api.log"; return 1; }
	check "the notes brought no suggestion" "0" "$(newest_suggestion_id)"
	# The triage gate's floor from the seeded settings, so the next capture
	# is triaged rather than held back.
	sleep 6

	step "2 the recording"
	"$DRIVE" shot video 0 0 "$SCENE_WIDTH" "$DEMO_HEIGHT" "$DEMO_SECONDS" "$RUN_DIR/demo.mov" \
		>>"$RUN_DIR/transcript.log" 2>&1 8>&- 9>&- &
	video_pid=$!
	track_helper "$video_pid"
	log "recording the top of the screen for ${DEMO_SECONDS}s (pid $video_pid)"
	sleep "$DEMO_BEFORE_SWITCH"
	raise_window "$TEXTEDIT_PID" cleanup-script.txt
	log "switched to cleanup-script.txt"
	wait_toast_still 30 >/dev/null || return 1
	suggestion="$(newest_suggestion_id)"
	check "a toast is up for the script" "none" "$(suggestion_feedback "$suggestion")"
	# The callout follows the toast by a moment.
	sleep 1
	check "its callout was drawn on the script" "1" "$(callout_drawn)"
	sleep "$((DEMO_BEFORE_TELL_ME_MORE - 1))"
	api click identifier=toast.tellMeMore >/dev/null \
		|| { log "Tell Me More would not take the click; see api.log"; return 1; }
	log "Tell Me More clicked"
	check "Tell Me More is recorded" "tellMeMore" "$(suggestion_feedback "$suggestion")"
	wait "$video_pid" || true
	check "the recording was written" "yes" "$([ -s "$RUN_DIR/demo.mov" ] && echo yes || echo no)"
	log "RESULT recording $RUN_DIR/demo.mov"
	return 0
}
