#!/bin/sh
# crucible.sh — the DRIVER half of Crucible, Ember's memory-ownership fuzzer.
#
# Generates programs (tools/crucible <seed> <loops>) and runs each through five ORACLES — the
# double-drop detector, a VM-fault check, ASan, an RSS leak check, and the VM↔native differential.
# Distinct failures are deduped by SIGNATURE and each is SHRUNK to a minimal repro saved under
# tools/crucible-finds/. Same seeds => same programs => reproducible.
#
#   tools/crucible.sh [seed-count]      (default 150)
#
# It builds the generator and the drop-trace / ASan compiler variants on demand. A clean run prints
# "0 findings"; any finding is a real bug (or a generator over-reach) with a minimal repro to act on.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export EMBER_STD="$ROOT/std"
GEN="$ROOT/build/crucible"
# Binaries are overridable so the same generated memory-ownership corpus can be re-run against a
# different runtime — e.g. CRUCIBLE_EMB=build/emberc-mn CRUCIBLE_ASAN=build/emberc-asan-mn to check the
# value-struct/generic/aggregate bug class still holds when `main` runs as an M:N scheduler fiber.
EMB="${CRUCIBLE_EMB:-$ROOT/build/emberc}"
DT="${CRUCIBLE_DT:-$ROOT/build/emberc-dt}"
ASAN="${CRUCIBLE_ASAN:-$ROOT/build/emberc-asan}"
TMP="${TMPDIR:-/tmp}/crucible.$$"
FINDS="$ROOT/tools/crucible-finds"
COUNT="${1:-150}"
mkdir -p "$TMP" "$FINDS"
trap 'rm -rf "$TMP"' EXIT

say() { printf '%s\n' "$*"; }

# ---- build the generator + variant compilers (only when stale) ---------------------------------
say "crucible: building generator + oracle compilers…"
cc -std=c17 -O2 "$ROOT/tools/crucible.c" -o "$GEN" || { say "generator build failed"; exit 1; }
(cd "$ROOT" && make >/dev/null 2>&1)   # incremental — keeps the reference VM/native compiler current
# Oracle staleness: rebuild if ANY compiler source is newer than the binary. A memory bug can live in
# the checker or the native emitter, not just runtime.c/vm.c — a narrow check ran a STALE oracle and
# reported FALSE findings after a check.c fix (the OFI-064 session). Track the newest src/include file.
newest_src=$(ls -t "$ROOT"/src/*.c "$ROOT"/include/*.h 2>/dev/null | head -1)
if [ ! -x "$DT" ] || [ "$newest_src" -nt "$DT" ]; then
    say "crucible: building drop-trace compiler…"
    cc -std=c17 -Iinclude -O1 -g -DEMBER_DROP_TRACE "$ROOT"/src/*.c -o "$DT" 2>/dev/null
fi
if [ ! -x "$ASAN" ] || [ "$newest_src" -nt "$ASAN" ]; then
    say "crucible: building ASan compiler…"
    (cd "$ROOT" && make asan >/dev/null 2>&1)
fi

# rss_of <program.em> -> peak resident KB for one VM run (leak oracle uses this).
rss_of() {
    bytes=$(/usr/bin/time -l "$EMB" --emit=run "$1" 2>&1 >/dev/null | grep -i "maximum resident" | grep -oE "[0-9]+" | head -1)
    [ -n "$bytes" ] && echo $((bytes / 1024)) || echo 0
}

# classify <program.em> <seed> -> a one-line failure SIGNATURE, or "" if all oracles pass.
classify() {
    em="$1"; seed="$2"
    # 1) double-drop detector — and tell a RUNTIME error (a real fault) from a `file.em:line: error:`
    #    COMPILE error (a generator over-reach), since both contain "error:".
    dt=$("$DT" --emit=run "$em" 2>&1)
    if printf '%s' "$dt" | grep -q "DOUBLE-DROP"; then
        printf 'double-drop:%s\n' "$(printf '%s' "$dt" | grep -oE 'type_id=[0-9]+' | head -1)"; return
    fi
    if printf '%s' "$dt" | grep -qE "runtime error:"; then
        printf 'vm-fault:%s\n' "$(printf '%s' "$dt" | grep -oE 'runtime error: [a-z ]+' | head -1)"; return
    fi
    if printf '%s' "$dt" | grep -qE "\.em:[0-9]+:[0-9]+: error:"; then echo "gen-compile-error"; return; fi
    # reference VM output (the drop-trace run above was clean, so this is the canonical result)
    vm=$("$EMB" --emit=run "$em" 2>&1)
    # 2) ASan
    as=$("$ASAN" --emit=run "$em" 2>&1)
    if printf '%s' "$as" | grep -qiE "AddressSanitizer|: ERROR"; then
        printf 'asan:%s\n' "$(printf '%s' "$as" | grep -oiE 'heap-use-after-free|double-free|heap-buffer-overflow|stack-' | head -1)"; return
    fi
    # 3) native differential (compile + run; compare output AND exit to the VM)
    if "$EMB" -o "$TMP/bin" "$em" >/dev/null 2>&1; then
        nat=$("$TMP/bin" 2>&1); natrc=$?
        if [ "$natrc" != "0" ]; then echo "native-crash"; return; fi
        if [ "$nat" != "$vm" ]; then echo "diff:VM-ne-native"; return; fi
    else
        echo "native-compile-fail"; return
    fi
    # 4) RSS leak: regenerate the same seed small vs large; flag super-linear growth.
    "$GEN" "$seed" 50   > "$TMP/lo.em"
    "$GEN" "$seed" 6000 > "$TMP/hi.em"
    rlo=$(rss_of "$TMP/lo.em"); rhi=$(rss_of "$TMP/hi.em")
    if [ "$rhi" -gt $((rlo * 4)) ] && [ $((rhi - rlo)) -gt 40000 ]; then
        echo "leak"; return
    fi
    echo ""
}

# shrink <program.em> <signature> -> minimal repro (greedily delete op functions while the signature
# holds). Prints the reduced program.
shrink() {
    cp "$1" "$TMP/work.em"; sig="$2"; changed=1
    while [ "$changed" = 1 ]; do
        changed=0
        for k in $(grep -oE '^fn op[0-9]+' "$TMP/work.em" | grep -oE '[0-9]+'); do
            awk -v k="$k" '
                $0 ~ ("^fn op" k "\\(\\) ") || $0 ~ ("^fn op" k "\\(\\)$") { skip=1 }
                skip && /^}/ { skip=0; next }
                skip { next }
                $0 ~ ("total \\+ op" k "\\(\\)$") { next }
                { print }
            ' "$TMP/work.em" > "$TMP/cand.em"
            if [ "$(classify "$TMP/cand.em" 0)" = "$sig" ]; then cp "$TMP/cand.em" "$TMP/work.em"; changed=1; fi
        done
    done
    cat "$TMP/work.em"
}

# A signature listed in tools/crucible-known.txt is a tracked, already-filed finding (so a run only
# fails on something NEW). One signature per line; `#` comments allowed.
KNOWN="$ROOT/tools/crucible-known.txt"
is_known() { [ -f "$KNOWN" ] && grep -v '^#' "$KNOWN" | grep -qxF "$1"; }

# ---- the soak loop ------------------------------------------------------------------------------
say "crucible: running $COUNT seeds through 5 oracles…"
seen=" "; finds=0; new=0; clean=0; i=1
while [ "$i" -le "$COUNT" ]; do
    "$GEN" "$i" 30 > "$TMP/p.em"
    sig=$(classify "$TMP/p.em" "$i")
    if [ -n "$sig" ]; then
        case "$seen" in
            *" $sig "*) : ;;
            *)
                seen="$seen$sig "
                finds=$((finds + 1))
                safe=$(printf '%s' "$sig" | tr -c 'A-Za-z0-9' '_')
                out="$FINDS/find${finds}_${safe}.em"
                shrink "$TMP/p.em" "$sig" > "$out"
                ops=$(grep -c '^fn op' "$out")
                if is_known "$sig"; then
                    say "── [known] [$sig]  seed=$i  (minimal: $ops op)"
                else
                    new=$((new + 1))
                    say "── [NEW]   [$sig]  seed=$i  → ${out#$ROOT/}  (minimal: $ops op)"
                fi
                ;;
        esac
    else
        clean=$((clean + 1))
    fi
    i=$((i + 1))
done

say ""
say "crucible: $COUNT seeds → $clean clean, $finds distinct ($new NEW)."
if [ "$new" = 0 ]; then
    say "crucible: ✓ no new memory faults."
    exit 0
fi
say "crucible: ✗ $new NEW finding(s) — repros in ${FINDS#$ROOT/}/"
exit 1
