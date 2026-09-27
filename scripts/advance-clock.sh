#!/usr/bin/env bash
# Move the clock of a replay `make run` launched ahead from a script, with no
# accessibility and no window: the control API's `advance` (docs/e2e.md "The
# control API"), sent by athina-drive to the directory scripts/launch.sh made
# for the lane and named in build/<lane>.control.
#
# The API answers only a request carrying that directory's secret, and the
# answer is what proves the clock moved: a lane that is gone, still starting,
# or serving no API (a release build, a sandboxed one) gives none, which is a
# failure rather than a clock nobody moved.
#
# Usage: scripts/advance-clock.sh <lane> <interval>
#   lane: the LANE given to make run, `replay` unless one was
#   interval: 90s, 15m, 2h, 1d12h, up to 30d
# Exit: 0 the clock moved, 1 the replay refused, 2 no answer or bad usage.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: scripts/advance-clock.sh <lane> <interval>" >&2; exit 2; }
lane="$1"
interval="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

control="$(cat "$ROOT/build/$lane.control" 2>/dev/null || true)"
if [ -z "$control" ]; then
	echo "advance-clock: lane $lane has no control API; start it with make run LANE=$lane" >&2
	exit 2
fi

(cd "$ROOT" && swift build --product athina-drive >/dev/null) || {
	echo "advance-clock: could not build athina-drive" >&2
	exit 2
}
ATHINA_CONTROL_DIR="$control" exec "$ROOT/.build/debug/athina-drive" api advance "interval=$interval"
