#!/usr/bin/env bash
# Launch build/Athina.app for a make target, replacing only the copy that the
# same lane launched before from this checkout: never an Athina from another
# checkout, another lane, or anything started some other way.
#
# Usage:
#   scripts/launch.sh replay [--lane <name>] [--fixtures <dir>] [--settings <file>]
#                            [--time-scale <n>] [--allow-stale]
#   scripts/launch.sh live --spend
#   scripts/launch.sh record --spend [<dir>]
#
# `replay` (`make run`) answers every model call from the fixtures in <dir>,
# the committed set unless given: no network, no key, no spend, and serves
# the control API (docs/e2e.md "The control API") on a directory made here for the
# lane, which build/<lane>.control names, so scripts/advance-clock.sh can move
# its clock. `live`
# (`make run-live`) is the live app, and `record` (`make record`) the live app
# writing every model call to a fixture file, into <dir> or the app's own
# recordings directory, with the debug panel open; both spend API credits,
# so both refuse to start without --spend, which `make run-live SPEND=1` and
# `make record SPEND=1` pass, and both say the hourly spend cap they will
# stop at, from the live settings, before they launch.
# A leading ~ in a path is expanded here, because zsh leaves it after `=`.
#
# Each lane has a pid file, build/<lane>.pid. `live` and `record` share the
# lane "live", since both use the live journal and settings; `replay` uses
# "replay" unless given --lane <name>.
#
# The instance is identified exactly, not guessed: the launch carries
# `--launch-token <id>`, a unique argument the app ignores, and the pid is the
# one running this checkout's bundle with that token in its arguments. Diffing
# the set of Athina processes before and after would adopt the wrong one when
# two launches from this checkout overlap, which "any number of replays at
# once" invites. The pid is reported, and written to the pid file, only once
# the app itself says it started, on the line it writes past every reason it
# could refuse this launch and past the point where its control API is
# listening. Elapsed time is never taken as proof: on a loaded Mac the app can
# still be short of that point after seconds.
#
# A live launch guards the live files. Before this script, every launch target
# began with `pkill -x Athina`, so two live instances were impossible; two of
# them share one journal, both write the whole settings file when they quit,
# and both bill the API. A live launch therefore refuses to start while another
# live Athina runs, naming it. A replay needs no such guard: its data
# directory is its own.
set -euo pipefail

usage() {
	cat >&2 <<'TEXT'
usage: scripts/launch.sh replay [--lane <name>] [--fixtures <dir>] [--settings <file>]
                                [--time-scale <n>] [--allow-stale]
       scripts/launch.sh live --spend
       scripts/launch.sh record --spend [<dir>]
TEXT
	exit 2
}

# The physical path, because that is the one `ps` reports for the running
# process, and both pid searches below match on it.
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# `$1` with a leading ~ expanded.
expand_tilde() {
	# A literal ~ is what is being matched, not expanded.
	# shellcheck disable=SC2088
	case "$1" in
	"~" | "~/"*) printf '%s\n' "$HOME${1#\~}" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

# The hourly spend cap the live app stops calling at, in dollars: Settings >
# Models, `mentor.hourlySpendCap` in the live settings.json, which a first
# launch copies from Mentor's when Athina has none yet (docs/coming-from-mentor.md),
# clamped as `MentorSettings.validated()` clamps it, and its default when unset.
spend_cap() {
	local support="$HOME/Library/Application Support" file cap=""
	for file in "$support/athina/settings.json" "$support/mentor/settings.json"; do
		[ -f "$file" ] || continue
		cap="$(plutil -extract mentor.hourlySpendCap raw -o - "$file" 2>/dev/null || true)"
		break
	done
	awk -v cap="${cap:-1}" 'BEGIN {
		if (cap < 0.05) cap = 0.05
		if (cap > 1000) cap = 1000
		printf "$%.2f an hour", cap
	}'
}

# Refuses a launch that would spend without being asked to, naming how to ask.
refuse_spend() {
	{
		echo "launch: make $1 calls the Anthropic API and spends credits, up to $(spend_cap) (the spend cap in Settings > Models)."
		echo "launch: nothing started; to spend, run make $1 SPEND=1, or make run for a replay that spends nothing"
	} >&2
	exit 1
}

[ "$#" -ge 1 ] || usage
MODE="$1"
shift
LIVE=0
# The app's arguments, built up below; each path is its own element, so one
# with a space in it stays one argument.
ARGS=()
case "$MODE" in
replay)
	LANE=replay
	fixtures="$ROOT/Tests/AthinaCoreTests/Fixtures/Replay"
	settings=""
	time_scale=""
	allow_stale=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--lane) [ "$#" -ge 2 ] || usage; LANE="$2"; shift 2 ;;
		--fixtures) [ "$#" -ge 2 ] || usage; fixtures="$(expand_tilde "$2")"; shift 2 ;;
		--settings) [ "$#" -ge 2 ] || usage; settings="$(expand_tilde "$2")"; shift 2 ;;
		--time-scale) [ "$#" -ge 2 ] || usage; time_scale="$2"; shift 2 ;;
		--allow-stale) allow_stale=1; shift ;;
		*) usage ;;
		esac
	done
	[ -d "$fixtures" ] || { echo "launch: no fixture directory at $fixtures" >&2; exit 1; }
	ARGS+=(--replay "$(cd "$fixtures" && pwd)")
	[ "$allow_stale" = 0 ] || ARGS+=(--allow-stale-fixtures)
	[ -z "$time_scale" ] || ARGS+=(--time-scale "$time_scale")
	if [ -n "$settings" ]; then
		[ -f "$settings" ] || { echo "launch: no settings file at $settings" >&2; exit 1; }
		ARGS+=(--settings "$(cd "$(dirname "$settings")" && pwd)/$(basename "$settings")")
	fi
	;;
live)
	if [ "${1:-}" = --spend ]; then shift; else refuse_spend run-live; fi
	[ "$#" -eq 0 ] || usage
	LANE=live
	LIVE=1
	;;
record)
	if [ "${1:-}" = --spend ]; then shift; else refuse_spend record; fi
	[ "$#" -le 1 ] || usage
	LANE=live
	LIVE=1
	ARGS+=(--record)
	if [ "$#" -eq 1 ] && [ -n "$1" ]; then
		dir="$(expand_tilde "$1")"
		# Only the recordings directory itself is kept private; its parents are
		# whatever they already were or would be.
		# shellcheck disable=SC2174
		mkdir -p -m 700 "$dir"
		ARGS+=("$(cd "$dir" && pwd)")
	fi
	ARGS+=(--open debug)
	;;
*) usage ;;
esac
APP="$ROOT/build/Athina.app"
EXECUTABLE="$APP/Contents/MacOS/Athina"
PID_FILE="$ROOT/build/$LANE.pid"
# The token is kept beside the pid rather than in it, so the pid stays the
# whole of that file for a person to `cat build/<lane>.pid` and `kill`.
TOKEN_FILE="$ROOT/build/$LANE.token"
# The replay's control directory (`--control`), which scripts/advance-clock.sh
# hands athina-drive.
CONTROL_FILE="$ROOT/build/$LANE.control"
# Where every control directory is made: the per-user temporary directory,
# closed to everyone else, whose path is short enough for the socket inside.
TEMPORARY="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
[ -n "$TEMPORARY" ] || TEMPORARY="${TMPDIR:-/tmp}"
TEMPORARY="${TEMPORARY%/}"
TOKEN="lane-$LANE-$$-$(date +%s)"

# The pid of this checkout's Athina whose arguments carry `$1`, or nothing.
# Both halves matter: the token alone would match the searching awk, whose own
# command line holds it, and the bundle alone would match a sibling lane.
lane_pid() {
	ps -axo pid=,command= | awk -v exe="$EXECUTABLE" -v token="$1" '{
		pid = $1
		sub(/^ *[0-9]+ +/, "")
		if (index($0, exe " ") != 1) next
		if (index($0, token)) print pid
	}' | head -n 1
}

# Every Athina on this Mac that is not a replay or a snapshot render, whatever
# checkout or bundle it came from, as "<pid> <command>" lines. A build from
# before the rename is the same app under its old name, Mentor, spending on the
# same key and holding the journal the first live Athina moves, so it counts.
#
# Which process is an Athina is decided on `comm`, the executable alone, never
# on the joined command line: a path with a space in it cannot be told from a
# path followed by an argument once they are joined, so a checkout under, say,
# "My Projects" would be invisible here and a second live Athina would start on
# the owner's journal, settings and bill. The command line is read only to say
# which ones are replays or snapshot renders, and to name them.
live_athinas() {
	{ ps -axo pid=,comm=; echo "|"; ps -axo pid=,command=; } | awk '
		$0 == "|" { commands = 1; next }
		{
			pid = $1
			sub(/^ *[0-9]+ +/, "")
			if (!commands) {
				if ($0 ~ /\/Athina\.app\/Contents\/MacOS\/Athina$/) athina[pid] = 1
				if ($0 ~ /\/Mentor\.app\/Contents\/MacOS\/Mentor$/) athina[pid] = 1
				next
			}
			if (!(pid in athina)) next
			if ($0 ~ /--replay($| )/ || $0 ~ /--snapshot($| )/) next
			print pid, $0
		}'
}

# Stops an Athina this script is answerable for, and waits for it to go: a
# killed app is still listed while the kernel tears it down, and the live guard
# would read that as a live Athina already running.
stop_pid() {
	local victim="$1"
	kill -TERM "$victim" 2>/dev/null || true
	for _ in $(seq 50); do
		kill -0 "$victim" 2>/dev/null || return 0
		sleep 0.1
	done
	echo "launch: pid $victim did not quit, stopping it" >&2
	kill -KILL "$victim" 2>/dev/null || true
	for _ in $(seq 50); do
		kill -0 "$victim" 2>/dev/null || return 0
		sleep 0.1
	done
}

# Stops what this lane launched, and only that. A pid on its own is not enough
# to say so: a lane stopped outside make leaves its pid file behind, and the
# Mac cycles through the pid space, so that number can come back as a sibling
# lane. The process has to still carry the token this lane launched it with.
stop_previous() {
	[ -f "$PID_FILE" ] || return 0
	local previous token
	previous="$(cat "$PID_FILE" 2>/dev/null || true)"
	token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
	if [ -n "$previous" ] && [ -n "$token" ] && [ "$(lane_pid "$token")" = "$previous" ]; then
		stop_pid "$previous"
	fi
	remove_control "$(cat "$CONTROL_FILE" 2>/dev/null || true)"
	rm -f "$PID_FILE" "$TOKEN_FILE" "$CONTROL_FILE"
}

# Removes a control directory this script made, and nothing else: the path
# comes from a file under build/, so only one named the way it names them, in
# the directory it makes them in, is taken for one.
remove_control() {
	case "$1" in
	"$TEMPORARY"/athina-run-ctl.*) rm -rf "$1" ;;
	esac
}

stop_previous

if [ "$LIVE" = 1 ]; then
	running="$(live_athinas || true)"
	if [ -n "$running" ]; then
		{
			echo "launch: a live Athina, or Mentor as it was called, is already running, so this one would share its journal, its settings, and its API spend:"
			echo "  ${running//$'\n'/$'\n'  }"
			echo "Quit it first (kill <pid>)."
		} >&2
		exit 1
	fi
	echo "launch: spending up to $(spend_cap), the spend cap in Settings > Models"
fi

# A replay serves the control API, which answers only a request carrying the
# secret in this 0700 directory, made the way the e2e harness makes its own
# (`control_prepare`). The app refuses it on a build without the API or in a
# sandbox, and the lane then runs without it.
CONTROL_DIR=""
if [ "$MODE" = replay ]; then
	CONTROL_DIR="$(mktemp -d "$TEMPORARY/athina-run-ctl.XXXXXX")"
	chmod 700 "$CONTROL_DIR"
	(umask 077 && head -c 32 /dev/urandom | xxd -p -c 64 >"$CONTROL_DIR/secret")
	ARGS+=(--control "$CONTROL_DIR")
fi

# `open` hands the app its own stdout and stderr, so the line it writes once it
# has started, and any refusal it prints, would otherwise reach nothing but the
# unified log. Both files are this launch's alone, so only the app it started
# ever writes to them.
STARTED_LINE="$(mktemp "${TMPDIR:-/tmp}/athina-started-XXXXXXXX")"
STARTUP_ERRORS="$(mktemp "${TMPDIR:-/tmp}/athina-launch-XXXXXXXX")"
# The control directory goes too unless the lane is claimed below.
trap 'rm -f "$STARTED_LINE" "$STARTUP_ERRORS"; remove_control "$CONTROL_DIR"' EXIT

# `${ARGS[@]}` alone is an unbound variable under set -u in the bash 3.2
# macOS ships, so an empty list is not expanded at all.
if [ ${#ARGS[@]} -gt 0 ]; then
	open -n --stdout "$STARTED_LINE" --stderr "$STARTUP_ERRORS" "$APP" --args "${ARGS[@]}" --launch-token "$TOKEN"
else
	open -n --stdout "$STARTED_LINE" --stderr "$STARTUP_ERRORS" "$APP" --args --launch-token "$TOKEN"
fi

pid=""
for _ in $(seq 100); do
	pid="$(lane_pid "$TOKEN" || true)"
	if [ -n "$pid" ]; then break; fi
	sleep 0.1
done
if [ -z "$pid" ]; then
	{
		echo "launch: Athina did not start from $APP"
		# It can refuse itself and be gone before the poll above ever sees it,
		# and what it said on the way out is the only explanation there is.
		if [ -s "$STARTUP_ERRORS" ]; then sed 's/^/  /' <"$STARTUP_ERRORS"; fi
	} >&2
	exit 1
fi

# A pid is not yet a running Athina: the app refuses a launch it must not make,
# such as one given a --settings file that is not settings, from
# applicationDidFinishLaunching, and how long that takes to reach is a property
# of the Mac, not of this launch.
# So wait for the app to say it started, and stop early when it says it did not
# or goes away. The timeout is in tenths of a second, and generous: it is there
# to end the wait, not to time the app.
STARTED_TIMEOUT=600
# The app's own way of saying it is not up (`LaunchReport` in AthinaCore), on
# stderr. Nothing else counts: this script is only ever given a launch that
# means to keep running.
DID_NOT_START='^Athina did not start: '
ready=0
for _ in $(seq "$STARTED_TIMEOUT"); do
	if [ -s "$STARTED_LINE" ]; then ready=1; break; fi
	# Only what the app says about itself, never merely that stderr has bytes on
	# it: `open --stderr` catches every framework diagnostic too, and one of those
	# arriving first would have this kill a lane that was starting perfectly well.
	if grep -q "$DID_NOT_START" "$STARTUP_ERRORS" 2>/dev/null; then break; fi
	if ! kill -0 "$pid" 2>/dev/null; then break; fi
	sleep 0.1
done

if [ "$ready" = 0 ]; then
	# This lane writes no pid file, so nothing would ever stop what it started:
	# a replay left behind goes on sensing the real screen into a directory the
	# sweep skips while it holds it, and a live one goes on billing.
	started_ours=0
	if [ "$(lane_pid "$TOKEN")" = "$pid" ]; then started_ours=1; fi
	said_no=0
	if grep -q "$DID_NOT_START" "$STARTUP_ERRORS" 2>/dev/null; then said_no=1; fi
	{
		# Why the wait ended, rather than the one reason it used to have: a lane
		# that said it did not start is not a lane that said nothing for a minute.
		if [ "$said_no" = 1 ]; then
			echo "launch: Athina (lane $LANE) said it did not start:"
		elif [ "$started_ours" = 1 ]; then
			echo "launch: Athina (lane $LANE, pid $pid) never wrote the line it writes once it has started, after $((STARTED_TIMEOUT / 10))s:"
		else
			echo "launch: Athina (lane $LANE) quit as it started:"
		fi
		if [ -s "$STARTUP_ERRORS" ]; then
			sed 's/^/  /' <"$STARTUP_ERRORS"
		else
			echo "  it said nothing; try: log show --last 2m --predicate 'subsystem == \"com.ahcarpenter.athina\"'"
		fi
		if [ "$started_ours" = 1 ]; then
			echo "  it is still running, so this lane stops it and claims nothing"
		fi
	} >&2
	if [ "$started_ours" = 1 ]; then stop_pid "$pid"; fi
	exit 1
fi

echo "$pid" >"$PID_FILE"
printf '%s\n' "$TOKEN" >"$TOKEN_FILE"
if [ -n "$CONTROL_DIR" ]; then
	# The app says on stderr why it serves no API, and the lane is still a
	# replay worth keeping: only the clock can no longer move from a script.
	control_refusal="$(grep -m 1 -E '^control API (refused|failed): ' "$STARTUP_ERRORS" 2>/dev/null || true)"
	if [ -n "$control_refusal" ]; then
		echo "launch: $control_refusal; scripts/advance-clock.sh cannot reach this lane" >&2
	else
		printf '%s\n' "$CONTROL_DIR" >"$CONTROL_FILE"
		CONTROL_DIR=""
	fi
fi
# Where it put its journal and settings, which it chose for itself: nothing
# names that directory any more, so the app is what says where it is.
echo "Athina running as pid $pid (lane $LANE) in $(sed -n '1s/^Athina started: pid [0-9]* in //p' "$STARTED_LINE")"
