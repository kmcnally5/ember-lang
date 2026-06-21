# Design: `Ptr` is a linear type (OFI-049 leak half)

*Author: Claude, 2026-06-19. **Status: IMPLEMENTED & SHIPPED** — see the "REVISIONS after adversarial
review" section below for the final, verified design (the draft above it is the pre-review v1, kept for
the decision trail). Landed checker-only in `src/check.c`; gated by the new `make ledger` fuzzer; OFI-049
fully closed. Compiler-decision record: `docs/architecture.md` (`## Decision: Ptr linearity`).*

## Problem

An opaque C handle (`Ptr` — a `FILE*` from `fopen`, a curl handle from `http_open`, …)
round-trips through Ember. The **double-close half** of OFI-049 (closed 2026-06-18) made
`Ptr` *move-only* (affine — "used **at most** once"): `is_move_type(TY_PTR)==1`, a closing
call `fclose(move f: Ptr)` consumes the binding, and reuse-after-close is a use-after-move
compile error. Deliberately, a `Ptr` got **no scope-exit destructor** (Ember can't know how
to free an arbitrary C handle — `fclose` vs `free` vs `sqlite3_close` differ).

The **leak half** is still open: a handle that is **never** consumed leaks silently —
`let f = fopen(...)` with no `fclose` type-checks and runs with no diagnostic (verified today).

## The fix: make `Ptr` *linear* ("used **exactly** once")

Linear = affine (already have: at most once) **+** must-consume (new: at least once).
A value of type `Ptr` that is *owned* must be **consumed on every control-flow path** before
its binding leaves scope. "Consumed" = ownership transferred out via exactly one of:

1. passed to a `move` parameter — `fclose(move f)` (the C side frees), or an Ember
   `fn takes(move f: Ptr)` (which re-inherits the obligation);
2. `return`ed — ownership transfers to the caller, which re-inherits the obligation;
3. moved into another `Ptr` binding — `let g = f` / `g = f` — `g` re-inherits the obligation.

This is a **checker-only** change (like the double-close half): both backends honour
`moves_local`/scope-drop identically, so a compile-time guarantee covers VM and native with no
codegen/VM/runtime edits. No runtime cost, no destructor (consistent with the prior decision).

### Why linear and not a destructor?

A destructor-carrying `Ptr` (auto-close at scope end, Rust `Drop`-style) would be more
ergonomic but (a) **relitigates** the deliberate "no scope-exit destructor for `Ptr`" decision
from the double-close fix, (b) needs a *per-handle* closer (one opaque `Ptr` type can't know
whether to call `fclose`/`free`/`sqlite3_close`) → typed handles `Handle<Tag>` with associated
`Drop` — a much larger feature touching all backends, and (c) silent auto-close of a C handle
can surprise/double-free. Linear keeps the soundness guarantee at zero runtime cost and leaves
typed-handle-with-`Drop` as a clean future widening (tracked separately).

## The hard part: must-consume needs AND-merge (the dual of the existing flow)

The checker already tracks move-state across control flow (`snapshot_moved` /`restore_moved`/
`merge_moved`) with **OR-union** at joins: a binding is `moved` if moved on **some** reaching
path (affine — sound for "can't use after"). Linearity needs the **dual**: "consumed on
**every** path" = **AND-intersection** at joins. Checking the existing OR `moved` flag at scope
exit is **unsound** — it would pass `if c { fclose(f) }` (moved on the then-path → OR says
"moved") while the else-path leaks.

**Plan:** add a second per-local flag `consumed` (AND-merge dual of `moved`), maintained at the
same sites with the same divergence rules, swapping OR→AND in the "both branches reach the join"
case. `consumed[i]==1` ⟺ binding `i` has been moved out on **every** path reaching this point.

- `consume()` sets `consumed=1` alongside `moved=1` (lockstep) for an owned `Ptr` move.
- `if/else`: `consumed = then_consumed AND else_consumed` (per reachability; a diverging branch
  is excluded — it is checked at its own `return`/`break`).
- `match`: AND-fold over the reaching (non-diverging) arms (identity = all-1).
- `loop`: no merge needed — consuming an *outer* `Ptr` in a loop already errors ("value moved
  inside a loop body, it would move again next iteration"); body-local handles are covered by
  the block-end / `break` / `continue` checks.
- `assign` (`f = …`): resets `consumed=0` (a fresh value re-obligates), mirroring `moved=0`.

## Where the leak check fires (every exit / transfer point)

A leak is reported when an **owned, un-consumed `Ptr`** leaves scope on a reachable path:

| Site | Range checked | Why |
|------|---------------|-----|
| `return` | all in-scope `[0,n)` except the returned binding | the return path abandons them |
| `break` / `continue` | the enclosing loop body's locals `[loop_base,n)` | they don't survive the loop exit (outer `Ptr`s consumed *after* the loop are fine) |
| `?` (try) early-return | all in-scope `[0,n)` | the `Err`/`None` path abandons them (hidden return) |
| block / match-arm / loop-body / fn-body end (`drop_locals`) | that scope's range `[from,n)` | the fall-through path |
| `var` reassignment | the target binding | the old un-consumed handle is overwritten (leaked) |

A monotonic `leaked` latch per local dedupes double-reports (e.g. a `return`-flagged leak that
`drop_locals` would re-see at fn end). Diagnostics name the binding, point a note at where it
was opened, and suggest closing on every path / returning to transfer ownership.

## Closing the two unsoundness bypasses (else the guarantee is hollow)

1. **Borrowed-`Ptr` consume.** Today `consume()`'s `!owned` move path (the OFI-064 clone-on-bind
   path) lets a *borrowed* `f: Ptr` param be passed to `fclose(move f)` — closing a handle you
   only borrowed (caller then double-closes / uses-after-close). Guard: consuming a `!owned`
   `TY_PTR` is an error — "cannot close a borrowed `Ptr`; take it by `move` to gain ownership."
2. **Store-into-aggregate.** Moving a `Ptr` into a struct field / array element / enum payload /
   closure capture / channel transfers the obligation into a container that has **no machinery
   to discharge it** → the obligation silently vanishes (a leak that compiles). Since the
   aggregate's drop can't close a `Ptr`, **storing a `Ptr` in any aggregate is a compile error**
   ("a `Ptr` is a linear resource with no destructor; keep it in a local and close it, or pass
   it by `move`"). The corpus never does this. Lifted when typed-handles-with-`Drop` land.

## Idioms this nudges toward (ergonomics)

The null-handle pattern stays clean because `fclose(NULL)` is a guarded no-op (the M6 fix):

```ember
var f = fopen(path, "r")
if f != null_ptr() {
    // … use the handle (borrowed) …
}
fclose(move f)            // single unconditional close (null-safe) — linear-happy
```

Early-return-on-error must close first (or restructure), which is *correct* — the alternative
leaked:

```ember
var f = fopen(path, "r")
if f == null_ptr() {
    fclose(move f)        // null-safe no-op; satisfies linearity
    return -1
}
… ; fclose(move f)
```

## What must keep compiling (the corpus)

`examples/16_ffi.em`, `tests/run/ffi_pointers.em`, `tests/run/ffi_null_handle.em`,
`tests/run/ptr_move.em`, `tests/native/ptr_move.em`, and `public/.../flare_chat.em` all
close their handles unconditionally → all stay green. `error_ptr_double_close.em` stays a
compile error. New negative tests assert the leak shapes are now rejected.

## Verification

A new **Ledger** fuzzer (Crucible/Ceilings sibling): generate `Ptr`-lifetime programs across
control-flow shapes (straight-line, if/else balanced & unbalanced, match, loop, early-return,
nested, reassign, move-out) each with a *known* accept/reject oracle (is the handle consumed on
every path?), and assert the compiler's verdict matches — catching both unsoundness (a leak that
compiles) and over-strictness (valid code rejected). Plus hand-written regression tests +
VM==native dual-run + ASan. Wire `make ledger` into `make verify`.

---

## REVISIONS after adversarial review (2026-06-19, 5-agent panel + synthesis)

The panel verified — by compiling them — **5 soundness holes and 2 false positives** in the v1
draft above. The core mechanism (AND-merged `consumed` dual of `moved`, checked at exits) is
sound, but it was written **binding-centric & value-site-centric**, and the checker's reality is
**erasure** (generics check the body once with type-params as `PARAM_BASE+k`, never re-checked at
`T=Ptr`) + **un-bound temporaries**. Final, verified design:

### R1 — The load-bearing fix: a type-FORMATION ban (erasure-proof)
Every guard keyed on `t == TY_PTR` is **blind inside a generic body**, and `is_refcounted(TY_PTR)`
is false so `Map<_,Ptr>.set(…, f)` never even calls `consume()` on the handle. So instead of
guarding value-construction sites, **forbid `Ptr` from ever being a *stored* type**:

> A `Ptr` may not be an **array element**, a **struct field**, an **enum/variant field**, a
> **channel element**, or a **generic type argument**.

Rejected at `intern_array`, `annotation_type` + generic-inst interning, struct/enum field
collection, and generic call type-arg binding (for **every** param, not just `Copy`-bounded). This
makes `[Ptr]`, `Map<_,Ptr>`, `Option<Ptr>`/`Result<Ptr,E>`, `Channel<Ptr>`, and a `Ptr` struct
field all **unconstructable** — subsuming the v1 "store-into-aggregate" bypass with one rule the
erasure can't slip past. (Closure capture is *already* an error via `is_move_type` — just needs a
Ptr-specific message.) Consequence: the common "checked open" must use the **null sentinel**
(`fopen`→null on failure, `fclose(NULL)` is a guarded no-op), not `Option<Ptr>`. Blessed with a
test. Typed-handles-with-`Drop` (future) will lift the ban.

### R2 — Linearity is value-based, not binding-based
Two new leak sites beyond the v1 table: a **discarded fresh `Ptr` temporary** (`fopen(...)` as an
expression statement — not a binding, and `is_owning_temp(TY_PTR)==0`) and the **bare `return`**
branch (unit fns). Keep the `is_owning_temp`/`drop_locals` `TY_PTR` carve-outs (Ptr has *no Ember
destructor*) but separate that fact from *is a linear obligation* (new check).

### R3 — One shared leak-scan helper at EVERY divergence site
`report_unconsumed_ptrs(c, from, except_slot)` — decl-independent (so it covers `move f: Ptr`
**params**, whose `decl==NULL`). Wired into: both `STMT_RETURN` branches (scan *after* `consume`,
so no "except returned binding" carve-out), `EXPR_TRY` (`?` hidden return), `STMT_BREAK`,
`STMT_CONTINUE`, and folded into `drop_locals` for block/arm/fn-end fall-through.

### R4 — Borrow-launder guard inside `consume()` (placement is load-bearing)
A borrowed `Ptr` read takes `consume()`'s `!owned` branch (the OFI-064 clone path) which returns 1
→ `let g = f` mints a spurious *owned* obligation, and `fclose` on a borrow compiles (double-close
vector). Guard at the **top of that branch**: `t==TY_PTR` → error, **return 0**. One placement
covers every consuming position (move-arg, let, assign, return, …) because they all route through
`consume()`. Also catches `mut f: Ptr` (`mut` is `owned=0`).

### R5 — The AND-merge must mirror the OR-merge's four-way divergence structure exactly
`snapshot/restore/merge_consumed` maintained **side-by-side** with the `moved` ones at every join
(mirror-drift discipline). Identity = **all-ones** (a match with zero reaching arms stays all-1).
- `if`: invert the four-way join (both-diverge→pre; else-diverges→then; neither→AND; then-only→else).
- `match`: `acc` init **all-1**, AND-fold over non-diverging arms.
- **loop: a loop IS a join** (deleted the v1 "no merge needed"). Snapshot outer-slot `consumed`
  at each `break`/`continue`; after the loop, outer `consumed = AND` over reaching break paths
  (+ normal-exit iff it can fall through). **This is what makes the textbook close-on-break read
  loop compile** (CRITICAL-6 false positive) — without it, the two halves of OFI-049 fight.

### R6 — Conditional-consume reports one clear leak at the join (HIGH-1)
`if c { fclose(f) }` (no else) wedges the binding: `moved=1` (use-after-move on a later close) but
`consumed=0` (leak on the else path). At a join where a `Ptr` is consumed on **some-but-not-all**
reaching paths, report the leak **there** with one actionable message, never the wedged state.

### R7 — `?` over a live owning `Ptr` temporary (HIGH-2, OFI-046 residual)
Largely mooted by R1 (no `Result<Ptr,E>`), but a `fopen()` temp live across an unrelated `?` is
still a residual; forbid an owned `Ptr` temporary across a `?` (or require it bound first).

### DECISION — hard error, false-positives-fixed, `defer`/`with` deferred
The double-close half is a **hard error**; an asymmetric "double-close errors, leak only warns" is
itself surprising, OFI-049 is explicitly a soundness item, and a warning the LLM ignores closes
nothing (the compiler IS the LLM's verification loop — the project's north star). So: **ship as a
hard error**, *after* the false positives (R5 loop-merge, R6 join) are fixed so correct code is
never rejected. The N-handle error-cleanup fan-out is the one residual friction; it wants a
`defer fclose(f)` / `with f = fopen() { … }` scoped-close — but the corpus has **zero** multi-handle
FFI code, so building that now is gold-plating. **Deferred to a new follow-on OFI**; the null-safe
single-close idiom covers today's usage. (Reversible: flip `type_error`→warning if Karl disagrees.)
```
