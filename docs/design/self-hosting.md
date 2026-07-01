# Self-hosting Ember — a staged bootstrap plan

> Status: **🎉 THE VM FIXED POINT IS REACHED — M0–M4 self-compile (2026-06-28).** Stage 0 is frozen
> (`stage0-v0.3.42`), the Stage A spikes are green, and **all four self-hosted modules — `lexer.em`,
> `parser.em`, `checker.em`, `codegen.em` — compile their OWN source byte-identically to stage-0 on both
> the VM and native backends** (the self-hosted compiler reproduces itself). The **lexer** and **parser**
> are also byte-identical over the whole corpus; the **checker** reaches stage-0's accept/reject verdict on
> **534/541 files with zero false-rejects (7 not-yet-rejected)** — and its M3b **ownership dataflow engine**
> (use-after-move + the `Ptr` must-consume leak scan, dual OR/AND merges) has now SHIPPED; the **bytecode
> backend** is byte-identical across 36 gated fixtures plus the compiler's own ~6000 lines. The whole
> pipeline is gated by `make selfhost` (**1139 checks, 0 failures**) and folded into `make verify`. The
> remaining work is **checker completeness** (the 7 not-yet-rejected invalid files; it never false-rejects,
> so it already compiles every valid program including itself) and finishing the **standalone bootstrap**.
> **The first bootstrap milestone has LANDED:** `selfhost/emberc.em` is the UNIFIED self-hosted compiler —
> the whole pipeline (lex → parse → **check** → codegen) as ONE program, compiled to a native self-built
> compiler **binary** (`emberc -o emberc-self selfhost/emberc.em`). It rejects an ill-typed program with
> exit 65, emits valid programs' bytecode byte-identically to stage-0, and **reproduces all four of its own
> modules byte-identically** — gated as Stage 5 of `make selfhost` (**1147/0**). The remaining bootstrap
> step is making the emitted bytecode *runnable* (a serialization format + a stage-0 loader, or an M5
> C-emit backend). Self-hosting is earned one differential-green stage at a time, never by a big-bang
> rewrite, and only as far as it actually improves the language and toolchain.
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
- **M3 🔨 IN PROGRESS (building 2026-06-27; dataflow engine landed 2026-06-28)** — self-hosted checker
  (`selfhost/checker.em`, methods-in-struct, int `SemType`); **full exact-diagnostic parity** the goal
  (Karl's call). The long pole. **Now gated as Stage 3 of `make selfhost`** (`check_dump.em` driver): the
  verdict (ACCEPT/REJECT) is diffed against the `emberc --emit=bytecode` oracle over the corpus. The gate
  **reports** the verdict-match rate but **hard-fails on any false-reject** — the safety invariant (a false
  rejection is a real bug; a missed rejection is just unfinished work). **Status: 534/541 verdict-match, 0
  false-rejects, 7 not-yet-rejected** (VM == native; the semantics of each check were mapped from
  `src/check.c` by recon workflows, implemented correct-by-construction, then adversarial workflows
  generated valid programs to hunt false-rejects — they found and fixed 7 the corpus didn't exercise, e.g.
  a bare `Option`/`Result` match and sized-field arithmetic). **The M3b ownership DATAFLOW engine — deferred
  during the first pass as too-risky — is now SHIPPED (post-fixed-point, 2026-06-28).** It is a single
  forward pass with DUAL merges held in parallel scalar arrays (NOT `Local` fields — `arr[i].field = v`
  writeback isn't self-compilable yet, OFI-061, so per-local mutable state lives in `local_moved` /
  `local_consumed`): `local_moved` is an OR-merge (moved on ANY path → use-after-move) and `local_consumed`
  is its AND-merge dual (a `Ptr` must-consume obligation discharged only when closed on EVERY reaching
  path → a leak otherwise). Branch/match merges are reachability-gated (`block_diverges`); the loop
  back-edge guards OFI-074 (a move that would recur next iteration); a **break-state accumulator**
  (`loop_break_consumed`) carries a close-on-break out of the loop, and a `for` AND-merges its break paths
  with the zero-iteration natural exit. On top of the SAFE-CORE structural *mutability* checks already
  shipped (assign-to-`let`, mutate-field/element-through-an-immutable-binding, pass-immutable-to-`mut`-param,
  `Ptr`-as-struct-field, break/continue-outside-loop, bool-condition), the dataflow now also rejects:
  **use-after-move**, the **`Ptr` must-consume leak** (an opened handle un-closed on some exit path,
  scanned at every return + the reachable fall-through), **double-close / close-a-borrow / discard-a-Ptr**,
  and **reassigning a still-open `Ptr`**. Built on: name resolution (complete) + a growing type-inference
  layer.
  `check_expr` returns a `SemType` (kept POSITIVE: top-level constants must be literals; `TY_INFER` is the
  lenient unknown, and every check is gated on concretely-known operands so an unmodelled corner emits
  nothing rather than a wrong diagnostic). Flat parallel-array TYPE TABLES (struct fields, struct methods,
  enum variants, fn param types) are built in a `register_types` pass; `annotation_type` resolves user
  structs/enums precisely while type-params, interfaces, newtypes, Self, generics and imports stay
  `TY_INFER`. Checks implemented: arithmetic same-numeric-type (int-literal / f32 width adaptation),
  redeclaration-in-scope, free-function + method arity, argument / field / let / return type mismatch,
  struct-literal construction (no-such-field / field-type / every-field-set-once), match (duplicate-case /
  non-exhaustive / wrong-variant / binding-arity, for plain user enums), and definite-return (an exact
  replica of stage-0's terminator analysis). A later mechanical batch (2026-06-28) added: read-of-`_`
  (the write-only discard), heterogeneous array literals (compared by coarse scalar class so int↔float
  coercion is never flagged), the extern parameter-qualifier rule (`move Ptr` / `mut [T]` stay valid,
  everything else rejected — mirroring `check.c:7493`), spawn-outside-a-nursery, spawn-of-an-extern, and a
  free function named like a numeric type (OFI-066). A further batch (2026-06-28) handled the corpus's
  *expected-type* cases at the use site (the checker stays synthesize-only — no `expected` threaded through
  `check_expr`): an unannotated `let` bound to a bare `None` or a `channel(N)` has no inferable type, and
  `?` in a function returning a concrete (non-Option/Result) type can't propagate; plus the **generic
  type-argument arity** at a struct literal (`Box<A,B>` / bare `Box` / `P<int>` all wrong — a new
  `struct_garity` table) and the **Show** contract on interpolation holes (a struct-without-`show` / enum /
  array can't render — `hole_showable`). The semantics for each were mapped from `src/check.c` and
  adversarially verified. A further sub-campaign (2026-06-28) closed the entire **generic-bound +
  substitution** cluster — `generic_bound` (a type argument must satisfy its parameter's interface bound at a
  struct literal — per-struct `sg_*` bound tables + `type_satisfies_bound` + struct `implements`),
  `copy_struct` / `bound_unsatisfied` (a bare-`T` value parameter binds `T` to the argument, so its type
  must satisfy `T`'s Copy/interface bounds at the call — per-fn `fg_*` tables + `fn_ptparam`),
  `unbounded_method` (no method on an unbounded type-param — a `local_unbounded_tp` parallel array),
  `generic_field` (a field declared `T` is checked at the construction's concrete argument — `Box<int>{value:
  "no"}` — `sf_tparam` substitution), and `generic_variant_type` (a `let x: Option<int> = Some("s")` payload
  is checked against the annotation's type argument). The parser gained an `is_copy` flag on `GenericParam`
  (tracked separately so `ast_print` stays byte-identical). Every step was differential-gated, so the
  pervasive `Box<Expr>`/`Option<X>` usage in the compiler stayed 0-false-reject. A further sub-campaign
  (2026-06-28) closed **newtype-value modelling** — a newtype value now carries a distinct `NEWTYPE_BASE`
  band (was erased to `TY_INFER`), making it a distinct nominal type: arithmetic on it is rejected (it isn't
  numeric — `newtype_arith`), it is assignable only to the same newtype (`newtype_mismatch`), and it is not
  iterable (`newtype_not_iterable`); the inherited behaviours (compare/order/show/`Hash`-`Eq` Map keys) stay
  lenient by recursing to the base. The ripple from making newtypes concrete was caught + fixed gate-driven
  (0 false-rejects); refinement types ride along (they parse as newtypes). A further sub-campaign
  (2026-06-28) closed **4 of the 6 parser-AST-blocked checks** by surfacing the dropped flags WITHOUT
  changing `--emit=ast` (so M2 stays byte-identical — the `is_copy` template): `DStruct` gained a `kind`
  field (0/1/2 = plain/rc/resource) → `rc_bad_field` (an rc field must be immutably shareable — `rc_field_ok`),
  `rc_field_mutation` (no assign THROUGH an rc value at any path step — a read-only `path_type` resolver +
  `mutation_through_rc`, no global ripple), `resource_noop_drop` (a resource drop must reference/close each
  Ptr field — recursive `expr_uses_self_field` body scan); and `DType` gained a `pred` field (the `where`
  predicate, captured not discarded) → `refinement_self_cycle` (a predicate can't construct its own type —
  `expr_calls_name`). **Remaining (7, the genuinely hard/invasive tail):** *borrow/escape analysis*
  (`borrow_conflict`, `escape_borrow`, `slice_escape`, `slice_frozen` — lifetime tracking the erased checker
  has no model for); `resource_clone_match` (needs `Result`/`Option` payload-type tracking through a `match`,
  to see a bound value is a resource); `enum_named` (named-arg validation — needs arg NAMES on `ECall`, which
  is matched at ~24 sites, so the AST change is disproportionate for one file); and a parse-time
  *literal-range* check (`int_literal_range`, a front-end change — the self-hosted parser wraps the
  out-of-range literal). **Sub-staging**: (a) verdict-parity via
  name-resolution + type-inference + exhaustiveness [done for the structural/dataflow tier]; (b)
  ownership/move dataflow [SHIPPED] + contracts [pending]; (c) exact message + position parity over the
  error files (prerequisite: extend the parser AST to carry `line:col` — adding positions won't change
  `ast_print`, so M2 stays green).
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
- **OFI-163** — self-hosted codegen: a generic `Option<T>`/`Result<T>` payload binding can't be
  refcount-classified without scrutinee type inference. **OPEN** — concrete user-enum payload bindings ARE
  classified; surfaced completing match-binding payload classification.
- **OFI-164** — self-hosted codegen: a non-empty array literal of inline-struct elements emits `NEW_ARRAY`
  (boxed) instead of `NEW_STRUCT_ARRAY` (inline-packed). **OPEN, low** — not on the front end's critical
  path (the compiler builds arrays via `.append()` loops, not struct-literal arrays).
- **OFI-165** — self-hosted codegen: a method call doesn't apply the owning-temp keep+drop discipline
  (`PICK`/`DROP_UNDER`) to its arguments, so an inline owning-temp array passed to a method's borrow
  parameter (`obj.m(clone_bools(x))`) leaks and diverges from stage-0. **OPEN** — surfaced building the M3b
  Ptr leak scan; worked around with the file's named-local idiom (the inline form was the lone outlier).

---

## 10. Progress and next steps

**🎉 THE VM FIXED POINT IS REACHED. M0–M4 self-compile.** Stage 0 is frozen (`stage0-v0.3.42`). The
**self-hosted compiler reproduces its OWN COMPLETE SOURCE byte-identically** to the C reference, on both the
bytecode VM and the native backend: **all four modules — `selfhost/lexer.em`, `selfhost/parser.em`,
`selfhost/checker.em`, and `selfhost/codegen.em` — self-compile byte-identical end-to-end** (`emberc
--emit=bytecode MODULE` == the self-hosted lexer→parser→codegen run on MODULE, on every function of every
module). The whole self-hosted toolchain is gated in `make selfhost` at **1139/0**, folded into `make
verify`. The lexer + parser are also byte-identical over the WHOLE corpus on both backends, the checker
reaches stage-0's verdict on **534/541 files with zero false-rejects (7 not-yet-rejected)**, and the bytecode backend is byte-identical
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
chunk, rather than the differential `--emit` path) and the long-pole checker completeness (now **25**
not-yet-rejected files, down from 61 — invalid programs the lenient self-hosted checker still accepts; it
never false-rejects, so it compiles every VALID program, including itself, correctly).

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
The VM fixed point is reached and the M3b ownership dataflow has shipped, so the frontier is now
**checker completeness** (the 7 not-yet-rejected files) and the **standalone bootstrap**. Ranked:

0d. **M3 — the use-site expected-type + arity + Show batch — LANDED (2026-06-28).** Rather than thread an
   `expected` type through all of `check_expr` (invasive, and a fixed-point risk), the corpus's
   expected-type triggers were handled at the use site: an unannotated `let` bound to a bare `None`
   (`infer_none`) or a `channel(N)` call (`channel_untyped`), and `?` in a function returning a concrete
   non-Option/Result type (`try_bad_return`). Plus generic type-argument **arity** at a struct literal
   (`generic_arity`, via `struct_garity`) and the **Show** contract on interpolation holes
   (`interp_not_showable`, via `hole_showable`). All five verified against stage-0, false-reject-free.
0e. **M3 — generic-bound satisfaction & substitution — LANDED (2026-06-28).** The whole cluster, built
   correct-by-construction against `src/check.c` and differential-gated at every step so the pervasive
   `Box`/`Option` usage stayed 0-false-reject: per-struct (`sg_*`) and per-fn (`fg_*`) type-param bound
   tables, `type_satisfies_bound` + struct-`implements`, a bare-`T` value-param→type-param map (`fn_ptparam`)
   for call-site Copy/interface bounds, a `local_unbounded_tp` parallel array for the unbounded-method ban,
   and `sf_tparam`/annotation-driven substitution for generic field and `Option`/`Result` payload checks.
   The parser gained an `is_copy` flag on `GenericParam` (tracked separately so `ast_print` stays
   byte-identical). Closes `generic_bound`, `copy_struct`, `bound_unsatisfied`, `unbounded_method`,
   `generic_field`, `generic_variant_type`.
0f. **M3 — newtype-value modelling — LANDED (2026-06-28).** A newtype value carries a distinct `NEWTYPE_BASE`
   band (`newtype_base` records each base); a newtype is a distinct nominal type — arithmetic rejected
   (`newtype_arith`), assignable only to the same newtype (`newtype_mismatch`), not iterable
   (`newtype_not_iterable`) — while inherited compare/order/show/`Hash`-`Eq` stay lenient by recursing to
   the base. Refinement types ride along. 0 false-rejects (the concrete-band ripple was caught gate-driven).
0g. **M3 — parser-AST-blocked cluster, 4 of 6 — LANDED (2026-06-28).** Surfaced the dropped AST flags without
   changing `--emit=ast` (M2 byte-identical, all four modules self-compile): `DStruct.kind` (rc/resource) →
   `rc_bad_field` (`rc_field_ok`), `rc_field_mutation` (`path_type` + `mutation_through_rc`),
   `resource_noop_drop` (drop-body scan `expr_uses_self_field`); and `DType.pred` (the `where` predicate) →
   `refinement_self_cycle` (`expr_calls_name`). Remaining: `resource_clone_match` (payload-type through a
   match) and `enum_named` (named-arg names → `ECall`, ~24 sites — disproportionate).
1. **M3 — borrow/escape analysis** (`borrow_conflict`, `escape_borrow`, `slice_escape`, `slice_frozen`) — the
   hardest remaining: slice/borrow lifetime tracking the erased checker has no model for.
2. **M3 — the remaining parser-AST tail + front-end + parity**: `resource_clone_match` (track `Result`/
   `Option` payload types through a `match`) and `enum_named` (named-arg validation, gated on the `~24-site
   ECall` change), plus a parse-time literal-range check (`int_literal_range`, a lexer/parser change). Then
   **M3c** — exact message + position parity over the error files (prerequisite: extend the parser AST to
   carry `line:col`; adding positions won't change `ast_print`, so M2 stays green).
3. **The standalone bootstrap — STARTED.** **Step 1 LANDED:** `selfhost/emberc.em`, the UNIFIED driver
   (lex → parse → check → codegen as one program), compiled to a native self-built compiler binary that
   rejects ill-typed programs (exit 65), emits valid bytecode byte-identical to stage-0, and reproduces all
   four of its own modules (gated, Stage 5 of `make selfhost`). **Step 2 — the M5 C-emit backend — IN
   PROGRESS.** Decision (recorded): emit C and let clang build the native binary, rather than a bytecode
   serialization format + a stage-0 loader — because it mirrors Ember's *existing* architecture (stage-0
   already has a C-emit native backend, `--emit=c`/`-o`), completes the self-hosting mirror (the 5th of
   stage-0's 5 components), reuses the *same* byte-identical differential (`--emit=c` is the oracle, vs no
   oracle for serialized bytecode), produces Ember's native artifact with nothing new added to stage-0, and
   walks toward the kernel's bare-metal codegen. `selfhost/cgen_c.em` + `cgen_c_dump.em` + the `tools/ccdiff.sh`
   differential harness drive it, gated as Stage 6 of `make selfhost` (one fixture per increment under
   `tests/selfhost/cgen_c/`, each byte-identical to stage-0 `--emit=c` on BOTH the VM and the self-built
   native binary). Built incrementally like the bytecode `codegen.em`: **M5a int-scalar expressions**
   (literals/idents/binops via the retain dance + user calls), **M5b strings** (interned literals + the
   `em_add` ownership/drop discipline), **M5c control flow** (if/else-if, `loop`/`break`/`continue`, range
   & array `for`, scalar `var` reassignment, per-block scope drops), and **M5d arrays** (literals →
   `em_array`, empty arrays from the annotation, `em_index`, `.len()`/`.append()`, scalar bindings derived
   from an array — `let n = xs.len()`, `let x = xs[i]` — array params as borrows, `for` over a param/local/
   literal with the temp-iterable drop, returning an owned array as a slot-niling move, array `var`
   reassignment as drop-old-then-store, owning-temp array call args dropped after the call, and `.len()` on a
   temp receiver) — **all byte-identical**. **M5e is structs + methods (the hard middle)**, split by
   stage-0's `is_value_struct` foundation: a struct is a VALUE-TYPE (a real C `em_s<sid>`, value semantics,
   no drop) iff it is recursively all-scalar and not an rc/resource struct, else BOXED (a heap ObjStruct
   Value, refcounted). The port classifies this itself from the AST (no checker), mirroring codegen.em's
   `build_structs`. **M5e.1a — value structs (within a function)** is done: the struct table + the typedef
   preamble + the runtime packed-layout metadata (`em_sN_off/knd/fst[]` + the `em_structs[]` StructType
   table, offsets a running sum with no alignment padding), construction as a C compound literal
   `((em_s<sid>){ … })` in declared field order, struct-typed `let` bindings (stored as the C em_s
   aggregate), scalar field reads `p.f` → `.f<idx>` (in arithmetic and bool conditions), sized-int/bool
   fields, multiple structs, and NESTED value structs (an inline `em_s<m> f<i>` field, `knd`=AEK_INLINE_
   STRUCT, read via a C member chain) — all byte-identical (fixture `structs_value.em`). **M5e.1b — value-
   struct params / returns / methods** is also done (fixture `structs_methods.em`): a value-struct parameter
   is `em_s<sid> a<i>` (by value), a value-struct return is a `em_s<sid>` C return type, and the em_invoke
   dispatcher unboxes each struct-param slot (em_unbox_struct) + boxes a struct result (em_box_struct); a
   method call `recv.m(args)` lowers to `em_fn_<K>(recv, args…)` (self arg 0, resolved via the `Struct.method`
   name); a method's `self` is the borrowed receiver, so a `self.field` read in a CONSUMING op is retained
   while a by-value param / let field (an owned copy) is not; the implicit trailing return of a struct-
   returning fn is `(em_s<sid>){0}`. Deferred within M5e.1: chained / call-result method receivers (a struct
   TEMP receiver needs materialisation into an em_s temp), field WRITE (`p.f = v`), and mut/move self.
   **M5f — enums + match** is done (fixture `enums_match.em`), the highest-leverage piece (the compiler's own
   AST is enums, ~800 `case` sites across the modules): an enum value is a BOXED refcounted runtime value with
   NO C type and NO metadata preamble — a variant construction is `em_enum(&g_em, <enum_id>, <tag>, <arity>,
   payload…)` (bare `Dot` or payload `Circle(4)`); an enum param / local / return is OWNED (dropped at scope
   exit, moved into a call via own_into_slot, like a string — tracked via is_enum_ty / is_enum_expr /
   fn_ret_enum). A `match scrut { case V(binds) { … } }` statement reads the scrutinee's tag (`em_tag`) and
   lowers to an if / else-if chain on the tag, binding payload fields POSITIONALLY via `em_enum_field`
   (borrows); `case _` is the trailing `else`. Covers bare + scalar + string + multi-field variants,
   wildcard, match-assigns-var, and nested match. Deferred in M5f: owned-payload USE (a string/enum payload
   flowing out of a case), generic enums (Option/Result — tied to generics/prelude), and an owning-temp
   scrutinee. **M5e.2 — BOXED structs** is done (fixture `structs_boxed.em`): a struct with any heap field
   (string / array / enum) is a heap ObjStruct Value (refcounted, dropped by drop_value), NOT a C value-type
   — every struct still gets a `typedef struct {…} em_s<sid>;` + a metadata row (a heap field is 16 bytes).
   Construction → `em_struct(&g_em, <sid>, <fcount>, fields…)` (an owned field MOVED in); field read `c.f` →
   `em_enum_field` (a BORROW — retained in a consuming op); field write `c.f = v` → `em_set_field`; a boxed
   LOCAL is OWNED (dropped) but a boxed PARAM is a BORROW (like an array); a method call → `em_fn_<K>(recv,
   args…)` with self the borrowed heap Value (a `mut self` mutation via em_set_field reaches the caller's
   object); `s.arrayfield.len()` / `s.arrayfield[i]` resolve through the struct table (f_array / f_elem). The
   value/boxed split is threaded through struct_sid_any + struct_sid_of (value, gated on is_value) /
   boxed_sid_of. Deferred: an owned-field READ escaping a case/return (em_field_owned), nested boxed structs,
   and enum fields. **With enums+match (M5f) + arrays (M5d) + boxed structs (M5e.2) all done, the LEXER is now
   the target for the first full module to self-compile via cgen_c.em.** Dogfooding the real lexer through
   cgen_c.em surfaced **M5g** (done, fixture `conv_eq.em`): (1) the string `==`/`!=` BORROW rule — `+`
   CONSUMES its operands (move) but `==`/`!=` only COMPARE, so an owned operand (a string param compared
   against many keyword literals — the lexer's hot path) is RETAINED not moved; (2) numeric CONVERSIONS
   `int(x)` / `i32(x)` / `u8(x)` / `f64(x)` → `em_conv(x, <kind>)`, with `let a = i32(n)` binding a sized C
   scalar. **M5h — built-in STRING methods (done, fixture `string_methods.em`):** `s.len()` → em_str_len
   (no ctx), `s.bytes()` → em_str_bytes (a fresh owned [u8], so `let bs = s.bytes()` is a dropped array local
   of element kind u8), `s.chars()`/`s.split(sep)` → [string]. **M5i (done, fixture `boxed_builtins.em`)**
   knocked out four more: `em_struct_array` for empty struct-element arrays; owned string/enum struct-field
   MOVES into calls (`f(own_into_slot(&g_em, em_enum_field(…)))`; a scalar field is a borrow); native runtime
   builtins via `em_native(&g_em, <id>, <argc>, (Value[]){…})` (a name→id table, byte_slice=22, string/array-
   returning results tracked as owned); and `let x = s.field` of a SCALAR field typing as a C scalar
   (int64_t), plus a BOXED struct literal passed to a call being an owning-temp dropped after (drop_mask
   hoisting). **M5j (done, fixture `struct_array_elem.em`)** closed the big one: STRUCT-ARRAY-ELEMENT
   typing — `let e = arr[i]` on a `[Struct]` array retains the em_index clone into an OWNED boxed-struct local
   (dropped at scope exit), and `e.field` resolves as an em_enum_field read (element struct sid tracked per
   binding via sc_elem_struct, from the `[Struct]` annotation on a param / `var xs: [Struct] = []`). **Remaining
   lexer tail** (each a specific ownership text distinction). **M5k (done, fixture `field_ownership.em`)**
   closed several: a REFCOUNTED (string/enum) boxed field CONSUMED by `+` is `own_into_slot(&g_em,
   em_enum_field(…))` inside the balance-retain (not the plain borrow retain-dance a `==`/`!=` operand gets);
   a string-returning METHOD result bound to a local is an OWNED string; and `main_index` defaults to `em_fn_0`
   for a standalone module compile with no `main` (a dogfood artifact — the lexer is imported, not run). **The
   lexer is now down to essentially ONE diff hunk** (an owned string from a method, used twice in a token-build,
   needing the move+drop). **🎯 MILESTONE — `selfhost/lexer.em` NOW C-EMITS BYTE-IDENTICALLY to stage-0** (VM
   AND native): the last diff was `let k = self.scan_token(…)` — an enum-returning METHOD result (`Tk`) that
   is_enum_expr wasn't tracking as owned; once fixed, the whole lexer module is byte-identical. This is the
   FIRST full self-hosted module to self-compile through the native C-emit backend — the first real native-
   bootstrap step. It is now a permanent gate in `make selfhost` ("whole MODULES self-C-emit byte-identical").
   Next targets, in order: the **parser** (`selfhost/parser.em`), then the **checker** and **codegen**, then
   the unified **emberc.em** — at which point the self-built native compiler can rebuild itself. **M5l (done,
   fixture `generics.em`) added GENERIC-STRUCT MONOMORPHIZATION** — the biggest remaining language feature and
   the first thing the parser needs (its whole AST is `Box<Expr>` / `Box<Ty>` / `Box<Stmt>`): a generic struct
   gets one runtime sid per distinct instantiation used, numbered after the declared structs and collected in
   stage-0's order by an InstColl pre-order walk of every body (registering each `Box<X>{…}` the first time
   seen); each instance's C type ALIASES the base (`typedef em_s<base> em_s<inst>;`) with the base's metadata
   (for a BOXED type arg — all the compiler uses); construction is `em_struct(&g_em, <inst>, <fcount>, …)`;
   `box.value` and a `Box<X>`-returning call/param resolve via base_of / sid_of_ty. With generics in, **the
   parser's struct preamble is now byte-identical**. **M5m (done, fixture `enum_payload_ownership.em`)** began
   the parser body: a `case V(s)` binding of a REFCOUNTED (string/enum/struct) payload field CONSUMED by `+`
   is `own_into_slot(&g_em, …)` (moves_local==2 — a retain into the concat), not the generic borrow
   retain-dance (a scalar payload / a `==` operand keeps the retain-dance). Driven by a new per-variant
   payload-field table (EnumTab.pf_refc) + a per-binding refcounted-borrow flag (sc_refc). **The parser is a
   BIG module (~500 diff hunks remain)** — its tail is dominated by **string interpolation** (206 sites,
   still unimplemented — its whole `ast_print` is `"…{expr}…"`), plus array-payload bindings, a struct-array-
   ELEMENT read passed to a call (own_into_slot the em_index clone), and more ownership. It is a genuine
   multi-increment (likely multi-session) effort; interpolation is the single biggest remaining feature. Known
   features still to add: string interpolation, array-payload `.len()`/index, `arr[i].field` DIRECTLY (temp
   element → materialise-retain-drop), an empty struct-array as a struct FIELD value (em_struct_array),
   `.len()` on a call-result string (temp-receiver drop), string
   interpolation (206 sites), a SCALAR generic type arg (Box<int> — packed, deferred; unused by the compiler),
   and Option/Result generic ENUMs. Orthogonal follow-up: float-literal emission needs a `%.17g` builtin
   (Ember interpolation is `%g`, so `FLOAT_VAL` can't be produced from a bare `{f}`). OFI-166 (the C
   operand-eval-order discipline — sequence side-effecting subexpressions into ordered statements; gcc
   evaluates a binop/call's operands right-to-left where clang/the VM go left-to-right) is observed
   throughout, verified on Linux gcc via Docker before each push. After structs: enums/match, then
   generics/monomorphization.
4. **M4 deferred-low — nested-inline struct flattening.** The `UNBOX_STRUCT` path for a `let ln =
   Line{a:P, b:P}` of recursively-all-scalar nested value structs; only ~3 corpus files need it (most real
   structs have a string/array/enum field → boxed), so it stays low priority.
5. **Cleanup OFIs.** **OFI-165** (method-call args lack the owning-temp keep+drop discipline — worked around
   with a named-local idiom), **OFI-163/164** (generic Option/Result payload INCREF; inline-struct array
   literals), **OFI-153** (generate the lexer keyword table from `vocab.def` + a sync gate), and **OFI-156**
   (cross-module bare-variant construction, currently routed through constructor fns).
