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
# could refuse this launch and past the point where it is listening for a clock
# request. Elapsed time is never taken as proof: on a loaded Mac the app can
# still be short of that point after seconds.
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
# checkout or bundle it came from, as "<pid> <command>" lines.
#
# Which process is a Mentor is decided on `comm`, the executable alone, never
# on the joined command line: a path with a space in it cannot be told from a
# path followed by an argument once they are joined, so a checkout under, say,
# "My Projects" would be invisible here and a second live Mentor would start on
# the owner's journal, settings and bill. The command line is read only to say
# which ones are replays or snapshot renders, and to name them.
live_mentors() {
	{ ps -axo pid=,comm=; echo "|"; ps -axo pid=,command=; } | awk '
		$0 == "|" { commands = 1; next }
		{
			pid = $1
			sub(/^ *[0-9]+ +/, "")
			if (!commands) {
				if ($0 ~ /\/Mentor\.app\/Contents\/MacOS\/Mentor$/) mentor[pid] = 1
				next
			}
			if (!(pid in mentor)) next
			if ($0 ~ /--replay($| )/ || $0 ~ /--snapshot($| )/) next
			print pid, $0
		}'
}

# Stops a Mentor this script is answerable for, and waits for it to go: a
# killed app is still listed while the kernel tears it down, and the live guard
# would read that as a live Mentor already running.
stop_pid() {
	local victim="$1" i
	kill -TERM "$victim" 2>/dev/null || true
	for i in $(seq 50); do
		kill -0 "$victim" 2>/dev/null || return 0
		sleep 0.1
	done
	echo "launch: pid $victim did not quit, stopping it" >&2
	kill -KILL "$victim" 2>/dev/null || true
	for i in $(seq 50); do
		kill -0 "$victim" 2>/dev/null || return 0
		sleep 0.1
	done
}

stop_previous() {
	[ -f "$PID_FILE" ] || return 0
	local previous
	previous="$(cat "$PID_FILE")"
	if [ -n "$previous" ] && ours | grep -qxF "$previous"; then
		stop_pid "$previous"
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
	{
		echo "launch: Mentor did not start from $APP"
		# It can refuse itself and be gone before the poll above ever sees it,
		# and what it said on the way out is the only explanation there is.
		if [ -s "$STARTUP_ERRORS" ]; then sed 's/^/  /' <"$STARTUP_ERRORS"; fi
	} >&2
	exit 1
fi

# A pid is not yet a running Mentor: the app refuses a launch it must not make,
# such as one given a --settings file that is not settings, from
# applicationDidFinishLaunching, and how long that takes to reach is a property
# of the Mac, not of this launch.
# So wait for the app to say it started, and stop early when it says it did not
# or goes away. The timeout is in tenths of a second, and generous: it is there
# to end the wait, not to time the app.
STARTED_TIMEOUT=600
# The app's own way of saying it is not up (`LaunchReport` in MentorCore), on
# stderr. Nothing else counts: this script is only ever given a launch that
# means to keep running.
DID_NOT_START='^Mentor did not start: '
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
	if ours | grep -qxF "$pid"; then started_ours=1; fi
	said_no=0
	if grep -q "$DID_NOT_START" "$STARTUP_ERRORS" 2>/dev/null; then said_no=1; fi
	{
		# Why the wait ended, rather than the one reason it used to have: a lane
		# that said it did not start is not a lane that said nothing for a minute.
		if [ "$said_no" = 1 ]; then
			echo "launch: Mentor (lane $LANE) said it did not start:"
		elif [ "$started_ours" = 1 ]; then
			echo "launch: Mentor (lane $LANE, pid $pid) never wrote the line it writes once it has started, after $((STARTED_TIMEOUT / 10))s:"
		else
			echo "launch: Mentor (lane $LANE) quit as it started:"
		fi
		if [ -s "$STARTUP_ERRORS" ]; then
			sed 's/^/  /' <"$STARTUP_ERRORS"
		else
			echo "  it said nothing; try: log show --last 2m --predicate 'subsystem == \"com.ahcarpenter.mentor\"'"
		fi
		if [ "$started_ours" = 1 ]; then
			echo "  it is still running, so this lane stops it and claims nothing"
		fi
	} >&2
	if [ "$started_ours" = 1 ]; then stop_pid "$pid"; fi
	exit 1
fi

echo "$pid" >"$PID_FILE"
# Where it put its journal and settings, which it chose for itself: nothing
# names that directory any more, so the app is what says where it is.
echo "Mentor running as pid $pid (lane $LANE) in $(sed -n '1s/^Mentor started: pid [0-9]* in //p' "$STARTED_LINE")"
