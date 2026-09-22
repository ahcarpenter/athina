# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# Talking back through every speech recognizer, with no microphone: each of
# the committed phrases (Tests/AthinaCoreTests/Fixtures/Speech) is played into
# the replay's listener with scripts/talk-back.sh, which takes exactly the
# path a held talk-back key does. For each recognizer, chosen in Settings >
# General through the picker, the question reaches the toast as a live
# transcript, is asked, and is answered by the replayed follow-up; then "tell
# me more" is matched as that answer. The journal records which recognizer
# heard each one. Finally "not now", heard by the last recognizer, answers the
# toast and closes it.
#
# The models come from the set speech-models-download saved.
SCENARIO_SUMMARY="each recognizer hears the committed phrases: the transcript reaches the toast, matches an answer, and drives a replayed follow-up, journaled with who heard it"
SCENARIO_ARGS=(--open settings:general)
SCENARIO_SPEECH_MODELS=1

PHRASES="$ROOT/Tests/AthinaCoreTests/Fixtures/Speech"

# picker title, raw value, the model the journal names.
RECOGNIZERS=(
	"Apple SpeechAnalyzer|speechAnalyzer|SpeechTranscriber"
	"OpenAI Whisper|whisper|whisper-base.en"
	"NVIDIA Parakeet|parakeet|parakeet-tdt-0.6b-v3-q8_0"
)

# The toast's listening row as accessibility reads it while a recording
# plays, and a picture of the toast, taken once that row shows the live
# transcript: the row reads "Listening…" and then the words heard so far, so
# the words the toast already shows elsewhere, an earlier question among
# them, never count.
watch_toast_transcript() {
	local tag="$1" words="$2" i toast
	for i in $(seq 1 60); do
		"$DRIVE" ax "$ATHINA_PID" texts 2>/dev/null | grep -i "Listening" >"$RUN_DIR/$tag-toast-texts.txt" || true
		if grep -qiF "$words" "$RUN_DIR/$tag-toast-texts.txt"; then
			toast="$(toast_window)"
			[ -n "$toast" ] && "$DRIVE" shot window "$toast" "$RUN_DIR/$tag-toast.png" >/dev/null 2>&1
			echo yes
			return 0
		fi
		sleep 0.05
	done
	echo no
}

newest_follow_up() {
	sqlite3 -readonly -separator '|' "$JOURNAL" \
		"select coalesce(heard_by, ''), coalesce(heard_by_model, ''), coalesce(answer, '') != '' from follow_ups order by id desc limit 1" 2>/dev/null || echo ""
}

scenario_run() {
	local entry title raw model suggestion heard handling answer seen row
	stage_flip_window
	wait_toast >/dev/null || return 1
	suggestion="$(newest_suggestion_id)"
	wait_athina_window General || ensure_general_open || { log "Settings > General never opened"; return 1; }
	scroll_general_to 0.38

	for entry in "${RECOGNIZERS[@]}"; do
		IFS='|' read -r title raw model <<<"$entry"
		log "talking back through $title"
		pick_speech_backend "$title" "$raw" || return 1
		general_state "$raw-chosen"
		check "$title is ready to listen" "yes" "$(grep -qE 'value="(Built into macOS|Downloaded and checked)"' "$RUN_DIR/$raw-chosen-texts.txt" && echo yes || echo no)"

		# A question: the live transcript in the toast, then the replayed answer.
		play_recording "$PHRASES/which-line.wav" "$raw-question"
		seen="$(watch_toast_transcript "$raw-question" "which line")"
		wait_recording || log "talk-back.sh reported a failure for the question through $title"
		snapshot_state "$raw-answered"
		heard="$(reply_field "$raw-question" heard)"
		handling="$(reply_field "$raw-question" handling)"
		answer="$(reply_field "$raw-question" answer)"
		log "$title heard \"$heard\" and $handling"
		check "$title: the live transcript reached the toast" "yes" "$seen"
		check "$title: the question was heard" "yes" "$(printf '%s' "$heard" | grep -qi "which line do you mean" && echo yes || echo no)"
		check "$title: the question was asked" "asked the mentor" "$handling"
		check "$title: the replayed follow-up answered it" "yes" "$([ -n "$answer" ] && [ "$answer" != withdrawn ] && echo yes || echo no)"
		check "$title: the reply names the recognizer" "$raw" "$(reply_field "$raw-question" backend)"
		row="$(newest_follow_up)"
		check "$title: the journal says who heard the question" "$raw" "${row%%|*}"
		check "$title: the journal names the model" "yes" "$(printf '%s' "$row" | grep -qF "|$model" && echo yes || echo no)"
		check "$title: the answer is journaled" "1" "${row##*|}"

		# An answer: "tell me more" is matched, whatever recognizer heard it.
		play_recording "$PHRASES/tell-me-more.wav" "$raw-answer"
		wait_recording || log "talk-back.sh reported a failure for tell me more through $title"
		check "$title: tell me more was heard" "yes" "$(reply_field "$raw-answer" heard | grep -qi "tell me more" && echo yes || echo no)"
		check "$title: tell me more answered the toast" "answered: Tell me more" "$(reply_field "$raw-answer" handling)"
	done

	check "the first spoken answer is journaled with its recognizer" "tellMeMore|speechAnalyzer" \
		"$(sqlite3 -readonly -separator '|' "$JOURNAL" "select feedback, coalesce(feedback_heard_by, '') from suggestions where id = $suggestion" 2>/dev/null)"

	play_recording "$PHRASES/not-now.wav" "not-now"
	wait_recording || log "talk-back.sh reported a failure for not now"
	check "not now answered the toast" "answered: Not now" "$(reply_field not-now handling)"
	sleep 1
	check "not now is journaled with the recognizer that heard it" "notNow|parakeet" \
		"$(sqlite3 -readonly -separator '|' "$JOURNAL" "select feedback, coalesce(feedback_heard_by, '') from suggestions where id = $suggestion" 2>/dev/null)"
	check "the toast went away" "gone" "$([ -n "$(toast_window)" ] && echo up || echo gone)"
	check "three recognizers heard three questions" "3" \
		"$(sqlite3 -readonly "$JOURNAL" "select count(distinct heard_by) from follow_ups where heard_by is not null and heard_by != 'typed'" 2>/dev/null)"
	return 0
}
