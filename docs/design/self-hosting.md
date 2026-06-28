# Self-hosting Ember — a staged bootstrap plan

> Status: **M0–M2 landed; M3 (checker) and M4 (bytecode backend) both in progress (2026-06-27).**
> Stage 0 is frozen (`stage0-v0.3.42`), the Stage A spikes are green, the **lexer** and **parser** are
> byte-identical to stage-0 over the whole corpus on both backends, the **checker** reaches stage-0's
> accept/reject verdict on 461/522 files with **zero false-rejects**, and the **bytecode backend** emits
> disassembly byte-identical to `--emit=bytecode` across 14 gated fixtures (scalars, control flow,
> strings, every struct representation, methods, arrays, moves, call-returns, non-identifier method
> receivers, empty arrays, interpolation lines) on both backends. The whole pipeline is gated by
> `make selfhost` (**1079 checks, 0 failures**) and folded into `make verify`. Self-hosting is earned
> one differential-green stage at a time, never by a big-bang rewrite, and only as far as it actually
> improves the language and toolchain.
>
> **Findings so far** (the dogfood paying off — every one filed as an OFI and most fixed):
> - The central "can the language hold a compiler?" risk is **retired** — recursive ASTs (`Box`+`[]`),
>   exhaustive `match`, `Map`/`Set` symbol tables, `Result`+`?` all run byte-identically VM==native; the
>   lexer, parser, and a growing checker/backend now hold up over the full corpus.
> - **OFI-157** — a VM-hosted recursive-descent parser must depth-guard well under `FRAMES_MAX = 256`
>   (the native backend has no such cap, so an unguarded deep recurse is a silent VM/native divergence).
>   `calc.em` guards at 100, ~2 VM frames per grammar level. **OPEN, documented constraint.**
> - **OFI-155 (HIGH) — CLOSED 2026-06-27.** Native miscompiled in-place mutation of a value-struct
>   *field* of a non-flat struct (`node.span.col = …`); fixed (runtime `em_set_field` inline branch +
>   cgen read-modify-writeback). Residual **OFI-158** (low, OPEN): a non-local boxed parent
>   (`o.mid.span.col`, `ns[i].span.col`) is a clean native error — rebuild immutably or use a local.
> - **OFI-156 (OPEN)** — an imported enum's **bare** variant can't be constructed cross-module
>   (`lx.TEof` → `undefined variable`); the multi-module front end routes bare tokens through a
>   constructor fn (`lx.eof()`).
> - **OFI-159 — CLOSED 2026-06-27.** `--emit=tokens` printed `INVALID` for 5 valid keywords
>   (`extern`/`type`/`where`/`requires`/`ensures`) — a missing `TOKEN_NAMES[]` entry; fixed so the
>   lexer differential measures against a correct oracle.
> - **OFI-161 (OPEN)** — native: a free function with a `mut` STRUCT parameter doesn't persist the
>   mutation (passes by value); `mut self` methods are unaffected, so the front end threads state through
>   methods-in-struct rather than free `mut Parser` functions.
> - **OFI-162 (OPEN)** — native: a *method* (`fn(self,…)`) that RETURNS a value-struct mis-compiles
>   (zeroed fields; a hard `em_s13` C error in some uses); a free function returning the same struct is
>   fine. Worked around in `selfhost/codegen.em` by returning an int classification code from the method.

Two things, kept separate throughout (per [CLAUDE.md](../../CLAUDE.md)):

- **stage 0** — the current reference compiler, written in C (`src/`). It is the bootstrap and,
  more importantly, the **differential oracle** every ported stage is measured against. It is
  kept and frozen, not thrown away.
- **the self-hosted compiler** — `emberc` written in Ember (`.em`), built incrementally on top of
  stage 0.

---

## 1. Why do this, and why now

A compiler is the most demanding ordinary program there is: heavy string work, large recursive
data structures, symbol tables, a thousand edge cases, and it must be both fast and correct.
Pointing Ember at that problem is the sharpest dogfood available — every missing feature, awkward
corner, or place the type system fights back shows up immediately, because we become our own most
demanding user. That is the whole reason, and it is the same instinct as the existing tape /
Crucible / dogfood-app discipline, scaled up to the largest program we could write.

Three concrete payoffs, stated plainly:

- **The manifesto claims get tested on a real, large program.** No `null`, `Result`/`Option` with
  `?`, ownership without GC, leak-until-exit accepted for a batch process — a compiler exercises
  every one of these under load. If they hold here, that is evidence; if they don't, we find out.
- **One language for the front end.** Once the front end is Ember, a contributor no longer needs C
  to work on it, and the build stops straddling two worlds for that half.
- **Maturity, factually.** "Compiles itself" is a property, demonstrated by a reproducibility fixed
  point (§5), not a slogan. We let the fixed point do the talking.

This is not a goal for its own sake. If a stage stops paying its way, we stop. stage 0 stays
viable indefinitely so the project is never stranded on a half-ported compiler.

---

## 2. Where things actually stand (prerequisite audit)

The conceptual core a compiler needs is, for the most part, already shipped and tested — and one
piece of evidence settles the central question on its own: **`std/json.em` is a recursive sum type
with a full recursive-descent parser, written in pure Ember today** (`enum Json { … Arr(items:
[Json]) }`, walked with `match`). That is the exact shape an AST is. The "can the language even
hold an AST?" risk is therefore not theoretical — it is demonstrated in the stdlib.

| Capability a compiler needs | Status in Ember today | Evidence |
|---|---|---|
| Recursive sum types (the AST) | **Present** | `std/json.em` — `enum Json` with `Arr(items: [Json])`, recursive `parse`/`stringify` |
| Enums + exhaustive `match` (token / node dispatch) | **Present** | language core; `tests/native/enum*.em` |
| Generic structs **and** generic enums, `Option`/`Result`, `?` | **Present (erased)** | `language.md` "Generics — runs structs, enums, functions, methods, and bounds"; `Option<Box<int>>` runs |
| `Map` / `Set` / `List` (symbol tables, interning, scopes) | **Present** | `std/map.em`, `std/set.em`, `std/list.em` |
| UTF-8 strings + byte-level ops (the lexer's staple) | **Present** | `std/string.em`; `char_code` / `from_char_code` builtins |
| Read a file in, write a file out | **Present** | `read_file` / `write_file` builtins (`include/builtin.h` NATIVE_READ_FILE/WRITE_FILE) |
| `argv` / env / exit code | **Present** | `args()` / `env()` / `exit()` builtins; `examples/14_cli.em` |
| Modules for a multi-file compiler | **Present** | `import "path" as name`, module-qualified types/calls, `_`-privacy; the stdlib is itself multi-module |
| FFI + owning a C handle (only if we need C bindings) | **Present** | `extern "c"`; `resource struct` with auto-`drop` (OFI-122 Phase 1) |
| Stage-0 introspection to diff against | **Present** | `emberc --emit=tokens\|ast\|bytecode\|c\|run` |
| Differential + fuzz harness to keep a port honest | **Present** | `tests/native/` (VM vs compiled binary), Crucible, Ledger, Ceilings, opcheck, `make verify` |

**Note the correction to the earlier informal analysis:** file I/O and `argv` are *not* missing — they
are builtins. Generic structs and generic enums both run. So the prerequisites are in much better
shape than a glance at the std module list suggested.

What is genuinely missing or constrained:

- **No `system()` / process-spawn builtin.** Confirmed absent (`include/builtin.h` lists ids 0–21
  plus graphics; nothing spawns a process). This matters only for an *integrated* self-hosted
  **native** driver that wants to invoke `cc` itself. The VM-first route (§3) does not need it at
  all. → proposed **OFI-151**.
- **No bounds on generic enums / standalone methods** (`language.md` ~L984). A design constraint on
  how we model typed nodes and visitors, not a wall — the JSON enum models a recursive tree without
  needing them. → proposed **OFI-152**, opened only if modelling actually hits it.
- **Leak-until-exit inside generic bodies** (the sound OFI-009 tail). For a long-running server this
  would bite; for a compiler — a short-lived batch process that builds an arena and exits — it is
  exactly the classic acceptable strategy. Explicitly fine here.
- **Recursion ergonomics to pin down.** `std/json` recurses through `[Json]` (a heap array);
  single-child recursion (`Binary(left, right)`) wants `Box<Expr>`. `Option<Box<int>>` already runs,
  so both shapes should be expressible — but we confirm the specific AST shapes on **both** backends
  in a spike before building on them (Stage A).
- **Scale, watched not assumed.** The largest pure-Ember modules today are `std/flare.em` (~154 KB)
  and `std/ui.em` (~78 KB) — good evidence the toolchain already handles large single modules. A
  compiler is bigger and deeply multi-module, so compile time and module-resolution depth are things
  to measure as we go, not take on faith.

**Scope of the C to be replaced.** `src/` is ~68k lines, but roughly half is an embedded font blob
(`font_inter.h`, ~34k) and editor/LSP/graphics tooling that the compiler proper does not include.
The front end + VM backend that stages 1–4 actually replace — lexer, parser, checker, bytecode
codegen, VM, runtime, and their support — is on the order of **22–23k lines of C**, and the type
checker alone (`check.c`, ~8.8k) is ~40% of that. Size the effort around the checker; everything
else is smaller.

---

## 3. Strategy

**Incremental, differential, front-end-first. Keep stage 0 as the reference the whole way.**

Port one stage at a time — lexer → parser → checker → backend — and after each, run stage 0 and the
Ember port over the same corpus and **diff the artifact stage 0 already knows how to emit**. The
existing `--emit` modes are purpose-built oracles for exactly this:

| Ported stage | Diff against | Stage-0 oracle |
|---|---|---|
| Lexer | token stream | `emberc --emit=tokens` |
| Parser | AST dump | `emberc --emit=ast` |
| Checker | accept/reject + diagnostic text | the diagnostics stage 0 emits on compile (clean-compile vs expected-rejection programs) |
| Bytecode backend | disassembly **and** run output | `emberc --emit=bytecode`, `emberc --emit=run` |

Byte-identical or it isn't done. This is the same culture as `tests/native/` (which already diffs
every program's VM run against its compiled-binary run) — we are pointing it at the compiler itself.

### Decision: the self-hosted compiler targets the VM bytecode backend first

Recommended and adopted (Karl deferred the call). Reasoning:

- **The VM is the reference semantics** — "the bytecode VM stays the reference semantics; [the
  native C output] is held to it by the differential test in `tests/native/`" (`src/cgen_c.c`
  header). Diffing self-hosted output against stage 0 is cleanest when the target *is* the reference.
- **No in-language `cc`/`system()` dependency to run results.** The one genuinely-missing primitive
  (§2) is avoided entirely on this path.
- **Lowest friction**, which is what you want for a bootstrap. A VM-hosted `emberc` is slower than a
  native one — fine for bootstrapping, and not the end state.

The **C-emitting native backend is a documented follow-on** (Stage 5), once the front end is already
self-hosted. Only then do we need either `system()` (OFI-151) for an integrated `emberc -o bin`
driver, or — simpler — have the self-hosted compiler emit C and let `make`/stage 0 run `cc`, exactly
as the toolchain already does today.

---

## 4. Stage-by-stage plan

Each stage names what to build in Ember, the **exact** differential test, the done-when bar, and the
risks. New Ember sources live under `selfhost/`; new tests under `tests/selfhost/`.

### Stage 0 — freeze the reference (do this first)

Tag a stage-0 `emberc` binary and keep `src/` buildable from scratch. From here on, stage 0 is
immutable for the purposes of the bootstrap; if the C compiler changes, re-tag deliberately. Document
the from-zero rebuild so anyone can reproduce the reference.

### Stage A — prerequisite spikes (small, before any real porting)

- **Recursive-AST spike.** A token enum + a minimal expression AST using both `Box<Expr>`
  (single-child) and `[Expr]` (n-ary), constructed and walked with a match-heavy evaluator. Compile
  and run on **VM and native**, differential green. This retires the one residual "is the shape
  expressible end-to-end?" question before we build on it.
- **Compiler-shaped data spike.** Confirm `Map`-based symbol tables and string interning behave at
  the sizes a checker needs (no surprises from erased generics / leak-until-exit at scale).
- **Decide the `system()` question.** Not needed for VM-first; open **OFI-151** now only if we commit
  to an integrated native driver at Stage 5.

### Stage 1 — lexer in Ember (`selfhost/lexer.em`)

- **Build:** source `string` → `[Token]`, emitting in stage 0's exact `line:col  TYPE  lexeme` form.
- **Differential:** for every `.em` across `examples/`, `tests/`, and `std/`, compare
  `emberc --emit=tokens X` against a tiny Ember driver that `read_file`s `X`, lexes it, and prints
  tokens in the identical format. Diff must be empty.
- **Done when:** token stream byte-identical over the whole corpus.
- **Risks:** UTF-8 column counting; numeric/string-literal edge cases; **the vocabulary must stay
  single-sourced** — `include/vocab.def` is the one source of truth, so generate the Ember lexer's
  keyword/operator table *from* it rather than hand-copying (mirrors `tools/gen_editor_assets`). →
  proposed **OFI-153**.

### Stage 2 — parser in Ember (`selfhost/parser.em`)

- **Build:** `[Token]` → AST (the recursive enum from Stage A, grown to the full grammar in
  `docs/grammar.ebnf`).
- **Differential:** AST dump vs `emberc --emit=ast` over the same corpus. Match stage 0's
  `ast_print` format (`src/ast_print.c`) so the diff is direct.
- **Done when:** AST dump byte-identical over the corpus.
- **Risks:** operator precedence; error-recovery parity; named-argument / 2-token-lookahead cases
  (the `pk2` path, OFI-140); keeping the AST shape faithful enough that downstream stages see the
  same tree stage 0 produces.

### Stage 3 — checker in Ember (`selfhost/check.em`) — the long pole

- **Build:** name resolution → types/inference → generics-erasure rules → ownership/move checking →
  contracts. This is the largest and subtlest component (`src/check.c` ~8.8k lines); stage it
  internally in that order rather than as one push.
- **Differential:** **diagnostic parity** — over the programs the suite expects to compile clean
  and the programs it expects stage 0 to **reject** (the `error_*` programs and similar), the Ember
  checker must reach the same accept/reject decision and emit the same error text as stage 0. Build
  out a dedicated checker corpus under `tests/selfhost/` as needed. *(Note: `tests/check` is the
  contract property-fuzzer and `tests/fault` is runtime faults — different concerns, not the
  type-diagnostic oracle.)*
- **Done when:** identical diagnostics across the corpus (or an explicitly-agreed canonical diff).
- **Risks:** this is where the language fights back, so **expect to surface real OFIs** — that is a
  feature of the exercise, not a setback. Per CLAUDE.md, when a divergence appears, reach for
  `--emit` + the minimal offending source as the repro before patching.

### Stage 4 — bytecode backend in Ember (`selfhost/codegen.em`)

- **Build:** AST → bytecode chunk, matching `src/codegen.c`.
- **Differential:** `--emit=bytecode` disassembly parity **and** end-to-end run parity (program
  output identical when the resulting bytecode runs on the VM).
- **Done when:** disassembly byte-identical **and** run output identical over `tests/native` +
  `tests/run`.
- **Risks:** opcode coverage (lean on `opcheck`); witness / dictionary-passing for bounded generics;
  correct `drop`/cleanup emission.

At the end of Stage 4 the **entire front end and the VM backend exist in Ember.**

### Stage 5 — C-emitting native backend in Ember (`selfhost/cgen_c.em`) — follow-on

- **Build:** port `src/cgen_c.c` so the self-hosted compiler can also produce native binaries.
- **Driver:** either add `system()` (OFI-151) so `emberc` invokes `cc` itself, or emit C and let
  `make`/stage 0 run `cc` — the same external-`cc` step the toolchain uses today.
- **Differential:** the existing `tests/native/` VM-vs-binary diff, now with the self-hosted compiler
  producing the C.

---

## 5. The bootstrap and the fixed point (the proof)

Once stages 1–4 are green, run the bootstrap:

1. **Stage 1 build** — compile `selfhost/*.em` with stage 0. Result: an `emberc` that *runs on the
   VM* and whose own backend emits bytecode.
2. **Self-compile** — run that emberc on its own source to produce stage-2 artifacts.
3. **Fixed point** — require stage-1 output and stage-2 output to be **byte-identical**. That
   reproducibility is the proof the compiler reproduces itself.

That fixed-point check is, incidentally, the construction at the heart of Ken Thompson's *Reflections
on Trusting Trust* — a compiler that compiles itself. We note it as a property worth stating, not as
a security guarantee.

Then **freeze stage 0 forever**: keep the C source and a tagged binary so anyone can re-bootstrap
from scratch, and document the reproduce-from-zero steps. A self-hosted language that can't be
rebuilt without itself is a trap; keeping stage 0 is what avoids it.

---

## 6. Testing and gates

- New `tests/selfhost/` tier plus a `make selfhost` target running the per-stage differentials.
- **`tools/cgdiff.sh`** — the codegen DEV-LOOP harness (the dev counterpart to the `make selfhost` Stage-4
  gate): point it at a probe (or `-d <dir>`, `-c` for a corpus sweep + first-divergence cause histogram) and
  it runs the file through the stage-0 oracle, the VM, and the native self-hosted codegen, printing the
  divergent *function* and first differing instructions — so an unbuilt or miscompiled construct is located
  in one shot. It drove the enum/`match` build and is the instrument for the rest of M4.
- As each stage goes green, fold its differential into `make verify` so it cannot silently regress.
- Keep Crucible (memory ownership), Ledger (move-check), Ceilings, and opcheck pointed at both
  compilers as they diverge — the divergences are where the interesting bugs live, and the
  differential catches silent wrong-answer drift, not just crashes.
- Every new stage lands with its tests in `tests/selfhost/` (CLAUDE.md: a feature without a test that
  exercises it is not done).

---

## 7. Milestones (sequence, not dates)

- **M0 ✅ DONE** — stage 0 frozen (`stage0-v0.3.42`); Stage A spikes green on both backends.
- **M1 ✅ DONE 2026-06-27** — self-hosted lexer (`selfhost/lexer.em`); token diff **empty over the whole
  corpus** (531/531 at last count, growing with the test suite), on both backends; folded into
  `make verify` (the `selfhost` gate). Enablers landed: OFI-159 (corrected the `--emit=tokens` oracle),
  the `byte_slice` builtin (byte-faithful lexemes), and a 3-agent adversarial pass (native parity, scales
  to 1.15 M tokens, two malformed-input error positions fixed). OFI-153 (generate the keyword table from
  `vocab.def`) is the remaining refinement.
- **M2 ✅ DONE 2026-06-27** — self-hosted parser (`selfhost/parser.em`, imports the lexer); AST diff
  **empty over all valid corpus files** (530/530 at last count) (`emberc --emit=ast`), VM and native;
  gated in `make verify`. It parses itself identically. **Adversarially verified** (3-agent pass): spec
  MATCHES on everything (precedence, lossy-but-parsed contracts/lambdas/named-args, desugaring, `>>`
  split, interpolation, all productions); found + fixed two corpus-untriggered bugs — a float `1.5e3`
  over-read (stage-0 `strtod`s past the lexeme; fixed via a token byte-offset + source over-read) and
  import/extern paths stored raw not escape-decoded. The AST also gained a per-`Box` `line` field (the
  prerequisite for M4's source-line column; adding it didn't change `ast_print`, so M2 stayed green).
  Known **OFI-157 constraint**: the parser is recursive, so the *VM-run* parser hits the 256-frame cap at
  ~48 levels of nesting (the native-compiled parser — what the gate uses — and the oracle both handle it);
  real source nests shallowly, so the corpus and bootstrap are unaffected. Surfaced **OFI-161** (native
  free-function `mut` struct param doesn't persist mutation — used methods-in-struct instead).
- **M3 🔨 IN PROGRESS (building 2026-06-27)** — self-hosted checker (`selfhost/checker.em`,
  methods-in-struct, int `SemType`); **full exact-diagnostic parity** the goal (Karl's call). The long
  pole. **Now gated as Stage 3 of `make selfhost`** (`check_dump.em` driver): the verdict (ACCEPT/REJECT)
  is diffed against the `emberc --emit=bytecode` oracle over the corpus. The gate **reports** the
  verdict-match rate but **hard-fails on any false-reject** — the safety invariant (a false rejection is
  a real bug; a missed rejection is just unfinished work). **Status: 461/522 verdict-match, 0
  false-rejects** (VM == native; the semantics of each check were mapped from `src/check.c` by recon
  workflows, implemented correct-by-construction, then adversarial workflows generated valid programs to
  hunt false-rejects — they found and fixed 7 the corpus didn't exercise, e.g. a bare `Option`/`Result`
  match and sized-field arithmetic). The **M3b ownership** work shipped only its SAFE CORE — the
  structural *mutability* checks (assign-to-`let`, mutate-field/element-through-an-immutable-binding,
  pass-immutable-to-`mut`-param, `Ptr`-as-struct-field) gated purely on the syntactic `is_var`/`qual`/
  `TY_PTR` facts, plus break/continue-outside-loop and bool-condition checks. The move/leak/escape
  *dataflow* (use-after-move, handle leaks, borrow-escape) is deliberately DEFERRED: a recon with
  per-check false-reject risk ratings found it unsound to replicate in a checker that keeps fields/calls/
  generics at `TY_INFER` — a naive version false-rejects pervasive valid code, so those stay accepted
  missed-rejections. Built: name resolution (complete) + a growing type-inference layer.
  `check_expr` returns a `SemType` (kept POSITIVE: top-level constants must be literals; `TY_INFER` is the
  lenient unknown, and every check is gated on concretely-known operands so an unmodelled corner emits
  nothing rather than a wrong diagnostic). Flat parallel-array TYPE TABLES (struct fields, struct methods,
  enum variants, fn param types) are built in a `register_types` pass; `annotation_type` resolves user
  structs/enums precisely while type-params, interfaces, newtypes, Self, generics and imports stay
  `TY_INFER`. Checks implemented: arithmetic same-numeric-type (int-literal / f32 width adaptation),
  redeclaration-in-scope, free-function + method arity, argument / field / let / return type mismatch,
  struct-literal construction (no-such-field / field-type / every-field-set-once), match (duplicate-case /
  non-exhaustive / wrong-variant / binding-arity, for plain user enums), and definite-return (an exact
  replica of stage-0's terminator analysis). The semantics for each were mapped from `src/check.c` by a
  recon workflow and adversarially verified. **Remaining**: the ~61 not-yet-rejected files are mostly
  ownership/move (the hard dataflow, M3b) plus a few deferred checks that would risk false-rejects without
  more modelling (newtype distinctness, no-such-method, named-field construction). **Sub-staging**: (a) verdict-parity via
  name-resolution + type-inference + exhaustiveness [in progress]; (b) ownership/move dataflow [the
  hardest] + contracts; (c) exact message + position parity over the error files (prerequisite: extend the
  parser AST to carry `line:col` — adding positions won't change `ast_print`, so M2 stays green).
- **M4 🔨 IN PROGRESS — a broad subset byte-identical, 2026-06-27.** Self-hosted bytecode backend
  (`selfhost/codegen.em` + driver `codegen_dump.em`), emitting disassembly **byte-identical** to stage-0
  `emberc --emit=bytecode` incl. the source-line column. Ports `src/codegen.c` (AST→bytecode) +
  `src/chunk.c` (the disassembler); the 91-opcode table + LEB128/big-endian operand codec come straight
  from `include/opcode.h`. Gated as **Stage 4** of `make selfhost` over a growing fixture set
  (`tests/selfhost/codegen/*.em`, **14 byte-identical** at last count), both backends, whole pipeline
  **1079/0**. **Done so far:** int/bool scalars + arithmetic; locals/stack slots; user-function & method
  calls; returns; control flow (if/loop/break/continue jump emit+patch); strings (CONCAT, interpolation
  TO_STRING, INCREF on a consumed place-read); **all three struct representations** (all-scalar multi-slot,
  boxed for `var`/refcounted-field, nested struct fields boxed); arrays incl. `.len()`/`.append()` and the
  element-kind table (empty `[]` kind from the `[T]` annotation); the **move/drop discipline** (owned
  string/array/boxed-struct lets dropped at every exit; moves zero the slot so the unchanged exit-drop is a
  no-op) — **this is the deferred ownership analysis landing in its codegen-driving role**; owned values
  returned from a **call** tracked as droppable (a re-derived fn-return-type table); built-in / user methods
  on **non-identifier receivers** (`a.vals.len()`, `t.text.len()`, `o.inner.mag()`); float literals; and
  interpolation-hole source lines re-based onto the enclosing string. **An adversarial divergence hunt +
  differential stress sweeps** drove this — they found ~12 corpus-untriggered divergences in supported
  features (a missing `EFloat` case, a nested struct-literal not boxed, a multi-slot struct call-arg, a
  refcounted-`var` reassign leak, …), each fixed + locked with a fixture, and surfaced OFI-162.
  The owned/non-identifier struct-access part of the cluster is now done too: a field read off a call-result
  uses `GET_FIELD_OWNED`, and a multi-slot struct returned from a call gets `BOX_STRUCT`'d before use as a
  method receiver or a struct field value (mapped by a 5-agent workflow against `src/codegen.c`, verified
  byte-identical). **A corpus-wide codegen differential** (the self-hosted backend run over all 434
  stage-0-accepted corpus files) puts the real frontier in numbers: **64/434 byte-identical**, and the
  divergences are dominated by *unbuilt features*, not the struct representation — only **3 files** need the
  nested-inline `UNBOX_STRUCT` flattening (`let ln = Line{a:P,b:P}`), so that "Step 0" is **deferred-low**.
  **Multi-module compilation** now works: the driver BFS-loads the entry file + every transitively-imported
  module (deduped by path, mirroring `src/main.c`), merges their decls `[entry, import1, …]`, and numbers all
  enum/struct/fn ids over the combined list — so an *imported* enum's `match` tags resolve correctly (a
  2-module probe is byte-identical), cross-module function calls (`ps.parse(x)`) emit a plain `CALL`, and an
  imported enum param (`ml.Lib`) is owned/dropped. Plus **numeric conversions** (`int(x)`/`i32(x)`/`u8(x)` →
  `CONV <kind>`) and the **`match` 64-case cap** (stage-0 elides the end-`JUMP` beyond the 64th case — the
  lexer's 71-variant `kind_name` needs this). Plus **`.bytes()`** (→ `STR_BYTES`, an owned byte array), **struct arrays** (`[Token]` →
  `NEW_STRUCT_ARRAY` when the element has no unique-owner field; an appended struct literal is built boxed),
  **array-element-type tracking** — `let t = arr[i]` now binds by the array's element kind (a
  string-bearing struct → a boxed droppable copy, an all-scalar struct → `INDEX;UNBOX_STRUCT` multi-slot, a
  string → `INDEX;INCREF`, a scalar → plain), with `arr[i].field` reading via `GET_FIELD_OWNED` (mapped by a
  5-agent workflow); a **multi-module foundation audit** that found + fixed two real cross-module gaps
  (qualified imported struct *types* `c.RGB` weren't resolved; cross-module call *return types* `c.green()`/
  `c.make_rgb()` weren't typed — unified through `resolve_call_fn_index`), which **halved parser.em's
  divergences (1338 → 692)** and dropped checker/codegen by ~800 each; refcounted-field/local `INCREF`
  (enum fields/locals are refcounted like strings),
  enum-returning method calls binding a droppable enum, and **`break`/`continue` loop-body cleanup** (they
  DROP+POP the locals declared since loop entry before jumping). **🎉 The cumulative result: `selfhost/lexer.em`
  now compiles BYTE-IDENTICAL to stage-0 on both the VM and native — the first fully self-compiling module**,
  gated in `make selfhost`. Driving off the compiler's own files took parser.em from ~4100 → ~1300 diffs and
  the corpus differential to **104/435**. **Short-circuit `&&`/`||`, global
  constants, and crash-hardening** came first, also by pivoting the dev loop onto the compiler's OWN modules: `cgdiff` on selfhost/{lexer,parser,checker,codegen}.em showed the front-end
  files were close but checker/codegen *crashed* the self-hosted codegen (an array-OOB). Three root causes,
  all fixed: `&&`/`||` are short-circuit (jumps), not binops (they were hitting `op_kcount[-1]`); a top-level
  `let` is an inlined compile-time constant (`return TY_INT` → `CONST (= 2)`); and a `match` on an *imported*
  enum (`ps.Decl`) was indexing the local enum table with -1 — guarded (the correct cross-module tag is the
  next milestone). checker.em and codegen.em now run to completion. **Built-in calls lower to `CALL_NATIVE`**
  — `print`/`println`/`read_file`/`write_file`/`char_code`/
  `args`/the math natives (core ids 0–22), with the per-native owning-temp `drop_mask` protocol (only
  print/println/read_file/write_file drop their fresh string args, via keep+`PICK`+`DROP_UNDER`; the
  transform natives release theirs internally), and native-return tracking so `let a = args()` is droppable.
  That took the corpus differential to **90/435 byte-identical**. **For-loops are done** — both fused forms
  (`FOR_RANGE` / `FOR_ARRAY`, incl. the indexed `for (i,x)`),
  break/continue/nesting, and the per-iteration body-local drop, ported exactly from `src/codegen.c` and
  Crucible-clean. Fixing them surfaced + closed a latent shared-unwind bug (a droppable block/loop/match
  body local must `DROP` *then* `POP`; only function-exit is `DROP`-only). This pushed the corpus
  differential from 64 → **79/434 byte-identical** (for-loops are pervasive, so many files flipped at once).
  **Enums + `match` are done** (the prior highest-frequency feature): NEW_ENUM construction (bare + payload),
  the `GET_TAG` tag-test dispatch chain ported exactly from `src/codegen.c` (payload binding, wildcard
  catch-all, the subject-`POP`/early-exit drop discipline), an `EnumTable` that injects the prelude
  `Option`/`Result` at the ids the parser can't see, and the enum move/drop discipline (enum lets/params are
  owned and dropped; passing an owned string/enum local to a call `INCREF`s) — verified byte-identical and
  **Crucible-clean** (187/187, covering enum/match). **Remaining M4, ranked by the corpus differential:**
  closures/generics (the `GET_LOCAL`/witness-passing bulk); contracts (`requires`/`ensures`);
  conversions (`CONV`); concurrency (channels/`SEND`); FFI (`CALL_C`); closures/generics; sized-int & float
  **arithmetic** + interpolation render-kind (one shared `scalar_type_code`, the "M4b" batch); the
  nested-inline flattening (deferred-low, 3 files); then the **VM fixed point** (the compiler compiles
  its own source). The dev loop for all of this is **`tools/cgdiff.sh`** (below).
- **M5** *(follow-on)* — self-hosted C-emit backend; native self-hosted binaries; `tests/native`
  green with the self-hosted compiler producing the C.

---

## 8. Risks and honest unknowns

- **The checker is the long pole** — ~8.8k lines of the subtlest semantics in the project. It will
  surface OFIs; plan for that and stage it internally.
- **Performance** — a VM-hosted `emberc` is slower than the C one. Acceptable for a bootstrap;
  revisit at Stage 5 when native self-hosted binaries arrive.
- **Erased generics shape the compiler's own data structures** — no monomorphized specialization to
  lean on, and leak-until-exit in generic bodies. Both are fine for a batch process; design the
  compiler's types around them deliberately rather than discovering them late.
- **Vocabulary single-sourcing** — `include/vocab.def` stays the one source; the Ember lexer's table
  is generated from it, never hand-copied (OFI-153).
- **Scope discipline** — self-host only as far as it serves the language. stage 0 is kept, not
  discarded; a stage that stops paying its way is paused, not forced.

---

## 9. OFIs (filed 2026-06-26 in [`docs/OFI.md`](../OFI.md))

The four proposed during planning, plus three surfaced by the Stage A dogfood:

- **OFI-151** — `system()` / process-spawn builtin (Stage 5 native driver). **OPEN, deferred to Stage 5.**
- **OFI-152** — bounds on generic enums / standalone methods. **OPEN, conditional** — only if AST/visitor
  modelling needs it (the recursive `[Json]`/`Box` shape does not).
- **OFI-153** — generate an Ember-consumable token table from `include/vocab.def` (lexer prerequisite).
  **OPEN, opens with Stage 1.**
- **OFI-154** — `tests/selfhost/` differential tier + `make selfhost` gate. **SHIPPED 2026-06-26.**
- **OFI-155 (HIGH)** — native miscompiled in-place mutation of a value-struct field of a non-flat struct
  (silent VM/native divergence). **CLOSED 2026-06-27** — runtime + cgen fix, adversarially verified.
- **OFI-156** — cross-module construction of an imported enum's bare variant fails. **OPEN** — workaround:
  constructor fns for bare tokens.
- **OFI-157** — VM/native recursion-depth divergence (`FRAMES_MAX = 256`). **OPEN, documented constraint.**
- **OFI-158** — native: nested value-struct field assign through a non-local boxed parent
  (`o.mid.span.col`, `ns[i].span.col`) is a clean error. **OPEN, low** — local/`self` paths work.
- **OFI-159** — `--emit=tokens` printed `INVALID` for 5 valid keywords (a missing `TOKEN_NAMES[]` entry).
  **CLOSED 2026-06-27** — corrected the lexer oracle before the M1 differential measured against it.
- **OFI-161** — native: a free function with a `mut` STRUCT parameter doesn't persist mutation (by-value).
  **OPEN** — `mut self` methods are unaffected; the front end uses methods-in-struct. Surfaced at M2.
- **OFI-162** — native: a *method* returning a value-struct mis-compiles (zeroed fields / hard `em_s13`
  error); a free function returning the same struct is fine. **OPEN** — worked around at M4 by returning
  an int code from the method (value-struct returns kept on free functions only).

---

## 10. Progress and next steps

**🎉 THE VM FIXED POINT IS REACHED. M0–M4 self-compile.** Stage 0 is frozen (`stage0-v0.3.42`). The
**self-hosted compiler reproduces its OWN COMPLETE SOURCE byte-identically** to the C reference, on both the
bytecode VM and the native backend: **all four modules — `selfhost/lexer.em`, `selfhost/parser.em`,
`selfhost/checker.em`, and `selfhost/codegen.em` — self-compile byte-identical end-to-end** (`emberc
--emit=bytecode MODULE` == the self-hosted lexer→parser→codegen run on MODULE, on every function of every
module). The whole self-hosted toolchain is gated in `make selfhost` at **1137/0**, folded into `make
verify`. The lexer + parser are also byte-identical over the WHOLE corpus on both backends, the checker
reaches stage-0's verdict on 479/540 files with zero false-rejects, and the bytecode backend is byte-identical
across 36 gated fixtures (scalars, control flow, strings, every struct representation, generic-struct
monomorphization, match-binding payload classification, array element kinds, wrapping & float/sized
arithmetic, interpolation render kinds, unary ops, methods, the move/drop discipline, multi-module diamonds).
Over the differential corpus (`tools/cgdiff.sh -c`) the self-hosted backend is byte-identical on a growing
fraction of arbitrary programs; the compiler's own ~6000 lines are 100%.

What "fixed point" means here: the differential is `emberc --emit=bytecode MODULE` (stage 0) vs `emberc
--emit=run selfhost/codegen_dump.em MODULE` (the self-hosted front end + codegen run on the VM). Compiling
`codegen.em` this way IS the self-hosted codegen compiling its own source; doing it for all four modules is
the self-hosted compiler reproducing itself. The remaining work toward a STANDALONE bootstrap is packaging
(a self-hosted driver that links the front end + codegen into a binary emitting object code / a runnable
chunk, rather than the differential `--emit` path) and the long-pole checker completeness (the 61
not-yet-rejected files — invalid programs the lenient self-hosted checker still accepts; it never
false-rejects, so it compiles every VALID program, including itself, correctly).

Ranked next moves:
0. **M4 — generic struct monomorphization** — **LANDED.** Stage-0 monomorphizes generic structs: each
   instantiation (`Box<Ty>`, `Box<Expr>`, …) is a DISTINCT struct type with its own `NEW_STRUCT` id,
   numbered after all declared structs, assigned in pre-order the first time each `Box<X>{…}` construction is
   checked (deduped per arg-types). The self-hosted backend now mirrors this with an `InstColl` pre-pass
   (`build_struct_instances`) that walks every function/method body in decl order, pre-order, registering
   each generic-struct construction's canonical `ty_key` first-seen; `lit_struct_id(ty)` resolves a `Box<X>`
   construction's `NEW_STRUCT` *operand* to `struct_count + instance_index` while the field LAYOUT stays the
   base id. Gated by `tests/selfhost/codegen/monomorph.em`. Two earlier foundational audits also landed:
   **multi-module** (cross-module enum/struct/call resolution — merged symbol universe, qualified types,
   `resolve_call_fn_index`) which halved parser.em, and the **generic-struct-literal** `TyGeneric` fix in
   `type_struct_id`.
0b. **M4 — the refcount/type-classification layer** — **LANDED (this campaign).** A cluster of byte-exact
   refcount/layout rules the self-hosted backend re-derives without a checker, all now mirroring stage-0 and
   gated by `tests/selfhost/codegen/bindings_arrays.em`:
   - **generic-struct return** (`ret_info` `TyGeneric` → base struct id) so `let x = mk()` of a `Box<T>`
     binds as a struct (field reads resolve);
   - **match-binding payload classification** — a `case V(x)` binding now carries its payload field's type:
     a STRING binding INCREFs when consumed, a STRUCT binding resolves `.field` (generic-aware via
     `ty_struct_id_g`), an ARRAY binding resolves `[i]`, an ENUM binding INCREFs as a refcounted borrow
     (`EnumTable.vf_*` flat payload-field table + `variant_field_index`);
   - **enum/refcounted array elements** — a new element-type code `-4` makes `arr[i]` of an `[Enum]` array
     INCREF like a `[string]` element; one shared `elem_type_code` classifier feeds array params, array
     `let`s, and bindings;
   - **field-array indexing** (`self.toks[i].kind`) — `index_elem_code` now resolves an indexed struct FIELD
     array (`StructTable.f_elem` + `field_elem_code`); previously the whole argument expression was dropped
     (emitted nothing), which was the pervasive `GET_LOCAL`-class divergence in the compiler's own source;
   - **array element kinds** — an empty `[]` / single `[x]` array as a struct field value takes the FIELD's
     element kind (`f_arrkind`), and `elem_kind_of` now classifies boxed (struct/enum/array) elements as
     `AEK_BOXED` instead of defaulting to int.
   Deferred: generic `Option<T>`/`Result<T>` payload bindings (OFI-163, needs scrutinee type inference) and
   inline-struct array literals (OFI-164).
0c. **M4 — parser.em closed to byte-identical (this campaign).** The residual `selfhost/parser.em`
   divergences all fell to small, baseline-verified fixes, taking it from 73/84 → **84/84 (whole module)**:
   **wrapping arithmetic** (`wrapping_add/sub/mul` → the dedicated `WRAP_*` opcodes, not a CALL);
   **interpolation `string_temp`** (an owning-temp string hole — a call/concat result — SKIPS `TO_STRING`,
   which would leak its owned reference; `hole_is_str_temp`); **field-read owning-temp precision**
   (`is_owning_temp_obj` — `arr[i].f` is `GET_FIELD_OWNED` only when the array stores INLINE structs, else a
   borrowed `GET_FIELD`, mirroring the checker's `is_owning_temp`); **inline-struct discrimination**
   (`struct_array_inline` now rejects a 16-byte NON-refcounted generic-param field like `Box<T>.value`, so
   `[Box<Expr>]` is boxed not inline-packed — needed `StructTable.f_enum`); **generic-aware array elements**
   (`elem_type_code` uses `ty_struct_id_g`, so a `[Box<Expr>]` element resolves to base `Box` — previously a
   `value[0].value` argument vanished); **enum place-read `let`** (`let op = self.advance().kind` INCREFs +
   binds a droppable enum); **bare-return unit** (`return` in a void fn pushes `CONST 0`, attributed to the
   keyword's line — `SReturn` gained a `line` field, transparent to ast_print so M2 stays green); and the
   **M4b scalar-kind foundation** — a per-slot `slot_kind` (set from a binding/param/match-binding's scalar
   type) feeds `render_kind_of` (the `TO_STRING` interpolation kind: f64=9, bool=10) and `scalar_kind_of`
   (a binary op's `num_kind` for float/sized operands). NEXT for M4b: `st_fkind`/fn-return scalar kinds so a
   field/call hole renders right; then port `selfhost/codegen.em` + `selfhost/checker.em` toward the VM
   fixed point.
1. **M4 — the nested/owned struct-value lowering cluster.** Three known divergences
   share one root — the backend's struct-value handling needs stage-0's owned-temp / flattening rules:
   field access on a call-result or nested path (`mk().text`, `ln.a.x`) via `GET_FIELD_OWNED` and the
   multi-slot flattening; a multi-slot struct returned from a call used as a method receiver (`make().m()`)
   needs `BOX_STRUCT` before `PICK`; a struct-returning call as a struct field value needs boxing. This is
   on the fixed-point critical path (the compiler reads `node.span.start` etc. pervasively). Map the rules
   from `src/codegen.c` (`resolve_multislot_field`, `cg_field_slot_offset`, `emit_call_result_box`,
   `fuzz_flatten_struct`) against live probes, then implement byte-identically.
2. **M4b — sized & float scalar types**: one shared `scalar_type_code(expr)` feeds the binary-op `num_kind`,
   the interpolation TO_STRING render-kind (bool=10, f32=8, f64=9, …), and the array element kind. Folds in
   hunt bug #7 (bool interpolation render-kind) and sized/float arithmetic at once.
3. **M4 — enums** (NEW_ENUM / GET_TAG / match dispatch) and **for-loops**, then closures/generics, then the
   **VM fixed point** (run the self-hosted compiler on its own source; require its output to equal stage-0's).
4. **M3 — the ownership/move dataflow (M3b)** and exact message+position parity (M3c): the remaining ~61
   not-yet-rejected files are mostly the deferred move/leak/escape analysis, which lands here and in M4's
   codegen-driving role together.
5. **OFI-153** (refinement): generate the lexer's keyword table from `vocab.def` (mirror
   `gen_editor_assets` + a sync gate), replacing the hand-mirrored tables.
6. **OFI-156**: cross-module bare-variant construction — the multi-module front end currently routes bare
   tokens through constructor fns; fixing it removes that boilerplate.
