#!/usr/bin/env bash
# Sample the running Mentor app's CPU and memory with top for a while.
# Each line is the CPU share over the preceding interval (100 = one core),
# not a lifetime average, so a launch burst does not colour later samples.
# Usage: scripts/measure.sh [seconds] [interval]
set -euo pipefail
duration="${1:-60}"
interval="${2:-2}"
pid="$(pgrep -x Mentor | head -n1 || true)"
if [ -z "$pid" ]; then
  echo "Mentor is not running (make run)" >&2
  exit 1
fi
samples=$((duration / interval))
echo "pid $pid, sampling every ${interval}s for ${duration}s"
printf '%-10s %6s %10s\n' "time" "%cpu" "mem"
# top's first sample is a lifetime figure; drop it.
top -l "$((samples + 1))" -s "$interval" -pid "$pid" -stats pid,cpu,mem 2>/dev/null \
  | awk -v pid="$pid" '$1 == pid { if (seen++) print strftime("%H:%M:%S"), $2, $3 }' \
  | tee /dev/stderr \
  | awk '{ total += $2; if ($2 > max) max = $2; mem = $3; n++ }
         END { if (n) printf "average cpu %.2f%%  peak cpu %.1f%%  last mem %s over %d samples\n", total / n, max, mem, n }'
