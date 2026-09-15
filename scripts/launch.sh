#!/usr/bin/env bash
# Launch build/Mentor.app for a make target, replacing only the copy that the
# same lane launched before from this checkout: never a Mentor from another
# checkout, another lane, or anything started some other way.
#
# Usage: scripts/launch.sh <lane> [app arguments...]
#
# <lane> names the pid file, build/<lane>.pid. `make run` and `make record`
# share the lane "live", since both use the live journal and settings;
# `make run-replay` uses "replay" unless given LANE=<name>. The bundle is
# opened as a new instance (`open -n`), so a Mentor that is already running is
# never activated in its place, and the new instance's pid is written once it
# is up. A pid in the file counts only while it still runs this checkout's
# bundle, so a pid the system has reused for something else is never stopped.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: scripts/launch.sh <lane> [app arguments...]" >&2; exit 2; }
LANE="$1"
shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Mentor.app"
EXECUTABLE="$APP/Contents/MacOS/Mentor"
PID_FILE="$ROOT/build/$LANE.pid"

# The pids of processes running this checkout's bundle, one per line.
ours() {
  ps -axo pid=,command= | awk -v exe="$EXECUTABLE" '{
    pid = $1
    sub(/^ *[0-9]+ +/, "")
    if ($0 == exe || index($0, exe " ") == 1) print pid
  }'
}

if [ -f "$PID_FILE" ]; then
  previous="$(cat "$PID_FILE")"
  if [ -n "$previous" ] && ours | grep -qxF "$previous"; then
    kill -TERM "$previous" 2>/dev/null || true
    for _ in $(seq 50); do
      kill -0 "$previous" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$previous" 2>/dev/null; then
      echo "launch: pid $previous did not quit, stopping it" >&2
      kill -KILL "$previous" 2>/dev/null || true
    fi
  fi
  rm -f "$PID_FILE"
fi

before="$(ours)"
if [ "$#" -gt 0 ]; then
  open -n "$APP" --args "$@"
else
  open -n "$APP"
fi
for _ in $(seq 100); do
  pid="$(ours | grep -vxF "$before" | tail -n 1 || true)"
  if [ -n "$pid" ]; then
    echo "$pid" > "$PID_FILE"
    echo "Mentor running as pid $pid (lane $LANE)"
    exit 0
  fi
  sleep 0.1
done
echo "launch: Mentor did not start from $APP" >&2
exit 1
