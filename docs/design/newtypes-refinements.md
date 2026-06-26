# Design: Newtypes & ranged refinement types (OFI-149 / OFI-150)

*Author: Claude, 2026-06-26. **Status: BOTH SHIPPED 2026-06-26.** OFI-149 (newtypes) + OFI-150 (refinements); 421/0, 7 gates, ASan; adversarial reviews fixed 3+4 bugs. Implementation notes vs this draft: unwrap is the conversion-call form `int(u)` (not an `as` cast — avoids a new ExprKind); refinements are checked at construction by codegen `self`-substitution (stack-balanced, sound at any nesting — NOT the slot-based inline approach, which had soundness gaps); refinement bases are numeric/bool only and the ctor arg must be pure (string refinements deferred); predicates use `&&` (Ember has no `and`). Validated by an
adversarial workflow (the "chocolate-teacup check" — 6 interrogation seats incl. two fresh online
counter-evidence passes + a hard code re-read + a devil's-advocate verdict) before drafting; verdict
**(B) build, scoped**. Sequenced **after** the Fault precision Phase 2/3 work (OFI-110d / OFI-111a/b).
Traces to MANIFESTO §2.3 (sum types / make-illegal-states-unrepresentable), §4.2 (progressive
disclosure), §5b (LLM-first least surprise), §5e (contracts), §5f (the move/Copy value split),
§5j (the verification & determinism loop).*

---

## 1. Why — the validated case (and the honest reframing)

Two sibling features, both *constraints attached to data*:

- **Newtypes (part a, OFI-149)** — a *nominal* constraint: this `int` is a `UserId`, distinct from an
  `OrderId` and from a bare `int`.
- **Refinements (part b, OFI-150)** — a *value* constraint: this `int` is always `0..100`, everywhere
  it travels, checked where the prover can't prove it away.

**What the validation pass confirmed (build it):**
- The bug they kill — **unit confusion / swapped arguments** — is a real top-tier bug class *and* a
  top-3 LLM code-generation error class. Newtypes turn it into a compile error at **zero runtime cost**
  (the single-field-scalar value-struct already lowers to a bare 16-byte `Value`).
- Refinements **extend Ember's verification moat from functions onto data** — *"the type is the proof
  of validity"* (Alexis King's "parse, don't validate"). This is on-thesis for §5j.
- External validation is real: easier-to-verify languages produce better AI code (the *vericoding*
  benchmark: ~82% verified-codegen success in Dafny vs ~27% in Lean; natural-language prose does **not**
  help), and the US ONCD memory-safety push (Feb 2024) explicitly asks for software **measurability** —
  exactly what data-level contracts provide and what Rust does not answer.
- The conservative slice has a 40-year production pedigree: **Ada/SPARK** ranged subtypes
  (`type Port is range 1 .. 65535`) with compiler-inserted runtime checks, statically discharged where
  the prover can.

**What the validation pass corrected (scope it, and don't over-claim):**
- **The prover will NOT fire at most refinement sites.** Ember's `--emit=prove` is Fourier–Motzkin over
  linear integer arithmetic, and it only models functions whose body is a *single `return` expression*,
  ≤8 int params, no branches (`src/prove.c:354,373`). A smart constructor has branches; a field/return
  assignment is not a standalone function. So **most refinement checks degrade to the runtime
  `OP_CONTRACT_CHECK` path.** What ships is **Ada-grade ranged types with runtime checks + an occasional
  static-discharge bonus**, *not* "statically-proved data." If that reframing kills the excitement, that
  itself is the signal that the **newtype half is the prize and the prover half is the garnish.**
- **Full liquid types are the documented fad trap** — a 17-year research history, a "tooling not ready"
  verdict from refinement-type *advocates* in 2025 (Tweag/IFL), and a PLDI 2025 study cataloguing nine
  usability barriers (the killer is *epistemic*: "why won't the solver prove it?"). The proposal already
  scopes that away; the discipline is to **stay** scoped — no SMT, no quantifiers, no measures.
- **OFI-026 is NOT a blocker** (the validation's one false claim, traced to a stale comment now fixed as
  OFI-148). Unit-return `ensures` on a `mut self` mutator is **closed and sound** — `std/ui.em` uses it
  in production. So refined *mutable struct fields* are deferred not because of silent corruption, but
  only because Ember has no *automatic* struct-invariant mechanism yet (manual `ensures` on each mutator
  works but isn't ergonomic). That makes field refinements a clean **v2**, not a landmine.

---

## 2. What exists today (ground truth — verified against the source)

| Capability | State | Where |
|---|---|---|
| 16-byte tagged `Value` | shipped | `include/value.h:28` |
| Single-field scalar **declared** struct = zero-cost (`typedef struct { Value f0; }`) | shipped | `src/cgen_c.c:3105` |
| Erased generic instances are **boxed** until monomorphization | shipped (caveat) | `src/cgen_c.c:248` |
| Numeric widths semantic-only (ride an `nk` operand, trap at op time) | shipped | `include/ember_rt.h:311` |
| Contracts `requires`/`ensures`/`result` → `OP_CONTRACT_CHECK` (debug-checked, release-elided, always type-checked) | shipped | `src/codegen.c:1606,2326`; `src/vm.c:2301` |
| Violation → `contract_violation` tape event + unified `Fault` (`FCAT_CONTRACT`) | shipped | `src/vm.c:2319`; `src/fault.c:41` |
| Static prover `--emit=prove` (Fourier–Motzkin, linear int, ≤8 vars, single-`return` body) | shipped | `src/prove.c` |
| Property fuzzer `--emit=check` (300 trials, rejects `requires`-violations, shrinks) | shipped | `src/vm.c:4705` |
| LSP inlay `✓ proved` / `○ runtime-checked` via `prove_fn_verdicts` | shipped | `src/lsp.c:2094` |
| Unit-return `ensures` on `mut self` | shipped (OFI-026 closed) | `src/check.c:6987`; `std/ui.em:375` |
| `type X = Y` declaration / refinement / newtype / branded syntax | **ABSENT** | grammar `Type = [T] \| ident<...>` |
| Subtyping / non-nominal coercion | **ABSENT** (Ember is nominal) | — |

The grammar has **no `type` declaration of any kind today** — introducing one is the new surface both
parts share.

---

## 3. Part (a) — Newtypes / opaque types (OFI-149)

### 3.1 Syntax

```ember
type UserId  = int
type OrderId = int
type Email   = string
```

- **One new declaration form:** `type Name = BaseType`. `type` is a new keyword. It is **always
  nominal** — there is deliberately *no* transparent-alias form (one obvious meaning, §5b; a model never
  has to guess whether an alias is distinct).
- **Construction:** `UserId(x)` — call-form, mirroring the existing numeric conversions `u8(x)`/`i32(x)`,
  so it sits inside the LLM's prior.
- **Unwrap:** explicit, `id as int` (a checked nominal→base coercion). **No implicit interconversion**
  in either direction — that is the whole point.

### 3.2 Semantics

- **Nominal distinctness** lives in the checker's `assignable`: a `UserId` is not assignable to/from
  `int` or `OrderId` without an explicit `Name(...)` construct or `... as Base` unwrap. Passing an
  `OrderId` where a `UserId` is expected is a compile error — *this* is what kills swapped-args.
- **Zero runtime cost:** `type Name = Base` **erases to `Base`** in both backends. No wrapper object, no
  new opcode, no refcount — the distinction exists only in the checker. (We do *not* even need the
  single-field-struct path; a newtype is lighter than that.)
- **Smart-constructor-as-gate:** for a plain newtype `UserId(x)` is total (any `int` is a valid
  `UserId`). The *gate* property becomes meaningful once a refinement (part b) is attached, where
  construction inserts the check. True opaqueness ("only this module may construct one") rides the
  existing `_`-privacy convention if the constructor is wrapped; a dedicated `opaque` marker is a later
  addition, not v1.

### 3.3 Walking skeleton (§5c — every stage in one slice, nothing "done" until it runs)

1. **Parser:** `type Name = BaseType` declaration (`src/parser.c`, `parse_decl`).
2. **Checker:** register the nominal alias; teach `assignable` to reject cross-type; type `Name(x)`
   construction and `x as Base` unwrap (`src/check.c`).
3. **Codegen (VM + native):** transparent erasure to the base representation — no opcode, no `em_s`
   wrapper (`src/codegen.c`, `src/cgen_c.c`).
4. **LSP:** hover shows `type Name = Base`; the mismatch diagnostic reads "OrderId is not UserId"
   (`src/lsp.c`).
5. **Docs + tests:** a `THE_EMBER_BOOK` section; `tests/run/newtype_mismatch.em` (the cross-type pass is
   a compile error), `tests/run/newtype_roundtrip.em` (construct → unwrap), and a native-differential
   case confirming byte-identical / zero-cost output.

### 3.4 v1 EXCLUDES

- **Operator / trait passthrough auto-derivation** (Rust's #1 newtype complaint — `derive`-style
  forwarding). v1 ships explicit forwarding methods or an explicit unwrap. An `opaque`/extension-method
  story is a deliberate later phase.
- **Zero-cost through erased generics** — a `UserId` as a generic argument / `Map<UserId, _>` value is
  boxed until monomorphization lands. Allowed, but **not advertised as zero-cost**.
- **Non-nominal transparent aliases** — out of scope on purpose.

**Effort:** small-medium (~2–4 days).

---

## 4. Part (b) — Ranged-int refinement types (OFI-150)

### 4.1 Syntax

```ember
type Percent = int where 0 <= self and self <= 100
type Nat     = int where self >= 0
type Port    = int<1..65535>                 // ranged sugar = `where 1 <= self and self <= 65535`
type Email   = string where is_valid_email(self)
```

- Extends the part-(a) `type` form with an optional `where P` clause; `int<lo..hi>` is sugar for the
  common ranged case.
- `P` is an ordinary `bool` expression over `self` — **the spec language is Ember** (§5e), so there is
  nothing new for a model to learn, and it may call ordinary predicate functions (`is_valid_email`).

### 4.2 Semantics — desugar onto the contract machinery

- **Construction / return into a refined slot** inserts an implicit `requires P`, lowering to the
  existing `OP_CONTRACT_CHECK` at the construction site — runtime-checked in debug, **elided in
  `--release`**.
- **Reading** a refined value gives the consumer a guaranteed `P` (an implicit `ensures`), so downstream
  code needn't re-check — the type *is* the proof.
- **Violation** routes through the existing `contract_violation` Fault with a dedicated `code`
  (`refinement_violation`) and the tape; the offending value renders as data via the Phase-2/3 value
  walker (OFI-111b) — which is exactly why that work is sequenced first.
- **Prover bonus (not the headline):** where a construction site *is* a provable single linear form,
  `prove_fn_verdicts` discharges it and emits zero runtime check. Most sites won't qualify and will
  runtime-check. We **never** market this as "proved data."
- **`--check`:** a refined parameter's generator becomes domain-aware for ranged ints (so trials aren't
  almost all rejected by the implicit `requires`); the fuzzer already rejects `requires`-violations.

### 4.3 The one inviolable rule — honesty about what's proved

The LSP inlay shows `✓ proved` **only** where a verdict was actually discharged. Everywhere else it
shows, with a reason:

```
○ runtime-checked — prover can't discharge (branchy constructor / nonlinear)
```

Never render a proof that isn't there. Over-claiming static verification erodes the exact moat we're
extending **and** walks straight into the #1 documented liquid-type usability failure (solver opacity,
PLDI 2025).

### 4.4 Walking skeleton

1. **Parser:** `where P` clause + `int<lo..hi>` sugar on the `type` decl.
2. **Checker:** attach the predicate; insert the implicit `requires` at construction; allow read as the
   base type.
3. **Codegen:** emit `OP_CONTRACT_CHECK` at the construction site (reuse the contract path verbatim).
4. **Prover + LSP:** attempt discharge at the construction site; honest `✓ / ○ + reason` inlay.
5. **`--check`:** domain-aware generation for ranged ints.
6. **Fault:** a `refinement_violation` code rendered through the OFI-111b value walker.
7. **Docs + tests:** `tests/fault/refinement_violation.em`, `tests/run/ranged_int.em`, and a
   `--check` counterexample test for a deliberately-too-loose constructor.

### 4.5 v1 EXCLUDES

- **Refined mutable struct fields / automatic struct-invariants** — no auto-invariant mechanism exists
  yet (manual `ensures` on each mutator *works* since OFI-026 closed, but isn't ergonomic). Clean **v2**.
- **SMT / quantifiers / measures / nonlinear arithmetic** — the documented fad trap. Anything outside
  the linear-integer fragment simply degrades to a runtime check; we do not chase completeness.
- **Refinements through erased generics** — boxed; allowed but not zero-cost.

**Effort:** medium (~1–1.5 wk). The full feature incl. mutable-field refinements is large → v2.

---

## 5. Sequencing & dependencies

```
Fault precision Phase 2/3  ──►  OFI-149 newtypes  ──►  OFI-150 refinements
(OFI-111b value walker esp.,    (independent,           (builds on 149 +
 OFI-111a columns, OFI-110d)     cheap, high value)      the unified Fault schema)
```

1. **Fault precision Phase 2/3 first** — completes the verification & determinism moat and gives
   refinements a value-rendering Fault schema (OFI-111b) to route their violations through. Doing
   refinements first would invert the dependency.
2. **OFI-149 newtypes** — the prize; smallest, highest value-per-effort, lowest risk.
3. **OFI-150 ranged refinements** — the conservative sibling, folded onto the Fault schema.

---

## 6. Proposed MANIFESTO §5k (draft — fold into MANIFESTO.md once approved)

> **§5k. Newtypes & refinement types — constraints on data, unified with contracts.** A `type Name =
> Base` declaration introduces a *distinct nominal* type at zero runtime cost (it erases to its base),
> so a `UserId` cannot be confused with an `OrderId` or a bare `int` — turning primitive-obsession and
> swapped-argument bugs (a top LLM-codegen error class) into compile errors. An optional `where P`
> clause (with `int<lo..hi>` sugar) attaches a value constraint that *travels with the data*: it
> desugars to the executable-contract machinery (§5e) — an implicit `requires` at construction, an
> implicit `ensures` guarantee on read — runtime-checked in debug, release-elided, statically discharged
> by the prover where it can, and surfaced as the same structured `Fault` + tape (§5c, §5j) everywhere
> else. This is "parse, don't validate" as a language feature: the type *is* the proof of validity. We
> deliberately stay in the decidable, runtime-degradable band (ranged ints, linear predicates) and
> refuse the liquid-type completeness chase (SMT/quantifiers/measures) whose ergonomics are a documented
> dead end — the value is cheap, LLM-legible constraints on data, not a theorem prover.

---

## 7. Decision trail

- Validated by the adversarial workflow `validate-refinement-newtypes` (run 2026-06-26): six
  interrogation seats — two fresh online counter-evidence passes (refinement-reality; newtype + LLM
  ergonomics), three code-grounded red teams (feasibility, chocolate-teacup cost/benefit, opportunity
  cost), one steelman — plus an independent devil's-advocate verdict.
- **Verdict: (B) build a scoped version**, newtypes leading, refinements narrow and conservative,
  sequenced behind the Fault precision Phase 2/3 work.
- **Key correction surfaced during validation:** OFI-026 is *closed* — the "field-refinement blocker"
  was a stale comment in `src/check.c`, corrected as **OFI-148**. Field refinements are therefore a
  clean v2 (gated only on an auto-invariant mechanism), not a soundness landmine.
