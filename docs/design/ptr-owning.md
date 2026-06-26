# Design: owning resources — `resource struct` with `drop` (OFI-122)

*Author: Claude, 2026-06-25. **Status: IMPLEMENTED & SHIPPED (Phase 1).** Designed below, hardened by a
19-agent adversarial soundness panel (the [`ptr-linearity.md`](ptr-linearity.md) workflow — its
confirmed holes are the "REVISIONS" section, all fixed), then built across the checker and BOTH
backends (a runtime drop hook: a re-entrant VM invoke + native `em_invoke`; `em_enum_take` for the
`?`-move). `std/sqlite`'s `Db`/`Stmt` are the first resources — the borrow-worker ceremony is gone.
Closes **OFI-122 Phase 1** (resources in collections are Phase 2). Verified: 390/0 on both backends,
all 7 verify gates green, reclaim-detector clean. The one implementation refinement vs the design below:
a handle is closed at the **top level** of `drop` (so the consumed mask is monotonic — no control-flow
merge needed), and `drop` takes plain `self` (so it is never auto-re-dropped). Native `std/sqlite` FFI
wiring is the tracked tail (OFI-143).*

## Problem (OFI-122)

[`ptr-linearity.md`](ptr-linearity.md) made a `Ptr` **linear** (used exactly once): an owned handle
must be `close`d on every path, enforced at check time with no runtime cost and **no destructor** —
because a raw `Ptr` is opaque, the compiler can't know whether to call `fclose` / `free` /
`sqlite3_close`. To keep that sound, a `Ptr` is **banned from being stored** in any aggregate (struct
field, array element, enum payload, channel element, generic argument — the OFI-049 "R1"
type-formation ban).

The consequence, named in that doc and filed as OFI-122: **no Ember value can own a C resource.** No
`struct Db { conn: Ptr }`, no `Result<Db, string>` checked-open, no connection pool, no statement
cache. `std/sqlite` (2026-06-24) is the sharpest case — a connection and a statement are bare `Ptr`s,
which forces the **owner-borrows-worker-closes ceremony** (an owner opens a handle and closes it
unconditionally, handing it *borrowed* to a worker that does the `?`-heavy work) just to use `?`.

The fix the doc itself anticipated: *"typed handles with associated `Drop` — a clean future widening."*

## The fix: `resource struct` — a uniquely-owned value with an automatic `drop`

A **`resource struct`** is a struct that *owns* a resource and provides a destructor. It is the dual
of `rc struct`: where `rc` is the blessed **shared-immutable** tool (MANIFESTO §5, "the safe half of
`Rc`"), a `resource` is the blessed **uniquely-owned mutable-with-cleanup** tool. Together they
complete the ownership-tools matrix — plain values, `rc` (shared), `slotmap` (identity), **`resource`
(owned)** — rather than adding a parallel mechanism (§3.4). RAII is the GC-free cleanup mechanism the
memory model (§5, "memory safety without a GC") is built on.

```ember
resource struct Db {
    conn: Ptr                                 // a Ptr field — allowed ONLY inside a resource struct
    fn drop(self) {
        let _ = sqlite_close(self.conn)       // runs automatically when a Db is dropped
    }
}
```

Three properties define it:

1. **Move-only (non-`Copy`).** A `resource` value is never implicitly duplicated — duplicating a live
   handle would double-close. It rides the §5f move-by-default model and is excluded from the `Copy`
   bound. Assigning / passing-by-value / storing **moves** it; use-after-move is the existing error.
2. **Auto-drop (RAII).** When an owned `resource` value dies — scope exit, an early `?`/`return`/
   `break`, a `var` overwrite, or the drop of a container holding it — the compiler runs its `drop`.
   The programmer declares `drop` once and **never calls it manually**. This is not new hidden control
   flow: strings, enums, arrays, and `rc` structs *already* auto-release at these exact sites; a
   `resource` extends that existing drop glue to run user code (the `rc`-struct per-type-drop hook).
3. **Lifts the `Ptr`-field ban — narrowly.** A `Ptr` may be a field **only inside a `resource
   struct`** (whose `drop` discharges it). A raw `Ptr` in a plain struct, `[Ptr]`, `Option<Ptr>`, etc.
   stay banned. This is the one type-formation change.

### Why this is tractable: it composes three shipped subsystems

- **The `Ptr` linear machinery** (checker: `consumed` / leak-scan / move tracking, `src/check.c`).
- **The `rc struct` per-type drop hook** — a type-level flag that flows checker→layout→codegen→runtime
  and dispatches a custom drop path in **both** backends (`src/runtime.c` `drop_value`, `src/cgen_c.c`).
  A `resource` is the same hook with "call the user's `drop`" instead of "decref".
- **The `Copy` bound** (§5f) already distinguishes move-only from copyable types.

The work is *composing* these, not greenfield runtime.

## The `drop` method contract

`fn drop(self)` receives the resource **by value** (it owns the dying value). Its rules:

- It **must consume every linear `Ptr` field of `self`, on every path** (the existing linear rule,
  applied to `self`'s `Ptr` fields). A `drop` that fails to close a `Ptr` field is a *leak* — a compile
  error. This is what makes the handle actually get closed.
- It **may not move `self` as a whole, nor move out a non-`Ptr` (boxed) field.** It may read fields
  (borrow) and call methods that borrow. (Mirrors Rust's `&mut self` drop for the non-handle parts —
  prevents recursive/double drop.)
- After `drop(self)` returns, the runtime **releases `self`'s boxed fields** (strings / arrays /
  nested `resource`s — a nested resource recursively runs *its* `drop`) and frees the struct shell.
  The `Ptr` fields were consumed by the user `drop`, and are plain `int64` to the runtime, so it
  never touches them — **no double-close**.
- A `resource struct` **must** declare exactly one `drop` (a resource with nothing to clean up is just
  a move-only struct and needs no `resource` marker).

## Where `drop` fires (every owned-resource death) — mirrors the existing drop sites

| Site | What drops |
|------|-----------|
| block / fn-body end | each owned `resource` local in scope not moved out |
| `return` / `?` / `break` / `continue` | each owned `resource` in the abandoned scope(s) (incl. the `?` hidden-return — *this is what makes `?` "just work"*) |
| `var` reassignment | the old `resource` value being overwritten |
| container drop | a `resource` field of a dropped struct/enum; (Phase 2) a `resource` element of a dropped array/map |
| move-out | the **source** stops dropping; the destination inherits the obligation |

These are the sites `drop_value` / `emit_drops` already handle for owned values; the change is the
per-type dispatch calling the user `drop` first.

## Staging

**Phase 1 (this campaign) — resource as local / struct field / enum payload / return.** This is the
bulk of the win: a `Db` value, `Result<Db, string>` checked-open, `Option<Db>`, a `Connection` struct
with a `Db` field, and — the headline — **`?` just works** with no borrow-worker ceremony, because the
resource auto-drops on the early-return path. Enum payloads (`Result`/`Option`) work via the existing
recursive enum-payload release; no new collection machinery needed.

**Phase 2 (follow-on) — resource in `[T]` / `Map<K,T>`** (connection pools, statement caches). This
needs genuine **move-in / borrow-out of non-`Copy` elements** in the collection APIs (`append`,
indexing, `get`) — today value-struct elements are *cloned* on store, which a unique resource can't
be. That clone→move change to the array/map element path is the one genuinely new piece, deferred.

### Before / after (the payoff)

```ember
// BEFORE (today) — the borrow-worker ceremony, just to use ?
fn main() -> int {
    let db = sql.open("notes.db")            // bare Ptr; must check ok(), close on every path
    let r = run(db)                          // borrow into a worker so ? doesn't leak the handle
    let _ = sql.close(db)
    match r { case Ok(n) { return 0 } case Err(e) { println("{e}"); return 1 } }
}
fn run(db: Ptr) -> Result<int, string> { … }

// AFTER (resource Db) — the ceremony evaporates
fn run() -> Result<int, string> {
    let db = sql.open("notes.db")?           // Result<Db,_>; Db is a value
    let _ = sql.exec(db, "CREATE …")?        // early-return-safe: db auto-drops on the ? path
    let _ = sql.exec(db, "INSERT …")?
    return Ok(0)
}                                            // db.drop() runs on every NORMAL exit (incl. each ?). A trap/Fault aborts → the OS reclaims the handle (leak-on-abort, never a double-close).
```

## Soundness vectors the adversarial panel must close

The OFI-049 review found 5 holes in its first draft; this design's attack surface, to verify by
*constructing breaking Ember programs*:

1. **Double-drop across a move** — move a `Db` into a field / return / another binding; the source must
   not also drop (the `moved`/`consumed` tracking).
2. **Drop-on-every-path** — a resource not moved out must drop on *every* exit incl. `?`/`break`/each
   `match` arm/loop break (the auto-drop generalization of the leak-scan; verify early exits).
3. **Use-after-move** — using a `Db` after it's moved is an error.
4. **Move-out-of-`self` / re-entrancy in `drop`** — `drop(self)` must not move `self` whole, nor move
   out a boxed field, nor call a method that re-drops `self`. Forbid; verify.
5. **Ban-lift leak-back** — reading a `Ptr` field outside `drop` must be a *borrow* only; a raw `Ptr`
   must not escape a resource back into a plain aggregate or a `move`-close.
6. **Partial field move** — moving a `Db` out of a struct field that holds it; the container's drop
   must not re-drop the moved-out resource (field-level move tracking).
7. **Copy smuggle** — a resource must not be duplicable via a non-`Copy` generic, an array/struct
   clone, or the OFI-064 clone-on-`match`-bind path (that path must *move*, not clone, a resource).
8. **`drop` doesn't close a `Ptr` field** — must be a leak error.
9. **Nested / generic resources** — a resource holding a resource; a resource as an enum payload under
   erasure — both drops must run exactly once, in order.
10. **Drop during unwind / early panic** — interaction with a builtin trap / Fault mid-scope.

## Corpus impact

- **No existing `Ptr` code changes.** Raw `Ptr` stays linear; the ban is only *lifted* for resource
  fields, never relaxed elsewhere. `examples/16_ffi.em`, `tests/run/ffi_*.em`, `tests/run/ptr_move.em`
  stay green.
- **`std/sqlite` gets refactored** onto a `resource struct Db` + `resource struct Stmt` (Phase 1:
  `Result<Db>` open, `?`-clean API), the flagship dogfood. Its goldens update; behavior is preserved.
- New negative tests assert each soundness vector is rejected; new positive tests assert the clean
  idioms compile and run leak-free (RSS + ASan + VM==native dual-run).

## Verification plan

Adversarial soundness panel (this doc's pre-implementation gate) → hardened design → implement
(checker + both backends) → extend the **Ledger** fuzzer with resource-lifetime shapes (known
accept/reject oracle: does every owned resource drop exactly once on every path?) → hand-written
regressions → VM==native differential → ASan + the reclaim double-drop detector → `make verify`.

---

## REVISIONS after adversarial review (2026-06-25, 9-vector panel + refute + synthesis)

The panel constructed and **code-verified** breaking programs for **all 9 vectors**; the refute stage
confirmed every one against the current tree. Verdict: **sound_with_revisions** — the *shape* is right
(the owned dual of `rc`), but the v1 spec's load-bearing claim — *"composes three shipped subsystems,
not greenfield"* — is **FALSE**. The three subsystems (Ptr-linear tracking, the `rc` drop hook, the
`Copy` bound) are **binding-granular and resource-unaware exactly where the feature needs them to be
resource-aware**. A faithful build of the v1 spec would **compile multiple double-close / use-after-free
programs on a live handle** *and simultaneously* **reject the one mandatory line of the whole feature**
(the canonical `drop` body). The unifying root cause: a `resource` is the **first non-refcounted,
droppable, unique-owner aggregate the runtime has ever seen**, so every site that assumed *"owned
non-scalar aggregate ⇒ refcounted ⇒ retain/clone is a safe handoff"* is now wrong.

6 distinct issues after dedup (2 critical holes, 3 high holes, 1 high false-positive, 1 sound/doc-only):

### R1 — `is_resource` type-flag + parse/decl plumbing (critical; net-new, NOT free)
No `resource`/`is_resource`/`has_drop` flag exists (only `is_rc`, `check.c:317`). Without a
discriminator a `resource struct` is indistinguishable from a plain value-struct at every decision
site. Add `resource` as a contextual struct modifier parallel to `rc` (`parser.c:~1854`); require
exactly one `fn drop(self)`. Add `is_resource` + drop-method-index to `StructInfo`, flowing
checker→layout→codegen→runtime like `is_rc`. **Explicitly gate** `is_value_struct` /
`nested_inline_sid` / `array_inline_struct_id` / `struct_all_scalar_id` / `param_multislot_sid` on
`!is_resource` — a resource is boxed today only by the *accident* that a `Ptr` field is 16 bytes;
don't rely on it (a future Ptr-less resource must not become an inline value-struct).

### R2 — gate the OFI-064 clone-on-bind-out fork against resources (critical; closes #1≡#5)
A `match case Ok(db)` binding is `owned=0` (`check.c:5692`). Reading it into an owner (`let keep=db`,
a `move`/by-borrow value-struct param) routes `consume()` to the `!owned` fork (`check.c:2365`); being
a struct (not `TY_PTR`) it skips the borrowed-Ptr guard and falls to `moves_local=2` = value-struct
**clone** (`check.c:2379`). The clone's `own_into_slot` **no-ops on the Ptr int64** (`runtime.c:440`),
so `conn` is duplicated; both owners run `drop` → double `sqlite_close`. **Fix:** in the `!owned` fork,
before the clone, reject moving/copying a resource (or a struct transitively containing one) out of a
borrow. **Phase-1 consequence:** a resource enum payload can only be **borrow-read** inside a `match`;
consumption of `Result<Db>`/`Option<Db>` flows through **`?`** (R3), not destructuring. (Owning-`match`
that *moves* the scrutinee out is genuinely new machinery → Phase 2.)

### R3 — `?`/owned-enum-payload extraction must MOVE (nil the slot), not retain-then-drop (critical; closes #2≡#7; both backends)
The headline idiom `let db = open()?`. Native `emit_try` (`cgen_c.c:1769`) lowers extraction as
`em_enum_field`(borrow) + `OBJ_RETAIN` + `drop_value(enum)` — sound only for a *refcounted* payload;
the plain-struct drop branch **reclaims unconditionally** (`runtime.c:250-260`, no `OBJ_RELEASE` gate),
so `drop_value(enum)` runs `Db.drop` immediately (close #1) and the success-path scope-exit drops `db`
again (close #2, on freed memory). **Empirically reproduced:** native exits 133, ASan heap-UAF; the same
program is clean on the VM (it borrows via `OP_GET_FIELD`). This is the OFI-062/063 deferred native tail.
**Fix:** add `em_enum_take` (read payload, **nil the enum slot**, then `drop_value(enum)` no-ops on it)
for unique-owner/resource payloads; rewrite native `emit_try` + owned-field-get; align the VM `?` path
(also fixes a minor enum-shell leak). **The VM==native dual-run MUST include `Result<resource>?`** — this
hole is invisible to a VM-only or `match`-only test. (Naïve `em_field_owned` would *clone* → also wrong.)

### R4 — `drop`'s `self` is a non-re-droppable receiver (high; closes #3)
A resource is a plain struct → `is_move_type=1`, no refcount gate → every `drop_value` re-runs `drop`.
`drop(self)` with move-self gets `release_at_exit=1` (`check.c:6508`) → `self` self-drops at the method's
own exit → infinite `drop`→`drop`. Triggers also via a `move self` helper and `let stolen=self`. **Fix:**
mark the drop method's `self` non-droppable (exclude from `release_at_exit` and `drop_locals`); the
*runtime* (not the body's scope-exit) frees the shell + boxed fields after `drop` returns. Forbid moving
`self` whole inside `drop`; ban calling a `move self` method (or `drop`) on `self` from within `drop`.

### R5 — close the `move self`-not-consumed gap + non-`drop` Ptr-field escape (high; closes #4)
**HOLE A:** the carve-out that lets `drop` consume `self.conn` is not drop-scoped, so a *second*
method `fn close(self){ sqlite_close(self.conn) }` compiles, its borrowed receiver auto-drops → double
close. **HOLE B:** `move self` **never consumes the receiver** (`check.c:3865`) — a pre-existing latent
bug — so `let r = db.close()` (move-self) leaves `db` live → double drop. **Fix:** (1) gate the
Ptr-field-consume carve-out to the drop body via a `c->in_resource_drop` flag; outside `drop`, a
`self.conn` read is **borrow-only** (mirror the borrowed-Ptr guard onto the `EXPR_GET` path). (2) Make
`move self` actually consume the receiver — **a blocking-prereq, filed as its own OFI** (it's a
corpus-wide latent-bug fix; run the full corpus + Ledger before layering resource work on it).

### R6 — per-field linear tracking for `self`'s Ptr fields in `drop` (high; closes #6 AND the #9 false-positive)
The leak scan is binding-granular: `self` is one struct local, `self.conn` is never its own `Local`, and
every leak-scan site filters on a whole `TY_PTR` local. So (a) a no-op `fn drop(self){}` **compiles and
leaks** the handle, and (b) the canonical `sqlite_close(self.conn)` is **rejected** by the partial-move
ban (`check.c:2401`) — the same missing layer breaks the feature in both directions. **Fix:** a per-field
`ptr_field_consumed[]` mask on `self` in a drop body; set it on a legal field-consume (the R5 carve-out
site) with the same OR/AND-merge discipline as `moved`/`consumed`; extend **every** exit leak-scan site
to AND-merge it and report a leak for any unconsumed Ptr field of `self`. Permit the field-move-out ONLY
as a direct consuming argument, ONLY for `self` of the drop's own type, NEVER to mint a fresh owned Ptr.

### R7 — doc-only: correct the "drop runs on EVERY exit / no leak possible" overclaim (low; closes #8 — sound)
Verified sound, but the worked example overclaims. Ember's drop is 100% static codegen; a builtin trap /
Fault / contract violation does `return VM_RUNTIME_ERROR` (or native `exit(70)`) with **no unwind** — so
on a trap with a live resource, `drop` does **not** run; the OS reclaims the fd. **Leak-on-abort, no
re-entry ⇒ no double-close** — exactly `panic=abort` RAII, sound. **Fix:** correct the example to "runs on
every NORMAL exit; a trap/Fault aborts and the OS reclaims the handle". (Optional OFI: a resource wrapping
*non*-OS-reclaimed state — a lock/temp file — gets no abort-path cleanup; inherent to synchronous RAII.)

### Implementation order (each step independently testable)
0. **R1** — the flag + plumbing + gate the value-struct predicates on `!is_resource`. *(prereq for all)*
1. **R5 part 2** — make `move self` consume the receiver. *Standalone pre-req OFI; fixes a latent
   corpus-wide bug; run the FULL corpus + Ledger first to confirm no regression.*
2. **R6 + R5 part 1 + R4** — the checker drop-body correctness layer (shared per-field-mask machinery).
   After this the canonical `drop` compiles, a no-op `drop` is a leak error, and `drop` can't re-drop self.
3. **R2** — gate the clone-on-bind-out fork; restrict Phase-1 `match`-on-resource to borrow-read.
4. **R3** — `em_enum_take` move-out (both backends); wire the `rc`-style per-type drop hook to dispatch
   the user `drop` in `drop_value` (`runtime.c`) + `cgen_c.c`. *The only code that must be byte-identical
   VM↔native.*
5. **R7** — correct this doc's worked example.
6. **Verify** — extend Ledger with resource-lifetime oracles (incl. `Result<resource>?`); VM==native
   differential + ASan + the reclaim double-drop detector; `make verify`. **A `Result<resource>?` case is
   mandatory** — the #2/#7 hole is invisible to VM-only/match-only tests.

### Residual risks to watch
- **Owning-`match` is now on the critical path.** R2 routes Phase-1 consumption through `?`. Confirm the
  std/sqlite refactor only needs `?` + borrow-read; if it needs to *destructure-and-keep* a `Result<Db>`,
  that's Phase-2 machinery and the estimate grows.
- **R3 box/unbox round-trip** must match leaf-by-leaf on both backends (OFI-062/063 history); gate on the
  `-DEMBER_DROP_TRACE` reclaim detector.
- **R5 part 2 changes existing semantics corpus-wide** — low likelihood of breakage but run everything first.
- **Native≠VM divergence is the recurring failure mode here** (the #2/#7 hole *was* a false VM==native
  assumption). Every resource regression runs on both backends; a VM-only green is meaningless.
- **Post-drop boxed-field release must not touch the Ptr fields** (consumed by user `drop`, now int64).
- **Nested resource via `?`** combines R3's move-out with recursive drop — re-verify each drop runs once.
