#!/bin/sh
# ledger.sh — the DRIVER half of Ledger, Ember's resource-LINEARITY fuzzer (OFI-049).
#
# Generates Ptr-lifetime programs (tools/ledger <seed>) — nested if/else+match trees, infinite-loop +
# break read loops, and reassignment chains — each carrying a KNOWN oracle (`//EXPECT:accept` if the
# handle is closed on every path, else `reject`). For each it asserts the compiler's verdict matches:
#
#   EXPECT accept  → emberc must type-check it AND the native (C) backend must compile it. A rejection
#                    here is OVER-STRICTNESS — the linearity checker wrongly flagged correct code (the
#                    close-on-break read loop is the classic regression).
#   EXPECT reject  → emberc must reject it with a LINEARITY diagnostic (a leak / borrowed-Ptr / discard
#                    message). NO error at all is UNSOUNDNESS — a leak that compiles. An error that is
#                    not a linearity one is a generator over-reach (counted, not a hard fail).
#
# A clean run prints "0 mismatches". Any mismatch is a real soundness or false-positive bug, with the
# offending program saved under tools/ledger-finds/ for a minimal repro.
#
#   tools/ledger.sh [seed-count]      (default 300)

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export EMBER_STD="$ROOT/std"
GEN="$ROOT/build/ledger"
EMB="$ROOT/build/emberc"
TMP="${TMPDIR:-/tmp}/ledger.$$"
FINDS="$ROOT/tools/ledger-finds"
COUNT="${1:-300}"
mkdir -p "$TMP" "$FINDS"
trap 'rm -rf "$TMP"' EXIT

say() { printf '%s\n' "$*"; }

say "ledger: building generator + reference compiler…"
cc -std=c17 -O2 "$ROOT/tools/ledger.c" -o "$GEN" || { say "generator build failed"; exit 1; }
(cd "$ROOT" && make >/dev/null 2>&1) || { say "emberc build failed"; exit 1; }

# A LINEARITY diagnostic — the only errors a `reject` program is allowed to fail with. Anything else
# (parse/type error) means the generator emitted something off-target.
LEAK_RE="not closed on this path|leaks the 'Ptr'|discarded . it leaks|borrowed 'Ptr'|cannot be (an|a) "

say "ledger: running $COUNT seeds…"
unsound=0; overstrict=0; overreach=0; ok=0; i=1
while [ "$i" -le "$COUNT" ]; do
    prog="$TMP/p.em"
    "$GEN" "$i" > "$prog"
    want=$(sed -n 's,^//EXPECT:,,p' "$prog" | head -1)
    out=$("$EMB" --emit=bytecode "$prog" 2>&1)
    has_err=0; printf '%s' "$out" | grep -qE "error:" && has_err=1

    if [ "$want" = "accept" ]; then
        if [ "$has_err" = 1 ]; then
            overstrict=$((overstrict + 1))
            cp "$prog" "$FINDS/overstrict_$i.em"
            say "── [OVER-STRICT] seed=$i  emberc rejected a balanced program → ${FINDS#$ROOT/}/overstrict_$i.em"
            printf '%s\n' "$out" | grep -E "error:" | head -1 | sed 's/^/      | /'
        else
            # Bonus: the native backend must also accept it (both backends honour the checker).
            if "$EMB" -o "$TMP/bin" "$prog" >/dev/null 2>&1; then ok=$((ok + 1)); else
                overstrict=$((overstrict + 1))
                cp "$prog" "$FINDS/native_$i.em"
                say "── [NATIVE-FAIL] seed=$i  VM accepted but native backend rejected → ${FINDS#$ROOT/}/native_$i.em"
            fi
        fi
    else   # want = reject
        if [ "$has_err" = 0 ]; then
            unsound=$((unsound + 1))
            cp "$prog" "$FINDS/unsound_$i.em"
            say "── [UNSOUND]   seed=$i  a LEAK compiled with no error → ${FINDS#$ROOT/}/unsound_$i.em"
        elif printf '%s' "$out" | grep -qE "$LEAK_RE"; then
            ok=$((ok + 1))
        else
            overreach=$((overreach + 1))
            cp "$prog" "$FINDS/overreach_$i.em"
            say "── [gen-overreach] seed=$i  rejected, but not by a linearity error (generator drift)"
        fi
    fi
    i=$((i + 1))
done

say ""
mism=$((unsound + overstrict))
say "ledger: $COUNT seeds → $ok matched, $unsound UNSOUND, $overstrict over-strict, $overreach gen-overreach."
if [ "$mism" -eq 0 ]; then
    say "ledger: ✓ every program's verdict matched its oracle (no leak compiled, no balanced program rejected)."
    [ "$overreach" -gt 0 ] && say "ledger: ($overreach generator over-reaches — non-linearity rejections, ignored)."
    exit 0
fi
say "ledger: ✗ $mism mismatch(es) — repros in ${FINDS#$ROOT/}/"
exit 1
