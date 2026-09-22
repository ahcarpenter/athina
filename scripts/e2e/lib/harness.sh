#!/usr/bin/env bash
# Shared machinery for the Athina end-to-end harness. Sourced by scripts/e2e/athina-e2e
# and by every scenario; never run on its own.
#
# What lives here is everything a scenario would otherwise write again: the
# warm fixture home, the sandbox, the launch and the stop by pid, the waits,
# and the safety that keeps a run off the owner's data and off his apps.

# --- Where everything is ------------------------------------------------------

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$E2E_DIR/../.." && pwd)"
# ATHINA_E2E_APP runs the scenarios against another bundle, such as the
# hardened release build `make release` leaves in build/release (README
# "Releasing"); the harness then checks that bundle as it is and never rebuilds it.
APP="$ROOT/build/Athina.app"
if [ -n "${ATHINA_E2E_APP:-}" ]; then
	# Absolute, since pids are matched on the path the process runs from.
	APP="$(cd "$ATHINA_E2E_APP" 2>/dev/null && pwd || printf '%s' "$ATHINA_E2E_APP")"
fi
APP_BINARY="$APP/Contents/MacOS/Athina"
DRIVE="$ROOT/.build/debug/athina-drive"
FIXTURES="$ROOT/Tests/AthinaCoreTests/Fixtures/Replay"
SETTINGS_SEED="$E2E_DIR/lib/settings.json"

# The owner's real data, which every run is sandboxed away from: where the app
# keeps it now, and where it kept it as Mentor (README "Coming from Mentor").
LIVE_SUPPORT="$HOME/Library/Application Support/athina"
LEGACY_SUPPORT="$HOME/Library/Application Support/mentor"
PREFS_DOMAIN="com.ahcarpenter.athina"

# Homes and evidence live outside the repository: a warm home holds caches that
# must not be committed, and a run holds screenshots of the real screen.
CACHE_ROOT="${ATHINA_E2E_CACHE:-$HOME/Library/Caches/athina-e2e}"
WARM_HOME="$CACHE_ROOT/warm-home"
# The speech models a download scenario fetched through Settings, kept so a
# later run starts with them rather than fetching hundreds of megabytes again
# (see seed_speech_models).
SPEECH_MODELS_CACHE="$CACHE_ROOT/speech-models"
# Read by the entry point and by scenarios that source this file.
# shellcheck disable=SC2034
RUNS_ROOT="$CACHE_ROOT/runs"

# --- Run state ----------------------------------------------------------------

RUN_DIR=""
HOME_DIR=""
JOURNAL=""
ATHINA_PID=""
EXCLUDED_PID=""
HELPER_PIDS=()
STAGED_PIDS=()
STAGED_WINDOWS=()
PREFS_BACKUP=""
PREFS_EXISTED=0
# Set by a scenario: "https" lets the run reach HTTPS servers, which only a
# scenario that downloads speech models needs (see launch_athina).
SCENARIO_NETWORK=""
# Set by the entry point's --appearance: light or dark, whatever the Mac shows.
APPEARANCE="${APPEARANCE:-}"
CHECKS_FAILED=0
CHECK_LINES=()

# --- Output -------------------------------------------------------------------

log() {
	local line
	line="$(date '+%H:%M:%S') $*"
	printf '%s\n' "$line" >&2
	[ -n "$RUN_DIR" ] && printf '%s\n' "$line" >>"$RUN_DIR/log.txt"
	return 0
}

die() {
	log "ERROR: $*"
	exit 1
}

# One check inside a scenario. A scenario fails when any of its checks does,
# and every check reaches the result line, so a failure names itself.
check() {
	local name="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		log "  ok   $name = $actual"
		CHECK_LINES+=("ok $name=$actual")
	else
		log "  FAIL $name: expected $expected, got $actual"
		CHECK_LINES+=("FAIL $name: expected=$expected actual=$actual")
		CHECKS_FAILED=$((CHECKS_FAILED + 1))
	fi
}

# --- Building -----------------------------------------------------------------

# Is anything under the given directories newer than the built product?
sources_newer_than() {
	local product="$1"
	shift
	[ -x "$product" ] || return 0
	[ -n "$(find "$@" -name '*.swift' -newer "$product" -print -quit)" ]
}

ensure_drive() {
	if sources_newer_than "$DRIVE" "$ROOT/Sources/AthinaDrive" "$ROOT/Sources/AthinaE2E"; then
		log "building athina-drive"
		(cd "$ROOT" && swift build --product athina-drive >/dev/null) || die "could not build athina-drive"
	fi
}

# A check of a stale bundle proves nothing, so the app is rebuilt when a source
# file is newer than it. Never while something is running from it, though:
# scripts/bundle.sh deletes the bundle first, and another lane, or the owner,
# may be using this one.
ensure_app() {
	if [ -n "${ATHINA_E2E_APP:-}" ]; then
		[ -x "$APP_BINARY" ] || die "ATHINA_E2E_APP names $APP, which holds no Athina executable"
		sources_newer_than "$APP_BINARY" "$ROOT/Sources" && log "WARNING: a source file is newer than $APP, which is checked as it is"
		return 0
	fi
	if sources_newer_than "$APP_BINARY" "$ROOT/Sources"; then
		if pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
			die "$APP is out of date and something is running from it; rebuild it when nothing is"
		fi
		log "building $APP (a source file is newer than it)"
		(cd "$ROOT" && scripts/bundle.sh release >/dev/null 2>&1) || die "could not build the app bundle"
	fi
}

# What was run, for whoever reads the evidence later.
record_build_provenance() {
	{
		printf 'commit %s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
		printf 'worktree %s\n' "$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ') file(s) modified"
		printf 'bundle %s\n' "$APP"
		printf 'app %s\n' "$(shasum -a 256 "$APP_BINARY" | cut -c1-16)"
		printf 'fixtures %s\n' "$FIXTURES"
	} >"$RUN_DIR/build.txt"
}

# --- The owner's preferences --------------------------------------------------

# CFFIXED_USER_HOME moves Application Support but not UserDefaults: a run still
# writes the selected Settings pane and window frames into the owner's real
# preferences domain through cfprefsd. So every run saves that domain and puts
# it back, whatever happens.
prefs_save() {
	PREFS_BACKUP="$RUN_DIR/preferences-before.plist"
	if defaults read "$PREFS_DOMAIN" >/dev/null 2>&1; then
		PREFS_EXISTED=1
		defaults export "$PREFS_DOMAIN" "$PREFS_BACKUP" || die "could not save $PREFS_DOMAIN"
		log "saved the $PREFS_DOMAIN preferences"
	else
		PREFS_EXISTED=0
		log "$PREFS_DOMAIN has no preferences to save"
	fi
}

prefs_restore() {
	[ -n "$PREFS_BACKUP" ] || return 0
	if [ "$PREFS_EXISTED" = 1 ]; then
		if defaults import "$PREFS_DOMAIN" "$PREFS_BACKUP"; then
			log "restored the $PREFS_DOMAIN preferences"
		else
			log "WARNING: could not restore $PREFS_DOMAIN from $PREFS_BACKUP"
		fi
	else
		defaults delete "$PREFS_DOMAIN" >/dev/null 2>&1 && log "removed the $PREFS_DOMAIN preferences this run created" || true
	fi
	return 0
}

# --- Homes --------------------------------------------------------------------

warm_home_stamp() { cat "$WARM_HOME/.athina-e2e-warm" 2>/dev/null || echo "none"; }

have_warm_home() { [ -s "$WARM_HOME/.athina-e2e-warm" ]; }

# A fresh home per run, cloned from the warm one.
#
# The clone is an APFS copy-on-write copy (`cp -c`), so it costs no time and no
# disk, and it carries the text-recognition model cache with it: without that
# cache the first capture of a run blocks 30 to 60 seconds inside OCR and the
# journal shows events with no observations.
new_home() {
	local dest="$1"
	have_warm_home || die "no warm home yet: run scripts/e2e/athina-e2e warm first"
	rm -rf "$dest"
	cp -c -R "$WARM_HOME" "$dest" || die "could not clone the warm home into $dest"
	# Start from an empty journal and settings; the caches are what we keep.
	rm -rf "$dest/Library/Application Support/athina"
	mkdir -p "$dest/Library/Application Support/athina"
}

# The settings a replay starts from. Two things matter beyond the timings: the
# owner's own apps are excluded, so a replayed callout never lands on his work,
# and the toast lives long enough to survive a wait for idle input.
seed_settings() {
	local home="$1" overrides="${2:-}"
	[ -n "$overrides" ] || overrides='{}'
	HOME_DIR="$home" OVERRIDES="$overrides" SETTINGS_SEED="$SETTINGS_SEED" python3 - <<'PY'
import json, os, pathlib
base = json.loads(pathlib.Path(os.environ["SETTINGS_SEED"]).read_text())
overrides = json.loads(os.environ["OVERRIDES"])

def merge(into, extra):
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(into.get(key), dict):
            merge(into[key], value)
        else:
            into[key] = value

merge(base, overrides)
path = pathlib.Path(os.environ["HOME_DIR"]) / "Library/Application Support/athina/settings.json"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(base, indent=2))
PY
}

# The speech models an earlier download scenario saved, cloned into the
# scratch home's own Application Support, where a replay finds them as the
# models downloaded live and copies them into its own directory as it starts
# (README "Talking back"). APFS clones cost no time and no disk. The copy keeps
# each file's modification date, which is what lets the replay trust the
# record of its checksum rather than hashing every file again.
seed_speech_models() {
	local home="$1"
	[ -d "$SPEECH_MODELS_CACHE" ] || { log "no saved speech models at $SPEECH_MODELS_CACHE: run speech-models-download first"; return 1; }
	cp -c -p -R "$SPEECH_MODELS_CACHE" "$home/Library/Application Support/athina/speech-models" \
		|| { log "could not copy the saved speech models into $home"; return 1; }
	log "seeded the scratch home with the saved speech models"
}

# Keeps what a run downloaded for the next one: every model this replay
# checked, with the record of that check.
save_speech_models() {
	local source
	source="$(replay_data_dir)/speech-models"
	[ -d "$source" ] || { log "this run downloaded no speech models"; return 1; }
	rm -rf "$SPEECH_MODELS_CACHE.saving"
	cp -c -p -R "$source" "$SPEECH_MODELS_CACHE.saving" || { log "could not save the speech models"; return 1; }
	rm -rf "$SPEECH_MODELS_CACHE" "$SPEECH_MODELS_CACHE.saving/.partial"
	mv "$SPEECH_MODELS_CACHE.saving" "$SPEECH_MODELS_CACHE"
	log "saved the speech models to $SPEECH_MODELS_CACHE"
}

# The directory the running replay keeps its files in, which it named as it
# started.
replay_data_dir() { dirname "$JOURNAL"; }

# --- Launching and stopping ---------------------------------------------------

# Replay only, sandboxed, in a scratch home, tracked by pid.
#
# Never `make run-replay` and never `pkill -x Athina`: the first stops the lane
# it launched before, and the second stops every Athina on the Mac, including
# other lanes' and the owner's own.
#
# Where the run's journal is, is the app's to say: a replay makes a directory
# per launch inside the home's `replay` (README "Replays side by side") and
# names it on the line it writes when it starts, which app.log catches. Reading
# it from there rather than dictating it means the path is known only once it
# is real, and the run never guesses at a directory the app did not make.
launch_athina() {
	local home="$1"
	shift
	local profile="$RUN_DIR/isolate.sb"
	# `9>&-` here and on every helper started in the background: the screen
	# lock's descriptor (lib/lock.sh) stays with the harness, so nothing that
	# outlives a killed run can keep the lock.
	sed -e "s#__LIVE_SUPPORT__#$LIVE_SUPPORT#" -e "s#__LEGACY_SUPPORT__#$LEGACY_SUPPORT#" "$E2E_DIR/lib/isolate.sb" >"$profile"
	if [ "$SCENARIO_NETWORK" = https ]; then
		# A replay's model calls never reach the network whatever the sandbox
		# allows, but this is the one kind of run that lifts the rule: HTTPS
		# out, for Settings to download speech models from Hugging Face, and
		# the system resolver that finds it. Nothing else goes out.
		cat >>"$profile" <<'SB'
(allow network-outbound (remote tcp "*:443"))
(allow network-outbound (literal "/private/var/run/mDNSResponder"))
SB
		log "this run may reach HTTPS servers, to download speech models"
	fi
	local appearance=()
	case "$APPEARANCE" in
	light | dark) appearance=(--appearance "$APPEARANCE") ;;
	"") ;;
	*) die "--appearance is light or dark, not $APPEARANCE" ;;
	esac
	CFFIXED_USER_HOME="$home" HOME="$home" \
		sandbox-exec -f "$profile" "$APP_BINARY" --replay "$FIXTURES" "$@" ${appearance[@]+"${appearance[@]}"} \
		>>"$RUN_DIR/app.log" 2>&1 9>&- &
	ATHINA_PID=$!
	JOURNAL=""
	log "launched Athina pid=$ATHINA_PID (replay, sandboxed, home=$home)"
	local i started
	for i in $(seq 1 90); do
		kill -0 "$ATHINA_PID" 2>/dev/null || die "Athina exited during launch; see $RUN_DIR/app.log"
		# Its own pid, so a relaunch in the same home never reads the last one's.
		started="$(grep -m 1 "^Athina started: pid $ATHINA_PID in " "$RUN_DIR/app.log" 2>/dev/null || true)"
		if [ -n "$started" ]; then JOURNAL="${started#* in }/journal.sqlite"; break; fi
		sleep 0.5
	done
	[ -n "$JOURNAL" ] || die "Athina never said where it keeps its journal; see $RUN_DIR/app.log"
	log "journal at $JOURNAL"
	for i in $(seq 1 90); do
		kill -0 "$ATHINA_PID" 2>/dev/null || die "Athina exited during launch; see $RUN_DIR/app.log"
		if "$DRIVE" ready "$ATHINA_PID" 2>/dev/null | grep -q READY; then
			log "Athina ready after $((i / 2))s"
			wake_input
			return 0
		fi
		# A macOS consent prompt can stall a launch silently; say so rather than
		# time out with no reason.
		if [ "$i" = 20 ] && pgrep -x UserNotificationCenter >/dev/null; then
			log "WARNING: UserNotificationCenter is up; a consent prompt may be waiting for the owner"
		fi
		sleep 0.5
	done
	die "Athina never became ready; see $RUN_DIR/app.log"
}

stop_pid() {
	local pid="$1" i
	[ -n "$pid" ] || return 0
	kill -0 "$pid" 2>/dev/null || return 0
	kill -TERM "$pid" 2>/dev/null || true
	for i in $(seq 1 20); do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 0.25
	done
	kill -KILL "$pid" 2>/dev/null || true
	return 0
}

track_helper() { HELPER_PIDS+=("$1"); }

# Everything the harness started, stopped in the reverse order, whatever
# happened. Registered as a trap before the first launch, so an abort, a
# failure, and a success all leave the Mac as they found it.
cleanup() {
	local status=$?
	set +e
	log "cleanup"
	local pid window
	for window in ${STAGED_WINDOWS[@]+"${STAGED_WINDOWS[@]}"}; do
		"$DRIVE" close "${window%%:*}" "${window##*:}" >>"$RUN_DIR/transcript.log" 2>&1
	done
	for pid in ${HELPER_PIDS[@]+"${HELPER_PIDS[@]}"}; do stop_pid "$pid"; done
	for pid in ${STAGED_PIDS[@]+"${STAGED_PIDS[@]}"}; do stop_pid "$pid"; done
	stop_pid "$ATHINA_PID"
	prefs_restore
	if [ -n "$HOME_DIR" ] && [ "${KEEP_HOME:-0}" != 1 ]; then
		rm -rf "$HOME_DIR"
	fi
	return $status
}

# --- Waits --------------------------------------------------------------------

# Sensing watches nothing while the session is idle, and a scenario is not a
# person: with nobody at the Mac the app journals "no input for ..." and
# captures nothing at all. A Shift press counts as session input, wakes
# sensing, and brings on an input-settled capture; it types nothing into
# whatever is in front.
wake_input() {
	"$DRIVE" key 56 >/dev/null 2>&1 || true
}

hid_idle_seconds() {
	ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF / 1000000000; exit}'
}

# The Mac is shared, and a pointer step while someone is typing both fails and
# interrupts them. Every scenario waits for a quiet keyboard and mouse first.
wait_idle_input() {
	local need="${1:-15}" limit="${2:-900}" i idle
	for i in $(seq 1 "$limit"); do
		idle="$(hid_idle_seconds)"
		if [ "${idle:-0}" -ge "$need" ]; then
			log "HID input idle for ${idle}s"
			return 0
		fi
		sleep 1
	done
	log "input never went idle for ${need}s"
	return 1
}

journal_count() {
	local table="$1"
	sqlite3 -readonly "$JOURNAL" "select count(*) from $table" 2>/dev/null || echo 0
}

# Wait for the first capture. On a warm home this is seconds; on a cold one it
# is the 30 to 60 second OCR model compile, which is exactly what the warm home
# exists to avoid.
wait_first_observation() {
	local limit="${1:-120}" i
	for i in $(seq 1 "$limit"); do
		[ "$(journal_count observations)" -ge 1 ] && { log "first observation after ${i}s"; return 0; }
		kill -0 "$ATHINA_PID" 2>/dev/null || die "Athina exited while waiting for the first capture"
		[ $((i % 3)) = 0 ] && wake_input
		sleep 1
	done
	return 1
}

toast_window() { "$DRIVE" toast "$ATHINA_PID" 2>/dev/null || true; }

newest_suggestion_open() {
	sqlite3 -readonly "$JOURNAL" \
		"select count(*) from suggestions where id = (select max(id) from suggestions) and feedback is null" 2>/dev/null || echo 0
}

newest_suggestion_id() {
	sqlite3 -readonly "$JOURNAL" "select coalesce(max(id), 0) from suggestions" 2>/dev/null || echo 0
}

suggestion_feedback() {
	sqlite3 -readonly "$JOURNAL" "select coalesce(feedback, 'none') from suggestions where id = $1" 2>/dev/null || echo unknown
}

# Wait until a toast is up for a suggestion nobody has answered, nudging
# sensing along the way: the helper window flips (a screen that never changes
# journals nothing) and Capture Now is pressed through accessibility.
# Prints the toast's window id.
wait_toast() {
	local limit="${1:-300}" i last_flip=0 last_capture=0 switches=0 now toast
	for i in $(seq 1 "$limit"); do
		kill -0 "$ATHINA_PID" 2>/dev/null || die "Athina exited while waiting for a toast"
		toast="$(toast_window)"
		if [ -n "$toast" ] && [ "$(newest_suggestion_open)" = 1 ]; then
			log "toast window $toast up for suggestion $(newest_suggestion_id)"
			printf '%s\n' "$toast"
			return 0
		fi
		now=$(date +%s)
		if [ $((now - last_flip)) -ge 10 ]; then
			# A screen that never changes journals nothing, and a window
			# switch is what makes the next capture a focus-change one, so
			# both nudges go together.
			[ -n "${FLIP_PID:-}" ] && { kill -USR1 "$FLIP_PID" 2>/dev/null || true; }
			wake_input
			if [ -n "${TEXTEDIT_PID:-}" ]; then
				if [ $((switches % 2)) = 0 ]; then
					raise_window "$TEXTEDIT_PID" plan.txt
				else
					raise_window "$TEXTEDIT_PID" notes.txt
				fi
				switches=$((switches + 1))
			fi
			last_flip=$now
		fi
		if [ $((now - last_capture)) -ge 30 ]; then
			"$DRIVE" ax "$ATHINA_PID" pressextra >/dev/null 2>&1
			sleep 0.5
			"$DRIVE" ax "$ATHINA_PID" pressx AXMenuItem "Capture Now" --scope extras >/dev/null 2>&1
			"$DRIVE" ax "$ATHINA_PID" cancelmenu >/dev/null 2>&1
			last_capture=$(date +%s)
		fi
		sleep 1
	done
	log "no toast within ${limit}s"
	return 1
}

# A toast can expire while a scenario waits for the Mac to go quiet. A pointer
# step that lands after it went is not a check of anything, so say so and stop.
require_toast() {
	[ -n "$(toast_window)" ] && [ "$(newest_suggestion_open)" = 1 ] && return 0
	log "the toast went away while waiting; rerun the scenario"
	return 1
}

# --- Staging ------------------------------------------------------------------

# A window that keeps changing, so sensing has something to see. It never takes
# focus and ignores the mouse, so it cannot get in the way of whoever is at the
# Mac.
stage_flip_window() {
	local x="${1:-120}" y="${2:-200}" w="${3:-700}" h="${4:-380}"
	"$DRIVE" flip "$x" "$y" "$w" "$h" >>"$RUN_DIR/flip.log" 2>&1 9>&- &
	FLIP_PID=$!
	track_helper "$FLIP_PID"
	sleep 1
	log "staged the flipping helper window at ${x},${y} ${w}x${h} (pid $FLIP_PID)"
}

# Two plain text documents to click into and to switch between.
#
# The staged app is also what sensing watches: the terminal a run is started
# from is an excluded app, so a run with it in front would journal nothing at
# all. TextEdit is opened by the harness and stopped by pid.
stage_text_document() {
	local first="$RUN_DIR/notes.txt" second="$RUN_DIR/plan.txt"
	cat >"$first" <<'TEXT'
Cleanup plan for the build machine
1. list the stale build roots
2. check nothing is mounted under them
3. remove them one at a time
TEXT
	cat >"$second" <<'TEXT'
Release checklist
- tag the build
- write the release notes
- tell the team where the artifacts are
TEXT
	local already
	already="$(pgrep -x TextEdit || true)"
	open -a TextEdit "$first" "$second" || { log "could not open TextEdit"; return 1; }
	sleep 3
	TEXTEDIT_PID="$(pgrep -n -x TextEdit || true)"
	[ -n "$TEXTEDIT_PID" ] || { log "TextEdit did not start"; return 1; }
	if [ -n "$already" ]; then
		# The owner had TextEdit open and `open -a` reused it. Quitting it
		# would take his work with it, so only these two documents come down.
		STAGED_WINDOWS+=("$TEXTEDIT_PID:notes.txt" "$TEXTEDIT_PID:plan.txt")
		log "TextEdit was already running (pid $TEXTEDIT_PID); only this run's documents will be closed"
	else
		STAGED_PIDS+=("$TEXTEDIT_PID")
	fi
	raise_window "$TEXTEDIT_PID" notes.txt
	log "staged TextEdit pid=$TEXTEDIT_PID with notes.txt and plan.txt"
}

# An app Athina is set to ignore, so a scenario can watch the item switch into
# and out of the excluded mode. Calculator has no documents of the owner's to
# reuse or close, and it is in the seeded exclusions beside his own apps.
stage_excluded_app() {
	local already
	already="$(pgrep -x Calculator || true)"
	open -g -a Calculator || { log "could not open Calculator"; return 1; }
	sleep 2
	EXCLUDED_PID="$(pgrep -n -x Calculator || true)"
	[ -n "$EXCLUDED_PID" ] || { log "Calculator did not start"; return 1; }
	if [ -n "$already" ]; then
		log "Calculator was already running (pid $EXCLUDED_PID); it will be left running"
	else
		STAGED_PIDS+=("$EXCLUDED_PID")
	fi
	log "staged the excluded app Calculator pid=$EXCLUDED_PID"
}

# Bring one window of a pid forward. Within an app this is a window switch, the
# change moment the capture scenarios are about.
raise_window() {
	"$DRIVE" raise "$1" "${2:-}" >>"$RUN_DIR/transcript.log" 2>&1 || log "could not raise ${2:-a window} of pid $1"
	return 0
}

# --- The menu bar -------------------------------------------------------------

# Athina's own status item, as one `extra` line of the bar report.
athina_extra() { "$DRIVE" bar | grep "^extra .*pid=$ATHINA_PID " || true; }

athina_item_width() { athina_extra | sed -n 's/.* w=\([0-9.]*\) .*/\1/p'; }

# The item's accessibility name, which is also how a scenario reads the mode.
athina_item_title() { athina_extra | sed -n 's/.*title="\([^"]*\)".*/\1/p'; }

# The mode out of that name, without the app's own name or the replay badge.
# The badge carries the clock's speed under --time-scale ("Replay 4.0x"), so a
# check on the mode has to read past it.
athina_item_mode() { athina_item_title | sed -E 's/^Athina, (Recording, |Replay[^,]*, )?//'; }

# The item's name lags an app switch by a few seconds, so a measurement taken
# right after one can still be of the mode before it.
wait_item_title() {
	local want="$1" limit="${2:-30}" i
	for i in $(seq 1 "$limit"); do
		case "$(athina_item_title)" in *"$want"*) return 0 ;; esac
		sleep 1
	done
	return 1
}

# --- Settings and talking back -----------------------------------------------

# The id of the first window of Athina's whose name starts with $1, empty when
# none is open.
athina_window_id() {
	"$DRIVE" windows "$ATHINA_PID" \
		| awk -v want="$1" 'index($0, "name=\"" want) {sub("id=", "", $1); print $1; exit}' || echo ""
}

wait_athina_window() {
	local want="$1" limit="${2:-20}" i
	for i in $(seq 1 "$limit"); do
		[ -n "$(athina_window_id "$want")" ] && return 0
		sleep 0.5
	done
	return 1
}

# Settings > General, open: the window --open settings:general put up, or, when
# it is gone (something on a shared screen can close it during a long wait),
# the Settings… item of Athina's own menu, as a person would reopen it. The
# window list is kept either way, so a closed window is on record.
ensure_general_open() {
	[ -n "$(athina_window_id General)" ] && return 0
	{ printf '=== General missing at %s\n' "$(date '+%H:%M:%S')"; "$DRIVE" windows "$ATHINA_PID"; } >>"$RUN_DIR/windows.log" 2>&1
	log "Settings > General is not open; opening it from the menu"
	"$DRIVE" ax "$ATHINA_PID" pressextra >>"$RUN_DIR/transcript.log" 2>&1 || return 1
	sleep 0.8
	"$DRIVE" ax "$ATHINA_PID" pressx AXMenuItem "Settings…" --scope extras >>"$RUN_DIR/transcript.log" 2>&1 || {
		"$DRIVE" ax "$ATHINA_PID" cancelmenu >>"$RUN_DIR/transcript.log" 2>&1
		return 1
	}
	wait_athina_window General 20
}

# A setting as the replay saved it, read from its own settings file: $1 is a
# Python expression over `s`, the file's JSON.
saved_setting() {
	SETTINGS_FILE="$(replay_data_dir)/settings.json" EXPRESSION="$1" python3 -c '
import json, os
s = json.load(open(os.environ["SETTINGS_FILE"]))
print(eval(os.environ["EXPRESSION"]))
' 2>/dev/null || echo ""
}

# The recognizer the replay has chosen. Nothing is saved until a setting
# changes, and until then it is the default, SpeechAnalyzer.
saved_speech_backend() {
	local saved
	saved="$(saved_setting 's["mentor"]["speech"]["backend"]')"
	echo "${saved:-speechAnalyzer}"
}

# Chooses a speech recognizer in Settings > General the way the keyboard or
# VoiceOver does, through the picker's own menu, and waits for the replay to
# save the choice.
pick_speech_backend() {
	local title="$1" raw="$2" i
	ensure_general_open || { log "Settings > General could not be opened"; return 1; }
	# The picker's row has to be on screen for accessibility to offer it.
	scroll_general_to 0.38
	press_named AXPopUpButton "Speech recognizer" || return 1
	press_named AXMenuItem "$title" || return 1
	for i in $(seq 1 20); do
		[ "$(saved_speech_backend)" = "$raw" ] && return 0
		sleep 0.5
	done
	log "the speech recognizer never became $raw"
	return 1
}

# Presses a control in Settings > General by its accessibility name. A row
# whose state just changed is rebuilt, and for a moment accessibility has no
# element by that name, so the press is tried again for a few seconds.
press_named() {
	local role="$1" name="$2" i
	for i in $(seq 1 10); do
		"$DRIVE" ax "$ATHINA_PID" pressx "$role" "$name" --scope General >>"$RUN_DIR/transcript.log" 2>&1 && return 0
		sleep 0.5
	done
	log "could not press $name"
	return 1
}

# Scrolls Settings > General by setting the pane's scroll bar, the only
# scroll a SwiftUI form takes from accessibility.
scroll_general_to() {
	"$DRIVE" ax "$ATHINA_PID" set AXScrollBar "" "$1" --scope General >>"$RUN_DIR/transcript.log" 2>&1 || true
	sleep 0.5
}

# The General pane's text as accessibility reads it, and a picture of it.
general_state() {
	local tag="$1" id
	"$DRIVE" ax "$ATHINA_PID" texts --scope General >"$RUN_DIR/$tag-texts.txt" 2>&1 || true
	"$DRIVE" ax "$ATHINA_PID" dump --scope General >"$RUN_DIR/$tag-tree.txt" 2>&1 || true
	{ printf '=== %s at %s\n' "$tag" "$(date '+%H:%M:%S')"; "$DRIVE" windows "$ATHINA_PID"; } >>"$RUN_DIR/windows.log" 2>&1
	id="$(athina_window_id General)"
	[ -n "$id" ] && "$DRIVE" shot window "$id" "$RUN_DIR/$tag.png" >/dev/null 2>&1
	return 0
}

# Plays a recording into the replay's listener through scripts/talk-back.sh,
# in the background; the answer lands in $RUN_DIR/<tag>-reply.json.
play_recording() {
	local file="$1" tag="$2"
	"$ROOT/scripts/talk-back.sh" "$ATHINA_PID" "$file" >"$RUN_DIR/$tag-reply.json" 2>>"$RUN_DIR/transcript.log" &
	PLAYING_PID=$!
}

# Waits for the recording played last to be heard and handled.
wait_recording() {
	local status=0
	wait "$PLAYING_PID" 2>/dev/null || status=$?
	PLAYING_PID=""
	return $status
}

# A field of a talk-back answer.
reply_field() {
	REPLY_FILE="$RUN_DIR/$1-reply.json" FIELD="$2" python3 -c '
import json, os
value = json.load(open(os.environ["REPLY_FILE"])).get(os.environ["FIELD"])
print("" if value is None else value)
' 2>/dev/null || echo ""
}

# --- Watchers -----------------------------------------------------------------

watch_announcements() {
	"$DRIVE" announce "$ATHINA_PID" >"$RUN_DIR/announcements.log" 2>&1 9>&- &
	track_helper $!
}

watch_clicks() {
	"$DRIVE" tap session >"$RUN_DIR/session-clicks.log" 2>&1 9>&- &
	track_helper $!
	"$DRIVE" tap pid "$ATHINA_PID" >"$RUN_DIR/athina-clicks.log" 2>&1 9>&- &
	track_helper $!
	sleep 0.5
}

# --- Evidence -----------------------------------------------------------------

# The state of everything at one moment: Athina's windows, a shot of the toast
# and of any open menu, and the journal.
snapshot_state() {
	local tag="$1" windows menu_id n=0
	{
		printf '=== %s at %s\n' "$tag" "$(date '+%H:%M:%S')"
		windows="$("$DRIVE" windows "$ATHINA_PID")"
		printf '%s\n' "$windows"
		printf -- '--- suggestions\n'
		"$DRIVE" journal "$JOURNAL" suggestions
	} >>"$RUN_DIR/transcript.log" 2>&1

	windows="$("$DRIVE" windows "$ATHINA_PID")"
	while read -r menu_id; do
		[ -n "$menu_id" ] || continue
		n=$((n + 1))
		"$DRIVE" shot window "$menu_id" "$RUN_DIR/$tag-menu$n.png" >/dev/null 2>&1
	done < <(printf '%s\n' "$windows" | awk '/layer=101/ {sub("id=", "", $1); print $1}')

	local toast
	toast="$(toast_window)"
	[ -n "$toast" ] && "$DRIVE" shot window "$toast" "$RUN_DIR/$tag-toast.png" >/dev/null 2>&1
	return 0
}

# What a scenario leaves behind for whoever reads the run afterwards.
write_evidence() {
	local query
	for query in suggestions calls follow-ups events observations; do
		"$DRIVE" journal "$JOURNAL" "$query" >"$RUN_DIR/journal-$query.tsv" 2>/dev/null || true
	done
	# The journal is WAL, so it is copied through sqlite3 rather than cp.
	sqlite3 -readonly "$JOURNAL" ".backup '$RUN_DIR/journal.sqlite'" 2>/dev/null || true
	return 0
}

# One machine-readable line per scenario, on stdout, whatever the log says.
result_line() {
	local name="$1" result="$2" seconds="$3" detail="$4"
	NAME="$name" RESULT="$result" SECONDS_TAKEN="$seconds" DETAIL="$detail" EVIDENCE="$RUN_DIR" \
		CHECKS="$(printf '%s\n' ${CHECK_LINES[@]+"${CHECK_LINES[@]}"})" python3 - <<'PY'
import json, os
print(json.dumps({
    "scenario": os.environ["NAME"],
    "result": os.environ["RESULT"],
    "seconds": int(os.environ["SECONDS_TAKEN"]),
    "detail": os.environ["DETAIL"],
    "evidence": os.environ["EVIDENCE"],
    "checks": [line for line in os.environ["CHECKS"].splitlines() if line],
}, sort_keys=True))
PY
}
