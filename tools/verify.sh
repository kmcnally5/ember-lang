#!/bin/sh
# tools/verify.sh — the one-command gate runner. Builds the compiler, then runs every standing
# correctness gate and prints a consolidated PASS/FAIL summary. This is the repeated manual work of
# the whole project in one place: after any compiler change, `make verify` (or tools/verify.sh) is
# the single check.
#
#   GATE       WHAT IT GUARDS
#   build      -Wall -Wextra -Werror clean compile (the serial reference build)
#   parallel   the same -Werror compile with -DEMBER_PARALLEL=1 — catches an #if-guarded
#              unused/typo in a parallel-only path the serial build never sees (no extra deps)
#   test       behaviour goldens + native VM==binary differential + editor-asset sync
#   opcheck    every bytecode operand's width is consistent across spec/codegen/VM (the LEB128 class)
#   ceilings   every compiler dimension scales (WORKS) or cleanly errors (CAPPED) — never silent-wraps
#   ledger     the resource-linearity fuzzer: no Ptr leak compiles, no balanced program is rejected
#   crucible   the memory-ownership fuzzer finds no new double-free / leak / VM≠native faults
#
# (The graphics / net / net-graphics builds need raylib/freetype/libcurl, so — like `make test` — they
# are NOT run here; build them with `make graphics` / `make net-graphics` when those deps are present.)
#
# Usage:  tools/verify.sh            run all gates
#         tools/verify.sh fast       skip crucible (the slow fuzzer) for a quick inner-loop check
#         tools/verify.sh <gate>...  run only the named gates (e.g. `tools/verify.sh test opcheck`)
#
# Exit status is non-zero if any gate fails, so it composes in scripts / CI.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2

ALL="build parallel test opcheck ceilings ledger crucible"
case "${1:-}" in
    "")     GATES="$ALL" ;;
    fast)   GATES="build parallel test opcheck ceilings ledger" ;;
    *)      GATES="$*" ;;
esac

# run_gate <name> <command...> — run a gate quietly, remember pass/fail + a one-line note.
PASS=0; FAIL=0; SUMMARY=""
run_gate() {
    name=$1; shift
    printf '  %-9s running…\r' "$name"
    out=$("$@" 2>&1); rc=$?
    # A one-line signature: the gate's own green/result line if present, else the last line.
    note=$(printf '%s\n' "$out" | grep -E '✓|passed [0-9]+|✗|FAIL|Error|error:' | tail -1)
    [ -z "$note" ] && note=$(printf '%s\n' "$out" | tail -1)
    if [ "$rc" -eq 0 ]; then
        printf '  \033[32m✓\033[0m %-9s %s\n' "$name" "$note"
        PASS=$((PASS + 1))
    else
        printf '  \033[31m✗\033[0m %-9s %s\n' "$name" "$note"
        FAIL=$((FAIL + 1))
        # On failure, echo the tail of the gate's output so the cause is visible inline.
        printf '%s\n' "$out" | tail -15 | sed 's/^/      | /'
    fi
}

echo "verify: $(echo "$GATES" | wc -w | tr -d ' ') gate(s) — $GATES"
for g in $GATES; do
    case "$g" in
        build)    run_gate build    make ;;
        parallel) run_gate parallel make parallel ;;
        test)     run_gate test     make test ;;
        opcheck)  run_gate opcheck  make opcheck ;;
        ceilings) run_gate ceilings make ceilings ;;
        ledger)   run_gate ledger   make ledger ;;
        crucible) run_gate crucible make crucible ;;
        *) echo "verify: unknown gate '$g' (known: $ALL)"; exit 2 ;;
    esac
done

echo
if [ "$FAIL" -eq 0 ]; then
    echo "verify: ✓ all $PASS gate(s) green."
    exit 0
fi
echo "verify: ✗ $FAIL of $((PASS + FAIL)) gate(s) FAILED."
exit 1
