#!/bin/sh
# parbench.sh — run benchmarks/parallel_bench.em under the serial compiler (cooperative
# green threads, one core) and the parallel compiler (real OS threads, all cores) and
# print the per-section wall-clock speedup. Same program both times; the checksum must
# match or the row is flagged — a parallel speedup that broke the answer is not a win.
#
# Usage: benchmarks/parbench.sh        (build via `make parbench`, which builds both bins)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SER="$ROOT/build/emberc-release"
PAR="$ROOT/build/emberc-par"
BENCH="$ROOT/benchmarks/parallel_bench.em"

for bin in "$SER" "$PAR"; do
    [ -x "$bin" ] || { echo "missing $bin — run: make release && make parallel" >&2; exit 2; }
done

ser_out=$("$SER" --emit=run "$BENCH" 2>&1)
par_out=$("$PAR" --emit=run "$BENCH" 2>&1)

cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "?")
printf '\n== Ember parallel benchmark (%s logical cores) ==\n' "$cores"
printf '%-12s %10s %10s %9s   %s\n' "section" "serial" "parallel" "speedup" "checksum"
printf '%-12s %10s %10s %9s   %s\n' "-------" "------" "--------" "-------" "--------"

# For each section the serial run emitted, pair it with the parallel run's line.
echo "$ser_out" | grep '^SECTION' | while read -r _ name s_sum s_ms; do
    pline=$(echo "$par_out" | grep "^SECTION $name ")
    p_sum=$(echo "$pline" | awk '{print $3}')
    p_ms=$(echo "$pline" | awk '{print $4}')
    if [ "$s_sum" != "$p_sum" ]; then
        printf '%-12s %8sms %8sms %9s   MISMATCH ser=%s par=%s\n' \
            "$name" "$s_ms" "$p_ms" "BAD" "$s_sum" "$p_sum"
        continue
    fi
    # speedup = serial_ms / parallel_ms, to 2 dp (guard divide-by-zero)
    if [ "$p_ms" -gt 0 ] 2>/dev/null; then
        spd=$(awk "BEGIN { printf \"%.2f\", $s_ms / $p_ms }")
    else
        spd="inf"
    fi
    printf '%-12s %8sms %8sms %8sx   %s\n' "$name" "$s_ms" "$p_ms" "$spd" "$s_sum"
done
echo ""
