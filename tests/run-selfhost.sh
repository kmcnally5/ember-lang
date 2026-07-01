#!/bin/sh
# tests/run-selfhost.sh — differential harness for the self-hosting bootstrap (docs/design/self-hosting.md).
#
# Each tests/selfhost/*.em is a compiler-shaped program — recursive ASTs, symbol tables, the lex/parse/eval
# shapes the reference compiler is built from. The point of the tier is to prove the language can express
# and run those shapes IDENTICALLY on both backends before any real stage is ported, so every case is run
# two ways and their stdout compared:
#
#   * on the bytecode VM:        emberc --emit=run X.em
#   * as a compiled native binary: emberc -o <bin> X.em  then run <bin>
#
# PASS iff the two stdouts are byte-identical — the same drift guard tests/native applies to the native
# backend, here pointed at the self-hosting prerequisites. (Only stdout is compared: structured Faults are
# the VM's job and go to stderr, while native aborts via a bare em_panic — OFI-109 — so stderr legitimately
# differs.) Native comparison is skipped if no C compiler is on PATH (the VM run still has to succeed).
#
# This tier is a DIFFERENTIAL, not a golden snapshot — there are no sibling .out files, so it is run by its
# own `make selfhost` target rather than the golden loop in tests/run.sh (which skips the selfhost stage).
#
# Usage:
#   tests/run-selfhost.sh        run every self-hosting case

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc"
export EMBER_STD="$ROOT/std"

if [ ! -x "$BIN" ]; then
    echo "selfhost: $BIN not built — run 'make' first" >&2
    exit 2
fi

HAVE_CC=0
command -v cc >/dev/null 2>&1 && HAVE_CC=1

# A missing C compiler silently halves the gate (no native binary to diff against). That is fine for
# local convenience but must be LOUD, so a cc-less CI lane can't pass native regressions unnoticed —
# and an opt-in knob lets a build that expects a compiler turn the absence into a hard failure.
if [ "$HAVE_CC" -eq 0 ]; then
    echo "selfhost: WARNING — no C compiler on PATH; the native half of the differential is SKIPPED (VM only)." >&2
    if [ "${SELFHOST_REQUIRE_NATIVE:-0}" != "0" ]; then
        echo "selfhost: SELFHOST_REQUIRE_NATIVE is set but cc is absent — failing." >&2
        exit 2
    fi
fi

pass=0
fail=0

for src in "$ROOT"/tests/selfhost/*.em; do
    [ -e "$src" ] || continue
    rel=${src#"$ROOT"/}
    base=$(basename "${src%.em}")

    # Reference run: the bytecode VM. A non-zero exit (e.g. an uncaught Fault) makes the program's
    # behaviour undefined for the differential, so treat a VM compile/run failure as a hard FAIL.
    if ! vm=$(cd "$ROOT" && "$BIN" --emit=run "$rel" 2>/dev/null); then
        echo "FAIL    $rel  (VM run failed)"
        fail=$((fail + 1))
        continue
    fi

    if [ "$HAVE_CC" -eq 0 ]; then
        echo "PASS    $rel  (VM only — no cc for native differential)"
        pass=$((pass + 1))
        continue
    fi

    bin="${TMPDIR:-/tmp}/emberc_selfhost_$$_$base"
    if ! (cd "$ROOT" && "$BIN" -o "$bin" "$rel" >/dev/null 2>&1); then
        echo "FAIL    $rel  (native — compile failed)"
        fail=$((fail + 1))
        continue
    fi
    nat=$("$bin" 2>/dev/null)
    nrc=$?
    rm -f "$bin"

    # The VM run already succeeded (exit 0), so a non-zero native exit is itself a divergence — a crash
    # or abort that may even have flushed correct stdout first. Without this check such a case scores PASS
    # on stdout alone (the silent-green hole). (Stderr asymmetry from OFI-109 is fine — we gate on the
    # exit code only when the VM side was clean.)
    if [ "$nrc" -ne 0 ]; then
        echo "FAIL    $rel  (native exited $nrc — VM run was clean, so this is a divergence)"
        fail=$((fail + 1))
        continue
    fi

    if [ "$vm" = "$nat" ]; then
        echo "PASS    $rel  (VM == native)"
        pass=$((pass + 1))
    else
        echo "FAIL    $rel  (VM != native)"
        echo "        VM:     [$vm]"
        echo "        binary: [$nat]"
        fail=$((fail + 1))
    fi
done

# ---- Stage 1: the self-hosted lexer (selfhost/lexer.em) ------------------------------------------
# Its token dump must be byte-identical to stage-0's `emberc --emit=tokens` over the WHOLE corpus — the
# Stage 1 differential (docs/design/self-hosting.md). Compile the Ember lexer ONCE to a native binary
# (fast) and diff its output against the stage-0 oracle for every .em under examples/, tests/, std/,
# selfhost/; with no cc, fall back to the VM (`--emit=run`, slower). The trailing `=> 0` line the run
# driver/binary prints is stripped. Only stdout is compared (stage-0 lex diagnostics go to stderr).
LEXSRC="$ROOT/selfhost/lex_dump.em"
if [ -f "$LEXSRC" ]; then
    lexbin=""
    if [ "$HAVE_CC" -eq 1 ]; then
        lexbin="${TMPDIR:-/tmp}/emberc_selfhost_lexer_$$"
        if ! (cd "$ROOT" && "$BIN" -o "$lexbin" selfhost/lex_dump.em >/dev/null 2>&1); then
            echo "FAIL    selfhost/lex_dump.em  (native compile failed)"
            fail=$((fail + 1))
            lexbin=""
        fi
    fi
    lpass=0
    lfail=0
    for src in $(cd "$ROOT" && find examples tests std selfhost -name '*.em' | sort); do
        oracle=$(cd "$ROOT" && "$BIN" --emit=tokens "$src" 2>/dev/null)
        if [ -n "$lexbin" ]; then
            actual=$(cd "$ROOT" && "$lexbin" "$src" 2>/dev/null | sed '/^=> 0$/d')
        else
            actual=$(cd "$ROOT" && "$BIN" --emit=run selfhost/lex_dump.em "$src" 2>/dev/null | sed '/^=> 0$/d')
        fi
        if [ "$oracle" = "$actual" ]; then
            lpass=$((lpass + 1))
        else
            lfail=$((lfail + 1))
            if [ "$lfail" -le 3 ]; then
                echo "FAIL    self-hosted lexer differs from stage-0 on $src"
                to="${TMPDIR:-/tmp}/selfhost_lex_oracle_$$"
                ta="${TMPDIR:-/tmp}/selfhost_lex_actual_$$"
                printf '%s\n' "$oracle" > "$to"
                printf '%s\n' "$actual" > "$ta"
                diff "$to" "$ta" | head -8 | sed 's/^/        /'
                rm -f "$to" "$ta"
            fi
        fi
    done
    [ -n "$lexbin" ] && rm -f "$lexbin"
    echo "selfhost lexer: $lpass/$((lpass + lfail)) files byte-identical to stage-0 --emit=tokens"
    pass=$((pass + lpass))
    fail=$((fail + lfail))
fi

# ---- Stage 2: the self-hosted parser (selfhost/parser.em via parse_dump.em) ----------------------
# Its AST dump must be byte-identical to stage-0's `emberc --emit=ast` over the corpus's VALID programs
# (docs/design/self-hosting.md). Files the stage-0 parser REJECTS (non-zero exit — deliberately malformed
# error-recovery tests) are skipped: matching error-recovery trees is a separate, out-of-scope goal.
PARSESRC="$ROOT/selfhost/parse_dump.em"
if [ -f "$PARSESRC" ]; then
    parsebin=""
    if [ "$HAVE_CC" -eq 1 ]; then
        parsebin="${TMPDIR:-/tmp}/emberc_selfhost_parser_$$"
        if ! (cd "$ROOT" && "$BIN" -o "$parsebin" selfhost/parse_dump.em >/dev/null 2>&1); then
            echo "FAIL    selfhost/parse_dump.em  (native compile failed)"
            fail=$((fail + 1))
            parsebin=""
        fi
    fi
    ppass=0
    pfail=0
    pskip=0
    for src in $(cd "$ROOT" && find examples tests std selfhost -name '*.em' | sort); do
        # Skip files the reference parser rejects (malformed / error-recovery tests).
        if ! (cd "$ROOT" && "$BIN" --emit=ast "$src" >/dev/null 2>&1); then
            pskip=$((pskip + 1))
            continue
        fi
        oracle=$(cd "$ROOT" && "$BIN" --emit=ast "$src" 2>/dev/null)
        if [ -n "$parsebin" ]; then
            actual=$(cd "$ROOT" && "$parsebin" "$src" 2>/dev/null | sed '/^=> 0$/d')
        else
            actual=$(cd "$ROOT" && "$BIN" --emit=run selfhost/parse_dump.em "$src" 2>/dev/null | sed '/^=> 0$/d')
        fi
        if [ "$oracle" = "$actual" ]; then
            ppass=$((ppass + 1))
        else
            pfail=$((pfail + 1))
            if [ "$pfail" -le 3 ]; then
                echo "FAIL    self-hosted parser differs from stage-0 on $src"
                to="${TMPDIR:-/tmp}/selfhost_ast_oracle_$$"
                ta="${TMPDIR:-/tmp}/selfhost_ast_actual_$$"
                printf '%s\n' "$oracle" > "$to"
                printf '%s\n' "$actual" > "$ta"
                diff "$to" "$ta" | head -10 | sed 's/^/        /'
                rm -f "$to" "$ta"
            fi
        fi
    done
    [ -n "$parsebin" ] && rm -f "$parsebin"
    echo "selfhost parser: $ppass/$((ppass + pfail)) valid files byte-identical to stage-0 --emit=ast ($pskip malformed skipped)"
    pass=$((pass + ppass))
    fail=$((fail + pfail))
fi

# ---- Stage 3: the self-hosted checker (selfhost/checker.em via check_dump.em) ---------------------
# The driver prints ACCEPT (no diagnostics) or REJECT; we compare its verdict to stage-0's
# `emberc --emit=bytecode` (exit 0 = accepts, non-zero = a check error) over the corpus. M3 is built in
# stages, so it does not yet REJECT every ill-typed program — the verdict-match rate is therefore REPORTED,
# not gated. What IS gated is the safety invariant: the self-hosted checker must NEVER reject a program
# stage-0 accepts (a false rejection is a real bug, where a missed rejection is just unfinished work). Files
# whose accept/reject depends on an opt-in build profile (net/db/http/sqlite/sse) or that are lexer-error
# fixtures are excluded — their builtins/shape are out of scope for the default-profile checker.
CHECKSRC="$ROOT/selfhost/check_dump.em"
if [ -f "$CHECKSRC" ]; then
    checkbin=""
    if [ "$HAVE_CC" -eq 1 ]; then
        checkbin="${TMPDIR:-/tmp}/emberc_selfhost_checker_$$"
        if ! (cd "$ROOT" && "$BIN" -o "$checkbin" selfhost/check_dump.em >/dev/null 2>&1); then
            echo "FAIL    selfhost/check_dump.em  (native compile failed)"
            fail=$((fail + 1))
            checkbin=""
        fi
    fi
    cmatch=0
    cmiss=0
    cfalse=0
    for src in $(cd "$ROOT" && find examples tests std selfhost -name '*.em' | grep -vE 'tests/(net|db)/|std/(http|sqlite|sse)|tests/lexer/errors' | sort); do
        if (cd "$ROOT" && "$BIN" --emit=bytecode "$src" >/dev/null 2>&1); then
            oracle="ACCEPT"
        else
            oracle="REJECT"
        fi
        if [ -n "$checkbin" ]; then
            mine=$(cd "$ROOT" && "$checkbin" "$src" 2>/dev/null | grep -E 'REJECT|ACCEPT')
        else
            mine=$(cd "$ROOT" && "$BIN" --emit=run selfhost/check_dump.em "$src" 2>/dev/null | grep -E 'REJECT|ACCEPT')
        fi
        if [ "$oracle" = "$mine" ]; then
            cmatch=$((cmatch + 1))
        elif [ "$oracle" = "ACCEPT" ]; then
            cfalse=$((cfalse + 1))
            if [ "$cfalse" -le 5 ]; then
                echo "FAIL    self-hosted checker FALSE-REJECTS a valid program: $src"
            fi
        else
            cmiss=$((cmiss + 1))
        fi
    done
    [ -n "$checkbin" ] && rm -f "$checkbin"
    echo "selfhost checker: $cmatch/$((cmatch + cmiss + cfalse)) verdict-match vs stage-0 ($cmiss not-yet-rejected, $cfalse false-rejects)"
    fail=$((fail + cfalse))
fi

# ---- Stage 4: the self-hosted bytecode backend (selfhost/codegen.em via codegen_dump.em) -----------
# Its disassembly must be BYTE-IDENTICAL to stage-0 `emberc --emit=bytecode` (offsets, opcodes, operands,
# constant pool, AND the source-line column) over the M4 codegen fixtures (tests/selfhost/codegen/*.em —
# the scalar subset implemented so far: int/bool arithmetic, locals, user-fn calls, returns). The fixture
# set grows as M4 coverage grows; a hard FAIL on any divergence locks in each increment.
CGSRC="$ROOT/selfhost/codegen_dump.em"
if [ -f "$CGSRC" ]; then
    cgbin=""
    if [ "$HAVE_CC" -eq 1 ]; then
        cgbin="${TMPDIR:-/tmp}/emberc_selfhost_codegen_$$"
        if ! (cd "$ROOT" && "$BIN" -o "$cgbin" selfhost/codegen_dump.em >/dev/null 2>&1); then
            echo "FAIL    selfhost/codegen_dump.em  (native compile failed)"
            fail=$((fail + 1))
            cgbin=""
        fi
    fi
    cgpass=0
    cgfail=0
    for src in $(cd "$ROOT" && find tests/selfhost/codegen -name '*.em' 2>/dev/null | sort); do
        oracle=$(cd "$ROOT" && "$BIN" --emit=bytecode "$src" 2>/dev/null)
        if [ -n "$cgbin" ]; then
            actual=$(cd "$ROOT" && "$cgbin" "$src" 2>/dev/null | sed '/^=> 0$/d')
        else
            actual=$(cd "$ROOT" && "$BIN" --emit=run selfhost/codegen_dump.em "$src" 2>/dev/null | sed '/^=> 0$/d')
        fi
        if [ "$oracle" = "$actual" ]; then
            cgpass=$((cgpass + 1))
        else
            cgfail=$((cgfail + 1))
            if [ "$cgfail" -le 3 ]; then
                echo "FAIL    self-hosted codegen differs from stage-0 on $src"
                to="${TMPDIR:-/tmp}/sh_cg_o_$$"
                ta="${TMPDIR:-/tmp}/sh_cg_a_$$"
                printf '%s\n' "$oracle" > "$to"
                printf '%s\n' "$actual" > "$ta"
                diff "$to" "$ta" | head -12 | sed 's/^/        /'
                rm -f "$to" "$ta"
            fi
        fi
    done
    # Self-compiling WHOLE MODULES: real compiler modules the self-hosted backend now reproduces
    # byte-identically end-to-end (not just curated fixtures). The list grows as each module goes green.
    for m in selfhost/lexer.em selfhost/parser.em selfhost/checker.em selfhost/codegen.em; do
        oracle=$(cd "$ROOT" && "$BIN" --emit=bytecode "$m" 2>/dev/null)
        if [ -n "$cgbin" ]; then
            actual=$(cd "$ROOT" && "$cgbin" "$m" 2>/dev/null | sed '/^=> 0$/d')
        else
            actual=$(cd "$ROOT" && "$BIN" --emit=run selfhost/codegen_dump.em "$m" 2>/dev/null | sed '/^=> 0$/d')
        fi
        if [ "$oracle" = "$actual" ]; then
            cgpass=$((cgpass + 1))
            echo "selfhost codegen: $m self-compiles BYTE-IDENTICAL (full module)"
        else
            cgfail=$((cgfail + 1))
            echo "FAIL    self-hosted codegen differs from stage-0 on $m (full module)"
        fi
    done
    [ -n "$cgbin" ] && rm -f "$cgbin"
    echo "selfhost codegen: $cgpass/$((cgpass + cgfail)) M4a scalar fixtures byte-identical to stage-0 --emit=bytecode"
    pass=$((pass + cgpass))
    fail=$((fail + cgfail))
fi

# ---- Stage 5: the UNIFIED self-hosted compiler (selfhost/emberc.em) --------------------------------
# The whole pipeline (lex → parse → CHECK → codegen) as ONE program, compiled to a native self-built
# compiler BINARY. We gate two properties: (1) it reproduces every self-hosted module's bytecode
# byte-identically to stage-0 (the fixed point through one driver), and (2) it REJECTS an ill-typed
# program with exit 65 while ACCEPTING a valid one. This is the first standalone-bootstrap milestone.
EMBERCSRC="$ROOT/selfhost/emberc.em"
if [ -f "$EMBERCSRC" ] && [ "$HAVE_CC" -eq 1 ]; then
    selfbin="${TMPDIR:-/tmp}/emberc_self_$$"
    if (cd "$ROOT" && "$BIN" -o "$selfbin" selfhost/emberc.em >/dev/null 2>&1); then
        ubpass=0
        ubfail=0
        for m in selfhost/lexer.em selfhost/parser.em selfhost/checker.em selfhost/codegen.em; do
            oracle=$(cd "$ROOT" && "$BIN" --emit=bytecode "$m" 2>/dev/null)
            actual=$(cd "$ROOT" && "$selfbin" "$m" 2>/dev/null)
            if [ "$oracle" = "$actual" ]; then
                ubpass=$((ubpass + 1))
            else
                ubfail=$((ubfail + 1))
                echo "FAIL    unified emberc-self differs from stage-0 on $m"
            fi
        done
        # the check gate: an ill-typed program must be REJECTED (exit 65), a valid one ACCEPTED (exit 0)
        if (cd "$ROOT" && "$selfbin" tests/run/error_newtype_arith.em >/dev/null 2>&1); then
            ubfail=$((ubfail + 1)); echo "FAIL    unified emberc-self accepted an ill-typed program"
        else
            ubpass=$((ubpass + 1))
        fi
        if (cd "$ROOT" && "$selfbin" examples/01_hello.em >/dev/null 2>&1); then
            ubpass=$((ubpass + 1))
        else
            ubfail=$((ubfail + 1)); echo "FAIL    unified emberc-self rejected a valid program"
        fi
        echo "selfhost unified: emberc-self reproduces $ubpass checks (4 modules + check gate), $ubfail failed"
        pass=$((pass + ubpass))
        fail=$((fail + ubfail))
    else
        echo "FAIL    selfhost/emberc.em (native compile failed)"
        fail=$((fail + 1))
    fi
    rm -f "$selfbin"
fi

# ---- Stage 6: the self-hosted C-EMIT backend (selfhost/cgen_c.em via cgen_c_dump.em) ----------------
# The M5 native backend (AST → C). Each fixture's self-hosted C output must be byte-identical to stage-0
# `emberc --emit=c`, on BOTH the VM and a native build — the same differential as every other stage. Built
# incrementally (M5a = int scalars), so the gated set grows as features land.
CCSRC="$ROOT/selfhost/cgen_c_dump.em"
if [ -f "$CCSRC" ]; then
    ccbin=""
    if [ "$HAVE_CC" -eq 1 ]; then
        ccbin="${TMPDIR:-/tmp}/emberc_selfhost_cgenc_$$"
        if ! (cd "$ROOT" && "$BIN" -o "$ccbin" selfhost/cgen_c_dump.em >/dev/null 2>&1); then
            echo "FAIL    selfhost/cgen_c_dump.em  (native compile failed)"
            fail=$((fail + 1)); ccbin=""
        fi
    fi
    ccpass=0; ccfail=0
    for src in $(cd "$ROOT" && find tests/selfhost/cgen_c -name '*.em' 2>/dev/null | sort); do
        oracle=$(cd "$ROOT" && "$BIN" --emit=c "$src" 2>/dev/null)
        if [ -n "$ccbin" ]; then
            actual=$(cd "$ROOT" && "$ccbin" "$src" 2>/dev/null | sed '/^=> 0$/d')
        else
            actual=$(cd "$ROOT" && "$BIN" --emit=run selfhost/cgen_c_dump.em "$src" 2>/dev/null | sed '/^=> 0$/d')
        fi
        if [ "$oracle" = "$actual" ]; then
            ccpass=$((ccpass + 1))
        else
            ccfail=$((ccfail + 1))
            echo "FAIL    self-hosted C-emit differs from stage-0 on $src"
        fi
    done
    echo "selfhost cgen_c: $ccpass/$((ccpass + ccfail)) M5 C-emit fixtures byte-identical to stage-0 --emit=c"
    pass=$((pass + ccpass)); fail=$((fail + ccfail))

    # The real payoff: whole self-hosted MODULES whose C-emit is byte-identical to stage-0 (not fixtures —
    # actual compiler source). The first native-bootstrap milestone. This list grows as each module's
    # features land in cgen_c.em.
    cmpass=0; cmfail=0
    for src in selfhost/lexer.em selfhost/parser.em selfhost/checker.em selfhost/codegen.em; do
        oracle=$(cd "$ROOT" && "$BIN" --emit=c "$src" 2>/dev/null)
        if [ -n "$ccbin" ]; then
            actual=$(cd "$ROOT" && "$ccbin" "$src" 2>/dev/null | sed '/^=> 0$/d')
        else
            actual=$(cd "$ROOT" && "$BIN" --emit=run selfhost/cgen_c_dump.em "$src" 2>/dev/null | sed '/^=> 0$/d')
        fi
        if [ "$oracle" = "$actual" ]; then
            cmpass=$((cmpass + 1))
        else
            cmfail=$((cmfail + 1))
            echo "FAIL    self-hosted C-emit differs from stage-0 on module $src"
        fi
    done
    echo "selfhost cgen_c: $cmpass/$((cmpass + cmfail)) whole MODULES self-C-emit byte-identical (lexer, parser, checker, codegen — the C-emit FIXED POINT)"
    pass=$((pass + cmpass)); fail=$((fail + cmfail))

    [ -n "$ccbin" ] && rm -f "$ccbin"
fi

echo "selfhost: passed $pass, failed $fail"
[ "$fail" -eq 0 ]
