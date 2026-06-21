#!/bin/sh
# tools/ceilings.sh — the compiler-LIMITS stress tester ("ceilings"). Crucible's sibling: Crucible
# fuzzes MEMORY ownership; this fuzzes the OTHER recurring class — bytecode operands and pool/table
# indices that are too NARROW, where a value past 255 silently wraps a one-byte field and dispatches
# to the WRONG constant / function / type (a miscompile, not a clean error). OFI-007, OFI-047, and
# OFI-056 were all this class, each found REACTIVELY after it shipped. This finds them proactively.
#
# For each compiler dimension it generates a program that pushes that dimension PAST the single-byte
# boundary (N=600 by default) and classifies the outcome into the ONLY two acceptable ones:
#   WORKS  — compiles, runs, prints the expected checksum, AND the native binary agrees (VM==native).
#   CAPPED — a CLEAN compile error (a "too many …" message, no crash). A documented, guarded ceiling.
# Anything else is a FAIL: a crash/abort, a wrong answer (the silent wrap), a hang, or VM≠native.
#
# tools/ceilings-known.txt records the EXPECTED outcome per dimension (WORKS|CAPPED). The run fails
# (exit 1) if any dimension's actual outcome differs — a WORKS that regressed to a cap or a wrap, a
# CAPPED that started crashing, or a new dimension nobody baselined. Lift a ceiling → flip its line
# to WORKS. Add a new narrow operand → add a probe here + a baseline line, so it can't wrap unseen.
#
# Usage:  tools/ceilings.sh [N]        (N = how far past 256 to push; default 600)

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EMB="$ROOT/build/emberc"
KNOWN="$ROOT/tools/ceilings-known.txt"
N="${1:-600}"   # default well past BOTH 256 and the old 512-class internal buffers (a regression
                # that reintroduces a fixed array sized ≤512 is then caught by the standard gate)
export EMBER_STD="$ROOT/std"

TMP="${TMPDIR:-/tmp}/ceilings.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

say() { printf '%s\n' "$*"; }

say "ceilings: building compiler…"
(cd "$ROOT" && make >/dev/null 2>&1) || { say "ceilings: build failed"; exit 1; }

# sum(a..b) inclusive — the checksum most probes fold their values into.
sum_range() { awk -v a="$1" -v b="$2" 'BEGIN { s = 0; for (i = a; i <= b; i++) s += i; print s }'; }

# ---- probe generators: each writes $TMP/<dim>.em and echoes that program's EXPECTED stdout --------
# Every probe folds the values it touches into a printed checksum, so a wrapped index (wrong
# constant/local/field/function) changes the number and is caught — a silent miscompile can't pass.

gen_const() {           # > N distinct constant literals in ONE function (OP_CONST → OP_CONST_LONG)
    { echo "fn main() -> int {"; echo "    var acc = 0"
      i=0; while [ "$i" -lt "$N" ]; do echo "    acc = acc + $((1000 + i))"; i=$((i + 1)); done
      echo '    print("{acc}")'; echo "    return 0"; echo "}"; } > "$TMP/const.em"
    sum_range 1000 $((1000 + N - 1))
}

gen_string() {          # > N distinct string literals in ONE function (OP_STRING → OP_STRING_LONG)
    { echo "fn main() -> int {"; echo "    var acc = 0"
      i=0; while [ "$i" -lt "$N" ]; do echo "    acc = acc + \"s$i=\".len()"; i=$((i + 1)); done
      echo '    print("{acc}")'; echo "    return 0"; echo "}"; } > "$TMP/string.em"
    awk -v n="$N" 'BEGIN { s = 0; for (i = 0; i < n; i++) s += length("s" i "="); print s }'
}

gen_local() {           # > N live locals in ONE function (OP_GET_LOCAL / OP_SET_LOCAL, 1-byte slot)
    { echo "fn main() -> int {"
      i=0; while [ "$i" -lt "$N" ]; do echo "    let v$i = $i"; i=$((i + 1)); done
      echo "    var acc = 0"
      i=0; while [ "$i" -lt "$N" ]; do echo "    acc = acc + v$i"; i=$((i + 1)); done
      echo '    print("{acc}")'; echo "    return 0"; echo "}"; } > "$TMP/local.em"
    sum_range 0 $((N - 1))
}

gen_func() {            # > N functions in the program (OP_CALL function-table index, LEB128 OPK_IDX)
    # Names are `fn_$i`, NOT `f$i`: `f32`/`f64` would collide with the f32/f64 width-conversion
    # builtins, so `f32()` parses as a conversion, not a call — noise unrelated to function count.
    { i=0; while [ "$i" -lt "$N" ]; do echo "fn fn_$i() -> int { return $i }"; i=$((i + 1)); done
      echo "fn main() -> int {"; echo "    var acc = 0"
      i=0; while [ "$i" -lt "$N" ]; do echo "    acc = acc + fn_$i()"; i=$((i + 1)); done
      echo '    print("{acc}")'; echo "    return 0"; echo "}"; } > "$TMP/func.em"
    sum_range 0 $((N - 1))
}

gen_structtype() {      # > N distinct struct TYPES (struct-type id operand). Each is read via its own
    # accessor fn (1 local each) so the per-function local cap can't confound this dimension.
    { i=0; while [ "$i" -lt "$N" ]; do
          echo "struct S$i { a: int }"
          echo "fn g$i() -> int { let s = S$i { a: $i }  return s.a }"
          i=$((i + 1)); done
      echo "fn main() -> int {"; echo "    var acc = 0"
      i=0; while [ "$i" -lt "$N" ]; do echo "    acc = acc + g$i()"; i=$((i + 1)); done
      echo '    print("{acc}")'; echo "    return 0"; echo "}"; } > "$TMP/structtype.em"
    sum_range 0 $((N - 1))
}

gen_field() {           # ONE struct with > N fields (OP_GET_FIELD / OP_SET_FIELD field index, 1-byte)
    { printf "struct Big {"
      i=0; while [ "$i" -lt "$N" ]; do printf " f%d: int" "$i"; i=$((i + 1)); done
      echo " }"
      printf "fn main() -> int {\n    let b = Big {"
      i=0; while [ "$i" -lt "$N" ]; do
          if [ "$i" -gt 0 ]; then printf ","; fi; printf " f%d: %d" "$i" "$i"; i=$((i + 1)); done
      echo " }"; echo "    var acc = 0"
      i=0; while [ "$i" -lt "$N" ]; do echo "    acc = acc + b.f$i"; i=$((i + 1)); done
      echo '    print("{acc}")'; echo "    return 0"; echo "}"; } > "$TMP/field.em"
    sum_range 0 $((N - 1))
}

gen_variant() {         # ONE enum with > N variants (OP_NEW_ENUM variant index, 1-byte). Construct the
    # LAST variant (index N-1 > 255, bare — no payload) and match it back to its number.
    { echo "enum E {"
      i=0; while [ "$i" -lt "$N" ]; do echo "    V$i"; i=$((i + 1)); done
      echo "}"
      echo "fn main() -> int {"
      echo "    let e: E = V$((N - 1))"
      echo "    var acc = 0"
      echo "    match e {"
      i=0; while [ "$i" -lt "$N" ]; do echo "        case V$i { acc = $i }"; i=$((i + 1)); done
      echo "    }"
      echo '    print("{acc}")'; echo "    return 0"; echo "}"; } > "$TMP/variant.em"
    echo $((N - 1))
}

DIMS="const string local func structtype field variant"

# `emberc --emit=run` and the compiled binary both append a `=> <return value>` trailer after the
# program's own output; strip it so the comparison sees just the printed checksum.
strip_trailer() { printf '%s' "$1" | sed 's/[[:space:]]*=>[[:space:]]*-\{0,1\}[0-9]\{1,\}[[:space:]]*$//'; }

# classify <dim> <expected> -> echoes WORKS | CAPPED:<msg> | FAIL:<reason>
classify() {
    dim="$1"; expected="$2"; em="$TMP/$dim.em"
    out=$(strip_trailer "$("$EMB" --emit=run "$em" 2>"$TMP/err")"); rc=$?
    if [ "$out" = "$expected" ] && [ "$rc" -eq 0 ]; then
        # WORKS on the VM — the binary must agree (a native-only wrap is still a miscompile).
        if "$EMB" -o "$TMP/bin" "$em" >"$TMP/nerr" 2>&1; then
            nout=$(strip_trailer "$("$TMP/bin" 2>/dev/null)"); nrc=$?
            if [ "$nrc" -ne 0 ]; then echo "FAIL:native-crash(rc=$nrc)"; return; fi
            if [ "$nout" != "$out" ]; then echo "FAIL:VM!=native"; return; fi
            echo "WORKS"
        else
            echo "FAIL:native-compile-fail"
        fi
        return
    fi
    if [ "$rc" -ge 128 ]; then echo "FAIL:crash(rc=$rc)"; return; fi          # signal — a real fault
    # A clean compile error is an acceptable (guarded) ceiling — capture the message so the cap is
    # legible AND so an UNRELATED compile error (a bad probe) is distinguishable from a real cap.
    msg=$(grep -m1 "error:" "$TMP/err" 2>/dev/null | sed 's/^[^:]*:[0-9]*:[0-9]*: //; s/^[^:]*: //')
    if [ -n "$msg" ]; then echo "CAPPED:$msg"; return; fi
    echo "FAIL:wrong-output(rc=$rc)"                                          # ran, wrong checksum = wrap
}

# baseline lookup: expected outcome (WORKS|CAPPED) for a dim, or "" if unbaselined.
baseline_of() { [ -f "$KNOWN" ] && awk -v d="$1" '$1==d {print $2}' "$KNOWN" | head -1; }

say "ceilings: stressing $(echo "$DIMS" | wc -w | tr -d ' ') dimensions at N=$N (past the 256 boundary)…"
say ""
printf '  %-12s %-8s %-8s %s\n' DIMENSION ACTUAL BASELINE NOTE
fails=0; drift=0
for dim in $DIMS; do
    expected=$("gen_$dim")
    actual=$(classify "$dim" "$expected")
    base=$(baseline_of "$dim")
    short=${actual%%:*}                       # WORKS | CAPPED | FAIL
    note=""
    case "$actual" in *:*) note="${actual#*:}";; esac   # the cap message / fail reason
    flag=" "
    if [ "$short" = "FAIL" ]; then
        flag="✗"; fails=$((fails + 1))
    elif [ -z "$base" ]; then
        flag="?"; note="unbaselined (${note:-$short}) — add to ceilings-known.txt"; drift=$((drift + 1))
    elif [ "$short" != "$base" ]; then
        flag="✗"; note="drift: baseline=$base actual=$short ${note}"; fails=$((fails + 1))
    fi
    printf '%s %-12s %-8s %-8s %s\n' "$flag" "$dim" "$short" "${base:-—}" "$note"
done
say ""

if [ "$fails" -gt 0 ]; then
    say "ceilings: ✗ $fails dimension(s) FAILED — a narrow operand wrapped, crashed, or regressed."
    say "          repros in $TMP were removed; re-run with the dim's gen_* to inspect."
    exit 1
fi
if [ "$drift" -gt 0 ]; then
    say "ceilings: $drift dimension(s) unbaselined — add a line to tools/ceilings-known.txt."
    exit 1
fi
say "ceilings: ✓ every dimension is either lifted (WORKS) or cleanly capped (CAPPED) — no silent wraps."
