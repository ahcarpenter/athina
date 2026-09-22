# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# SpeechAnalyzer's language assets download through the same row a model
# does. The replay runs in French (France), a language macOS supports but has
# not installed on a Mac set up in English, so Settings > General reads it as
# not downloaded; Download asks macOS for the assets, the row shows the
# system's progress, and once they are installed the recognizer reads as built
# in. macOS downloads them itself, from Apple, so the sandbox's closed network
# does not stop it, and it keeps them, shared with other apps: nothing here
# deletes them, and a later run finds them installed and says so.
SCENARIO_SUMMARY="SpeechAnalyzer's assets for a language macOS has not installed download through Settings with the system's progress, and then read as built in"
SCENARIO_ARGS=(--open settings:general -AppleLocale fr_FR)

has_text() {
	grep -qF "$2" "$RUN_DIR/$1" && echo yes || echo no
}

scenario_run() {
	local started seconds i texts="$RUN_DIR/poll.txt" progress=0
	wait_athina_window General || { log "Settings > General never opened"; return 1; }
	scroll_general_to 0.38
	general_state "analyzer-french"
	check "the language is the Mac's" "yes" "$(has_text analyzer-french-texts.txt 'value="French (France)"')"
	if [ "$(has_text analyzer-french-texts.txt 'value="Built into macOS"')" = yes ]; then
		log "French is already installed on this Mac; there is nothing to download"
		check "French reads as built in" "yes" "yes"
		return 0
	fi
	check "French reads as not downloaded" "yes" "$(has_text analyzer-french-texts.txt 'value="Not downloaded"')"
	started=$(date +%s)
	press_named AXButton "Download Apple SpeechAnalyzer, French (France)" || return 1
	for i in $(seq 1 1800); do
		"$DRIVE" ax "$ATHINA_PID" texts --scope General >"$texts" 2>/dev/null || true
		grep -qF 'value="Built into macOS"' "$texts" && break
		if [ "$progress" = 0 ] && grep -qE 'value="(Starting|[0-9]+%)"' "$texts"; then
			general_state "analyzer-downloading"
			progress=1
		fi
		sleep 0.5
	done
	seconds=$(( $(date +%s) - started ))
	general_state "analyzer-installed"
	log "macOS installed SpeechAnalyzer's French assets in ${seconds}s"
	printf 'SpeechAnalyzer fr_FR\t%s\n' "$seconds" >"$RUN_DIR/assets.tsv"
	check "the row showed the download" "1" "$progress"
	check "French reads as built in once installed" "yes" "$(has_text analyzer-installed-texts.txt 'value="Built into macOS"')"
	return 0
}
