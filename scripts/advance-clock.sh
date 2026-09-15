#!/usr/bin/env bash
# Move a running replay's clock ahead from a script, with no accessibility and
# no window: posts the distributed notification a replay listens for, addressed
# to its pid (`ClockRemote` in Sources/MentorCore/System/ClockMode.swift).
# A live or recording Mentor, and any other replay, ignores it. The replay logs
# "clock moved ahead" when it moves, or why it refused.
#
# Usage: scripts/advance-clock.sh <pid> <interval>    (interval: 90s, 15m, 2h, 1d12h, up to 30d)
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: scripts/advance-clock.sh <pid> <interval>" >&2; exit 2; }
[[ "$1" =~ ^[0-9]+$ ]] || { echo "advance-clock: $1 is not a process id" >&2; exit 2; }

osascript -l JavaScript - "$1" "$2" <<'SCRIPT'
ObjC.import('Foundation')
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    'com.ahcarpenter.mentor.advance-clock', argv[0], $({ interval: argv[1] }), true
  )
}
SCRIPT
