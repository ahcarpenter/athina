#!/usr/bin/env bash
# Sample the running Mentor app's CPU and memory with ps for a while.
# Usage: scripts/measure.sh [seconds] [interval]
set -euo pipefail
duration="${1:-60}"
interval="${2:-2}"
pid="$(pgrep -x Mentor | head -n1 || true)"
if [ -z "$pid" ]; then
  echo "Mentor is not running (make run)" >&2
  exit 1
fi
echo "pid $pid, sampling every ${interval}s for ${duration}s"
printf '%-10s %6s %10s\n' "time" "%cpu" "rss"
samples=0
total=0
maxcpu=0
maxrss=0
end=$((SECONDS + duration))
while [ $SECONDS -lt $end ]; do
  line="$(ps -o %cpu=,rss= -p "$pid" || true)"
  [ -z "$line" ] && { echo "process exited" >&2; exit 1; }
  cpu="$(echo "$line" | awk '{print $1}')"
  rss="$(echo "$line" | awk '{print $2}')"
  printf '%-10s %6s %7.1f MB\n' "$(date +%H:%M:%S)" "$cpu" "$(echo "$rss / 1024" | bc -l)"
  total="$(echo "$total + $cpu" | bc -l)"
  maxcpu="$(echo "if ($cpu > $maxcpu) $cpu else $maxcpu" | bc -l)"
  [ "$rss" -gt "$maxrss" ] && maxrss="$rss"
  samples=$((samples + 1))
  sleep "$interval"
done
echo "average cpu $(echo "scale=2; $total / $samples" | bc -l)%  peak cpu ${maxcpu}%  peak rss $((maxrss / 1024)) MB"
