#!/usr/bin/env bash
# Launch build/Mentor.app for a make target, replacing only the copy that the
# same lane launched before from this checkout: never a Mentor from another
# checkout, another lane, or anything started some other way.
#
# Usage: scripts/launch.sh <lane> [--live] [-- app arguments...]
#
# <lane> names the pid file, build/<lane>.pid. `make run` and `make record`
# share the lane "live", since both use the live journal and settings;
# `make run-replay` uses "replay" unless given LANE=<name>.
#
# The instance is identified exactly, not guessed: the launch carries
# `--launch-token <id>`, a unique argument the app ignores, and the pid is the
# one running this checkout's bundle with that token in its arguments. Diffing
# the set of Mentor processes before and after would adopt the wrong one when
# two launches from this checkout overlap, which "any number of replays at
# once" invites. The pid is reported, and written to the pid file, only once
# the app itself says it started, on the line it writes past every reason it
# could refuse this launch. Elapsed time is never taken as proof: on a loaded
# Mac the app can still be short of that point after seconds.
#
# `--live` guards the live files. Before this script, every launch target began
# with `pkill -x Mentor`, so two live instances were impossible; two of them
# share one journal, both write the whole settings file when they quit, and
# both bill the API. A live launch therefore refuses to start while another
# live Mentor runs, naming it. A replay needs no such guard: its data
# directory is its own.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: scripts/launch.sh <lane> [--live] [-- app arguments...]" >&2; exit 2; }
LANE="$1"
shift
LIVE=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--live) LIVE=1; shift ;;
	--) shift; break ;;
	*) break ;;
	esac
done

# The physical path, because that is the one `ps` reports for the running
# process, and both pid searches below match on it.
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="$ROOT/build/Mentor.app"
EXECUTABLE="$APP/Contents/MacOS/Mentor"
PID_FILE="$ROOT/build/$LANE.pid"
TOKEN="lane-$LANE-$$-$(date +%s)"

# The pids of processes running this checkout's bundle, one per line.
ours() {
	ps -axo pid=,command= | awk -v exe="$EXECUTABLE" '{
		pid = $1
		sub(/^ *[0-9]+ +/, "")
		if ($0 == exe || index($0, exe " ") == 1) print pid
	}'
}

# Every Mentor on this Mac that is not a replay or a snapshot render, whatever
# checkout or bundle it came from, as "<pid> <command>" lines. The bundle path
# has to be the command itself, as in `ours` and `started`: a process that only
# names it in its arguments, this script's own awk helpers among them, is not a
# running Mentor.
live_mentors() {
	ps -axo pid=,command= | awk '{
		pid = $1
		sub(/^ *[0-9]+ +/, "")
		if ($0 !~ /^[^ ]*\/Mentor\.app\/Contents\/MacOS\/Mentor($| )/) next
		if ($0 ~ /--replay($| )/ || $0 ~ /--snapshot($| )/) next
		print pid, $0
	}'
}

stop_previous() {
	[ -f "$PID_FILE" ] || return 0
	local previous
	previous="$(cat "$PID_FILE")"
	if [ -n "$previous" ] && ours | grep -qxF "$previous"; then
		kill -TERM "$previous" 2>/dev/null || true
		local i
		for i in $(seq 50); do
			kill -0 "$previous" 2>/dev/null || break
			sleep 0.1
		done
		if kill -0 "$previous" 2>/dev/null; then
			echo "launch: pid $previous did not quit, stopping it" >&2
			kill -KILL "$previous" 2>/dev/null || true
			# A killed app is still listed while the kernel tears it down, and the
			# live guard below would read that as a live Mentor already running.
			for i in $(seq 50); do
				kill -0 "$previous" 2>/dev/null || break
				sleep 0.1
			done
		fi
	fi
	rm -f "$PID_FILE"
}

stop_previous

if [ "$LIVE" = 1 ]; then
	running="$(live_mentors || true)"
	if [ -n "$running" ]; then
		{
			echo "launch: a live Mentor is already running, so this one would share its journal, its settings, and its API spend:"
			echo "$running" | sed 's/^/  /'
			echo "Quit it first (kill <pid>)."
		} >&2
		exit 1
	fi
fi

# The pid of this checkout's Mentor carrying this launch's token. The bundle
# has to match as well as the token: `ps` lists the searching awk too, and its
# own command line holds the token, so a token-only search finds awk first.
started() {
	ps -axo pid=,command= | awk -v exe="$EXECUTABLE" -v token="$TOKEN" '{
		pid = $1
		sub(/^ *[0-9]+ +/, "")
		if (index($0, exe " ") != 1) next
		if (index($0, token)) print pid
	}' | head -n 1
}

# `open` hands the app its own stdout and stderr, so the line it writes once it
# has started, and any refusal it prints, would otherwise reach nothing but the
# unified log. Both files are this launch's alone, so only the app it started
# ever writes to them.
STARTED_LINE="$(mktemp "${TMPDIR:-/tmp}/mentor-started-XXXXXXXX")"
STARTUP_ERRORS="$(mktemp "${TMPDIR:-/tmp}/mentor-launch-XXXXXXXX")"
trap 'rm -f "$STARTED_LINE" "$STARTUP_ERRORS"' EXIT

if [ "$#" -gt 0 ]; then
	open -n --stdout "$STARTED_LINE" --stderr "$STARTUP_ERRORS" "$APP" --args "$@" --launch-token "$TOKEN"
else
	open -n --stdout "$STARTED_LINE" --stderr "$STARTUP_ERRORS" "$APP" --args --launch-token "$TOKEN"
fi

pid=""
for _ in $(seq 100); do
	pid="$(started || true)"
	if [ -n "$pid" ]; then break; fi
	sleep 0.1
done
if [ -z "$pid" ]; then
	echo "launch: Mentor did not start from $APP" >&2
	exit 1
fi

# A pid is not yet a running Mentor: the app refuses a launch it must not make,
# such as a --data-dir another replay holds, from applicationDidFinishLaunching,
# and how long that takes to reach is a property of the Mac, not of this launch.
# So wait for the app to say it started, and stop early when it says it did not
# or goes away. The timeout is in tenths of a second, and generous: it is there
# to end the wait, not to time the app.
STARTED_TIMEOUT=600
ready=0
for _ in $(seq "$STARTED_TIMEOUT"); do
	if [ -s "$STARTED_LINE" ]; then ready=1; break; fi
	if [ -s "$STARTUP_ERRORS" ]; then break; fi
	if ! kill -0 "$pid" 2>/dev/null; then break; fi
	sleep 0.1
done

if [ "$ready" = 0 ]; then
	{
		if kill -0 "$pid" 2>/dev/null; then
			echo "launch: Mentor (lane $LANE, pid $pid) never wrote the line it writes once it has started, after $((STARTED_TIMEOUT / 10))s; it is running but not started, so this lane claims nothing:"
		else
			echo "launch: Mentor (lane $LANE) quit as it started, so nothing is running:"
		fi
		if [ -s "$STARTUP_ERRORS" ]; then
			sed 's/^/  /' <"$STARTUP_ERRORS"
		else
			echo "  it said nothing; try: log show --last 2m --predicate 'subsystem == \"com.ahcarpenter.mentor\"'"
		fi
	} >&2
	exit 1
fi

echo "$pid" >"$PID_FILE"
echo "Mentor running as pid $pid (lane $LANE)"
