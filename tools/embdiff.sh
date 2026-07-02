#!/bin/sh
# tools/embdiff.sh — the byte-diff dev loop for the self-hosted bytecode SERIALIZER (selfhost/serialize.em,
# docs/design/bytecode-container.md, Phase 1c). For each source file it produces the `.emb` container two
# ways and requires them byte-identical:
#
#   * stage 0 (the C reference):   emberc --emit=bytecode-bin -o <a.emb> FILE
#   * the self-hosted serializer:  emberc --emit=run selfhost/serialize_dump.em FILE <b.emb>
#
# On a divergence it prints the byte offset of the first difference and a hexdump window around it, plus
# which section that offset falls in — the same "show me the first hunk" loop cgdiff/ccdiff gave the
# bytecode and C-emit ports. PASS iff every file's two containers are identical.
#
# Usage:
#   tools/embdiff.sh FILE.em [FILE.em ...]
#   tools/embdiff.sh -d DIR          # every *.em under DIR (non-graphics)

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc"
export EMBER_STD="$ROOT/std"
[ -x "$BIN" ] || { echo "embdiff: $BIN not built — run 'make' first" >&2; exit 2; }

A="${TMPDIR:-/tmp}/embdiff_stage0_$$.emb"
B="${TMPDIR:-/tmp}/embdiff_self_$$.emb"

files=""
if [ "${1:-}" = "-d" ]; then
    files=$(find "$2" -name '*.em' | grep -v graphics | sort)
else
    files="$*"
fi

pass=0
fail=0
for f in $files; do
    [ -f "$f" ] || continue
    rel=${f#"$ROOT"/}
    rm -f "$A" "$B"
    if ! (cd "$ROOT" && "$BIN" --emit=bytecode-bin -o "$A" "$rel" >/dev/null 2>&1); then
        continue   # stage 0 can't compile it (checker error / no main) — not a serializer case
    fi
    (cd "$ROOT" && "$BIN" --emit=run selfhost/serialize_dump.em "$rel" "$B" >/dev/null 2>&1)
    if [ ! -f "$B" ]; then
        echo "FAIL    $rel  (self-hosted serializer produced no .emb)"
        fail=$((fail + 1))
        continue
    fi
    if cmp -s "$A" "$B"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        off=$(cmp "$A" "$B" 2>/dev/null | sed -n 's/.* differ: byte \([0-9]*\).*/\1/p')
        echo "FAIL    $rel  (differ at byte ${off:-?}; stage0=$(wc -c <"$A") self=$(wc -c <"$B") bytes)"
        if [ -n "${off:-}" ]; then
            start=$((off > 16 ? off - 16 : 0))
            echo "  stage0 @${start}:"; xxd -s "$start" -l 48 "$A" | sed 's/^/    /'
            echo "  self   @${start}:"; xxd -s "$start" -l 48 "$B" | sed 's/^/    /'
        fi
    fi
done
rm -f "$A" "$B"
echo "embdiff: $pass byte-identical, $fail differ"
[ "$fail" -eq 0 ]
