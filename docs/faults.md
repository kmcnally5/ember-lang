---
title: Faults — the error model
nav_order: 5
description: Ember's unified failure report — one Fault artifact for builtin traps, contract violations, and errors, rendered for both humans and AI agents.
---

# Faults — Ember's unified failure report

> Status: **Phase 0 + Phase 1 (runtime core) shipped.** Compile-side convergence, the
> `?`-propagation route trace, persisted repro, and native parity are tracked follow-ups
> (OFI-108…111). This doc is the living spec for the whole campaign.

## Why

Ember is LLM-first: a failure must be optimally consumable by a model that will try to
*repair the code*, and excellent for a human. The program-repair literature is blunt about
what moves fix-rate: a **precise location**, the **violating runtime values** (never
hallucinated), and the **violated intent** (not just the syntactic rule). Human visual
chrome (carets, colour, ANSI) actively *confuses* a token-based model and is a
prompt-injection vector.

So every failure in Ember produces **one structured artifact — a `Fault`** — rendered two
ways from a single source of truth:

- **human** render: the familiar `error[...]: ...` stream, teacher-voice, the default.
- **agent** render: one terse, marker-free, **escaped JSON object per line** (JSON Lines)
  for a tool or an LLM. Selected with `--faults=agent`.

The pattern already existed in miniature (`src/diag.c`: one `Diag` record → `print_human`
+ `diag_flush_json`). The Fault generalises it so compile-time and runtime failures finally
speak one schema.

## The headline idea: every runtime trap is a violated *implicit contract*

Contracts (`requires`/`ensures`) are Ember's flagship bet. A builtin trap — an
out-of-bounds index, a divide by zero, an overflow — is *the same thing*: a precondition was
violated. So Ember reports each builtin trap as an implicit contract, in the same
intent-framed, value-carrying shape a user `requires` produces.

Before:

```
emberc: runtime error: array index out of bounds
```

After (human render, the default):

```
error[index_out_of_bounds]: array index out of bounds
  --> app.em:4 (in get)
  why:    indexing requires 0 <= index < len
  values: index = 5, len = 3
  route:  get (line 4) <- main (line 9)
  hint:   valid indices are 0..len-1; guard with `if i < arr.len()`, or use `arr.get(i)` which returns an Option
```

After (agent render, `--faults=agent`, one line):

```json
{"severity":"error","category":"runtime","code":"index_out_of_bounds","message":"array index out of bounds","file":"app.em","line":4,"fn":"get","why":"indexing requires 0 <= index < len","values":[{"name":"index","value":"5"},{"name":"len","value":"3"}],"route":[{"fn":"get","line":4},{"fn":"main","line":9}],"hint":"valid indices are 0..len-1; guard with `if i < arr.len()`, or use `arr.get(i)` which returns an Option"}
```

The operand values (`index = 5`, `len = 3`) are read from the **live C locals at the trap**,
never reconstructed — the same "values from the tape, never hallucinated" guarantee the tape
already enforces. The check that fires the trap already runs on the success path, so a Fault
costs **nothing** on the hot path: only the body of the already-taken failure branch changed.

## The schema

Defined in [`include/fault.h`](https://github.com/kmcnally5/ember-lang/blob/main/include/fault.h). A `Fault` carries:

| field        | meaning |
|--------------|---------|
| `severity`   | error / warning / note |
| `category`   | parse · type · contract · **runtime** · unhandled_err · counterexample |
| `code`       | stable machine handle, e.g. `index_out_of_bounds` (the agent's routing key) |
| `message`    | one-line human summary |
| `file`, `line`, `fn` | where it surfaced (line-precise; see *Precision* below) |
| `why`        | the violated intent — the implicit/explicit contract |
| `values[]`   | the concrete operands involved (the strongest repair signal) |
| `route[]`    | the call chain it surfaced through (origin last) |
| `hint`       | a concrete fix in user terms |

Two renderers (`fault_render_human`, `fault_render_agent`) in
[`src/fault.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/fault.c) consume one `Fault`. Both escape every string through the
single shared `json_write_string` ([`src/jsonw.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/jsonw.c)), so no control/ANSI byte
can leak into the agent channel. Empty fields are **omitted** from the agent JSON, not
emitted as `null` — noise hurts a model.

## Implicit-contract catalogue (Phase 1, VM)

Each builtin trap reports as a Fault with these `code` / `why` pairs and the live operands:

| code | why | values |
|------|-----|--------|
| `index_out_of_bounds`     | indexing requires 0 <= index < len            | index, len |
| `division_by_zero`        | division requires a non-zero divisor           | divisor, dividend |
| `modulo_by_zero`          | modulo requires a non-zero divisor             | divisor, dividend |
| `shift_out_of_range`      | shifting requires 0 <= amount < width          | shift, width |
| `integer_overflow`        | arithmetic requires the result to fit the type | lhs, rhs (or value) |
| `remove_at_out_of_range`  | remove_at requires 0 <= index < len            | index, len |
| `slice_out_of_range`      | slicing requires 0 <= lo <= hi <= len          | lo, hi, len |
| `value_out_of_range`      | the value must fit the target integer type     | value, min, max |

Frameless / non-operand aborts (stack overflow, call-depth, deadlock, send-on-closed,
slice-view-write, corrupt bytecode) keep the plain `emberc: runtime error: …` line for now;
they have no meaningful operands to project.

## CLI

```
emberc --emit=run app.em                 # human render (default)
emberc --faults=agent --emit=run app.em  # agent render (JSON Lines on stderr)
```

`--faults=human|agent` selects the runtime render. It is independent of
`--diagnostics=json` (which controls compile-time diagnostics and is unchanged /
byte-identical). The exit code stays a flat `65` for every runtime fault — the `category`
field is the durable machine signal, not the exit code.

Faults render to **stderr**, one JSON object per line, so a `--emit=trace` tape on stdout is
never corrupted.

## Precision (what's honest about v1)

- **Line-precise, file-attributed, with the surfacing function.** The runtime keeps no
  per-byte column table and no per-function source path (`Function` carries only a name), so
  `where` is `file:line (in fn)`. `file` is the entry source path; the `fn` name
  disambiguates the multi-module case. Columns/carets and per-function files are a follow-up
  (OFI-111).
- **Route is the synchronous call-stack backtrace** at the abort instant. The Zig-style
  per-`?`-hop error-return-trace (with the propagated `Err` value at each hop) is OFI-108.
- **u64 overflow operands** are shown as their two's-complement i64 view (the shared helper
  takes `int64_t`); a minor wart tracked in OFI-111.

## Roadmap

- **Phase 0 — done.** Extract the single JSON-string escaper; fix the tape's bare-`%s`
  escaping bug (OFI-107).
- **Phase 1 (runtime core) — done.** The Fault struct + two renderers; builtin traps as
  implicit contracts with values + call-stack route; the `--faults` flag.
- **Contracts — done (OFI-110a).** A `requires`/`ensures`/`assert` violation renders on the
  unified channel (`category=contract`, code, call-stack route); the message + the
  `contract_violation` tape event are unchanged, so `--check` is unaffected.
- **Err-reaching-main — done (OFI-110c).** An `Err`/`None` that `main` returns unhandled is an
  `FCAT_UNHANDLED_ERR` Fault (carrying the error value) and exits non-zero — was: exit 0 with
  `=> <obj>`. Identity via the prelude Result/Option variants recorded at codegen.
- **`?`-propagation route — done (OFI-108).** A release-elided `OP_ROUTE_HOP` on the `?`
  failure branch records each `(fn, line)` the Err travelled into an in-VM ring (cleared at
  every call), attached to the Err-reaching-main Fault — where the call stack is useless
  because the frames have unwound. VM-only.
- **Still open — OFI-110(c):** compile-diagnostics → agent Fault render + `Token` byte-spans +
  severity wiring (lower priority — `--diagnostics=json` already serves compile errors).
- **Value walker — done (OFI-111b, 2026-06-26).** A non-scalar Err/None payload renders as DATA
  (`Err("io")`, `MyErr { code: 5 }`, `NotFound("/x")`) via `render_value_into` (src/vm.c): codegen
  preserves struct field names + enum variant names in the CompiledProgram; nested strings are quoted,
  a top-level string is not (goldens stay stable); hidden witness fields are skipped; depth + 256-byte
  budget bounded.
- **Location precision — done (OFI-111a, 2026-06-26).** A Fault reports the true
  `file:line:col` of the failing expression (a parallel `Chunk.cols` mirrors `lines`; `Fault.col`
  renders as `:col` in human, `"col"` in agent) and the true SOURCE FILE of the surfacing function
  (`Function.source_file`, stamped per module; a lifted lambda carries its own path). The
  source-excerpt CARET is deferred (the runtime retains no source text). **Still open — OFI-111(d)**
  (deterministic persisted repro, gated on OFI-044).
- **Native Faults are intentionally bare — scoped to the VM (OFI-109, decided 2026-06-25).** The
  bytecode VM is the canonical, rich-diagnostics path (`emberc --emit=run`): it renders the full
  structured Fault (file/line/route/values, exit 65). The AST→C **native** backend is the
  differential/release build; a trap there aborts via `em_panic` (a bare message + exit 70), with no
  frame table or contracts. This is by architecture, not a missing feature — the differential harness
  compares **stdout** (where program output lives), so a Fault going to stderr is correctly outside its
  scope. Reach for full native Faults (thread file/line through `em_panic`, emit native contracts, unify
  exit 65) only if the native backend ever becomes the *primary* implementation; until then, run the VM
  for rich errors.
