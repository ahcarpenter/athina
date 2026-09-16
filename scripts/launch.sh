#!/usr/bin/env bash
# Launch build/Mentor.app for a make target, replacing only the copy that the
# same lane launched before from this checkout: never a Mentor from another
# checkout, another lane, or anything started some other way.
#
# Usage: scripts/launch.sh <lane> [--live] [--allow-second-live] [-- app arguments...]
#
# <lane> names the pid file, build/<lane>.pid. `make run` and `make record`
# share the lane "live", since both use the live journal and settings;
# `make run-replay` uses "replay" unless given LANE=<name>.
#
# The instance is identified exactly, not guessed: the launch carries
# `--launch-token <id>`, a unique argument the app ignores, and the pid is the
# process whose arguments hold that token. Diffing the set of Mentor processes
# before and after would adopt the wrong one when two launches from this
# checkout overlap, which "any number of replays at once" invites.
#
# `--live` guards the live files. Before this script, every launch target began
# with `pkill -x Mentor`, so two live instances were impossible; two of them
# share one journal, both write the whole settings file when they quit, and
# both bill the API. A live launch therefore refuses to start while another
# live Mentor runs, naming it, unless `--allow-second-live` says that is
# wanted. A replay needs no such guard: its data directory is its own.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: scripts/launch.sh <lane> [--live] [--allow-second-live] [-- app arguments...]" >&2; exit 2; }
LANE="$1"
shift
LIVE=0
ALLOW_SECOND_LIVE=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--live) LIVE=1; shift ;;
	--allow-second-live) ALLOW_SECOND_LIVE=1; shift ;;
	--) shift; break ;;
	*) break ;;
	esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
live_mentors() {
	ps -axo pid=,command= | awk '{
		line = $0
		pid = $1
		sub(/^ *[0-9]+ +/, "")
		if ($0 !~ /\/Mentor\.app\/Contents\/MacOS\/Mentor($| )/) next
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
		fi
	fi
	rm -f "$PID_FILE"
}

stop_previous

if [ "$LIVE" = 1 ] && [ "$ALLOW_SECOND_LIVE" = 0 ]; then
	running="$(live_mentors || true)"
	if [ -n "$running" ]; then
		{
			echo "launch: a live Mentor is already running, so this one would share its journal, its settings, and its API spend:"
			echo "$running" | sed 's/^/  /'
			echo "Quit it first (kill <pid>), or pass ALLOW_SECOND_LIVE=1 to start a second live copy on purpose."
		} >&2
		exit 1
	fi
fi

if [ "$#" -gt 0 ]; then
	open -n "$APP" --args "$@" --launch-token "$TOKEN"
else
	open -n "$APP" --args --launch-token "$TOKEN"
fi

for _ in $(seq 100); do
	pid="$(ps -axo pid=,command= | awk -v token="$TOKEN" 'index($0, token) { print $1 }' | head -n 1 || true)"
	if [ -n "$pid" ]; then
		echo "$pid" >"$PID_FILE"
		echo "Mentor running as pid $pid (lane $LANE)"
		exit 0
	fi
	sleep 0.1
done
echo "launch: Mentor did not start from $APP" >&2
exit 1
