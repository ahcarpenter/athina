#!/usr/bin/env bash
# Play a recording into a running replay's listener, as if the talk-back key
# were held for its length: the audio goes through the speech recognizer
# chosen in Settings > General, the live transcript into the toast, and the
# final one into the toast's answers or a replayed follow-up question. Posts
# the distributed notification a replay listens for, addressed to its pid
# (`TalkBackRemote` in Sources/AthinaCore/Voice/TalkBackRemote.swift), and
# waits for the replay's answer, which says what was heard, by which
# recognizer, and what was done with it. It needs no microphone and no
# permission; only a replay listens, so no live Athina ever hears it.
#
# Like scripts/advance-clock.sh, no answer inside the timeout is a failure
# named with the pid, never a silent success.
#
# Usage: [ATHINA_TALK_BACK_TIMEOUT=<seconds>] scripts/talk-back.sh <pid> <audio file>
# Prints the answer as JSON on stdout.
# Exit: 0 it was heard and handled, 1 no answer in time, 2 bad usage, 3 the
# replay did not play it or heard nothing.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: scripts/talk-back.sh <pid> <audio file>" >&2; exit 2; }
[[ "$1" =~ ^[0-9]+$ ]] || { echo "talk-back: $1 is not a process id" >&2; exit 2; }
pid="$1"
[ -f "$2" ] || { echo "talk-back: no file at $2" >&2; exit 2; }
file="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
# A question waits for the replayed follow-up answer, which comes after the
# fixture's recorded latency.
timeout="${ATHINA_TALK_BACK_TIMEOUT:-90}"

# The reply file is made the way scripts/advance-clock.sh makes it: inside the
# per-user temporary directory the app's NSTemporaryDirectory names, and
# removed so the replay can create it.
temporary="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
[ -n "$temporary" ] || temporary="${TMPDIR:-/tmp}"
reply="$(mktemp "${temporary%/}/athina-talk-back-XXXXXXXX")"
rm -f "$reply"
trap 'rm -f "$reply"' EXIT

osascript -l JavaScript - "$pid" "$file" "$reply" <<'SCRIPT'
ObjC.import('Foundation')
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    'com.ahcarpenter.athina.talk-back', argv[0], $({ file: argv[1], replyTo: argv[2] }), true
  )
}
SCRIPT

deadline=$(( $(date +%s) + timeout ))
while ! /usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$reply" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    {
      echo "talk-back: pid $pid did not answer at $reply within ${timeout}s"
      echo "  it may not be a running replay, it may still be starting, or it may have refused to answer there"
      echo "  (a replay answers only at a new file inside $temporary): log show --last 2m --predicate 'subsystem == \"com.ahcarpenter.athina\"'"
    } >&2
    exit 1
  fi
  sleep 0.1
done

cat "$reply"
echo
heard="$(/usr/bin/python3 -c 'import json,sys; print(1 if json.load(open(sys.argv[1])).get("heard") else 0)' "$reply" 2>/dev/null || echo 0)"
[ "$heard" = 1 ] || exit 3
