#!/usr/bin/env bash
# `make demo`: records the README's demo from the real screen and cuts the GIF
# from it. The recording is the end-to-end harness's `demo` scenario
# (scripts/e2e/scenarios/demo.sh), a replay of the committed fixtures with no
# key and nothing spent, which takes the screen lock and waits for a quiet
# keyboard and mouse first; the GIF is scripts/demo-gif.swift's cut of the
# recording, written to docs/images/demo.gif with every frame beside it in
# build/demo-frames to look at before committing (docs/replay.md "The
# committed fixtures"). Ends in one summary line; the scenario's log is in
# build/logs/demo.log.
#
# Usage: scripts/demo.sh
# Exit: 0 the GIF was written, 1 the scenario failed or the cut could not be
# made, as each says.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
mkdir -p build/logs
result="$(scripts/e2e/athina-e2e run demo 2>build/logs/demo.log)"
if [ "$(jq -r '.result' <<<"$result" 2>/dev/null)" != pass ]; then
	echo "demo: the recording failed: $(jq -r '.detail' <<<"$result" 2>/dev/null); see build/logs/demo.log" >&2
	exit 1
fi
recording="$(jq -r '.evidence' <<<"$result")/demo.mov"
rm -rf build/demo-frames
swift scripts/demo-gif.swift "$recording" docs/images/demo.gif --frames build/demo-frames || exit 1
echo "demo: docs/images/demo.gif cut from $recording; its frames are in build/demo-frames"
