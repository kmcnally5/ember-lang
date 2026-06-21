#!/bin/sh
# tests/run-parallel.sh — regression harness for the PARALLEL runtime (MANIFESTO §5f).
#
# Some concurrency programs are only correct under the parallel runtime (build/emberc-par,
# -DEMBER_PARALLEL): with the spawn-at-spawn-time model a spawned task runs CONCURRENTLY with
# the rest of the nursery body, so an event loop can poll it with the non-blocking try_recv.
# Under the serial cooperative scheduler the same program would block forever (the body runs
# to the closing brace before any spawned task is scheduled), so these cases CANNOT live in the
# dependency-free, deterministic default suite (tests/run.sh, which uses the serial build).
#
# This runner is invoked by `make test-parallel`. Each tests/parallel/*.em is run under
# build/emberc-par with a hard TIMEOUT and its stdout compared to a sibling .out golden. The
# timeout is the point: if spawn-at-spawn-time ever regresses to fork-join, the poll loop hangs
# and the case FAILS via timeout instead of wedging the suite. Programs must produce
# INTERLEAVING-INDEPENDENT output (a received value, a sum) — never rely on print order, which
# is nondeterministic across real threads.
#
# Usage:
#   tests/run-parallel.sh            run all parallel cases
#   tests/run-parallel.sh --update   regenerate the goldens from current output

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc-par"
export EMBER_STD="$ROOT/std"
TIMEOUT_S=30

UPDATE=0
if [ "${1:-}" = "--update" ]; then
    UPDATE=1
fi

if [ ! -x "$BIN" ]; then
    echo "skip: $BIN not built — run 'make parallel' first"
    exit 0
fi

# Pick a timeout command (coreutils `timeout` or `gtimeout`); if neither, run without one.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout $TIMEOUT_S"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout $TIMEOUT_S"
fi

pass=0
fail=0
updated=0

for src in "$ROOT"/tests/parallel/*.em; do
    [ -e "$src" ] || continue
    golden="${src%.em}.out"
    # stdout only (the channel-stat destructor and raylib/libcurl logs go to stderr); keep the
    # `=> N` return trailer — for these tests the returned value is the deterministic assertion.
    actual=$($TIMEOUT_CMD "$BIN" --emit=run "$src" 2>/dev/null)
    rc=$?

    if [ "$rc" -eq 124 ]; then
        echo "FAIL $(basename "$src") — TIMED OUT (spawn-at-spawn-time may have regressed to fork-join)"
        fail=$((fail + 1))
        continue
    fi

    if [ "$UPDATE" -eq 1 ]; then
        printf '%s\n' "$actual" > "$golden"
        updated=$((updated + 1))
        continue
    fi

    if [ ! -f "$golden" ]; then
        echo "FAIL $(basename "$src") — no golden (run with --update)"
        fail=$((fail + 1))
        continue
    fi

    if [ "$actual" = "$(cat "$golden")" ]; then
        pass=$((pass + 1))
    else
        echo "FAIL $(basename "$src")"
        printf '  expected: %s\n' "$(cat "$golden")"
        printf '  actual:   %s\n' "$actual"
        fail=$((fail + 1))
    fi
done

if [ "$UPDATE" -eq 1 ]; then
    echo "updated $updated parallel golden(s)"
    exit 0
fi

echo "parallel: passed $pass, failed $fail"
[ "$fail" -eq 0 ]
