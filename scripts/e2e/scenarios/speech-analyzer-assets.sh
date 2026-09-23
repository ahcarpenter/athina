# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/athina-e2e, which sources this file.
# shellcheck disable=SC2034
# SpeechAnalyzer's language assets download through the same row a model
# does. The replay runs in French (France) unless told otherwise, a language
# macOS supports but has not installed on a Mac set up in English, so Settings > General reads it as
# not downloaded; Download asks macOS for the assets, the row shows the
# system's progress, and once they are installed the recognizer reads as built
# in. macOS downloads them itself, from Apple, so the sandbox's closed network
# does not stop it, and it keeps them, shared with other apps: nothing here
# deletes them, and a later run finds them installed and says so.
SCENARIO_SUMMARY="SpeechAnalyzer's assets for a language macOS has not installed download through Settings with the system's progress, and then read as built in"

# Another language on a Mac that already has French: ATHINA_E2E_SPEECH_LOCALE,
# one of those named below. fr_CA is the one to run to check that the
# person's language wins over the app's own: Athina is localized only in
# English, so it runs as English (Canada) there, which SpeechTranscriber also
# hears.
SPEECH_LOCALE="${ATHINA_E2E_SPEECH_LOCALE:-fr_FR}"
case "$SPEECH_LOCALE" in
fr_FR) SPEECH_LANGUAGE="French (France)" ;;
fr_CA) SPEECH_LANGUAGE="French (Canada)" ;;
de_DE) SPEECH_LANGUAGE="German (Germany)" ;;
es_ES) SPEECH_LANGUAGE="Spanish (Spain)" ;;
it_IT) SPEECH_LANGUAGE="Italian (Italy)" ;;
*) SPEECH_LANGUAGE="" ;;
esac
# Both the locale and the language list: a region alone, with English still
# the first language, is English in that region.
SCENARIO_ARGS=(--open settings:general -AppleLanguages "(${SPEECH_LOCALE/_/-})" -AppleLocale "$SPEECH_LOCALE")

has_text() {
	grep -qF "$2" "$RUN_DIR/$1" && echo yes || echo no
}

scenario_run() {
	local started seconds i texts="$RUN_DIR/poll.txt" progress=0
	wait_athina_window General || ensure_general_open || { log "Settings > General never opened"; return 1; }
	scroll_general_to 0.38
	general_state "analyzer-language"
	[ -n "$SPEECH_LANGUAGE" ] || { log "no language name for $SPEECH_LOCALE"; return 1; }
	check "the language is the Mac's" "yes" "$(has_text analyzer-language-texts.txt "value=\"$SPEECH_LANGUAGE\"")"
	if [ "$(has_text analyzer-language-texts.txt 'value="Built into macOS"')" = yes ]; then
		log "$SPEECH_LANGUAGE is already installed on this Mac; there is nothing to download"
		check "$SPEECH_LANGUAGE reads as built in" "yes" "yes"
		return 0
	fi
	check "$SPEECH_LANGUAGE reads as not downloaded" "yes" "$(has_text analyzer-language-texts.txt 'value="Not downloaded"')"
	started=$(date +%s)
	press_named AXButton "Download Apple SpeechAnalyzer, $SPEECH_LANGUAGE" || return 1
	for i in $(seq 1 1800); do
		"$DRIVE" ax "$ATHINA_PID" texts --scope General >"$texts" 2>/dev/null || true
		grep -qF 'value="Built into macOS"' "$texts" && break
		# A percentage in the locale's own form: "24 %" in French, with a
		# narrow space before the sign.
		if [ "$progress" = 0 ] && grep -qE '^AXStaticText .*value="(Starting|[0-9]+[^"0-9]{0,4}%)"' "$texts"; then
			general_state "analyzer-downloading"
			progress=1
		fi
		sleep 0.5
	done
	seconds=$(( $(date +%s) - started ))
	general_state "analyzer-installed"
	log "macOS installed SpeechAnalyzer's $SPEECH_LANGUAGE assets in ${seconds}s"
	printf 'SpeechAnalyzer %s\t%s\n' "$SPEECH_LOCALE" "$seconds" >"$RUN_DIR/assets.tsv"
	check "the row showed the download" "1" "$progress"
	check "$SPEECH_LANGUAGE reads as built in once installed" "yes" "$(has_text analyzer-installed-texts.txt 'value="Built into macOS"')"
	return 0
}
