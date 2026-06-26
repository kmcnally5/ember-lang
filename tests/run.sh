#!/bin/sh
# tests/run.sh — Ember regression harness (golden-file / snapshot testing).
#
# Two tiers:
#   1. Snapshot cases under tests/<stage>/*.em, each compared against a sibling
#      golden file (.tokens for the lexer stage). These lock exact output.
#   2. Smoke cases: every examples/*.em must still lex without a lexical error.
#      The examples are the living integration baseline.
#
# Usage:
#   tests/run.sh            run all cases; exit non-zero if any fail
#   tests/run.sh --update   regenerate every snapshot golden from current output
#                           (only after you've reviewed the diff — this blesses
#                            whatever the compiler currently emits)
#
# POSIX sh, no dependencies beyond the built compiler at build/emberc.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc"

UPDATE=0
if [ "${1:-}" = "--update" ]; then
    UPDATE=1
fi

if [ ! -x "$BIN" ]; then
    echo "error: $BIN not found — run 'make' first" >&2
    exit 2
fi

pass=0
fail=0
updated=0

# golden_ext maps a stage directory name to the extension its goldens use, so a
# future tests/parser/ can emit .ast without changing this harness.
golden_ext() {
    case "$1" in
        lexer)   echo "tokens" ;;
        parser)  echo "ast" ;;
        codegen) echo "bytecode" ;;
        run)     echo "out" ;;
        trace)   echo "tape" ;;
        check)   echo "check" ;;
        replay)  echo "replay" ;;
        prove)   echo "prove" ;;
        docs)    echo "md" ;;
        fault)   echo "fault" ;;
        *)       echo "out" ;;
    esac
}

# emit_flag maps a stage directory name to the compiler's --emit mode for it.
emit_flag() {
    case "$1" in
        lexer)   echo "tokens" ;;
        parser)  echo "ast" ;;
        codegen) echo "bytecode" ;;
        run)     echo "run" ;;
        trace)   echo "trace" ;;
        check)   echo "check" ;;
        replay)  echo "replay" ;;
        prove)   echo "prove" ;;
        docs)    echo "docs" ;;
        fault)   echo "run" ;;
        *)       echo "tokens" ;;
    esac
}

# extra_flags adds per-stage compiler flags beyond --emit. The `fault` stage runs ordinary
# programs (--emit=run) but selects the AGENT Fault render (--faults=agent) so the LLM-facing
# JSON-Lines failure artifact is golden-locked (docs/faults.md).
extra_flags() {
    case "$1" in
        fault) echo "--faults=agent" ;;
        *)     echo "" ;;
    esac
}

# Tier 1 — snapshot cases, one stage directory at a time.
for dir in "$ROOT"/tests/*/; do
    [ -d "$dir" ] || continue
    stage=$(basename "$dir")
    # The graphics stage needs the raylib build and a display — it's driven separately
    # by tests/run-graphics.sh (`make test-graphics`), not this dependency-free suite.
    [ "$stage" = "graphics" ] && continue
    # The parallel stage is correct only under the -DEMBER_PARALLEL runtime (spawn-at-spawn-time
    # concurrency); under this serial suite those programs would block forever. Driven separately
    # by tests/run-parallel.sh (`make test-parallel`).
    [ "$stage" = "parallel" ] && continue
    # The net stage needs the -DEMBER_NET libcurl build (std/http's curl externs); under this
    # dependency-free suite those imports don't resolve. Driven separately by tests/run-net.sh
    # (`make test-net`), whose header already documents net as kept OUT of this suite. (OFI-105)
    [ "$stage" = "net" ] && continue
    # The db stage needs the -DEMBER_SQLITE vendored-SQLite build (std/sqlite's externs); under this
    # dependency-free suite those imports don't resolve. Driven separately by tests/run-db.sh
    # (`make test-db`), whose header documents db as kept OUT of this suite.
    [ "$stage" = "db" ] && continue
    # The native stage is a DIFFERENTIAL suite (VM vs compiled binary), not a golden
    # comparison — handled in its own block below.
    [ "$stage" = "native" ] && continue
    ext=$(golden_ext "$stage")
    emit=$(emit_flag "$stage")
    extra=$(extra_flags "$stage")

    for em in "$dir"*.em; do
        [ -e "$em" ] || continue
        rel=${em#"$ROOT"/}
        golden="${em%.em}.$ext"
        # Run from ROOT with a repo-relative path and capture stderr too, so any
        # diagnostics in the golden are stable across machines (no absolute paths)
        # and error cases can be regression-tested by their messages.
        actual=$(cd "$ROOT" && "$BIN" --emit="$emit" $extra "$rel" 2>&1)

        if [ "$UPDATE" -eq 1 ]; then
            printf '%s\n' "$actual" > "$golden"
            echo "UPDATED $rel"
            updated=$((updated + 1))
            continue
        fi

        if [ ! -f "$golden" ]; then
            echo "FAIL    $rel  (no golden — run: tests/run.sh --update)"
            fail=$((fail + 1))
            continue
        fi

        if printf '%s\n' "$actual" | diff -u "$golden" - >/dev/null 2>&1; then
            echo "PASS    $rel"
            pass=$((pass + 1))
        else
            echo "FAIL    $rel"
            printf '%s\n' "$actual" | diff -u "$golden" - | sed 's/^/        /'
            fail=$((fail + 1))
        fi
    done
done

# Tier 1b — native backend differential (docs/architecture.md "Decision: native
# backend"). Each tests/native/*.em is run BOTH on the bytecode VM and as a binary
# compiled by `emberc -o`, and their STDOUT must match — the drift guard that keeps
# AST→C in lockstep with the reference VM. (Only stdout: rich structured Faults are the
# VM's job and go to stderr; native aborts via a bare em_panic by design — OFI-109.)
# Skipped under --update (no goldens) and
# if no C compiler is on PATH.
if [ "$UPDATE" -eq 0 ] && [ -d "$ROOT/tests/native" ] && command -v cc >/dev/null 2>&1; then
    for em in "$ROOT"/tests/native/*.em; do
        [ -e "$em" ] || continue
        rel=${em#"$ROOT"/}
        bin="${TMPDIR:-/tmp}/emberc_native_$$_$(basename "${em%.em}")"
        vm=$(cd "$ROOT" && "$BIN" --emit=run "$rel" 2>/dev/null)
        if ! (cd "$ROOT" && "$BIN" -o "$bin" "$rel" >/dev/null 2>&1); then
            echo "FAIL    $rel  (native — compile failed)"
            fail=$((fail + 1))
            continue
        fi
        nat=$("$bin" 2>/dev/null)
        rm -f "$bin"
        if [ "$vm" = "$nat" ]; then
            echo "PASS    $rel  (native: VM == binary)"
            pass=$((pass + 1))
        else
            echo "FAIL    $rel  (native: VM != binary)"
            echo "        VM:     [$vm]"
            echo "        binary: [$nat]"
            fail=$((fail + 1))
        fi
    done
fi

# Tier 2 — smoke: every example must fully compile (lex, parse, AND type-check via
# --emit=bytecode), so a showcase example can't silently drift off the implemented
# language behind a lex-only check (that drift was OFI-030). The graphics examples
# import std/draw/std/ui and need the raylib backend natives, which the default
# dependency-free build lacks — they only LEX+PARSE here and are FULLY compiled in
# tests/run-graphics.sh under build/emberc-gfx.
# Skipped during --update, since they carry no goldens to regenerate.
if [ "$UPDATE" -eq 0 ]; then
    for em in "$ROOT"/examples/*.em; do
        [ -e "$em" ] || continue
        rel=${em#"$ROOT"/}
        if ! (cd "$ROOT" && "$BIN" --emit=tokens "$rel") >/dev/null 2>&1; then
            echo "FAIL    $rel  (smoke — lexical error)"
            fail=$((fail + 1))
        elif ! (cd "$ROOT" && "$BIN" --emit=ast "$rel") >/dev/null 2>&1; then
            echo "FAIL    $rel  (smoke — parse error)"
            fail=$((fail + 1))
        elif grep -qE '^[[:space:]]*import[[:space:]]+"std/(draw|ui)"' "$em"; then
            echo "PASS    $rel  (smoke: lex + parse — graphics, full-compiled in run-graphics.sh)"
            pass=$((pass + 1))
        elif ! (cd "$ROOT" && "$BIN" --emit=bytecode "$rel") >/dev/null 2>&1; then
            echo "FAIL    $rel  (smoke — type/codegen error)"
            fail=$((fail + 1))
        else
            echo "PASS    $rel  (smoke: full compile)"
            pass=$((pass + 1))
        fi
    done
fi

echo
if [ "$UPDATE" -eq 1 ]; then
    echo "updated $updated golden file(s)"
    exit 0
fi

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
