#!/bin/sh
# tests/run-graphics.sh — regression harness for the graphics/UI stack (MANIFESTO §5g).
#
# Graphics programs need the raylib backend (build/emberc-gfx) and a display, so they
# are kept OUT of the dependency-free default suite (tests/run.sh). This runner is
# invoked by `make test-graphics`. Each tests/graphics/*.em is run with --emit=run and
# its stdout (minus raylib's own logging and the `=> N` return trailer) is compared to
# a sibling .out golden. The test programs inject input state rather than relying on a
# real mouse, so their output is deterministic.
#
# Usage:
#   tests/run-graphics.sh            run all graphics cases
#   tests/run-graphics.sh --update   regenerate the goldens from current output

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc-gfx"
export EMBER_STD="$ROOT/std"

UPDATE=0
if [ "${1:-}" = "--update" ]; then
    UPDATE=1
fi

if [ ! -x "$BIN" ]; then
    echo "skip: $BIN not built — run 'make graphics' first (needs raylib)"
    exit 0
fi

pass=0
fail=0
updated=0

for src in "$ROOT"/tests/graphics/*.em; do
    [ -e "$src" ] || continue
    golden="${src%.em}.out"
    # Drop raylib's INFO/WARNING lines and the harness `=> N` trailer; keep program output.
    # Normalize the UI tape's polled mouse position — it reflects the real hardware cursor
    # (wherever it physically is during the run), which is environmental, not deterministic.
    # The draw commands and interaction events, which ARE deterministic, stay asserted.
    actual=$("$BIN" --emit=run "$src" 2>/dev/null \
        | grep -vE '^(INFO|WARNING):' \
        | grep -vE '^=> ' \
        | sed 's/"mouse":\[[0-9-]*,[0-9-]*\]/"mouse":[_,_]/g')

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

    # Compare TOLERANTLY when python3 is available (OFI-068): text metrics drift +/-1px across freetype
    # versions, shifting x/w in the tape; tools/tape-cmp.py allows up to EMBER_TAPE_TOL px on position
    # fields while keeping op/colour/text/structure exact. Without python3, fall back to an exact match.
    ok=0
    if command -v python3 >/dev/null 2>&1; then
        amatch=$(mktemp)
        printf '%s\n' "$actual" > "$amatch"
        if python3 "$ROOT/tools/tape-cmp.py" "$golden" "$amatch" >/tmp/tape_cmp_msg 2>&1; then
            ok=1
        fi
        rm -f "$amatch"
    else
        [ "$actual" = "$(cat "$golden")" ] && ok=1
    fi
    if [ "$ok" -eq 1 ]; then
        pass=$((pass + 1))
    else
        echo "FAIL $(basename "$src")"
        [ -s /tmp/tape_cmp_msg ] && printf '  %s\n' "$(cat /tmp/tape_cmp_msg)"
        printf '  expected: %s\n' "$(cat "$golden")"
        printf '  actual:   %s\n' "$actual"
        fail=$((fail + 1))
    fi
done

if [ "$UPDATE" -eq 1 ]; then
    echo "updated $updated graphics golden(s)"
    exit 0
fi

# Smoke: the graphics SHOWCASE examples (examples/*.em importing std/draw or std/ui)
# need the raylib natives, so the default suite (tests/run.sh) only lex+parses them.
# Full-compile them here under emberc-gfx so they can't drift off the language unnoticed
# (the graphics-example half of OFI-030).
for em in "$ROOT"/examples/*.em; do
    [ -e "$em" ] || continue
    grep -qE '^[[:space:]]*import[[:space:]]+"std/(draw|ui)"' "$em" || continue
    rel=${em#"$ROOT"/}
    if (cd "$ROOT" && "$BIN" --emit=bytecode "$rel") >/dev/null 2>&1; then
        pass=$((pass + 1))
    else
        echo "FAIL $rel — graphics example does not full-compile"
        fail=$((fail + 1))
    fi
done

echo "graphics: passed $pass, failed $fail"
[ "$fail" -eq 0 ]
