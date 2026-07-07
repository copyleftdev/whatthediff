#!/usr/bin/env bash
# Scale benchmark with hard correctness assertions.
#
# For each corpus size: generate a deterministic corpus with planted rogues,
# run wtd, and FAIL unless wtd flags exactly the planted rogue set. Timing and
# peak RSS are reported per size so scaling behavior is visible.
#
# Usage: scripts/bench.sh [work_dir]
#   SIZES="100 1000 10000" scripts/bench.sh   # override sizes
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-${TMPDIR:-/tmp}/wtd-bench}"
SIZES="${SIZES:-100 1000 10000 50000}"
FORMAT="${FORMAT:-yaml}"

command -v jq >/dev/null || { echo "bench: jq required" >&2; exit 1; }
TIME_BIN=""
[ -x /usr/bin/time ] && TIME_BIN=/usr/bin/time

echo "building ReleaseFast..."
(cd "$ROOT" && zig build -Doptimize=ReleaseFast)
WTD="$ROOT/zig-out/bin/wtd"
GEN="$ROOT/zig-out/bin/gencorpus"

mkdir -p "$WORK"
fail=0

printf "\n%-9s %-8s %-10s %-12s %-10s %-12s %-8s\n" \
  "files" "rogues" "wall_s" "per_file_us" "rss_mb" "primitives" "verdict"

for n in $SIZES; do
  dir="$WORK/c$n"
  rm -rf "$dir"
  rogues=$(( n / 50 )); [ "$rogues" -lt 1 ] && rogues=1

  manifest="$("$GEN" "$dir" --files "$n" --seed 42 --rogues "$rogues" --format "$FORMAT")"

  report="$WORK/report-$n.json"
  timelog="$WORK/time-$n.txt"
  if [ -n "$TIME_BIN" ]; then
    "$TIME_BIN" -v "$WTD" "$dir" --json > "$report" 2> "$timelog"
    wall=$(grep -oP 'Elapsed \(wall clock\).*: \K.*' "$timelog" \
      | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2 }')
    rss_mb=$(grep -oP 'Maximum resident set size \(kbytes\): \K\d+' "$timelog" \
      | awk '{ printf "%.1f", $1/1024 }')
  else
    start=$(date +%s.%N)
    "$WTD" "$dir" --json > "$report"
    wall=$(echo "$(date +%s.%N) - $start" | bc)
    rss_mb="n/a"
  fi

  # Hard assertion: flagged outliers == planted rogues, exactly.
  flagged=$(jq -r '[.artifacts[] | select(.outlier) | .path | split("/") | last] | sort | join(",")' "$report")
  planted=$(echo "$manifest" | jq -r '.rogue_names | sort | join(",")')
  prims=$(jq -r '.corpus.distinct_primitives' "$report")
  n_artifacts=$(jq -r '.corpus.artifacts' "$report")

  verdict="PASS"
  if [ "$flagged" != "$planted" ] || [ "$n_artifacts" != "$n" ]; then
    verdict="FAIL"
    fail=1
    echo "  MISMATCH at n=$n:" >&2
    echo "    planted: $planted" >&2
    echo "    flagged: $flagged" >&2
    echo "    artifacts: $n_artifacts (expected $n)" >&2
  fi

  per_file=$(awk -v w="$wall" -v n="$n" 'BEGIN { printf "%.1f", w/n*1000000 }')
  printf "%-9s %-8s %-10s %-12s %-10s %-12s %-8s\n" \
    "$n" "$rogues" "$wall" "$per_file" "$rss_mb" "$prims" "$verdict"
done

# Edge: an oversized artifact must be skipped, never crash the run.
edge="$WORK/edge"
rm -rf "$edge"
"$GEN" "$edge" --files 10 --seed 7 --rogues 1 --format "$FORMAT" > /dev/null
dd if=/dev/zero of="$edge/zz-huge.txt" bs=1M count=65 status=none
"$WTD" "$edge" --json > "$WORK/report-edge.json"
skipped=$(jq -r '.corpus.skipped' "$WORK/report-edge.json")
arts=$(jq -r '.corpus.artifacts' "$WORK/report-edge.json")
if [ "$skipped" -ge 1 ] && [ "$arts" -eq 10 ]; then
  echo -e "\nedge: 65MiB artifact skipped cleanly (skipped=$skipped) — PASS"
else
  echo -e "\nedge: oversized artifact handling FAILED (skipped=$skipped artifacts=$arts)" >&2
  fail=1
fi

exit "$fail"
