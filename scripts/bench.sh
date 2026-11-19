#!/bin/bash
# Benchmarks: one-time compile cost, host overhead, decode and encode speed vs libjpeg-turbo and ImageIO.
# Results and machine conditions go to work/bench-<host>-<date>/ (not committed). ITERS (default 20).
set -euo pipefail
source "$(dirname "$0")/env.sh"
swift build -c release --package-path Tools >/dev/null
out="work/bench-$(hostname -s)-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$out"
{
  sysctl -n machdep.cpu.brand_string; sysctl -n hw.memsize
  system_profiler SPDisplaysDataType | grep -E 'Chipset|Cores'; sw_vers
  pmset -g batt | head -2; pmset -g therm 2>/dev/null | tail -3
} > "$out/conditions.txt" 2>&1
E=Tools/.build/release/ejm
for c in compile-cost host; do
  echo "== ejm $c"; $E $c | tee -a "$out/results.txt"
done
echo "== ejm bench-json (decode + encode)"
$E bench-json "${ITERS:-20}" results/bench | tee -a "$out/results.txt"
echo "commit the new results/bench/*.json and run: Tools/.build/release/ejm charts"
echo "results: $out"
