#!/bin/sh
# tests/run-net.sh — regression harness for the networking stack (std/http + the reusable Anthropic
# client). These programs import std/http, whose extern "c" bindings only link in the networking build
# (build/emberc-net), so they are kept OUT of the dependency-free default suite (tests/run.sh). This
# runner is invoked by `make test-net`. Each tests/net/*.em is run with --emit=run and its stdout
# compared to a sibling .out golden. The cases are designed to make NO live request (they exercise the
# pure request/response/protocol logic), so their output is deterministic and offline.
#
# Usage:
#   tests/run-net.sh            run all net cases
#   tests/run-net.sh --update   regenerate the goldens from current output

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc-net"
export EMBER_STD="$ROOT/std"

UPDATE=0
if [ "${1:-}" = "--update" ]; then
    UPDATE=1
fi

if [ ! -x "$BIN" ]; then
    echo "skip: $BIN not built — run 'make net' first (needs libcurl)"
    exit 0
fi

pass=0
fail=0
updated=0

for src in "$ROOT"/tests/net/*.em; do
    [ -e "$src" ] || continue
    golden="${src%.em}.out"
    actual=$("$BIN" --emit=run "$src" 2>/dev/null)

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
    echo "updated $updated net golden(s)"
    exit 0
fi

echo "net: passed $pass, failed $fail"
[ "$fail" -eq 0 ]
