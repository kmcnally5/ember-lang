#!/bin/sh
# tests/run-db.sh — regression harness for the database stack (std/sqlite). These programs import
# std/sqlite, whose extern "c" bindings only link in the database build (build/emberc-db), so they are
# kept OUT of the dependency-free default suite (tests/run.sh). This runner is invoked by `make test-db`.
# Each tests/db/*.em is run with --emit=run and its stdout compared to a sibling .out golden. The CRUD
# and error cases use an in-memory database (":memory:") so they touch no files and stay deterministic;
# persist.em uses a scratch file under the system temp dir and normalises its table, so it too is
# deterministic regardless of what a prior run left behind.
#
# Usage:
#   tests/run-db.sh            run all database cases
#   tests/run-db.sh --update   regenerate the goldens from current output

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc-db"
export EMBER_STD="$ROOT/std"

UPDATE=0
if [ "${1:-}" = "--update" ]; then
    UPDATE=1
fi

if [ ! -x "$BIN" ]; then
    echo "skip: $BIN not built — run 'make db' first (vendored SQLite)"
    exit 0
fi

# Remove the persistence test's scratch database so a stale or corrupt file can never skew the run.
rm -f /tmp/ember_sqlite_persist_test.db

pass=0
fail=0
updated=0

for src in "$ROOT"/tests/db/*.em; do
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
    echo "updated $updated db golden(s)"
    exit 0
fi

echo "db: passed $pass, failed $fail"
[ "$fail" -eq 0 ]
