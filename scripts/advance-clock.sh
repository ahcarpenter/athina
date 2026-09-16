#!/usr/bin/env bash
# Move a running replay's clock ahead from a script, with no accessibility and
# no window: posts the distributed notification a replay listens for, addressed
# to its pid (`ClockRemote` in Sources/MentorCore/System/ClockMode.swift).
#
# The request names a file for the replay to answer at, and this script waits
# for that answer. A distributed notification reaches only the observers
# registered when it is posted and says nothing about who heard it, so without
# the answer a request sent to a replay that is still starting, to a live
# Mentor, which never listens, or to a pid that is not Mentor at all would look
# exactly like success and leave a check waiting on a clock that never moved.
# No answer inside the timeout is a failure, named with the pid.
#
# Usage: [MENTOR_CLOCK_TIMEOUT=<seconds>] scripts/advance-clock.sh <pid> <interval>
#   interval: 90s, 15m, 2h, 1d12h, up to 30d
# Exit: 0 the clock moved, 1 no answer in time, 2 bad usage, 3 the replay refused.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: scripts/advance-clock.sh <pid> <interval>" >&2; exit 2; }
[[ "$1" =~ ^[0-9]+$ ]] || { echo "advance-clock: $1 is not a process id" >&2; exit 2; }
pid="$1"
interval="$2"
timeout="${MENTOR_CLOCK_TIMEOUT:-10}"

reply="$(mktemp "${TMPDIR:-/tmp}/mentor-clock-XXXXXXXX")"
rm -f "$reply"
cleanup() { rm -f "$reply"; }
trap cleanup EXIT

osascript -l JavaScript - "$pid" "$interval" "$reply" <<'SCRIPT'
ObjC.import('Foundation')
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    'com.ahcarpenter.mentor.advance-clock', argv[0], $({ interval: argv[1], replyTo: argv[2] }), true
  )
}
SCRIPT

# The replay answers on its main actor, so the wait is a poll of the file it
# writes atomically; a partial read is impossible.
deadline=$(( $(date +%s) + timeout ))
while [ ! -s "$reply" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "advance-clock: pid $pid did not answer within ${timeout}s; it may not be a running replay, or it may still be starting" >&2
    exit 1
  fi
  sleep 0.1
done

moved="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["moved"])' "$reply" 2>/dev/null || echo Error)"
summary="$(/usr/bin/python3 - "$reply" <<'PY' 2>/dev/null || echo "unreadable answer"
import json, sys
reply = json.load(open(sys.argv[1]))
if reply["moved"]:
    print(f'pid {reply["pid"]} moved its clock ahead, {reply["movedAhead"]:.0f}s in all, now {reply["now"]}')
else:
    print(f'pid {reply["pid"]} refused: {reply.get("reason", "unknown reason")}')
PY
)"
if [ "$moved" = "True" ]; then
  echo "$summary"
  exit 0
fi
echo "advance-clock: $summary" >&2
exit 3
