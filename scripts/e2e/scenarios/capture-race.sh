# shellcheck shell=bash
# SCENARIO_* below are read by scripts/e2e/mentor-e2e, which sources this file.
# shellcheck disable=SC2034
# Change moments that land while a capture is in flight.
#
# A capture takes real time whatever the clock is doing, so on a scaled clock
# one is almost always in flight and every window switch lands mid-capture.
# The journal then says whether the switch survived: a kept moment is followed
# by a focus-change capture, a dropped one by a capture for some other reason.
#
# Reading the result: before the capture-race fix, dropped is greater than zero
# and the app captures the screen the person left rather than the one they
# moved to. After it, dropped is zero. The scenario reports the counts and
# passes when it produced enough change moments to judge, so the same run is
# the proof before and after.
SCENARIO_SUMMARY="counts change moments kept and dropped while captures are in flight (the capture-race proof)"

SCENARIO_ARGS=(--time-scale 60)
# A long floor cadence, so a capture that follows a switch followed the switch
# and not the clock; idle far away, because a scaled clock reads idle scaled too.
SCENARIO_SETTINGS='{"idleThreshold": 3000, "floorInterval": 600, "mentor": {"mentorMinInterval": 3600}}'

scenario_run() {
	local i kept dropped moments
	stage_flip_window
	wait_first_observation 90 || return 1

	# Twenty change moments: flip the helper window, then press a key so input
	# arrives, at a pace that puts each one inside a capture.
	for i in $(seq 1 20); do
		kill -USR1 "$FLIP_PID" 2>/dev/null || true
		"$DRIVE" key 56 >/dev/null 2>&1
		sleep 3
		[ $((i % 5)) = 0 ] && log "change moment $i of 20, observations so far: $(journal_count observations)"
	done
	sleep 5

	"$DRIVE" journal "$JOURNAL" capture-race >"$RUN_DIR/capture-race.tsv"
	cat "$RUN_DIR/capture-race.tsv" >>"$RUN_DIR/transcript.log"
	moments="$(sed -n 's/^moments=\([0-9]*\) .*/\1/p' "$RUN_DIR/capture-race.tsv")"
	kept="$(sed -n 's/.* kept=\([0-9]*\) .*/\1/p' "$RUN_DIR/capture-race.tsv")"
	dropped="$(sed -n 's/.* dropped=\([0-9]*\) .*/\1/p' "$RUN_DIR/capture-race.tsv")"
	log "change moments=$moments kept=$kept dropped=$dropped"

	check "the run produced change moments to judge" "yes" "$([ "${moments:-0}" -ge 3 ] && echo yes || echo no)"
	check "every change moment was judged" "yes" "$([ $(( ${kept:-0} + ${dropped:-0} )) -ge 3 ] && echo yes || echo no)"
	log "RESULT kept=$kept dropped=$dropped (dropped > 0 means the capture race is still there)"
	return 0
}
