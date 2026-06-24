#!/bin/sh
# tools/opcheck.sh — proves the bytecode operand layer is internally consistent end-to-end. Two
# halves, matching the two ways operand layout can drift:
#   1) the CODEC round-trip (tools/opcheck.c): encode∘decode is the identity for every operand kind,
#      every opcode's spec round-trips, and opcode_operand_bytes agrees with the codec.
#   2) the -DEMBER_OPCHECK VM over the whole corpus: after each instruction, the handler must have
#      consumed EXACTLY the operand bytes its spec declares — so a handler reading the wrong width
#      (the OFI-007/047/056 class) aborts HERE, pinpointed, instead of desyncing far downstream.
# Together: encoder ↔ decoder ↔ disassembler ↔ VM all derive from the one opcode spec, and any
# mismatch is a build/test-time failure. Run it after any opcode change. `make opcheck`.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export EMBER_STD="$ROOT/std"
TMP="${TMPDIR:-/tmp}/opcheck.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
say() { printf '%s\n' "$*"; }

# 1) codec round-trip — opcode.c is dependency-free, so this links in isolation.
say "opcheck: building + running the codec round-trip…"
cc -std=c17 -Wall -Wextra -Werror -Iinclude -O1 \
   "$ROOT/tools/opcheck.c" "$ROOT/src/opcode.c" -o "$TMP/codec" \
   || { say "opcheck: codec test failed to build"; exit 1; }
"$TMP/codec" || exit 1

# 2) the OPCHECK VM: each handler asserts ip advanced by exactly the spec's operand width.
say "opcheck: building the OPCHECK VM…"
OC="$ROOT/build/emberc-opcheck"
mkdir -p "$ROOT/build"
cc -std=c17 -Iinclude -D_DEFAULT_SOURCE -O1 -g -DEMBER_OPCHECK=1 "$ROOT"/src/*.c -lm -o "$OC" 2>"$TMP/blog" \
   || { say "opcheck: OPCHECK VM failed to build"; tail -20 "$TMP/blog"; exit 1; }

# 3) run the corpus through it; any "*** OPCHECK:" on stderr is a handler/spec width mismatch. We
#    only care about that signal — a program erroring for other reasons (e.g. a graphics native is
#    absent in this non-graphics build) is irrelevant to operand consistency.
say "opcheck: running the corpus under the OPCHECK VM…"
violations=0; ran=0
run_one() {
    out=$("$OC" --emit=run "$1" 2>&1)
    if printf '%s' "$out" | grep -q "OPCHECK:"; then
        say "  ✗ $(basename "$1")"
        printf '%s\n' "$out" | grep "OPCHECK:" | sed 's/^/        /'
        violations=$((violations + 1))
    fi
    ran=$((ran + 1))
}
for d in tests/run tests/native examples; do
    for em in "$ROOT/$d"/*.em; do
        [ -e "$em" ] || continue
        run_one "$em"
    done
done

# 4) a >256-constant and >256-string function so OP_CONST_LONG / OP_STRING_LONG (the 3-byte index)
#    are actually executed under the OPCHECK VM — the regular corpus never crosses the 256 boundary.
{ echo "fn main() -> int {"; echo "  var a = 0"
  i=0; while [ "$i" -lt 300 ]; do echo "  a = a + $((1000 + i))"; i=$((i + 1)); done
  i=0; while [ "$i" -lt 300 ]; do echo "  a = a + \"s$i=\".len()"; i=$((i + 1)); done
  echo '  print("{a}")'; echo "  return 0"; echo "}"; } > "$TMP/long.em"
run_one "$TMP/long.em"

say ""
if [ "$violations" -gt 0 ]; then
    say "opcheck: ✗ $violations program(s) hit a handler/spec operand mismatch (of $ran run)."
    exit 1
fi
say "opcheck: ✓ codec round-trips and all $ran corpus programs consume operands exactly per spec."
