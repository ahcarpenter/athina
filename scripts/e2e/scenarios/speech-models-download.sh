# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# Every speech model the manifest lists downloads through Settings > General,
# one at a time, pressed by name through accessibility the way VoiceOver
# presses a button: the row shows its progress while it downloads, the file is
# checked against its published checksum before the row says Ready, and a
# model can be deleted and downloaded again. Each model's size and how long it
# took land in models.tsv, and the downloaded set is saved for the scenarios
# that talk back through it (speech-talk-back).
#
# This is the one scenario that may reach the network: HTTPS only, for Hugging
# Face (see launch_athina). A replay's model calls stay answered from fixtures.
SCENARIO_SUMMARY="every speech model downloads through Settings with its progress shown, is checked, and can be deleted; sizes and times are reported"
SCENARIO_ARGS=(--open settings:general)
SCENARIO_NETWORK=https

# name, file under speech-models, bytes: the manifest (SpeechModelCatalog.swift).
SPEECH_MODELS=(
	"OpenAI Whisper Base, English|whisper/ggml-base.en.bin|147964211"
	"OpenAI Whisper Small, English|whisper/ggml-small.en.bin|487614201"
	"OpenAI Whisper Large v3 Turbo, 99 languages|whisper/ggml-large-v3-turbo-q5_0.bin|574041195"
	"NVIDIA Parakeet TDT 0.6B v3|parakeet/ggml-parakeet-tdt-0.6b-v3-q8_0.bin|668757119"
	"NVIDIA Parakeet TDT 0.6B v3, compact|parakeet/ggml-parakeet-tdt-0.6b-v3-q4_k.bin|415611879"
)

file_size() { stat -f %z "$1" 2>/dev/null || echo 0; }

# Presses Download on a model's row and waits for the checked file, keeping a
# picture of the row part way through the download and while it is checked,
# as accessibility reads them: a percentage between 20 and 79, then Checking.
# The row is scrolled into view first ($2 is the scroll position): a form
# draws, and offers accessibility, only the rows on screen. Prints the
# seconds it took.
download_model() {
	local name="$1" at="$2" path="$3" bytes="$4" tag="$5" models started texts downloading=0 checking=0 i
	models="$(replay_data_dir)/speech-models"
	texts="$RUN_DIR/$tag-poll.txt"
	scroll_general_to "$at"
	started=$(date +%s)
	press_named AXButton "Download $name" || return 1
	for i in $(seq 1 2400); do
		[ -f "$models/$path.verified" ] && break
		"$DRIVE" ax "$ATHINA_PID" texts --scope General >"$texts" 2>/dev/null || true
		# The row's percentage, not a text field that shows one, such as
		# Minimum confidence.
		if [ "$downloading" = 0 ] && grep -qE '^AXStaticText .*value="[2-7][0-9]%"' "$texts"; then
			general_state "$tag-downloading"
			downloading=1
		fi
		if [ "$checking" = 0 ] && grep -qF 'value="Checking"' "$texts"; then
			general_state "$tag-checking"
			checking=1
		fi
		sleep 0.2
	done
	rm -f "$texts"
	[ -f "$models/$path.verified" ] || { log "$name never finished downloading"; return 1; }
	echo $(( $(date +%s) - started ))
}

scenario_run() {
	local entry name path bytes seconds tag models got at total=0 total_seconds=0
	wait_athina_window General || { log "Settings > General never opened"; return 1; }
	models="$(replay_data_dir)/speech-models"
	# The talk-back section, with the recognizer rows, in view.
	scroll_general_to 0.38
	general_state "analyzer-built-in"
	check "SpeechAnalyzer is the default recognizer" "speechAnalyzer" "$(saved_speech_backend)"
	check "SpeechAnalyzer is built in" "yes" "$(has_general_text analyzer-built-in-texts.txt "Built into macOS")"

	pick_speech_backend "OpenAI Whisper" whisper || return 1
	general_state "whisper-not-downloaded"
	check "Whisper starts not downloaded" "yes" "$(has_general_text whisper-not-downloaded-texts.txt "Not downloaded")"

	printf 'model\tbytes\tseconds\n' >"$RUN_DIR/models.tsv"
	for entry in "${SPEECH_MODELS[@]}"; do
		IFS='|' read -r name path bytes <<<"$entry"
		tag="$(basename "$path" .bin)"
		if [ "$name" = "NVIDIA Parakeet TDT 0.6B v3" ]; then
			# The largest download, from the talk-back section's own status row,
			# with Parakeet chosen, so that row shows its progress.
			pick_speech_backend "NVIDIA Parakeet" parakeet || return 1
			scroll_general_to 0.38
			general_state "parakeet-not-downloaded"
			at=0.38
		else
			at=1.0
		fi
		log "downloading $name ($bytes bytes)"
		seconds="$(download_model "$name" "$at" "$path" "$bytes" "$tag")" || return 1
		got="$(file_size "$models/$path")"
		check "$name is the manifest's size" "$bytes" "$got"
		check "$name was checked" "yes" "$([ -f "$models/$path.verified" ] && echo yes || echo no)"
		check "nothing is left half downloaded for $name" "no" "$([ -e "$models/.partial/$(basename "$path")" ] && echo yes || echo no)"
		printf '%s\t%s\t%s\n' "$name" "$got" "$seconds" >>"$RUN_DIR/models.tsv"
		log "$name: $got bytes in ${seconds}s"
		total=$((total + got))
		total_seconds=$((total_seconds + seconds))
	done
	printf 'all\t%s\t%s\n' "$total" "$total_seconds" >>"$RUN_DIR/models.tsv"

	scroll_general_to 0.38
	general_state "parakeet-ready"
	check "the chosen model reads as downloaded and checked" "yes" "$(has_general_text parakeet-ready-texts.txt "Downloaded and checked")"
	pick_speech_backend "OpenAI Whisper" whisper || return 1
	general_state "whisper-ready"
	check "each recognizer keeps its own model" "yes" "$(has_general_text whisper-ready-texts.txt "Downloaded and checked")"

	# Delete one, then download it again, so the saved set stays whole.
	scroll_general_to 1.0
	general_state "models-ready"
	press_named AXButton "Delete OpenAI Whisper Base, English" || return 1
	sleep 1
	general_state "whisper-deleted"
	check "Delete removes the file" "no" "$([ -e "$models/whisper/ggml-base.en.bin" ] && echo yes || echo no)"
	check "Delete removes the record of its check" "no" "$([ -e "$models/whisper/ggml-base.en.bin.verified" ] && echo yes || echo no)"
	check "a deleted model reads as not downloaded" "yes" "$(has_general_text whisper-deleted-texts.txt "Not downloaded")"
	seconds="$(download_model "OpenAI Whisper Base, English" 1.0 whisper/ggml-base.en.bin 147964211 base-again)" || return 1
	log "downloaded OpenAI Whisper Base, English again in ${seconds}s"

	save_speech_models || return 1
	check "the downloaded models are saved for the next run" "5" "$(find "$SPEECH_MODELS_CACHE" -name '*.verified' | wc -l | tr -d ' ')"
	return 0
}

has_general_text() {
	grep -qF "$2" "$RUN_DIR/$1" && echo yes || echo no
}
