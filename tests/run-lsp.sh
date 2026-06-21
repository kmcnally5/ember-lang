#!/bin/sh
# tests/run-lsp.sh — regression harness for the Ember language server (emberc --lsp).
#
# The LSP speaks JSON-RPC with Content-Length framing over stdio, so unlike the .em golden suites
# this drives a real session and asserts the protocol responses. A tiny Python driver builds the
# frames and checks them (Python is a TEST dependency only — the compiler/LSP link nothing). It is
# kept out of the dependency-free `make test`; run it with `make test-lsp`. Covers slices 1-4:
# diagnostics, hover, go-to-definition, completion, and document symbols.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc"

if [ ! -x "$BIN" ]; then
    echo "skip: $BIN not built — run 'make' first"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "skip: python3 not found (the LSP test driver needs it)"
    exit 0
fi

EMBER_STD="$ROOT/std" BIN="$BIN" python3 - <<'PY'
import subprocess, json, os, sys

def frame(obj):
    b = json.dumps(obj).encode()
    return b"Content-Length: %d\r\n\r\n%s" % (len(b), b)

URI = "file:///tmp/ember_lsp_regression.em"
BAD  = "fn main() -> int {\n    return \"oops\"\n}\n"
GOOD = ("struct Point {\n    x: int\n    y: int\n}\n\n"
        "/// Add two integers and return the sum.\n"
        "fn add(a: int, b: int) -> int {\n    return a + b\n}\n\n"
        "fn px(p: Point) -> int {\n    return p.x\n}\n\n"
        "fn main() -> int {\n    println(add(1, 2))\n    return add(1, 2)\n}\n")

glines = GOOD.split("\n")

# A second document with a nested struct + a method, to exercise `self.` and chained `a.b.`
# member completion (Phase 2c). Both resolve through the same semantic index.
URI2 = "file:///tmp/ember_lsp_nested.em"
NEST = ("struct Inner {\n    v: int\n}\n\n"
        "struct Outer {\n    inner: Inner\n"
        "    fn get(self) -> int {\n        return self.inner.v\n    }\n}\n\n"
        "fn use_o(o: Outer) -> int {\n    return o.get() + o.inner.v\n}\n")
nlines = NEST.split("\n")
srow = next(i for i, l in enumerate(nlines) if "self.inner.v" in l)
pos_self  = {"line": srow, "character": nlines[srow].index("self.inner.v") + len("self.")}
crow = next(i for i, l in enumerate(nlines) if "o.inner.v" in l)
pos_chain = {"line": crow, "character": nlines[crow].index("o.inner.v") + len("o.inner.")}
# the method name `get` in the call `o.get()` — for method hover + go-to-definition (Phase 2d).
methrow = next(i for i, l in enumerate(nlines) if "o.get()" in l)
pos_method = {"line": methrow, "character": nlines[methrow].index("o.get()") + len("o.")}

# A third document that IMPORTS a std module, to exercise CROSS-MODULE hover + cross-file
# go-to-definition (A3/A4): `str.contains(...)` resolves to std/string.em. EMBER_STD is set
# above, so the import resolves against the real stdlib.
URI3 = "file:///tmp/ember_lsp_xmod.em"
XMOD = ('import "std/string" as str\n\n'
        'fn has_err(line: string) -> bool {\n'
        '    return str.contains(line, "ERROR")\n'
        '}\n')
xlines = XMOD.split("\n")
xrow = next(i for i, l in enumerate(xlines) if "str.contains" in l)
pos_xmod = {"line": xrow, "character": xlines[xrow].index("contains")}

# A fourth document exercising BUILT-IN array/string method hover (OFI-038). These intrinsics are
# special-cased in the checker (not resolved through a struct's method table), so before the fix they
# left no semantic-index entry and hovering them returned nothing — the bug Karl hit on
# `tokens.append(...)` in 06_calculator.em. Each now records an SK_METHOD card.
URI4 = "file:///tmp/ember_lsp_intrinsic.em"
INTR = ("fn go() -> int {\n"
        "    var xs: [int] = []\n"
        "    xs.append(7)\n"
        '    let parts = "a,b".split(",")\n'
        "    return xs.len() + parts.len()\n"
        "}\n")
ilines = INTR.split("\n")
def iloc(line_sub, name):
    row = next(i for i, l in enumerate(ilines) if line_sub in l)
    return {"line": row, "character": ilines[row].index(line_sub) + line_sub.index(name)}
pos_append = iloc("xs.append(7)", "append")   # array .append → mutating, value param
pos_alen   = iloc("xs.len()", "len")          # array .len → int
pos_split  = iloc('"a,b".split(",")', "split")  # string .split → [string], sep param

# A fifth document exercising CHANNEL builtin hover (channel/send/recv/close). These are
# special-cased in the checker by name and were missing from vocab.def, so hovering them in
# examples/05_concurrency.em returned nothing — the bug Karl hit on `send`/`close`. Each now
# has an EMBER_BUILTIN doc card.
URI5 = "file:///tmp/ember_lsp_channel.em"
CHAN = ("fn main() {\n"
        "    let c: Channel<int> = channel(8)\n"
        "    send(c, 1)\n"
        "    match recv(c) {\n"
        "        case Some(v) { println(v) }\n"
        "        case None    {}\n"
        "    }\n"
        "    close(c)\n"
        "}\n")
clines = CHAN.split("\n")
def cloc(line_sub, name):
    row = next(i for i, l in enumerate(clines) if line_sub in l)
    return {"line": row, "character": clines[row].index(line_sub) + line_sub.index(name)}
pos_channel = cloc("= channel(8)", "channel")
pos_send    = cloc("send(c, 1)", "send")
pos_recv    = cloc("recv(c)", "recv")
pos_close   = cloc("close(c)", "close")

def locate(sub):
    for li, l in enumerate(glines):
        c = l.find(sub)
        if c >= 0:
            return {"line": li, "character": c}
    raise SystemExit("fixture missing substring: " + sub)

# locate the 'add' call inside main for hover/definition, a builtin call, and a keyword.
pos         = locate("add(1")
pos_builtin = locate("println")
pos_keyword = locate("return a")  # the `return` inside add
# the parameter `a` used in `return a + b` — for semantic-index hover/definition (Phase 2).
arow = next(i for i, l in enumerate(glines) if "return a + b" in l)
pos_param = {"line": arow, "character": glines[arow].index("a + b")}
# the cursor just after the dot in `return p.x` — for `.`-member completion (Phase 2b).
mrow = next(i for i, l in enumerate(glines) if "return p.x" in l)
pos_member = {"line": mrow, "character": glines[mrow].index("p.") + 2}
# the field name `x` in `p.x` — for field hover off the EXPR_GET name position (Phase 2c groundwork).
pos_field = {"line": mrow, "character": glines[mrow].index("p.x") + 2}
# the type name `Point` in `fn px(p: Point)` — for type-reference hover (A2).
trow = next(i for i, l in enumerate(glines) if "p: Point" in l)
pos_type = {"line": trow, "character": glines[trow].index("Point") + 1}

session = [
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}},
    {"jsonrpc":"2.0","method":"initialized","params":{}},
    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
        "uri":URI,"languageId":"ember","version":1,"text":BAD}}},
    {"jsonrpc":"2.0","method":"textDocument/didChange","params":{
        "textDocument":{"uri":URI,"version":2},"contentChanges":[{"text":GOOD}]}},
    {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI},"position":pos}},
    {"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{
        "textDocument":{"uri":URI},"position":pos}},
    {"jsonrpc":"2.0","id":4,"method":"textDocument/documentSymbol","params":{
        "textDocument":{"uri":URI}}},
    {"jsonrpc":"2.0","id":5,"method":"textDocument/completion","params":{
        "textDocument":{"uri":URI},"position":pos}},
    {"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI},"position":pos_builtin}},
    {"jsonrpc":"2.0","id":8,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI},"position":pos_keyword}},
    {"jsonrpc":"2.0","id":9,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI},"position":pos_param}},
    {"jsonrpc":"2.0","id":10,"method":"textDocument/definition","params":{
        "textDocument":{"uri":URI},"position":pos_param}},
    {"jsonrpc":"2.0","id":11,"method":"textDocument/completion","params":{
        "textDocument":{"uri":URI},"position":pos_member,
        "context":{"triggerKind":2,"triggerCharacter":"."}}},
    {"jsonrpc":"2.0","id":12,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI},"position":pos_field}},
    {"jsonrpc":"2.0","id":13,"method":"textDocument/definition","params":{
        "textDocument":{"uri":URI},"position":pos_field}},
    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
        "uri":URI2,"languageId":"ember","version":1,"text":NEST}}},
    {"jsonrpc":"2.0","id":14,"method":"textDocument/completion","params":{
        "textDocument":{"uri":URI2},"position":pos_self,
        "context":{"triggerKind":2,"triggerCharacter":"."}}},
    {"jsonrpc":"2.0","id":15,"method":"textDocument/completion","params":{
        "textDocument":{"uri":URI2},"position":pos_chain,
        "context":{"triggerKind":2,"triggerCharacter":"."}}},
    {"jsonrpc":"2.0","id":16,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI2},"position":pos_method}},
    {"jsonrpc":"2.0","id":17,"method":"textDocument/definition","params":{
        "textDocument":{"uri":URI2},"position":pos_method}},
    {"jsonrpc":"2.0","id":18,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI},"position":pos_type}},
    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
        "uri":URI3,"languageId":"ember","version":1,"text":XMOD}}},
    {"jsonrpc":"2.0","id":19,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI3},"position":pos_xmod}},
    {"jsonrpc":"2.0","id":20,"method":"textDocument/definition","params":{
        "textDocument":{"uri":URI3},"position":pos_xmod}},
    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
        "uri":URI4,"languageId":"ember","version":1,"text":INTR}}},
    {"jsonrpc":"2.0","id":21,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI4},"position":pos_append}},
    {"jsonrpc":"2.0","id":22,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI4},"position":pos_alen}},
    {"jsonrpc":"2.0","id":23,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI4},"position":pos_split}},
    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
        "uri":URI5,"languageId":"ember","version":1,"text":CHAN}}},
    {"jsonrpc":"2.0","id":24,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI5},"position":pos_channel}},
    {"jsonrpc":"2.0","id":25,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI5},"position":pos_send}},
    {"jsonrpc":"2.0","id":26,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI5},"position":pos_recv}},
    {"jsonrpc":"2.0","id":27,"method":"textDocument/hover","params":{
        "textDocument":{"uri":URI5},"position":pos_close}},
    {"jsonrpc":"2.0","id":28,"method":"textDocument/semanticTokens/full","params":{
        "textDocument":{"uri":URI}}},
    {"jsonrpc":"2.0","id":6,"method":"shutdown"},
    {"jsonrpc":"2.0","method":"exit"},
]
data = b"".join(frame(m) for m in session)
out = subprocess.run([os.environ["BIN"], "--lsp"], input=data,
                     capture_output=True, env=os.environ).stdout

msgs = []
i = 0
while i < len(out):
    j = out.find(b"\r\n\r\n", i)
    if j < 0:
        break
    hdr = out[i:j].decode()
    length = int(next(h for h in hdr.split("\r\n") if h.lower().startswith("content-length:")).split(":")[1])
    msgs.append(json.loads(out[j+4:j+4+length]))
    i = j + 4 + length

byid    = {m["id"]: m for m in msgs if "id" in m}
notes   = [m for m in msgs if m.get("method") == "textDocument/publishDiagnostics"]

def fail(why):
    print("FAIL:", why)
    for m in msgs:
        print(" ", json.dumps(m))
    sys.exit(1)

# initialize advertises the slice 1-4 capabilities.
caps = byid.get(1, {}).get("result", {}).get("capabilities", {})
for need in ("hoverProvider", "definitionProvider", "documentSymbolProvider", "completionProvider"):
    if need not in caps:
        fail("initialize missing capability: " + need)

# positionEncoding negotiation (LSP 3.17): this session offered no general.positionEncodings, so the
# server must fall back to the utf-16 default and SAY so. (The dedicated non-ASCII regression below
# exercises the utf-8 path and the byte<->utf-16 column mapping.)
if caps.get("positionEncoding") != "utf-16":
    fail("a client offering no positionEncodings must negotiate the utf-16 default, got: "
         + str(caps.get("positionEncoding")))

# diagnostics: the bad open reports one error, the fixed change clears them.
if len(notes) < 2 or len(notes[0]["params"]["diagnostics"]) != 1:
    fail("didOpen should report exactly one diagnostic")
if notes[-1]["params"]["diagnostics"] != []:
    fail("didChange (fixed) should clear diagnostics")

# hover over the `add(1, 2)` CALL: the rich card shows the (function) kind, the signature,
# the `///` doc, AND the declared-at line (A2 — free-function references are now indexed).
hv = byid.get(2, {}).get("result")
hvv = hv["contents"]["value"] if hv else ""
if not hv or "fn add(a: int, b: int) -> int" not in hvv:
    fail("hover did not return add's signature")
if "Add two integers and return the sum." not in hvv:
    fail("hover did not include add's /// doc comment")
if "(function)" not in hvv or "declared at line" not in hvv:
    fail("function-call hover is missing the (function) kind / declared-line extras: " + hvv)

# hover over a built-in shows its native signature.
hb = byid.get(7, {}).get("result")
if not hb or "fn println(value:" not in hb["contents"]["value"]:
    fail("hover did not document the println built-in")

# hover over a keyword shows its gloss.
hk = byid.get(8, {}).get("result")
if not hk or "`return`" not in hk["contents"]["value"]:
    fail("hover did not document the return keyword")

# definition resolves to a location with a range.
df = byid.get(3, {}).get("result")
if not df or "range" not in df or df["range"]["start"]["line"] != 6:
    fail("definition did not point at the add declaration (line 6)")

# documentSymbol lists the top-level declarations (+ nested struct fields).
syms = byid.get(4, {}).get("result") or []
names = {s["name"] for s in syms}
if not {"Point", "add", "main"}.issubset(names):
    fail("documentSymbol missing top-level declarations: " + str(names))
point = next(s for s in syms if s["name"] == "Point")
if {c["name"] for c in point.get("children", [])} < {"x", "y"}:
    fail("Point symbol missing field children")

# completion offers the symbols and keywords.
labels = {it["label"] for it in (byid.get(5, {}).get("result", {}).get("items", []))}
if not {"add", "Point", "fn", "return"}.issubset(labels):
    fail("completion missing expected items")

# semantic index (Phase 2): hovering a parameter shows its checker-inferred type + role,
# plus the rich-hover campaign's "declared at line N" provenance (Karl's explicit ask).
hp = byid.get(9, {}).get("result")
hpv = hp["contents"]["value"] if hp else ""
if not hp or "a: int" not in hpv or "parameter" not in hpv:
    fail("hover over a parameter did not report its inferred type from the semantic index")
if "declared at line" not in hpv:
    fail("parameter hover is missing the 'declared at line N' provenance")

# go-to-definition on that parameter resolves (scope-aware) to a location in the same file.
dp = byid.get(10, {}).get("result")
if not dp or "range" not in dp or dp.get("uri") != URI:
    fail("definition on a parameter did not resolve via the semantic index")

# `.`-member completion (Phase 2b): `p.` (p: Point) offers Point's fields/methods, NOT globals.
mitems = byid.get(11, {}).get("result", {}).get("items", [])
mlabels = {it["label"] for it in mitems}
if not {"x", "y"}.issubset(mlabels):
    fail("member completion on a Point receiver did not offer its fields: " + str(mlabels))
if "add" in mlabels or "fn" in mlabels:
    fail("member completion leaked global symbols/keywords (the `.`-trigger inconsistency)")
if not all(it["kind"] in (2, 5) for it in mitems):   # Method / Field only
    fail("member completion offered non-member kinds")

# field hover (Phase 2c groundwork + rich-hover campaign): hovering `.x` resolves the field's type
# off its own position, and the card now carries its owning struct, byte layout, and declared line.
hf = byid.get(12, {}).get("result")
hfv = hf["contents"]["value"] if hf else ""
if not hf or "x: int" not in hfv or "field" not in hfv:
    fail("hover over a struct field did not report its type from the semantic index")
if "in Point" not in hfv or "offset 0" not in hfv or "declared at line" not in hfv:
    fail("field hover is missing the container / byte-layout / declared-line extras: " + hfv)

# field go-to-definition (Phase 2c): `.x` jumps to the field's declaration in `struct Point` (line 1).
fd = byid.get(13, {}).get("result")
if not fd or "range" not in fd or fd["range"]["start"]["line"] != 1:
    fail("go-to-definition on a struct field did not jump to its declaration (line 1)")

# `self.` member completion (Phase 2c): offers the enclosing struct's fields/methods.
slabels = {it["label"] for it in byid.get(14, {}).get("result", {}).get("items", [])}
if not {"inner", "get"}.issubset(slabels):
    fail("`self.` completion did not offer the struct's members: " + str(slabels))

# chained `o.inner.` completion (Phase 2c): resolves the field's type, offers ITS members.
clabels = {it["label"] for it in byid.get(15, {}).get("result", {}).get("items", [])}
if "v" not in clabels:
    fail("chained `o.inner.` completion did not offer the nested field: " + str(clabels))

# method hover (Phase 2d): hovering a method call shows the method's signature.
hm = byid.get(16, {}).get("result")
if not hm or "fn get(self) -> int" not in hm["contents"]["value"]:
    fail("hover over a method call did not show its signature")

# method go-to-definition (Phase 2d): jumps to the method's declaration (line 6 of NEST).
md = byid.get(17, {}).get("result")
if not md or "range" not in md or md.get("uri") != URI2 or md["range"]["start"]["line"] != 6:
    fail("go-to-definition on a method did not jump to its declaration (line 6)")

# type-reference hover (A2): hovering `Point` in `p: Point` shows the (type) kind + declared line.
ht = byid.get(18, {}).get("result")
htv = ht["contents"]["value"] if ht else ""
if not ht or "(type)" not in htv or "struct Point" not in htv or "declared at line" not in htv:
    fail("hover over a type reference did not show the (type) card with its declaration: " + htv)

# CROSS-MODULE hover (A3): hovering `str.contains(...)` shows the function's signature, its owning
# MODULE, and the imported FILE it is declared in — the headline of the rich-hover campaign (this
# returned nothing at all before).
hx = byid.get(19, {}).get("result")
hxv = hx["contents"]["value"] if hx else ""
if not hx or "fn contains(s: string, sub: string) -> bool" not in hxv:
    fail("cross-module hover did not show the imported function's signature: " + hxv)
if "(function)" not in hxv or "module str" not in hxv or "declared in string.em" not in hxv:
    fail("cross-module hover is missing the module / cross-file declaration: " + hxv)

# CROSS-FILE go-to-definition (A4): `str.contains` jumps INTO std/string.em (a different file).
dx = byid.get(20, {}).get("result")
if not dx or "range" not in dx or not dx.get("uri", "").endswith("string.em"):
    fail("cross-file go-to-definition did not resolve into std/string.em: " + str(dx))

# BUILT-IN method hover (OFI-038): hovering an array/string intrinsic now shows an SK_METHOD card
# with a signature rendered from the receiver/param/return types — previously these returned null.
ha = byid.get(21, {}).get("result")
hav = ha["contents"]["value"] if ha else ""
if not ha or "fn append(value: int)" not in hav or "(method)" not in hav:
    fail("hover over array .append did not show its intrinsic signature: " + hav)
if "in [int]" not in hav:
    fail("array .append hover is missing the receiver-type container: " + hav)
hl = byid.get(22, {}).get("result")
if not hl or "fn len() -> int" not in hl["contents"]["value"]:
    fail("hover over array .len did not show its intrinsic signature")
hs = byid.get(23, {}).get("result")
hsv = hs["contents"]["value"] if hs else ""
if not hs or "fn split(sep: string) -> [string]" not in hsv or "in string" not in hsv:
    fail("hover over string .split did not show its intrinsic signature: " + hsv)

# CHANNEL builtin hover: channel/send/recv/close each show their generic native signature.
hc = byid.get(24, {}).get("result")
if not hc or "fn channel<T>(capacity: int) -> Channel<T>" not in hc["contents"]["value"]:
    fail("hover over the channel builtin did not show its signature")
hsd = byid.get(25, {}).get("result")
if not hsd or "fn send<T>(ch: Channel<T>, value: T)" not in hsd["contents"]["value"]:
    fail("hover over the send builtin did not show its signature")
hrc = byid.get(26, {}).get("result")
if not hrc or "fn recv<T>(ch: Channel<T>) -> Option<T>" not in hrc["contents"]["value"]:
    fail("hover over the recv builtin did not show its signature")
hcl = byid.get(27, {}).get("result")
if not hcl or "fn close<T>(ch: Channel<T>)" not in hcl["contents"]["value"]:
    fail("hover over the close builtin did not show its signature")

# SEMANTIC TOKENS: the checker re-colours resolved identifiers by what they DENOTE (type vs
# parameter vs property vs function) — the layer the editor grammar can't classify. Advertised with
# a legend; the response is a delta-encoded [dLine,dStart,len,type,mods]*. Decode and spot-check.
ST_TYPES = ["namespace", "type", "parameter", "variable", "property", "enumMember", "function", "method"]
if "semanticTokensProvider" not in caps:
    fail("initialize did not advertise semanticTokensProvider")
stdata = byid.get(28, {}).get("result", {}).get("data")
if not stdata or len(stdata) % 5 != 0:
    fail("semanticTokens/full returned no well-formed data: " + str(stdata))
_sl = _sc = 0
sttoks = set()
for _k in range(0, len(stdata), 5):
    _dl, _ds, _len, _ty, _mod = stdata[_k:_k+5]
    _sl += _dl
    _sc = (_sc + _ds) if _dl == 0 else _ds
    sttoks.add((glines[_sl][_sc:_sc+_len], ST_TYPES[_ty]))
for need in (("Point", "type"), ("a", "parameter"), ("x", "property"), ("add", "function")):
    if need not in sttoks:
        fail("semantic tokens missing %r; got %s" % (need, sorted(sttoks)))
print("lsp: passed — semantic tokens (checker-resolved type/parameter/property/function over the index)")

print("lsp: passed — diagnostics, hover (+locals, +fields, +methods, +functions, +types, +variants, "
      "+constants, +CROSS-MODULE, +BUILT-IN intrinsics, rich cards w/ kind+scope+declared-line+value+layout), definition "
      "(+scope-aware, +fields, +methods, +CROSS-FILE), documentSymbol, completion (+`.`-members, "
      "+`self.`, +chained)")


# ---- positionEncoding negotiation + non-ASCII column mapping (LSP 3.17) -------------------------
# The compiler tracks columns in BYTES, but LSP's default "character" unit is UTF-16. The server
# negotiates: it speaks utf-8 (our native byte offsets) when the client offers it, otherwise it
# falls back to utf-16 and TRANSLATES columns at the wire. A non-ASCII byte before a token is exactly
# where byte != utf-16, so this is the regression that proves the conversion (and guards Zed, whose
# clients commonly negotiate utf-8, alongside any utf-16-only client). 'héllo ' — é (U+00E9) is 2
# UTF-8 bytes but 1 UTF-16 unit; `nme` after it is undefined, giving a diagnostic whose start column
# differs by 1 between the two encodings.
NAURI = "file:///tmp/ember_lsp_nonascii.em"
NASRC = ('fn greet(name: string) -> string {\n'
         '    return "héllo " + nme\n'
         '}\n')
naline    = NASRC.split("\n")[1]
exp_utf8  = len(naline[:naline.index("nme")].encode())   # BYTE column of `nme`
exp_utf16 = naline.index("nme")                          # UTF-16 column (BMP: == code points)
if exp_utf8 == exp_utf16:
    fail("non-ASCII fixture is not exercising the conversion (byte == utf16) — fix the fixture")

def encoding_run(offered):
    caps_in = {"general": {"positionEncodings": offered}} if offered else {}
    sess = [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":caps_in}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
            "uri":NAURI,"languageId":"ember","version":1,"text":NASRC}}},
        {"jsonrpc":"2.0","id":9,"method":"shutdown"},
        {"jsonrpc":"2.0","method":"exit"},
    ]
    rout = subprocess.run([os.environ["BIN"], "--lsp"],
                          input=b"".join(frame(m) for m in sess),
                          capture_output=True, env=os.environ).stdout
    rmsgs = []; k = 0
    while k < len(rout):
        jj = rout.find(b"\r\n\r\n", k)
        if jj < 0:
            break
        h  = rout[k:jj].decode()
        ln = int(next(x for x in h.split("\r\n") if x.lower().startswith("content-length:")).split(":")[1])
        rmsgs.append(json.loads(rout[jj+4:jj+4+ln])); k = jj+4+ln
    enc = next((m for m in rmsgs if m.get("id") == 1), {}) \
            .get("result", {}).get("capabilities", {}).get("positionEncoding")
    starts = [d["range"]["start"]["character"]
              for m in rmsgs if m.get("method") == "textDocument/publishDiagnostics"
              for d in m["params"]["diagnostics"] if d["message"] == "undefined variable"]
    return enc, (starts[0] if starts else None)

enc8, col8 = encoding_run(["utf-8", "utf-16"])
if enc8 != "utf-8":
    fail("a utf-8-capable client must negotiate utf-8, got: " + str(enc8))
if col8 != exp_utf8:
    fail("under utf-8 the `nme` diagnostic must be at the BYTE column %d, got %s" % (exp_utf8, col8))

enc16, col16 = encoding_run(["utf-16"])
if enc16 != "utf-16":
    fail("a utf-16-only client must negotiate utf-16, got: " + str(enc16))
if col16 != exp_utf16:
    fail("under utf-16 the `nme` diagnostic must be at the UTF-16 column %d, got %s" % (exp_utf16, col16))

print("lsp: passed — positionEncoding negotiation (utf-8 preferred, utf-16 fallback) + non-ASCII "
      "byte<->UTF-16 column mapping (`nme` at byte %d / utf16 %d)" % (exp_utf8, exp_utf16))

# ---- project-wide find-references + rename (the semantic index, inverted) -----------------------
# References/rename need real files on disk (the server walks the workspace root), so build a tiny
# two-file project in a temp dir: lib.em defines `greet`, main.em imports it and calls it twice. A
# symbol's identity is (def_file, def_line, spelling) — def_col is too coarse — so guard that
# (a) cross-file references find the declaration + every call, (b) rename edits span BOTH files, and
# (c) two same-named locals in different scopes are NOT conflated.
import tempfile, shutil
rp = tempfile.mkdtemp(prefix="ember_lsp_refs_")
open(os.path.join(rp, "lib.em"), "w").write(
    "fn greet(name: string) -> string {\n    return name\n}\n")
open(os.path.join(rp, "main.em"), "w").write(
    'import "lib" as lib\n\nfn main() -> int {\n    println(lib.greet("a"))\n'
    '    println(lib.greet("b"))\n    return 0\n}\n')
open(os.path.join(rp, "calc.em"), "w").write(
    "fn a() -> int {\n    let total = 1\n    return total + total\n}\n\n"
    "fn b() -> int {\n    let total = 2\n    return total\n}\n")

def lsp_session(messages):
    out = subprocess.run([os.environ["BIN"], "--lsp"],
                         input=b"".join(frame(m) for m in messages),
                         capture_output=True, env=os.environ).stdout
    res = []; p = 0
    while p < len(out):
        q = out.find(b"\r\n\r\n", p)
        if q < 0:
            break
        hh = out[p:q].decode()
        L = int(next(x for x in hh.split("\r\n") if x.lower().startswith("content-length:")).split(":")[1])
        res.append(json.loads(out[q+4:q+4+L])); p = q + 4 + L
    return {m["id"]: m for m in res if "id" in m}

def colof(path_file, line_sub, sub):
    ls = open(os.path.join(rp, path_file)).read().split("\n")
    row = next(i for i, l in enumerate(ls) if line_sub in l)
    return row, ls[row].index(line_sub) + line_sub.index(sub)

MAINU = "file://" + os.path.join(rp, "main.em")
GROW, GCOL = colof("main.em", "lib.greet", "greet")    # cursor on `greet` in the first call

def proj_msgs(extra):
    return ([
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
            "capabilities":{"general":{"positionEncodings":["utf-8"]}},
            "workspaceFolders":[{"uri":"file://"+rp,"name":"refs"}]}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
            "uri":MAINU,"languageId":"ember","version":1,
            "text":open(os.path.join(rp,"main.em")).read()}}},
    ] + extra + [{"jsonrpc":"2.0","id":9,"method":"shutdown"}, {"jsonrpc":"2.0","method":"exit"}])

proj_caps = lsp_session(proj_msgs([])).get(1, {}).get("result", {}).get("capabilities", {})
for need in ("referencesProvider", "renameProvider"):
    if need not in proj_caps:
        fail("initialize did not advertise " + need)

# (a) cross-file references: the `greet` declaration (lib.em) + both calls (main.em).
refs = lsp_session(proj_msgs([
    {"jsonrpc":"2.0","id":2,"method":"textDocument/references","params":{
        "textDocument":{"uri":MAINU}, "position":{"line":GROW,"character":GCOL}}}])).get(2, {}).get("result", [])
rfiles = sorted({r["uri"].split("/")[-1] for r in refs})
if len(refs) != 3 or rfiles != ["lib.em", "main.em"]:
    fail("cross-file references for `greet` wrong: %d refs in %s" % (len(refs), rfiles))

# (b) rename spans BOTH files: 2 edits in main.em, 1 in lib.em, all -> the new name.
ren = lsp_session(proj_msgs([
    {"jsonrpc":"2.0","id":3,"method":"textDocument/rename","params":{
        "textDocument":{"uri":MAINU}, "position":{"line":GROW,"character":GCOL},
        "newName":"hello"}}])).get(3, {}).get("result", {}).get("changes", {})
if len(ren) != 2 or sorted(len(v) for v in ren.values()) != [1, 2]:
    fail("cross-file rename did not span both files: %s" % {k.split('/')[-1]: len(v) for k, v in ren.items()})
if not all(e["newText"] == "hello" for v in ren.values() for e in v):
    fail("rename produced the wrong newText")

# (c) scope safety: renaming `total` in a() touches a()'s 3 sites only — never b()'s same-named local.
CALCU = "file://" + os.path.join(rp, "calc.em")
trow, tcol = colof("calc.em", "let total", "total")
calc = lsp_session([
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "capabilities":{"general":{"positionEncodings":["utf-8"]}}, "workspaceFolders":[{"uri":"file://"+rp}]}},
    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
        "uri":CALCU,"languageId":"ember","version":1,"text":open(os.path.join(rp,"calc.em")).read()}}},
    {"jsonrpc":"2.0","id":4,"method":"textDocument/rename","params":{
        "textDocument":{"uri":CALCU}, "position":{"line":trow,"character":tcol}, "newName":"sum"}},
    {"jsonrpc":"2.0","id":9,"method":"shutdown"}, {"jsonrpc":"2.0","method":"exit"}]).get(4, {}).get("result", {}).get("changes", {})
cedits = [e for v in calc.values() for e in v]
if len(cedits) != 3:                          # a()'s `let total` + its two uses; b()'s total untouched
    fail("scoped local rename touched %d sites (expected 3 — it must not reach b())" % len(cedits))
if any(e["range"]["start"]["line"] >= 5 for e in cedits):   # b() begins at line 5 (0-based)
    fail("scoped rename leaked into b()'s `total`")

shutil.rmtree(rp, ignore_errors=True)
print("lsp: passed — project-wide find-references + rename (cross-file, scope-safe; identity = "
      "def-file + def-line + spelling)")


# ---- inlay hints: inferred-type annotations on unannotated `let`/`var` ---------------------------
# An unannotated binding is the token pattern `let`/`var` · IDENT · `=`; the hint shows the type the
# checker inferred (from the binding's uses), placed right after the name. Annotated bindings get
# nothing (the type is already on screen).
IHURI = "file:///tmp/ember_lsp_inlay.em"
IHSRC = ("fn main() -> int {\n"
         "    let sum = 1 + 2\n"
         '    let label = "hi"\n'
         "    let typed: int = 5\n"
         "    var xs = [1, 2, 3]\n"
         "    println(label)\n"
         "    return sum + typed + xs.len()\n"
         "}\n")
ihl = IHSRC.split("\n")
ih = lsp_session([
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8"]}}}},
    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
        "uri":IHURI,"languageId":"ember","version":1,"text":IHSRC}}},
    {"jsonrpc":"2.0","id":5,"method":"textDocument/inlayHint","params":{
        "textDocument":{"uri":IHURI},"range":{"start":{"line":0,"character":0},"end":{"line":99,"character":0}}}},
    {"jsonrpc":"2.0","id":9,"method":"shutdown"}, {"jsonrpc":"2.0","method":"exit"}])
if "inlayHintProvider" not in ih.get(1, {}).get("result", {}).get("capabilities", {}):
    fail("initialize did not advertise inlayHintProvider")
hints = ih.get(5, {}).get("result", [])
if {h["label"] for h in hints} != {": int", ": string", ": [int]"}:
    fail("inlay hints wrong: %s" % sorted(h["label"] for h in hints))
if any("typed" in ihl[h["position"]["line"]] for h in hints):
    fail("inlay hint wrongly emitted on the annotated binding `typed`")
for h in hints:                                  # each hint sits right after a binding name
    before = ihl[h["position"]["line"]][:h["position"]["character"]]
    if not before.rstrip().split()[-1].isidentifier():
        fail("inlay hint not placed after a binding name: %r" % before)
print("lsp: passed — inlay hints (inferred-type on unannotated let/var; annotated skipped; placed after the name)")


# ---- signature help: the parameter popup while typing a call ------------------------------------
# Inside foo(a, |b) the active parameter is the count of top-level commas before the cursor. A free
# function renders per-parameter labels (so the client can highlight); builtins show the signature.
SHURI = "file:///tmp/ember_lsp_sig.em"
SHSRC = ("fn add(a: int, b: int) -> int {\n    return a + b\n}\n\n"
         "fn main() -> int {\n    let r = add(1, 2)\n    println(42)\n    return r\n}\n")
shl = SHSRC.split("\n")
arow = next(i for i, l in enumerate(shl) if "add(1, 2)" in l)
a0 = shl[arow].index("add(") + len("add(")           # cursor just after `add(`  -> param 0
a1 = shl[arow].index("add(1, ") + len("add(1, ")     # cursor after the comma    -> param 1
prow = next(i for i, l in enumerate(shl) if "println(" in l)
pcol = shl[prow].index("println(") + len("println(")

def sighelp(row, col):
    r = lsp_session([
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8"]}}}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
            "uri":SHURI,"languageId":"ember","version":1,"text":SHSRC}}},
        {"jsonrpc":"2.0","id":2,"method":"textDocument/signatureHelp","params":{
            "textDocument":{"uri":SHURI},"position":{"line":row,"character":col}}},
        {"jsonrpc":"2.0","id":9,"method":"shutdown"}, {"jsonrpc":"2.0","method":"exit"}])
    return r.get(1, {}).get("result", {}).get("capabilities", {}), r.get(2, {}).get("result")

caps_sh, s0 = sighelp(arow, a0)
if "signatureHelpProvider" not in caps_sh:
    fail("initialize did not advertise signatureHelpProvider")
if not s0 or s0["signatures"][0]["label"] != "fn add(a: int, b: int) -> int":
    fail("signature help label wrong: %s" % (s0,))
if [p["label"] for p in s0["signatures"][0]["parameters"]] != ["a: int", "b: int"]:
    fail("signature help parameters wrong: %s" % s0["signatures"][0]["parameters"])
if s0["activeParameter"] != 0:
    fail("active parameter should be 0 just after `add(`, got %d" % s0["activeParameter"])
_, s1 = sighelp(arow, a1)
if not s1 or s1["activeParameter"] != 1:
    fail("active parameter should be 1 after the comma, got %s" % (s1 and s1.get("activeParameter")))
_, sb = sighelp(prow, pcol)
if not sb or "fn println(value:" not in sb["signatures"][0]["label"]:
    fail("signature help did not document the println builtin: %s" % (sb,))
print("lsp: passed — signature help (free-fn params + active-parameter tracking; builtins)")


# ---- graphics signatures known in the default build + imported-error isolation ------------------
# The graphics primitives' SIGNATURES compile into every build (only the raylib IMPLEMENTATION is
# opt-in), so the LSP type-checks graphics programs from the dependency-free build instead of
# flagging every draw call as undefined. Diagnostics are attributed to the module they occur in, so
# an error inside an imported module never leaks onto the importer.
def diags(uri, src, root=None):
    init = {"capabilities": {}}
    if root:
        init["workspaceFolders"] = [{"uri": "file://" + root}]
    out = subprocess.run([os.environ["BIN"], "--lsp"], capture_output=True, env=os.environ,
        input=b"".join(frame(m) for m in [
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":init},
            {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
                "uri":uri,"languageId":"ember","version":1,"text":src}}},
            {"jsonrpc":"2.0","id":9,"method":"shutdown"}, {"jsonrpc":"2.0","method":"exit"}])).stdout
    p = 0
    while p < len(out):
        q = out.find(b"\r\n\r\n", p)
        if q < 0:
            break
        hh = out[p:q].decode()
        L = int(next(x for x in hh.split("\r\n") if x.lower().startswith("content-length:")).split(":")[1])
        m = json.loads(out[q+4:q+4+L]); p = q + 4 + L
        if m.get("method") == "textDocument/publishDiagnostics":
            return m["params"]["diagnostics"]
    return []

GFXURI = "file:///tmp/ember_lsp_gfx.em"
# (1) a program calling graphics primitives directly type-checks cleanly in the default build
gok = ('fn main() -> int {\n    window_open(200, 150, "x")\n'
       '    draw_rect(0, 0, 10, 10, 255)\n    window_close()\n    return 0\n}\n')
if diags(GFXURI, gok):
    fail("graphics primitives should type-check in the default build, got: %s" % diags(GFXURI, gok))
# (2) the SIGNATURE is still enforced — a wrong-arity graphics call is an error (not swallowed)
if not any("graphics primitive" in d["message"]
           for d in diags(GFXURI, "fn main() -> int {\n    draw_rect(0, 0, 10)\n    return 0\n}\n")):
    fail("a wrong-arity graphics call must still error")
# (3) a genuinely undefined function is still flagged
if not any("undefined function" in d["message"]
           for d in diags(GFXURI, "fn main() -> int {\n    return nope(1)\n}\n")):
    fail("a genuinely undefined function must still error")
# (4) an error INSIDE an imported module does not leak onto the importer (attribution by file)
lp = tempfile.mkdtemp(prefix="ember_lsp_leak_")
open(os.path.join(lp, "badlib.em"), "w").write('fn boom() -> int {\n    return "not an int"\n}\n')
imp_src = 'import "badlib" as b\n\nfn main() -> int {\n    return b.boom()\n}\n'
open(os.path.join(lp, "app.em"), "w").write(imp_src)
leaked = diags("file://" + os.path.join(lp, "app.em"), imp_src, root=lp)
if leaked:                                # app.em's own code is correct; badlib's error must not leak in
    fail("an imported module's error leaked onto the importer: %s" % leaked)
shutil.rmtree(lp, ignore_errors=True)
print("lsp: passed — graphics signatures type-check in the default build (still enforced, not swallowed); "
      "imported-module errors stay in their own file")


# ---- contract verification in the editor: prover-verdict inlays + contract code actions ----------
# The prover statically discharges `ensures` clauses in the linear-integer fragment; the LSP marks
# each with a proved / runtime-checked inlay (the verification-loop differentiator, shown inline) and
# offers code actions that scaffold a `requires`/`ensures` clause before the body brace.
PVURI = "file:///tmp/ember_lsp_prove.em"
PVSRC = ("fn add_nonneg(a: int, b: int) -> int\n    requires a >= 0\n    requires b >= 0\n"
         "    ensures result >= 0\n{\n    return a + b\n}\n\n"
         "fn shift(x: int, k: int) -> int\n    ensures result >= x\n{\n    return x + k\n}\n")
pvl = PVSRC.split("\n")
pv = lsp_session([
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8"]}}}},
    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
        "uri":PVURI,"languageId":"ember","version":1,"text":PVSRC}}},
    {"jsonrpc":"2.0","id":2,"method":"textDocument/inlayHint","params":{
        "textDocument":{"uri":PVURI},"range":{"start":{"line":0,"character":0},"end":{"line":99,"character":0}}}},
    {"jsonrpc":"2.0","id":3,"method":"textDocument/codeAction","params":{
        "textDocument":{"uri":PVURI},"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":3}},
        "context":{"diagnostics":[]}}},
    {"jsonrpc":"2.0","id":9,"method":"shutdown"}, {"jsonrpc":"2.0","method":"exit"}])
if "codeActionProvider" not in pv.get(1, {}).get("result", {}).get("capabilities", {}):
    fail("initialize did not advertise codeActionProvider")
# Prover verdicts: the provable `ensures result >= 0` is marked proved; `result >= x` is not.
verdicts = {pvl[h["position"]["line"]].strip(): h["label"]
            for h in pv.get(2, {}).get("result", [])
            if "proved" in h["label"] or "runtime" in h["label"]}
if "proved" not in verdicts.get("ensures result >= 0", ""):
    fail("the prover should discharge `result >= 0` from `a>=0, b>=0`, got: %s" % verdicts)
if "runtime" not in verdicts.get("ensures result >= x", ""):
    fail("`result >= x` is not provable without `k>=0` — should be runtime-checked, got: %s" % verdicts)
# Code actions: both contract scaffolds offered, each a WorkspaceEdit that inserts the clause.
acts = pv.get(3, {}).get("result", [])
titles = " ".join(a["title"] for a in acts)
if "requires" not in titles or "ensures" not in titles:
    fail("contract code actions missing (expected add-requires + add-ensures): %s" % titles)
for a in acts:
    nt = a["edit"]["changes"][PVURI][0]["newText"]
    kw = "requires" if "requires" in a["title"] else "ensures"
    if kw not in nt:
        fail("the %s code action's edit does not insert a %s clause: %r" % (kw, kw, nt))
print("lsp: passed — contract verification (prover-verdict inlays: proved vs runtime-checked) + contract code actions")


# ---- semantic tokens stay out of comments + cover real identifiers (regression) ------------------
# A re-lexed string-interpolation hole carried line-1 positions, which painted semantic tokens onto
# the file's header comment (and cross-module index entries leaked too). Guard: every token lands on
# a real identifier, never inside a `//` comment — INCLUDING identifiers inside `{ }` interpolations.
STC_URI = "file:///tmp/ember_lsp_semtok_comments.em"
STC_SRC = ("// header comment mentioning send, channel, close — none of these may be coloured\n"
           "fn greet(who: string) -> string {\n"
           "    let label = who\n"
           '    return "hello {label} ({who.len()})"\n'
           "}\n")
stcl = STC_SRC.split("\n")
stc = lsp_session([
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8"]}}}},
    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
        "uri":STC_URI,"languageId":"ember","version":1,"text":STC_SRC}}},
    {"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":STC_URI}}},
    {"jsonrpc":"2.0","id":9,"method":"shutdown"}, {"jsonrpc":"2.0","method":"exit"}])
stdata = stc.get(2, {}).get("result", {}).get("data", [])
_l = _c = 0
_seen_interp = False
for _k in range(0, len(stdata), 5):
    _dl, _ds, _len, _ty, _mod = stdata[_k:_k+5]
    _l += _dl
    _c = (_c + _ds) if _dl == 0 else _ds
    _src = stcl[_l]
    _tok = _src[_c:_c+_len]
    _cpos = _src.find("//")
    if _cpos >= 0 and _c >= _cpos:
        fail("a semantic token landed inside a `//` comment: L%d:%d %r" % (_l, _c, _tok))
    if not (_tok and all(ch.isalnum() or ch == '_' for ch in _tok)):
        fail("a semantic token does not cover an identifier: L%d:%d %r" % (_l, _c, _tok))
    if _tok == "label" and _l == 3:      # interpolated identifier at its REAL line, not line 0/1
        _seen_interp = True
if not _seen_interp:
    fail("the interpolated identifier `label` was not tokenized at its real position (line 4)")
print("lsp: passed — semantic tokens stay out of comments + cover real identifiers (interpolation positions fixed)")


# ---- crash regression: the server is long-lived, so the front end is re-run once per request in
# ONE process. Two uninitialised-memory bugs only surfaced once the arena handed back recycled
# (dirty) memory: an unset Checker.global_count (collect_global wrote globals[garbage]) and an unset
# Type.qualifier on a bare struct-literal type (annotation_type strcmp'd a garbage pointer). They
# bite a real, multi-module program that imports std (many top-level `let` constants + `Name{…}`
# struct literals across modules); the cumulative arena churn matters, so we sweep hover/definition/
# completion over EVERY position of examples/graphics/09_ui.em. Pre-fix this SIGSEGV'd around request ~2365;
# now it must complete cleanly. ROOT is derived from EMBER_STD (which `make test-lsp` sets to ROOT/std).
import os.path
ex = os.path.join(os.path.dirname(os.environ["EMBER_STD"]), "examples", "graphics", "09_ui.em")
if not os.path.exists(ex):
    print("lsp: skip crash regression — %s not found" % ex)
else:
    etext  = open(ex).read()
    elines = etext.split("\n")
    EURI   = "file://" + os.path.abspath(ex)
    stress = [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}},
        {"jsonrpc":"2.0","method":"initialized","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
            "uri":EURI,"languageId":"ember","version":1,"text":etext}}},
    ]
    rid = 100
    for li, ln in enumerate(elines):
        for ci in range(0, len(ln) + 2):
            for meth in ("hover", "definition", "completion"):
                stress.append({"jsonrpc":"2.0","id":rid,"method":"textDocument/"+meth,
                               "params":{"textDocument":{"uri":EURI},
                                         "position":{"line":li,"character":ci}}})
                rid += 1
    stress += [{"jsonrpc":"2.0","id":rid,"method":"shutdown"}, {"jsonrpc":"2.0","method":"exit"}]
    sdata = b"".join(frame(m) for m in stress)
    sp = subprocess.run([os.environ["BIN"], "--lsp"], input=sdata,
                        capture_output=True, env=os.environ)
    if sp.returncode != 0:
        fail("server crashed under request churn (returncode %d) — uninitialised-memory "
             "regression in the front end (sweep of examples/graphics/09_ui.em)" % sp.returncode)
    print("lsp: passed — crash regression (%d requests over examples/graphics/09_ui.em, no crash)" % (rid - 100))
PY
