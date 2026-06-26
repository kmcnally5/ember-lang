# Self-hosting Ember — a staged bootstrap plan

> Status: **plan only.** Nothing here is built yet. This document is the agreed route, not a
> claim about today's compiler. Self-hosting is earned one differential-green stage at a time,
> never by a big-bang rewrite, and only as far as it actually improves the language and toolchain.

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
- As each stage goes green, fold its differential into `make verify` so it cannot silently regress.
- Keep Crucible (memory ownership), Ledger (move-check), Ceilings, and opcheck pointed at both
  compilers as they diverge — the divergences are where the interesting bugs live, and the
  differential catches silent wrong-answer drift, not just crashes.
- Every new stage lands with its tests in `tests/selfhost/` (CLAUDE.md: a feature without a test that
  exercises it is not done).

---

## 7. Milestones (sequence, not dates)

- **M0** — freeze stage 0; Stage A spikes green on both backends.
- **M1** — self-hosted lexer; token diff empty over the full corpus; in `make verify`.
- **M2** — self-hosted parser; AST diff empty over the corpus.
- **M3** — self-hosted checker; diagnostic parity over the check/fault corpora. *(The long pole —
  budget the most here.)*
- **M4** — self-hosted bytecode backend; first bootstrap; **VM fixed point byte-identical.**
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

## 9. Proposed OFIs (ready to open; next free number is OFI-151)

These are raised per the CLAUDE.md OFI convention — gaps found while drawing up the plan. They are
*proposed* here, not yet written into [`docs/OFI.md`](../OFI.md).

- **OFI-151** — `system()` / process-spawn builtin. Lets a self-hosted *native* driver invoke `cc`.
  Not needed for VM-first; required only for an integrated `emberc -o bin` at Stage 5 (the
  alternative is emit-C-then-external-`cc`).
- **OFI-152** — bounds on generic enums / standalone methods. Open only if AST/visitor modelling
  actually needs an interface bound on a generic enum's type parameter.
- **OFI-153** — generate an Ember-consumable token/vocabulary table from `include/vocab.def`
  (lexer self-host prerequisite; mirrors `tools/gen_editor_assets`).
- **OFI-154** — `tests/selfhost/` differential tier + `make selfhost` gate, folded into `make verify`
  as stages land.

---

## 10. First concrete step

Freeze stage 0 and run the **Stage A recursive-AST spike** on both backends. It is the smallest piece
of work that retires the most residual risk, and it gates everything after it.
