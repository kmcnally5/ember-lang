#!/usr/bin/env python3
# tools/string-diff.py — a differential oracle for std/string's Unicode code-point helpers.
#
# Python strings ARE code-point indexed, so CPython is a ground-truth reference for what
# str.cp_count / cp_at / cp_prefix / cp_slice / cp_insert / cp_delete must do. This tool fuzzes
# random UTF-8 strings (mixing 1-, 2-, 3- and 4-byte code points — ASCII, Latin-1, CJK, emoji,
# combining marks) and random indices (in- AND out-of-range), generates ONE Ember program that
# runs every case through std/string, and compares its output to the Python reference — element by
# element as code-point integers, so the comparison itself can't be confused by encoding/escaping.
#
# It is the repeatable proof that the string library is UTF-8 correct: re-run it after any change to
# std/string.em, chars()/from_char_code, or the string runtime.
#
#   tools/string-diff.py [N] [seed]     N random strings (default 150), reproducible by seed (default 1)
#
# Exit status is non-zero on any mismatch (prints the offending case + both code-point sequences).
import os, sys, subprocess, random

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMBERC = os.path.join(ROOT, "build", "emberc")
N    = int(sys.argv[1]) if len(sys.argv) > 1 else 150
SEED = int(sys.argv[2]) if len(sys.argv) > 2 else 1
rng  = random.Random(SEED)

# Code-point pools spanning all UTF-8 widths. A combining mark (U+0300..) deliberately follows so
# multi-code-point "characters" are exercised (cp_* index by code point, never by grapheme).
POOLS = (
    list(range(0x20, 0x7F)) +          # 1-byte ASCII (printable)
    list(range(0xA1, 0x100)) +         # 2-byte Latin-1 supplement (¡..ÿ)
    [0x0301, 0x0308, 0x0327] +         # 2-byte combining marks
    [0x4E2D, 0x6587, 0x65E5, 0x672C] + # 3-byte CJK
    [0x1F600, 0x1F4A9, 0x1F680]        # 4-byte emoji (astral)
)

def rand_cps():
    return [rng.choice(POOLS) for _ in range(rng.randint(0, 9))]

# ---- the reference: EXACTLY std/string's clamping spec (so the diff catches runtime/codegen bugs,
# and for in-range indices it coincides with CPython's native Unicode semantics = ground truth) ----
def ref(op, cps, a, b):
    n = len(cps)
    if op == "count":   return [ord(c) for c in str(n)]           # code points of the decimal count
    if op == "at":      return [cps[a]] if 0 <= a < n else []
    if op == "prefix":  hi = max(0, min(a, n));            return cps[0:hi]
    if op == "slice":
        lo = a if a >= 0 else 0
        hi = b if b <= n else n
        return [cps[i] for i in range(lo, hi) if 0 <= i < n]
    if op == "insert":  at = max(0, min(a, n));            return cps[:at] + INSERT + cps[at:]
    if op == "delete":  return [cps[j] for j in range(n) if j != a]
    raise ValueError(op)

INSERT = [0x2D, 0x1F4A9]   # the fixed insert payload: "-💩" (an ASCII + a 4-byte emoji)

def ember_str(cps):
    if not cps: return '""'
    return "concat([" + ", ".join("from_char_code(%d)" % c for c in cps) + "])"

# Build the case list: every string × every op, with a spread of in- and out-of-range indices.
cases = []   # (id, op, cps, a, b)
def add(op, cps, a=0, b=0): cases.append((len(cases), op, cps, a, b))
for _ in range(N):
    cps = rand_cps(); n = len(cps)
    idxs = sorted({0, n, n // 2, rng.randint(-2, n + 2), rng.randint(-2, n + 2)})
    add("count", cps)
    for i in idxs:
        add("at", cps, i); add("prefix", cps, i); add("insert", cps, i); add("delete", cps, i)
        add("slice", cps, i, rng.randint(-2, n + 2))

# ---- emit one Ember program that runs every case and prints `id|cp,cp,...` of each result ----
lines = ['import "std/string" as str', "",
         "fn emit(id: int, s: string) {",
         "    var parts: [string] = []",
         "    let cs = s.chars()",
         "    var i = 0",
         "    loop {",
         "        if i == cs.len() { break }",
         '        parts.append("{char_code(cs[i])}")',
         "        i = i + 1",
         "    }",
         '    println("{id}|{str.join(parts, ",")}")',
         "}", "",
         "fn main() -> int {",
         "    let INS = " + ember_str(INSERT)]
for cid, op, cps, a, b in cases:
    s = ember_str(cps)
    if   op == "count":  expr = '"{str.cp_count(%s)}"' % s
    elif op == "at":     expr = "str.cp_at(%s, %d)" % (s, a)
    elif op == "prefix": expr = "str.cp_prefix(%s, %d)" % (s, a)
    elif op == "slice":  expr = "str.cp_slice(%s, %d, %d)" % (s, a, b)
    elif op == "insert": expr = "str.cp_insert(%s, %d, INS)" % (s, a)
    elif op == "delete": expr = "str.cp_delete(%s, %d)" % (s, a)
    lines.append("    emit(%d, %s)" % (cid, expr))
lines += ["    return 0", "}"]
prog = "\n".join(lines) + "\n"

tmp = os.path.join("/tmp", "ember_string_diff.em")
open(tmp, "w").write(prog)
r = subprocess.run([EMBERC, "--emit=run", tmp], capture_output=True, text=True)
if r.returncode != 0:
    sys.stderr.write("string-diff: emberc failed:\n" + r.stdout + r.stderr); sys.exit(2)

got = {}
for ln in r.stdout.splitlines():
    if "|" not in ln or "=>" in ln: continue
    cid, _, rest = ln.partition("|")
    if not cid.strip().lstrip("-").isdigit(): continue
    got[int(cid)] = [int(x) for x in rest.split(",") if x != ""]

fails = 0
for cid, op, cps, a, b in cases:
    want = ref(op, cps, a, b)
    have = got.get(cid)
    if have != want:
        fails += 1
        if fails <= 20:
            print("MISMATCH id=%d op=%s s=%s a=%d b=%d\n   want=%s\n   have=%s"
                  % (cid, op, cps, a, b, want, have))
n_str = N
print("\nstring-diff: %d cases over %d random strings (seed %d) — %s"
      % (len(cases), n_str, SEED, "%d MISMATCH(es)" % fails if fails else "ALL MATCH ✓"))
sys.exit(1 if fails else 0)
