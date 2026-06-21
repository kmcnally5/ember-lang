# The Ember Manifesto

*Design philosophy and founding decisions. Draft 1 — June 2026.*

Ember is a statically-typed, brace-delimited systems language. This document records **what
we learned from the languages that came before us** — chiefly Rust, the defining systems
language of this era — and **the deliberate choices we are making in response.** Every
language-design decision in Ember should trace back to a principle here.

---

## 1. The landscape we're entering (2026)

By 2026 the systems-language conversation is dominated by three poles:

- **Rust** — has moved from "hype" to "mandate." It's the only language seriously challenging
  C++ for memory-safe systems control. Google reports Android memory-safety bugs fell below
  20% of all vulnerabilities for the first time, with ~1000× lower memory-safety bug density
  in Rust vs. C/C++ code, 4× lower rollback rate, and 25% less time in review. The Linux
  kernel, Windows kernel, and Android have all committed real code. Rust *won the argument*
  about memory safety without a garbage collector.
- **Zig** — the pragmatic "better C." Radically simple, explicit, control-focused. No borrow
  checker, no hidden control flow, `comptime` instead of macros. Replaces C where Rust
  replaces C++.
- **Go** — still the productivity champion for networked services: trivial concurrency, fast
  compiles, a real GC. The cost is runtime overhead and less control.

Ember's thesis: **Rust proved the destination (compile-time safety, zero-cost abstractions)
is right, but the road there is harder than it needs to be.** We aim for Rust-grade safety
with something much closer to Go/Zig-grade *approachability and iteration speed.*

---

## 2. What Rust got right (we keep these)

These are settled questions. Ember does not relitigate them.

1. **Memory safety without a GC, enforced at compile time.** Ownership-based lifetime
   management eliminates use-after-free, double-free, null-deref, and data races as a *class*.
   This is Rust's central victory and Ember's non-negotiable baseline.
2. **Zero-cost abstractions.** High-level constructs that compile to code as tight as
   hand-written low-level code. No runtime tax for expressiveness.
3. **Sum types + exhaustive pattern matching.** `enum`/`match` (algebraic data types) are the
   single most-loved feature of modern languages. Ember has them as first-class citizens.
4. **Errors as values, not exceptions.** A `Result`-style type forces callers to acknowledge
   failure. No invisible non-local control flow.
5. **No null.** Optionality is an explicit type (`Option`-style), not a hole in every
   reference.
6. **Immutable by default.** Mutability is opt-in and visible.
7. **First-class tooling as part of the language, not an afterthought.** Cargo is half of why
   Rust succeeded. Ember ships its build system, package manager, formatter, and test runner
   *in the box, from day one,* with one canonical way to do each.
8. **Safety-by-default with an explicit escape hatch.** Rust's `unsafe` is the right model: a
   small, greppable, auditable region where you take the wheel. Ember keeps this.

---

## 3. What Rust got wrong (we improve on these)

Drawn from the Rust team's own 2026 retrospective and the wider 2025–2026 critique. These are
Ember's reasons to exist.

### 3.1 The borrow checker is too steep, too early
New Rust developers spend **weeks to months "fighting the borrow checker"**; code that's
correct in C/Go/Python gets rejected for reasons newcomers have never had to think about.
Experts stop complaining — but the funnel loses people before they become experts.

> **Ember's answer:** Safety must be *progressively disclosed*. A beginner should write
> correct, safe programs on day one without learning lifetime theory. Lifetimes/regions
> exist, but explicit lifetime *annotations* are the rare exception, not a daily tax —
> inference does the work, and the common patterns (tree-shaped ownership, function-local
> borrows) need **zero annotations**. When the checker rejects code, the error explains the
> fix in terms of the program, not the theory. We treat "the diagnostic" as a core language
> feature, not compiler output.

### 3.2 Async is a second, harder language ("function coloring")
Async/await splits the world into colored functions; async can't be called from sync without
ceremony; the ecosystem fragmented around runtimes (Tokio won by momentum; async-std was
discontinued in 2025); and you **lose the stack trace** when debugging. Async Rust "has many
more rough edges than sync Rust and requires a different mindset."

> **Ember's answer:** Concurrency is a *language* concern, not a library concern, and there is
> **one** runtime, in the standard library. We favor a model without function coloring —
> lightweight tasks / structured concurrency where a normal function can be suspended by the
> scheduler (Go-goroutine / green-thread ergonomics) — so there is no async/sync split to
> bridge and no runtime-lock-in to fragment the ecosystem. Concurrent code keeps real,
> debuggable stack traces. **Cancellation is structured and safe by construction**, not a
> footgun.

### 3.3 Compile times don't scale gracefully
30–120s for medium projects, 5–10 min clean builds on large dependency trees. Even the Rust
team flags this as a future scaling risk; it's especially painful for GUI/visual iteration.

> **Ember's answer:** **Fast iteration is a design constraint, not a nice-to-have.** We design
> the language to be cheaply compilable: a clean module/compilation-unit boundary,
> incremental-by-default builds, a fast debug path that prioritizes build speed over runtime
> speed, and we resist language features whose cost is paid in compile time across the whole
> program. Target: sub-second incremental rebuilds for normal edits.

### 3.4 Too many ways, too much surface area
Async complexity, trait/lifetime interactions, and accreted features make the language large.
"Simple business logic that should take an hour takes half a day."

> **Ember's answer:** Bias toward **one obvious way** (Go's discipline) over **every powerful
> way** (C++/Rust's accretion). New features must pay for their complexity budget. We'd rather
> ship a smaller language people hold entirely in their heads than a maximal one they navigate
> by IDE.

### 3.5 Ecosystem trust & maturity is unguided
Users struggle to pick "trustworthy, appropriate crates"; whole industries lack mature support.

> **Ember's answer:** A curated, versioned **standard library that's actually batteries-
> included** (the things every program needs — collections, async runtime, HTTP, JSON, time,
> randomness — are blessed and in-tree), reducing how often you reach into an unvetted
> dependency at all. Package provenance and a trust signal are first-class in the package
> manager, not bolted on.

---

## 4. Ember's founding principles (the firm choices)

1. **Safe by default, simple by default, fast to build — pick all three.** If a feature
   forces a trade among safety, approachability, and iteration speed, that's a design smell;
   redesign it.
2. **Progressive disclosure.** The first program needs almost no theory. Power is available
   when reached for, never required up front. You should be productive in *hours*, not months.
3. **One way to do the common thing.** Minimize the language; maximize the orthogonality of
   what's left.
4. **Concurrency belongs to the language.** One runtime, no function coloring, structured and
   cancellation-safe, with real stack traces.
5. **The compiler is a teacher.** Diagnostics that explain the fix in the user's terms are
   part of the language spec, not an implementation detail.
6. **Iteration speed is sacred.** Sub-second incremental builds are a requirement we design
   toward, not hope for.
7. **Batteries included, provenance visible.** A real standard library; a package manager that
   tells you what you're trusting.
8. **Errors are values; there is no null; data is immutable until you say otherwise.**
9. **An escape hatch exists and is greppable.** `unsafe`-style regions for when you must,
   small and auditable.
10. **Braces.** `{ }` delimit blocks. Familiar to everyone coming from C, C#, Java, Rust, Go.

---

## 5. Decisions made

### ✅ Memory model — *decided June 2026*
**Ownership as the default, with inferred lifetimes, plus blessed `Rc`/arena tools for
graph-shaped data.** A program gets Rust-grade compile-time safety, but lifetime *annotations*
are the rare exception — inference handles the common tree-shaped and function-local cases with
zero annotations. When data is genuinely graph-shaped (where a pure borrow checker would force
a fight), the language provides in-tree reference-counting and arena/region tools as the
sanctioned answer instead of escalating the borrow-checker battle. This is the concrete
mechanism behind §3.1.

### ✅ Concurrency primitive — *decided June 2026*
**Structured concurrency via `nursery`-style blocks.** Concurrent tasks are scoped to a block
and cannot outlive it; the parent does not proceed until its children complete or are
cancelled. This gives us §3.2 in full: no function coloring (a normal function can be spawned),
cancellation that is safe by construction (scope exit cancels and joins), real debuggable stack
traces, and **one** language-owned runtime so the ecosystem can't fragment around competing
executors.

> **Implementation status (honest).** The *model* above is the goal; the **M:N green-thread
> scheduler is now BUILT** (OFI-071, `make mn`, 2026-06-20) — a worker pool (≈ncpu OS threads)
> multiplexing many lightweight fibers that *park* (not block their OS thread) on channels, with
> structured nursery join, structured cancellation (a failing task tears its group down at yield
> seams), and global deadlock detection. So `spawn` is cheap (8000 fibers in one nursery run on a
> handful of threads — verified) and there is no function colouring. It reuses the VM's cooperative
> `VM_YIELD` as the suspension point, so no stackful context-switch is needed. It is currently
> **gated behind its own build flag** (the default `--emit=run` stays cooperative N:1 and
> `-DEMBER_PARALLEL` stays 1:1 thread-per-spawn) until it clears a broader soak; verified TSan-clean,
> ASan-clean, byte-identical to the serial runtime on the test suite (modulo legitimately
> nondeterministic concurrent output ordering), and stress-passing. Remaining before the default
> flips: a wider soak + right-sized/segmented fiber stacks for the 100k-fiber tier (a `Fiber`
> currently embeds a full value stack). See `docs/architecture.md` and **OFI-071**.

### ✅ Generics — *decided June 2026*
**Definition-site-checked generics with interface/trait bounds, where code representation is a
build-profile decision the compiler makes — not programmer syntax.**

Two parts:
1. **Checked once, at the definition,** against declared interface bounds — *not* re-checked at
   each instantiation (the C++ template-error trap). This keeps diagnostics clean (§3.5, "the
   compiler is a teacher") and decouples type-checking from code generation.
2. **Representation is profile-dependent:** debug builds use a single **erased / dictionary-
   passing** copy (uniform value representation) for sub-second rebuilds (§3.3); release builds
   **monomorphize** for zero-cost abstraction and full runtime speed (§2.2). The programmer
   writes generics one way; the compiler chooses representation per profile.

This is the only generics strategy that satisfies founding principle #1 ("pick all three").
The accepted cost: the runtime needs **value-witness machinery** (generic size/alignment/copy/
drop) so the erased path works (the Swift-proven but non-trivial route), and debug vs. release
builds can show different performance characteristics.

### ✅ Numeric types — *decided June 2026*
**Explicit-width numeric types, with `int` and `float` as ergonomic aliases.** A systems
language must let you state precision and layout, so the full family exists: `i8 i16 i32 i64`,
`u8 u16 u32 u64`, `f32 f64`. But the common case stays friendly (progressive disclosure, §4):
**`int` is an alias for `i64`** and **`float` is an alias for `f64`**. Write `int`/`float` by
default; reach for an explicit width when precision or memory layout matters. `bool` is its own
type and is never numeric (no coercion — `if 1` is an error). *Today only `int` executes; the
width family and `float` land with the value-model expansion, but the model is fixed now so it
doesn't have to be retrofitted.*

**Integer overflow traps** (aborts with a runtime error) rather than silently wrapping or
invoking undefined behaviour — the safety-first default, matching Ember's correctness focus
(Swift, and Rust in debug, do the same). Explicit wrapping operations and a faster
wrap-in-release mode are possible later; trapping is the floor. *Decided & implemented June 2026
(via overflow-checked arithmetic; `float` runs as f64, `int` as i64, no implicit int↔float
coercion).*

## 5b. Syntax & the LLM-first principle — *decided June 2026*

**Ember's primary audience is an LLM with no prior Ember training, then humans.** Coding is
moving to AI; we design for the model that has never seen Ember but has read every other
language.

**Governing principle — "least surprise, for the model":** a zero-shot LLM predicts semantics
from surface syntax using priors from existing languages. The correct keyword/form is the one
whose cross-language *connotation matches Ember's actual behavior.* Where connotation and
behavior agree, zero-shot generation is correct; where they conflict, the syntax lures the
model into bugs. This principle outranks both FROG continuity and brevity.

Decisions that follow from it (all embodied in [examples/](examples/)):

- **`match` / `case`** for pattern matching — *not* `switch`. `switch` carries a strong prior
  of fallthrough / `break` / `default` / non-exhaustive value-compare, all false in Ember;
  `match` correctly connotes exhaustive, no-fallthrough, pattern-binding. We keep FROG's `case`
  arm keyword (knowledge preserved) and only replace the misleading head keyword.
- **Keyword ownership model** — borrow immutably by default (no annotation), `mut` for a
  mutable borrow, `move` to transfer ownership. No `&`/`&mut` *reference/ownership* sigils and no
  visible lifetime syntax, which would drag in Rust's lifetime/aliasing priors (the #1 LLM Rust
  error class). (`&` is not unused: it is plain bitwise-and, as in C/Go — a value operator, never
  a reference. Ownership is keyword-based precisely so the sigils stay free for arithmetic.)
  The safe behavior is the zero-annotation default; the dangerous direction (a move) must be
  typed explicitly, so a Rust-trained model fails safe. **The qualifier is written before the
  binding, uniformly** — `mut self`, `move items: [string]` — because it describes the
  *parameter*, not the type. (Earlier drafts put it on the type for named params; that was
  inconsistent with `mut self` and is fixed.)
- **Interface conformance is nominal and explicit, via `implements`** — `struct User implements
  Ord, Eq { … }`. Ember does not infer conformance structurally (Go-style): an explicit
  declaration gives better diagnostics (§3.5) and is unambiguous for a zero-shot model, and a
  dedicated keyword beats overloading `:` (already used for `field: type` and `T: Bound`).
  Conformance is declared in the type header, not in separate `impl` blocks; retroactive
  implementation for types you don't own is a possible later `extend`-style addition.
  An interface serves **both** polymorphism modes: a static **generic bound** (`<T: Ord>`,
  monomorphized through a witness, no indirection) and a runtime **value type** (`let s: Shape`,
  `[Shape]` — *dynamic dispatch* through a boxed `{receiver, vtable}`, Go/Rust-style, polymorphism
  without inheritance). Value-type use is restricted to **object-safe** interfaces (no `Self`
  beyond the receiver), since the concrete type is erased; non-object-safe interfaces remain usable
  as bounds. Implicit upcast where the interface type is expected — no cast syntax (least surprise).
- **`let` / `var`** for immutable/mutable bindings — precise match to Swift/Kotlin priors,
  single-token each (lower error rate than the droppable two-token `let mut`). `let` carries
  forward from FROG.
- **Errors as values:** `Result<T,E>` + `?`, `Option<T>`, and **no `null`** — extends FROG's
  explicit tuple-error style with type safety and the boilerplate-killing `?` operator.
- **`nursery { spawn … }`** for structured concurrency with typed `Channel<T>` — the
  scoped evolution of FROG's `async()`/`channel()`.
- **Signatures are fully typed; locals may infer.** Contracts (function/method/field types)
  are where types matter most to humans and models, so they are mandatory; local `let`/`var`
  may use inference.
- **`{name}` string interpolation**, `->` return types, braces for all blocks.
- **No statement terminators — newlines are significant (Go-style).** Ember has no
  semicolons (the examples never use them). The lexer emits an implicit terminator at a line
  break only when the line's last token can end a statement (identifier, literal, `)`, `]`,
  `}`, `?`, or `return`/`break`/`continue`); after a token that implies continuation (an
  operator, `,`, `(`, `=`, `->`, `&&`, …) the newline is suppressed, so multi-line expressions
  read naturally. This keeps the language semicolon-free and LLM-legible: a model writes
  ordinary line-broken code and it parses. *Decided while building the parser, 2026-06-10.*

## 5c. Execution model & build method — *decided June 2026*

Ember compiles to **bytecode executed by a stack VM**. It is not a tree-walking interpreter —
the goal is compiled-language speed, and a tree-walker would be both throwaway and a second
backend to keep in lockstep. There is **one backend**.

*Amended June 2026 (native backend).* Ember now also has a **native release path**: a second
lowering, AST→C, that emits a standalone binary (`emberc -o`). This does **not** reopen the
dual-backend trap above. The rule that earns the lesson is narrower than "one backend" — it is
**one front-end and one reference semantics**: the lexer/parser/checker are shared, and the **VM
remains canonical** (it is what `--check`/`--replay`/`--prove`/`--trace` run, and what the native
output is diffed against, bit-for-bit, by `tests/native/`). The C backend is a *consumer* of the
same checked AST, not a parallel language. See [architecture.md](docs/architecture.md) "Decision:
a native backend that lowers the AST to C".

**Pipeline:** `source → tokens → AST → type-check → lower → bytecode → VM`. Codegen lowers
*typed* AST directly to stack bytecode (clox/FROG-style); no separate optimizing IR yet (that
is a later concern and just more surface to keep in sync).

**Method — the walking skeleton.** We learned from FROG that building the whole language as an
interpreter and *then* bolting on a VM causes a painful retrofit, dual-backend drift, and
opcode staleness. So Ember grows the **entire pipeline end-to-end from a trivial subset
outward**: every feature is added through *all* stages in one slice and is not "done" until it
executes. The front-end can never get ahead of the backend.

**Drift prevention is a compile error, not a tool.** FROG needed bespoke Go tooling
(`vmcoverage`) to stop opcode/AST drift. In C we get it for free:
- **One source of truth for opcodes** (an X-macro table) generates the opcode enum, names,
  operand metadata, and disassembler — they cannot drift because there is one list.
- **`-Wswitch` (via `-Wall -Werror`) with no `default:` arm** on the codegen and VM-dispatch
  switches makes the build fail the instant an AST node or opcode lacks a handler. This *is*
  FROG's "100% coverage" guarantee, enforced by the compiler. (We deliberately omit the
  `default:` arm there; switches that legitimately want a fallthrough, like the parser's, keep
  theirs — so we don't use the broader `-Wswitch-enum`.)
- **`--emit=bytecode` disassembly goldens** and **`--emit=run` execution goldens** lock the
  backend against regression alongside the token/AST goldens.

**Observability is a seam, not a bolt-on.** Like the VM itself, execution tracing is threaded
through from the start rather than retrofitted (the FROG `--tape` lesson: bolted on late, it
could only observe coarse, pre-existing checkpoints). The `Chunk` carries a **source line
table** (instruction → source line) filled by codegen, and the VM's dispatch loop fires one
**observer-only** event per instruction to an optional sink (NULL = ~zero cost). `emberc --tape`
(alias `--emit=trace`) records the execution **tape** as JSON-Lines — `{ip, op, line, stack}`
per step — source-correlated and growing automatically with every opcode. For an LLM-first
language this is a feature, not just a debug tool. Richer *semantic* events (error propagation,
`nursery` task lifecycle, `?` boundaries) and user-registerable hooks (an Ember function
subscribing, FROG-style) layer onto the same seam as those features land; we don't design the
event catalogue up front.

The **UI tape** (§5g) is the first such richer recorder built on this idea: at frame
granularity it logs the input that drove each frame, every draw command issued, and the
high-level interactions (`click`/`toggle`/`focus`/`menu`) — same JSON-Lines shape, so an
LLM reads "what the UI did and why" exactly as it reads the instruction tape. The
per-instruction tape is too fine for a 60fps loop; the frame tape is the right altitude.
This is a concrete instance of the bet: a graphical program that explains itself as data.

## 5d. Modules & visibility — *decided June 2026*

A source file is a **module**. `import "path" as name` binds another module under an **explicit
alias**, and its members are referenced **qualified** through that alias (`mathx.square`). Origin
is always visible at the use site — the LLM-first "least surprise" principle (§5b): a model reading
`mathx.square(x)` knows exactly where `square` lives, and there is no implicit flat merge to create
ambiguity or collisions. Modules are loaded transitively (deduped by path) and compiled as one
whole program for now; mutual imports are fine, and a clean module boundary keeps §3.3 (graceful
compile times) reachable when separate compilation lands.

**Visibility is the leading-underscore convention:** a top-level declaration whose name begins with
`_` is **private to its module**; everything else is exported. This is *name-coupled* visibility —
the same idea Go proves at scale (it uses capitalization), and the `_private` convention every LLM
knows from Python — so it adds **zero keyword surface** (§3.4) and self-documents at the call site.
It is *enforced* (not a mere convention): a qualified reference to a `_name` in another module is a
compile error. Two deliberate consequences: **public is the default** (opt into privacy with `_`),
and changing a declaration's visibility means renaming it (a tolerated cost). The rule applies only
to **top-level declaration names**, leaving `_`/`_x` free for a future wildcard / ignored-binding
meaning in pattern and local contexts (no conflict — different scope, as in Python). This carries
forward FROG's convention rather than discarding hard-won familiarity.

## 5e. Contracts & machine-verifiable specification — *decided June 2026*

**Functions may carry executable contracts — `requires` preconditions and `ensures`
postconditions — and this is Ember's flagship differentiator.** A contract is an ordinary
bool expression written between the signature and the body; `ensures` clauses may name
`result`, the return value:

```ember
fn clamp(x: int, lo: int, hi: int) -> int
    requires lo <= hi
    ensures result >= lo
    ensures result <= hi
{
    if x < lo { return lo }
    if x > hi { return hi }
    return x
}
```

**Why this, and why now — the reason traces to §5b (LLM-first).** Coding is moving to AI, and the
2025–26 evidence is blunt: LLMs generate Python well because its syntax is free, and generate
Rust poorly because *its ownership/mutability syntax is hard for a model to comprehend and
produce*. Ember's bet is to be the first language that is **both** memory-safe-without-GC **and**
LLM-legible. Contracts complete that bet, because the AI-native-language frontier converges on two
requirements: **structured tracing as a first-class effect** (Ember already has it — §5c, the
tape) and **every function carrying a formal specification** — because a model is far better at
checking *"does this implementation satisfy this constraint?"* than *"does this code match this
vague comment?"*. Contracts are that specification, and fused with the tape they close a loop **no
other language offers**: a model writes the spec and the implementation separately, runs the
program, and a violation returns as a **structured, machine-readable trace event** (`{"event":
"contract_violation", "fn":…, "detail":…, "stack":[…]}`) naming exactly which clause failed, on
what values. The model wrote the contract; the runtime tells it the truth in a format built for a
machine. Design-by-contract (Eiffel) and verifiers (Dafny, SPARK) long predate us; the novelty is
the *fusion* — LLM-first ergonomics + lightweight contracts + a machine-readable execution trace,
for AI authorship.

**Decisions (all implemented June 2026, free functions + methods, runtime-checked):**
- **Keywords `requires` / `ensures`, and `result`** for the return value in `ensures` — the
  least-surprise choice (§5b): a zero-shot model has seen them in Dafny/SPARK/Eiffel and reads the
  pre/post connotation correctly.
- **Debug builds check; release elides.** Contracts are checked at runtime in the default (debug)
  build — `requires` on entry, `ensures` before every return; a violation aborts with a clear
  error *and* emits the trace event. A `--release` build elides them entirely (zero cost), the
  proven Rust-`debug_assert` / Swift-precondition model. **Type-checking always runs** — a
  contract that isn't a `bool` is a compile error in every profile; only the runtime check is
  elided. This is §4.1 ("safe, simple, fast to build — pick all three") applied: correctness in
  development, no tax in production.
- **Contracts are bool expressions** that may call ordinary predicate functions (`is_sorted(xs)`),
  so the spec language *is* Ember — nothing new for a model to learn. They should read, not mutate
  (a borrow-only discipline); enforced purity, struct invariants, `old(x)` pre-state, and static
  proof of the clauses we can discharge are deliberate later layers, not the foundation.

## 5f. Generic ownership: move-by-default and the `Copy` bound — *decided June 2026*

Ownership safety (§5, §2.1) must hold **inside generic bodies too** — that is non-negotiable. A
type parameter `T` is therefore a **move type by default**: a generic body is ownership-checked
exactly like concrete code, so a `T` value can't be silently aliased or returned from a borrow.
(Before this, `T` was assumed freely copyable, and a generic that aliased a struct argument
*double-freed it at run time* — the precise memory-unsafety the language exists to prevent.) A
generic that returns its argument therefore takes it `move`; in practice generic code is linear,
so the standard library needed no change.

The ergonomic exemption is the **`Copy` bound**: `fn id<T: Copy>(x: T) -> T` declares `T`
copyable, so it may be aliased and returned by value without `move`. `Copy` is written like any
bound and composes (`T: Ord + Copy`); it is a *contextual marker*, not a keyword (zero keyword
surface, §3.4). At a call, a non-copyable argument for a `Copy` parameter is a clean error.

**The Ember-native part:** `Copy` means **every type *except* a struct or array.** Scalars copy
bitwise; strings, enums, and closures are immutable and reference-counted, so "copying" one is a
cheap, sound `incref`. Only the unique-owner *aggregates* are non-`Copy`. This is broader and
simpler than Rust's `Copy` (which excludes `String`), and it falls out of Ember's value model:
the move/Copy split is exactly the unique-owner / shareable split the runtime already draws. This
is the concrete shape of the **mutable value semantics** Ember shares with the post-Rust frontier
— ownership safety with no lifetime annotations, now sound through generics.

## 5g. Graphics & the native backend — *decided June 2026*

**Ember does graphics, and it does them immediate-mode.** This is a deliberate bet that the place
Rust most visibly fails — GUI — is where an LLM-first language can most visibly win.

**Why immediate-mode.** A UI is graph-shaped, shared, mutable state, which is the single worst case
for *any* ownership model (Rust's borrow checker and Ember's move/borrow alike). Rust's GUIs
converged on immediate-mode (egui) precisely because it sidesteps that: the UI is a **pure function
of state that exists for one frame** — no retained widget tree, no `Rc<RefCell>` graph. For Ember
this is doubly right: (1) it keeps the ownership model (§5, §5f) clean — the graph-shaped state
that fights every borrow checker simply never appears; (2) it is the most LLM-legible shape there
is — `if ui.button("Save") { save() }`, no callbacks-with-lifetimes, no widget lifecycle, app state
is just plain Ember values the loop owns. Retained-mode trees with event handlers are exactly the
lifetime-entangled code LLMs fail at — the same reason they fail at Rust.

**Architecture — Ember describes, C renders.** The heavy work (layout, GPU, the OS event pump)
lives in native C; Ember only *describes* each frame, so 60fps stays reachable on the bytecode VM
(the Dear ImGui model). Ember drives the loop itself (`loop { if win.should_close() break; …
draw … }`) rather than a host callback — the loop body *is* the frame, the most legible shape — and
input is **polled and returned as values** (`key_down(k) -> bool`), never callback-registered, in
keeping with Ember's "errors are values, no hidden control flow."

**The backend is a single, blessed, in-tree dependency, hidden behind an Ember API.** Per §3.5
(batteries-included, not a pile of unvetted crates), Ember reaches the screen through **one**
curated C library — **raylib** — exposed as native primitives, exactly like `print`/`read_file`.
This is Ember's first third-party C dependency, taken deliberately. Text is rendered with a real
**embedded TrueType font** (Inter, OFL-1.1, baked into the binary so it stays self-contained and
zero-install) — not a bitmap font — through the same single `draw_text`/`measure_text` chokepoint,
so the whole toolkit gets crisp, properly-metricked type for free. Crucially the backend is an
*implementation detail*: users `import "std/draw"` (primitives) and `import "std/ui"` (immediate-mode
widgets, layered in Ember on top), never raylib — so the engine is swappable (raylib → SDL3) without
touching a line of Ember. Graphics is an **opt-in build** (`make graphics`, `-DEMBER_GRAPHICS=1`):
the default compiler stays dependency-free, and the test suite never needs a display.

The superpowers stack: **contracts** verify UI-state invariants — `std/ui`'s `slider` carries an
executable spec (`requires lo < hi`, `ensures` the result stays within `[lo, hi]`), `window_begin`
asserts its window registry's parallel arrays stay the same length, and even the void `begin`
mutator states a frame-start postcondition (nothing hovered, cursor at the margin), with any
violation surfacing as a structured `contract_violation` event on the tape; the **execution tape**
records every frame's draw calls and input events as machine-readable data a model debugs from; and
**structured concurrency** runs background work off the UI loop with no async colouring. No other
language combines an LLM-first surface, ownership without lifetimes, a machine-readable trace, and
an immediate-mode UI. *Spiked June 2026 (window + rectangle + keyboard input); the `std/ui` widget
layer's foundation followed — a `Ui` context value (held by the loop, no globals: the IMGUI
"state monad"), hash-based widget IDs, the hot/active interaction model, a layout cursor, and the
first widgets (button, label, checkbox, slider), all reporting interaction as values. Swappable
**themes** (a `Style` struct the `Ui` holds — theming is data), **text input** (`text_field`, with
single-focus edit state on the `Ui` — all single-line input needs), and **rich layout** (every widget
advances one shared cursor; `same_line` for rows, `indent`/`unindent` for groups, `spacing` for gaps —
no layout stack required) followed. Then the hard one: **overlapping, draggable, z-ordered windows**
— the case an ownership model dreads. Done by making the draw model *deferred*: `draw_rect`/`draw_text`
buffer commands tagged with a layer, and `frame_end` stable-sorts them so a window on a higher layer
renders over one below regardless of code order. Input routes *inverse* to drawing — the topmost
window under the mouse (resolved from last frame's rects) captures the click, so it can't fall through
to an occluded window. Windows **auto-size to their content** and **clip** it to their body (a scissor
push/pop pair in the draw buffer that nests by intersection), so nothing bleeds onto a neighbour.
Window position and z-order persist across frames in a small registry on the `Ui` (parallel arrays,
no graph). **Dropdown menus and tooltips** layer on as modal top-layer transients (`menu_begin` /
`menu_item` / `menu_end`), reusing the layer machinery; dismissal uses last frame's item extent.
Remaining: scroll regions (now just a clip plus a content offset) and a window resize grip.*

## 5h. Foreign function interface (C) — *decided June 2026*

Ember prizes an **empty dependency tree** (§3.5, §4) and a self-contained runtime — so calling
into C is a deliberate, bounded door, opened the way the graphics backend was (§5g): in-tree,
explicit, and not the default path. The decision: a program declares foreign functions in an
**`extern "c"` block**, naming the C-side signature in ordinary Ember syntax —

```ember
extern "c" {
    fn sin(x: f64) -> f64
    fn atan2(y: f64, x: f64) -> f64
}
```

— and then calls them like any function (`sin(x)`). The `extern` declaration **is the trust
boundary**: there is no raw `unsafe` block; the signature you write is the contract Ember
type-checks against, and a mismatch with the real C function is the one place Ember's guarantees
stop (documented as the escape hatch). The reasons this is the right shape: it reads the way a
zero-shot model expects (§5b — `extern "C"` is the C/C++/Rust convention), it keeps foreign calls
*visible at the use site* (a declared block, not an ambient import), and it gives the compiler a
typed boundary to marshal across.

**Scope, opened incrementally.** The first slice is **scalar arguments and returns against the C
math library** (`libm` is part of the standard C runtime — no new dependency): `extern "c"`,
type-checked scalar marshalling, and an `OP_CALL_C` dispatch through an in-tree registry of typed
wrappers (no `libffi`, no `dlopen` — the empty-tree principle holds). The next brick is **structs
by value** — exactly where the *C ABI matters*. The dependency-free way to get it **exactly right**:
**delegate the ABI to the system C compiler.** At the `extern` boundary Ember flattens a struct
argument to its scalar leaves (it already holds all-scalar structs as a flat run of slots — §5c,
value-types); each registry wrapper reassembles a *concrete C struct* from those leaves and passes
it **by value**, so the C compiler generates the platform's exact aggregate calling convention
(arm64 AAPCS64, x86-64 SysV, …) for free, and flattens any struct result back to leaves. So Ember
needs no hand-rolled register/stack marshalling and no C-ABI layout table — the boundary is defined
by the **leaf scalar sequence**, and the C side owns the ABI.

The third brick — **pointers, buffers, and opaque handles** — extends the same leaf model: a
`string` passes as a borrowed `const char*`, a packed scalar array (`[u8]`/`[i32]`/…) passes as a
borrowed buffer (`mut` if C writes it), and an opaque `Ptr` round-trips a C handle (`FILE*`, …) that
Ember never dereferences. Each is **borrowed for the duration of the call** — Ember keeps ownership
and frees nothing C owns — so the `extern` block stays the whole trust boundary with no `unsafe`.
This is enough to bind real C (libc file I/O, string functions). Returning C-owned memory (a
`char*` Ember must copy or free) and arbitrary dynamic linking remain deliberate future widenings,
never the default.

A `Ptr` handle is **linear** — used *exactly once* — extending the keyword ownership model (§5) to a
resource the runtime can't see inside. *At most once:* a closing call takes it `move`, so reuse after
close is a caught double-free. *At least once:* an owned handle that reaches the end of its scope
un-closed, on any path, is a compile error — the leak the equivalent C silently commits. The compiler
proves consume-on-every-path entirely at check time (no runtime cost, no destructor — Ember can't know
a foreign handle's closer); the cost is that a `Ptr` must live in a local and be closed or returned, not
stashed in a struct/`Option`/`Map`. This is the manifesto's bet in miniature — *least surprise for the
model* (write the obvious open/use/close and the compiler keeps you honest) over *least typing* — and it
makes the two oldest FFI footguns, double-close and leak, both unrepresentable.

## 5i. Capabilities & the agent era — *decided June 2026 (right-sized after a pre-mortem)*

**The agent-era goal:** Ember should let you bound and audit what *model-written, model-run* code is
allowed to do. A pre-mortem (researching Deno's permission model and WASI's component model) reframed
*how* to get there, and what to lead with:

- **The sandbox is delivered by the platform, not by pervasive in-language plumbing.** WASI Preview 2 /
  the Component Model is already a capability-based, ambient-authority-free, *polyglot* standard for
  running untrusted code — load a component, grant it exactly the capabilities it needs, at syscall
  granularity. The cheapest, most-standard way for Ember to "run agent code safely" is therefore to
  **target WASI/components** (also Ember's portability + interop play) plus a **Deno-style runtime
  permission baseline** natively. Building a heavy in-language object-capability system to re-derive
  this would be a chocolate teacup — high ergonomic cost for a benefit the platform already gives.
- **What in-language capabilities add that the platform can't:** per-module / per-call granularity
  *inside* one program (Deno's documented hole is that *all* code runs at one privilege — it can't
  restrict a single dependency), *dynamic* authority (a handle to one chosen file), and **authority
  visible in the type** for the model and the reader.

**The decision (right-sized):** authority is carried by unforgeable **capability values**, passed
explicitly — the object-capability model, **not** an effect-row type system — but adopted as a
**light, opt-in layer**, not a mandate that taxes every program:

1. **Gate the real ambient-authority holes** — the **FFI** first (`extern "c"`, §5h, the genuine
   escape hatch: make it grantable, not silent), then `Fs`/`Net`.
2. **Capabilities are ordinary owned/borrowed values** (they ride §5's ownership, not a new type
   layer); a root is **minted only by the runtime** and unforgeable (sealed types — no public
   constructor); lesser capabilities derive from greater, forming an auditable tree.
3. **Purity falls out** — a function with no capability parameters cannot touch the world; free, no
   annotation. This is also a *verification* primitive (§5j): pure functions are trivially fuzzable,
   testable, and replayable.
4. **Stay opt-in for now** — do **not** force `main(sys: Sys)` and capability-threading on hello-world
   (that would re-create a lifetime-class LLM error, the very thing §5b forbids). Coarse stdout stays
   ambient until WASI/runtime-perms make the strict mode cheap.

```ember
fn parse(src: string) -> Ast              // no capability ⇒ pure: a verification + safety primitive
fn fetch(net: Net, url: string) -> Bytes  // authority visible in the type; deny by not passing `net`
extern "c" uses ffi { fn cvec2_len(v: Vec2) -> f64 }   // the C escape hatch becomes grantable
```

**Why capabilities, not an effect system — the data settled this.** Row-polymorphic effect systems
(Koka/Links) reintroduce the exact disease Ember was built to cure: *"adding a new effect deep in the
call stack requires updating every function signature to the top"* — the async-colouring trap (§3.2)
generalised. Their inference (row unification) is hard and their errors cryptic (violates §4.5); OCaml
5 shipped effect *handlers* but **deliberately left effects untyped**; and effect rows are novel syntax
a zero-shot model barely knows (§5b). Capabilities-as-values avoid all of it — an ordinary typed
parameter, no inference, trivial diagnostics, free composition with ownership, and *dynamic* authority
static effects can't express.

**Sequencing & non-goals.** The FFI gate + the tape recording *which capability authorised each
effect* (the audit log, §5c) are cheap and land first; pervasive I/O gating and a strict
`main(sys)` mode wait until WASI/runtime-perms make them tax-free. Errors stay values (§5b) and
concurrency stays uncoloured (§5a), so capabilities are the *only* ambient-authority effect left —
which is exactly why the minimal, ownership-aligned mechanism is right and a general effect system
would be over-engineering. Explicit non-goals: **not** full algebraic effect *handlers* (heavy,
less legible — a possible later opt-in); **not** an effect-row type system; **not** a replacement
for OS/WASI sandboxing against genuinely adversarial native code.

## 5j. The verification & determinism loop — *decided June 2026 (the lead AI-era differentiator)*

**This is the strongest, most universal, most defensible bet for the agent era — and Ember is already
half-built for it.** The pre-mortem (§5i) found that *running* model code safely is largely a solved,
platform-level problem (WASI, microVMs); what *every* agent interaction needs, and what no mainstream
language gives, is a **closed correctness loop**: the model writes code + a machine-checkable
specification, and the language *automatically* exercises it and hands back **structured, replayable
counterexamples** the model can act on. It needs **no ecosystem** to be valuable, imposes **no
ergonomic tax** (it's opt-in and the spec doubles as documentation), and is the literal endgame of the
LLM-first thesis (§5b): the surface the model is *best* at is one with an executable spec and a
tight feedback signal.

Ember already has the two hard pieces no one else fused:
- **Executable contracts** (§5e) — `requires`/`ensures`/`result`, debug-checked, release-elided.
- **The machine-readable execution tape** (§5c) — every run emits structured JSON-Lines events,
  including `contract_violation`.

The decision is to complete the loop, in bricks, each useful alone:

1. **`assert(cond [, "msg"])`** — an in-language assertion that lowers to the contract-check
   machinery, so a violation is a structured tape event, not a bare crash. The primitive the rest
   builds on. *(First brick.)*
2. **Property-based checking driven by contracts** — `emberc --check` (and later a `check` block):
   generate inputs that satisfy a function's `requires`, run it, and report the first input that
   violates an `ensures`/`assert` as a tape counterexample. The contract *is* the spec; the tool
   fuzzes it. Scalars first, then structs/arrays; shrinking later.
3. **Deterministic record–replay** — the tape grows from an audit log into a *seed*: capture every
   nondeterministic input (clock, rand, I/O results, scheduling) so any run — especially a failing
   agent run — replays bit-for-bit for debugging. (Capabilities, §5i, are what make nondeterminism
   enumerable: only capability calls can be nondeterministic.)
4. **Machine-checked contracts (later, opt-in)** — discharge `requires`/`ensures` statically via an
   SMT backend for the fragment that's decidable; fall back to property-checking otherwise.

The payoff: an Ember function carries its spec, gets auto-fuzzed into counterexamples, and any run is
replayable — a feedback loop a model closes on its own. *No mainstream language combines an executable
spec, a structured trace, and deterministic replay; this is Ember's moat.*

## 6. Open questions (to decide next, deliberately)

These are *not yet decided* and should be settled before they're baked into the grammar:

- **Separate compilation & incremental rebuilds:** modules and their boundary are decided (§5d);
  what remains is where incremental rebuilds cut, once whole-program compilation needs to scale.
- **Metaprogramming:** Zig-style `comptime` vs. macros vs. neither (start with neither).

*(Resolved: polymorphism is **nominal** with explicit `implements` conformance — see §5b. The
module system and visibility are decided — see §5d.)*

---

*This is a living document. Amend it deliberately; cite it constantly.*
