#!/usr/bin/env bash
# Sample the running Mentor app's CPU and memory with top for a while.
# Each line is the CPU share over the preceding interval (100 = one core),
# not a lifetime average, so a launch burst does not colour later samples.
# top prints all samples when it finishes, so lines are numbered, not timed.
# Usage: [MENTOR_PID=<pid>] scripts/measure.sh [seconds] [interval]
# With several Mentors running (another checkout's, a replay lane), name the
# one to sample with MENTOR_PID (`make measure PID=<pid>`); the pid of a lane
# launched with make is in build/<lane>.pid.
set -euo pipefail
duration="${1:-60}"
interval="${2:-2}"
pid="${MENTOR_PID:-}"
if [ -z "$pid" ]; then
  running="$(pgrep -x Mentor || true)"
  if [ -z "$running" ]; then
    echo "Mentor is not running (make run)" >&2
    exit 1
  fi
  if [ "$(echo "$running" | wc -l)" -gt 1 ]; then
    echo "several Mentors are running ($(echo $running)); choose one with MENTOR_PID=<pid>" >&2
    exit 1
  fi
  pid="$running"
fi
samples=$((duration / interval))
echo "pid $pid, sampling every ${interval}s for ${duration}s"
printf '%-8s %6s %8s\n' "sample" "%cpu" "mem"
n=0
total=0
max=0
mem=""
# top's first sample is a lifetime figure; skip it.
while read -r _ cpu memory; do
  if [ "$n" -eq 0 ] && [ -z "$mem" ]; then mem="$memory"; continue; fi
  printf '%-8s %6s %8s\n' "$((n + 1))" "$cpu" "$memory"
  total="$(echo "$total + $cpu" | bc -l)"
  max="$(echo "if ($cpu > $max) $cpu else $max" | bc -l)"
  mem="$memory"
  n=$((n + 1))
done < <(top -l "$((samples + 1))" -s "$interval" -pid "$pid" -stats pid,cpu,mem 2>/dev/null | grep "^$pid ")
if [ "$n" -gt 0 ]; then
  printf 'average cpu %.2f%%  peak cpu %s%%  last mem %s over %d samples\n' "$(echo "$total / $n" | bc -l)" "$max" "$mem" "$n"
else
  echo "no samples (did the app exit?)" >&2
  exit 1
fi
