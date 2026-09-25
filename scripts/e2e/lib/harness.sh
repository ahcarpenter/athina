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
# When the build of the bundle now in $APP started (scripts/bundle.sh).
APP_BUILT="$APP.built"
DRIVE="$ROOT/.build/debug/athina-drive"
# When the build that last brought athina-drive up to date started (ensure_drive).
DRIVE_BUILT="$ROOT/build/athina-drive.built"
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
# Read by the entry point and by scenarios that source this file.
# shellcheck disable=SC2034
RUNS_ROOT="$CACHE_ROOT/runs"

# --- Run state ----------------------------------------------------------------

RUN_DIR=""
HOME_DIR=""
JOURNAL=""
ATHINA_PID=""
# The arguments the run's Athina was launched with, so a relaunch gets the same.
LAUNCH_ARGS=()
LAUNCHED_AT=0
RELAUNCHES=0
EXCLUDED_PID=""
CONTROL_DIR=""
HELPER_PIDS=()
# The watchers of the launch now running, whose logs the checks read.
WATCHER_PIDS=()
STAGED_PIDS=()
STAGED_WINDOWS=()
PREFS_BACKUP=""
PREFS_EXISTED=0
CHECKS_FAILED=0
CHECK_LINES=()
# The step of a scenario that names its steps (step), which every check and a
# scenario that stops early carry.
STEP=""

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
# and every check reaches the result line, so a failure names itself, and the
# step it was made in when the scenario names its steps.
check() {
	local name="$1" expected="$2" actual="$3"
	[ -n "$STEP" ] && name="step $STEP: $name"
	if [ "$expected" = "$actual" ]; then
		log "  ok   $name = $actual"
		CHECK_LINES+=("ok $name=$actual")
	else
		log "  FAIL $name: expected $expected, got $actual"
		CHECK_LINES+=("FAIL $name: expected=$expected actual=$actual")
		CHECKS_FAILED=$((CHECKS_FAILED + 1))
	fi
}

# Start the next step of a scenario that runs several in one launch, named
# "<number> <what it proves>", so a failed check, or a scenario that stops at
# it, says which step it was.
step() {
	STEP="$1"
	log "--- step $STEP"
}

# --- Building -----------------------------------------------------------------

# Is anything under the given directories newer than the built product?
sources_newer_than() {
	local product="$1"
	shift
	[ -x "$product" ] || return 0
	[ -n "$(find "$@" -name '*.swift' -newer "$product" -print -quit)" ]
}

# Is anything under the given directories newer than the stamp of the build
# that last brought the built product up to date? Not the product itself: a
# source saved during a build, after it was compiled, is older than the product
# that build lands, and SwiftPM leaves athina-drive as it was when no source
# really changed, so after a touch-only edit it stays older than that source
# however often it is built. The stamp, made when that build started, is what
# says the source was built.
sources_newer_than_build() {
	local product="$1" stamp="$2"
	shift 2
	[ -x "$product" ] && [ -e "$stamp" ] || return 0
	[ -n "$(find "$@" -name '*.swift' -newer "$stamp" -print -quit)" ]
}

# Where a build happens, for its log line. The entry point builds before it
# takes the screen lock, so no other checkout waits on a build; one inside the
# lock means a source file was saved after the last build started, which is
# while this run waited for the lock or during that build.
build_when() {
	if [ "${SCREEN_LOCK_STATE:-0}" = 0 ]; then
		echo "before taking the screen lock"
	else
		echo "inside the screen lock, since a source file was saved after the last build started"
	fi
}

ensure_drive() {
	sources_newer_than_build "$DRIVE" "$DRIVE_BUILT" "$ROOT/Sources/AthinaDrive" "$ROOT/Sources/AthinaE2E" "$ROOT/Sources/AthinaControlProtocol" || return 0
	log "building athina-drive $(build_when)"
	# Stamped when the build starts, so a source saved during it is still newer.
	mkdir -p "$(dirname "$DRIVE_BUILT")"
	local started
	started="$(mktemp "$DRIVE_BUILT.XXXXXX")"
	(cd "$ROOT" && swift build --product athina-drive >/dev/null) || { rm -f "$started"; die "could not build athina-drive"; }
	mv -f "$started" "$DRIVE_BUILT"
}

# A check of a stale bundle proves nothing, so the app is rebuilt when a source
# file was saved after its last build started, which scripts/bundle.sh stamps
# for every build, `make build` included. The harness's own bundle is the
# development one, so it is rebuilt too when it carries no control API, as
# after `scripts/bundle.sh --no-control`, rather than skip the API tier. Never
# while something is running from it, though: scripts/bundle.sh deletes the
# bundle first, and another lane, or the owner, may be using this one.
#
# Sets CONTROL_API to whether the API tier runs: always on the harness's own
# bundle, and on an ATHINA_E2E_APP bundle only when it carries the control API,
# which no release build does, so there each API-tier scenario is skipped.
# CONTROL_API is read by the entry point.
# shellcheck disable=SC2034
ensure_app() {
	CONTROL_API=yes
	if [ -n "${ATHINA_E2E_APP:-}" ]; then
		[ -x "$APP_BINARY" ] || die "ATHINA_E2E_APP names $APP, which holds no Athina executable"
		sources_newer_than "$APP_BINARY" "$ROOT/Sources" && log "WARNING: a source file is newer than $APP, which is checked as it is"
		bundle_has_control_api || CONTROL_API=no
		return 0
	fi
	local why
	if sources_newer_than_build "$APP_BINARY" "$APP_BUILT" "$ROOT/Sources"; then
		why="may be out of date"
	elif ! bundle_has_control_api; then
		why="is the development bundle but carries no control API"
	else
		return 0
	fi
	if pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
		die "$APP $why and something is running from it; rebuild it when nothing is"
	fi
	log "building $APP $(build_when), since it $why"
	(cd "$ROOT" && scripts/bundle.sh release >/dev/null 2>&1) || die "could not build the app bundle"
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
# and the toast lives long enough to survive a wait for idle input. The triage
# gate is at its 5 second floor, so with the replay answering at once (see
# launch_athina) the first toast comes seconds after the first capture.
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

# --- Launching and stopping ---------------------------------------------------

# Replay only, sandboxed, in a scratch home, tracked by pid, and answered at
# once: `--replay-latency immediate` skips each fixture's recorded latency, 41
# seconds for the mentor call that raises a toast, which a check has no use for
# and which is time for a click by whoever is at the Mac to dismiss the toast.
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
	# `8>&- 9>&-` here and on every helper started in the background: the
	# locks' descriptors (lib/lock.sh) stay with the harness, so nothing that
	# outlives a killed run can keep a lock.
	sed -e "s#__LIVE_SUPPORT__#$LIVE_SUPPORT#" -e "s#__LEGACY_SUPPORT__#$LEGACY_SUPPORT#" "$E2E_DIR/lib/isolate.sb" >"$profile"
	CFFIXED_USER_HOME="$home" HOME="$home" \
		sandbox-exec -f "$profile" "$APP_BINARY" --replay "$FIXTURES" --replay-latency immediate "$@" \
		>>"$RUN_DIR/app.log" 2>&1 8>&- 9>&- &
	ATHINA_PID=$!
	LAUNCH_ARGS=("$@")
	LAUNCHED_AT=$(date +%s)
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
			# An API-tier run posts no input of its own unless a scenario that
			# needs sensing asks for it (wait_first_observation does).
			[ "${SCENARIO_TIER:-screen}" = api ] || wake_input
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

# Stop the run's Athina and launch it again in the same home with the same
# arguments. A replay makes a new data directory for each launch, so the new one
# starts from an empty journal, as the first did. The earlier launch's journal
# and watcher logs are kept with the evidence under names of their own, and the
# watchers start again on fresh logs, so a check after the relaunch reads only
# what the new launch saw.
relaunch_athina() {
	local pid name
	RELAUNCHES=$((RELAUNCHES + 1))
	sqlite3 -readonly "$JOURNAL" ".backup '$RUN_DIR/journal-launch$RELAUNCHES.sqlite'" 2>/dev/null || true
	for pid in ${WATCHER_PIDS[@]+"${WATCHER_PIDS[@]}"}; do stop_pid "$pid"; done
	WATCHER_PIDS=()
	for name in announcements session-clicks athina-clicks; do
		mv "$RUN_DIR/$name.log" "$RUN_DIR/$name-launch$RELAUNCHES.log"
	done
	log "relaunching Athina (pid $ATHINA_PID's journal and watcher logs kept as journal-launch$RELAUNCHES.sqlite and *-launch$RELAUNCHES.log)"
	stop_pid "$ATHINA_PID"
	launch_athina "$HOME_DIR" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}
	# The same control directory, where the new launch makes its socket again.
	if [ -n "$CONTROL_DIR" ]; then control_wait; fi
	watch_announcements
	watch_clicks
	wait_first_observation 90 || log "WARNING: no capture yet after the relaunch"
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
	for pid in ${HELPER_PIDS[@]+"${HELPER_PIDS[@]}"} ${WATCHER_PIDS[@]+"${WATCHER_PIDS[@]}"}; do stop_pid "$pid"; done
	for pid in ${STAGED_PIDS[@]+"${STAGED_PIDS[@]}"}; do stop_pid "$pid"; done
	stop_pid "$ATHINA_PID"
	[ -n "${CONTROL_DIR:-}" ] && rm -rf "$CONTROL_DIR"
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
# exists to avoid. Sensing captures nothing while an excluded app is in front,
# and whoever is at the Mac may have gone back to one since TextEdit was
# staged, so the nudge brings TextEdit forward again.
wait_first_observation() {
	local limit="${1:-120}" i
	for i in $(seq 1 "$limit"); do
		[ "$(journal_count observations)" -ge 1 ] && { log "first observation after ${i}s"; return 0; }
		kill -0 "$ATHINA_PID" 2>/dev/null || die "Athina exited while waiting for the first capture"
		if [ $((i % 3)) = 0 ]; then
			wake_input
			[ -n "${TEXTEDIT_PID:-}" ] && raise_window "$TEXTEDIT_PID" notes.txt
		fi
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
# sensing along the way: every 2 seconds the helper window flips (a screen that
# never changes journals nothing) and TextEdit switches windows, and after 30
# seconds with no toast Capture Now is pressed through accessibility. It looks
# for the toast every quarter second, since with an immediate replay and the
# triage gate at its floor the toast comes seconds after the first capture.
# Prints the toast's window id.
wait_toast() {
	local limit="${1:-300}" started last_flip=0 last_capture switches=0 now toast
	started=$(date +%s)
	last_capture=$started
	while [ $(($(date +%s) - started)) -lt "$limit" ]; do
		kill -0 "$ATHINA_PID" 2>/dev/null || die "Athina exited while waiting for a toast"
		toast="$(toast_window)"
		if [ -n "$toast" ] && [ "$(newest_suggestion_open)" = 1 ]; then
			now=$(date +%s)
			log "toast window $toast up for suggestion $(newest_suggestion_id) after waiting $((now - started))s ($((now - LAUNCHED_AT))s since launch)"
			printf '%s\n' "$toast"
			return 0
		fi
		now=$(date +%s)
		if [ $((now - last_flip)) -ge 2 ]; then
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
		sleep 0.25
	done
	log "no toast within ${limit}s"
	return 1
}

toast_up() { [ -n "$(toast_window)" ] && [ "$(newest_suggestion_open)" = 1 ]; }

# Make sure the scenario's toast is still up, first waiting for `idle` seconds
# of quiet keyboard and mouse when that is given, and bring a new toast up when
# it went.
#
# The toast listens for clicks anywhere, as it must, so a click by whoever is at
# the Mac dismisses it, and a wait for idle input is exactly when that happens.
# That is someone using their Mac, not a failure of anything, so rather than
# fail the run, Athina is relaunched for a new toast and the wait starts again,
# three times at most. A relaunch rather than Show Last Suggestion: that brings
# the toast back but not an unanswered suggestion, since the journal keeps the
# dismissal, and the checks after this read the answer the suggestion gets
# next. So a scenario reads the suggestion and the toast after this returns,
# never before.
keep_toast_up() {
	local idle="${1:-0}" relaunched=0 newest
	while :; do
		if [ "$idle" -gt 0 ]; then
			wait_idle_input "$idle" || return 1
		fi
		toast_up && return 0
		newest="$(newest_suggestion_id)"
		if [ "$relaunched" -ge 3 ]; then
			log "the toast went away $((relaunched + 1)) times (suggestion $newest: $(suggestion_feedback "$newest")); the Mac is too busy for this scenario now"
			return 1
		fi
		relaunched=$((relaunched + 1))
		log "the toast went away (suggestion $newest: $(suggestion_feedback "$newest")); relaunching for a new one"
		relaunch_athina
		wait_toast >/dev/null || return 1
	done
}

# --- Staging ------------------------------------------------------------------

# A window that keeps changing, so sensing has something to see. It never takes
# focus and ignores the mouse, so it cannot get in the way of whoever is at the
# Mac.
stage_flip_window() {
	local x="${1:-120}" y="${2:-200}" w="${3:-700}" h="${4:-380}"
	"$DRIVE" flip "$x" "$y" "$w" "$h" >>"$RUN_DIR/flip.log" 2>&1 8>&- 9>&- &
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
	# TextEdit has been seen to take over 20 seconds to come up on a busy Mac,
	# so this waits for the document's window rather than a fixed time: a run
	# that went on without it would watch whatever else was in front.
	for _ in $(seq 1 30); do
		TEXTEDIT_PID="$(pgrep -n -x TextEdit || true)"
		[ -n "$TEXTEDIT_PID" ] && "$DRIVE" windows "$TEXTEDIT_PID" 2>/dev/null | grep -q 'name="notes.txt' && break
		sleep 1
	done
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

# The id of the first window whose name starts with $1, empty when none is open.
window_id() {
	"$DRIVE" windows "$ATHINA_PID" \
		| awk -v want="$1" 'index($0, "name=\"" want) {sub("id=", "", $1); print $1; exit}' || echo ""
}

# --- The control API ----------------------------------------------------------

# An API-tier scenario (SCENARIO_TIER=api) drives Athina through its control
# API (README "The control API") rather than the pointer and accessibility from
# outside: the app finds its own controls and clicks them through its own event
# path, so no step waits for idle input.

# Whether the bundle under test carries the control API, as the release check
# (scripts/check-no-control-api.sh) finds it: a release build carries none.
bundle_has_control_api() {
	local status=0
	"$ROOT/scripts/check-no-control-api.sh" "$APP_BINARY" >/dev/null 2>&1 || status=$?
	case "$status" in
	0) return 1 ;;
	1) return 0 ;;
	*) die "could not tell whether $APP carries the control API" ;;
	esac
}

# The run's control directory: 0700, inside the per-user temporary directory
# (itself closed to everyone else) rather than the run's home, whose path is
# too long for a Unix socket, and holding the run's secret. The app makes its
# socket there; athina-drive api finds both through ATHINA_CONTROL_DIR.
control_prepare() {
	local temporary
	temporary="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
	[ -n "$temporary" ] || temporary="${TMPDIR:-/tmp}"
	CONTROL_DIR="$(mktemp -d "${temporary%/}/athina-ctl.XXXXXX")" || die "could not make a control directory"
	chmod 700 "$CONTROL_DIR"
	(umask 077 && head -c 32 /dev/urandom | xxd -p -c 64 >"$CONTROL_DIR/secret") || die "could not write the control secret"
	export ATHINA_CONTROL_DIR="$CONTROL_DIR"
	log "control directory $CONTROL_DIR"
}

# Waits until the app answers on its control socket. The app says on stderr
# why when it will not serve one, which ends the run with that reason.
control_wait() {
	local i refusal
	for i in $(seq 1 100); do
		if "$DRIVE" api ping >>"$RUN_DIR/api.log" 2>&1; then
			log "control API answering after $((i / 10)).$((i % 10))s"
			return 0
		fi
		refusal="$(grep -m 1 -E '^control API (refused|failed): ' "$RUN_DIR/app.log" 2>/dev/null || true)"
		[ -n "$refusal" ] && die "$refusal"
		kill -0 "$ATHINA_PID" 2>/dev/null || die "Athina exited before its control API answered; see $RUN_DIR/app.log"
		sleep 0.1
	done
	die "the control API never answered; see $RUN_DIR/app.log and $RUN_DIR/api.log"
}

# Reads $2 (a function) until it prints $1, for up to two seconds, and prints
# the last read: SwiftUI redraws a control a moment after the click that
# changed it has been handled.
settled() {
	local want="$1" read="$2" got="" i
	for i in $(seq 1 20); do
		got="$("$read")"
		[ "$got" = "$want" ] && break
		sleep 0.1
	done
	printf '%s\n' "$got"
}

# A Python expression over a JSON answer, bound to `r`, printed: for checks
# that count or search what an answer holds. Arguments after the expression
# are `a[0]`, `a[1]`, and so on.
json_eval() {
	python3 -c 'import json, re, sys; r = json.loads(sys.argv[1]); a = sys.argv[3:]; print(eval(sys.argv[2]))' "$@" 2>>"$RUN_DIR/api.log"
}

# One request to the app; the answer goes to api.log and, with --field, the
# field alone to stdout. Returns non-zero when the answer is not ok.
api() {
	local status=0 answer
	answer="$("$DRIVE" api "$@" 2>>"$RUN_DIR/api.log")" || status=$?
	printf '%s %s\n    %s\n' "$(date '+%H:%M:%S')" "$*" "$answer" >>"$RUN_DIR/api.log"
	printf '%s\n' "$answer"
	return "$status"
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

# --- Watchers -----------------------------------------------------------------

watch_announcements() {
	"$DRIVE" announce "$ATHINA_PID" >"$RUN_DIR/announcements.log" 2>&1 8>&- 9>&- &
	WATCHER_PIDS+=($!)
}

watch_clicks() {
	"$DRIVE" tap session >"$RUN_DIR/session-clicks.log" 2>&1 8>&- 9>&- &
	WATCHER_PIDS+=($!)
	"$DRIVE" tap pid "$ATHINA_PID" >"$RUN_DIR/athina-clicks.log" 2>&1 8>&- 9>&- &
	WATCHER_PIDS+=($!)
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
