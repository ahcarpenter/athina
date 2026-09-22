# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# A speech model that cannot be used is reported, and talking back stays off
# rather than falling back to another recognizer. With the sandbox's network
# closed, as every other run has it, Whisper is chosen in Settings > General:
# its model is not downloaded, so the menu offers Set Up Talk Back and a recording played in
# is refused with the reason, which the toast shows; nothing else hears it.
# Download then fails, the row says why and offers Try Again, and nothing is
# left on disk. Choosing SpeechAnalyzer again makes talking back ready.
SCENARIO_SUMMARY="a recognizer that cannot run is reported in Settings and the menu, talking back stays off, and a download that cannot connect fails with the reason"
SCENARIO_ARGS=(--open settings:general)

PHRASES="$ROOT/Tests/AthinaCoreTests/Fixtures/Speech"

has_text() {
	grep -qF "$2" "$RUN_DIR/$1" && echo yes || echo no
}

menu_texts() {
	local tag="$1"
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 0.8
	"$DRIVE" ax "$ATHINA_PID" menuitems >"$RUN_DIR/$tag-menu-items.txt" 2>&1 || true
	snapshot_state "$tag"
	"$DRIVE" ax "$ATHINA_PID" cancelmenu >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.4
}

scenario_run() {
	local models handling i
	stage_flip_window
	wait_toast >/dev/null || return 1
	wait_athina_window General || ensure_general_open || { log "Settings > General never opened"; return 1; }
	models="$(replay_data_dir)/speech-models"
	scroll_general_to 0.38

	pick_speech_backend "OpenAI Whisper" whisper || return 1
	general_state "whisper-not-downloaded"
	check "the chosen model reads as not downloaded" "yes" "$(has_text whisper-not-downloaded-texts.txt 'value="Not downloaded"')"
	# The menu's talk-back row is the command that fixes it (README "Design
	# conventions"), as it is for a missing shortcut.
	menu_texts "menu-not-downloaded"
	check "the menu offers to set talking back up" "yes" "$(has_text menu-not-downloaded-menu-items.txt "Set Up Talk Back…")"

	# Talking back is off: a recording is refused with the reason, and no
	# other recognizer hears it.
	"$ROOT/scripts/talk-back.sh" "$ATHINA_PID" "$PHRASES/which-line.wav" >"$RUN_DIR/refused-reply.json" 2>>"$RUN_DIR/transcript.log" || true
	snapshot_state "refused"
	handling="$(reply_field refused handling)"
	check "the recording is refused with the reason" "yes" "$(printf '%s' "$handling" | grep -qF "OpenAI Whisper Base, English is not downloaded yet, so talking back is off." && echo yes || echo no)"
	check "nothing heard it" "" "$(reply_field refused heard)"
	check "no question was asked" "0" "$(journal_count follow_ups)"

	press_named AXButton "Download OpenAI Whisper Base, English" || return 1
	for i in $(seq 1 60); do
		"$DRIVE" ax "$ATHINA_PID" texts --scope General >"$RUN_DIR/poll.txt" 2>/dev/null || true
		grep -qF 'value="Failed"' "$RUN_DIR/poll.txt" && break
		sleep 0.5
	done
	general_state "whisper-failed"
	check "the download fails" "yes" "$(has_text whisper-failed-texts.txt 'value="Failed"')"
	check "the row says why" "yes" "$(has_text whisper-failed-texts.txt "This Mac could not reach huggingface.co: ")"
	check "the row offers Try Again" "yes" "$(grep -qF 'desc="Try Again OpenAI Whisper Base, English"' "$RUN_DIR/whisper-failed-tree.txt" && echo yes || echo no)"
	check "nothing is left on disk" "0" "$(find "$models" -type f 2>/dev/null | wc -l | tr -d ' ')"
	menu_texts "menu-failed"
	check "the menu still offers to set talking back up" "yes" "$(has_text menu-failed-menu-items.txt "Set Up Talk Back…")"

	press_named AXButton "Try Again OpenAI Whisper Base, English" || return 1
	sleep 2
	general_state "whisper-failed-again"
	check "trying again fails the same way while offline" "yes" "$(has_text whisper-failed-again-texts.txt "This Mac could not reach huggingface.co: ")"

	pick_speech_backend "Apple SpeechAnalyzer" speechAnalyzer || return 1
	general_state "analyzer-built-in"
	check "SpeechAnalyzer is ready again" "yes" "$(has_text analyzer-built-in-texts.txt 'value="Built into macOS"')"
	return 0
}
