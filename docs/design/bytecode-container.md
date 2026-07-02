# The `.emb` bytecode container — a serializable `CompiledProgram` (self-hosting Phase 1)

> Status: **DESIGN — awaiting review.** This is the Phase 1 deliverable of the standalone-toolchain
> campaign (see [self-hosting.md](self-hosting.md)). It specifies the on-disk format that makes the
> self-hosted compiler's bytecode *runnable*, closing the gap between "the Ember-written codegen emits a
> byte-identical disassembly" and "the Ember-written compiler produces something you can execute." No code
> is written until this design is signed off.

## 1. Why this exists

Today the self-hosted pipeline reaches two fixed points, but neither yields a *runnable* artifact from
Ember-only code:

- `selfhost/emberc.em` (lex → parse → **check** → codegen) emits stage-0's `--emit=bytecode`
  **disassembly text** — verifiable, but not executable.
- `selfhost/cgen_c.em` emits real C that compiles to a binary, but **skips the checker** and needs a C
  compiler present to run anything.

To make the *bytecode* path a real compiler (the bytecode-first decision, so we keep no-`cc`
`--emit=run` execution), the Ember codegen must write its `Chunk`s to a file that the existing C VM can
load and run. That file is the `.emb` container. The C VM gains one new mode, `--run-bytecode`, that
loads a `.emb` and executes it exactly as `--emit=run` would.

**Scope of Phase 1:** serialize/deserialize + one builtin + the loader mode + a differential gate. It does
**not** add language-feature coverage to the backend (that is Phase 2). Phase 1 is proven on the subset the
self-hosted codegen already compiles byte-identically — the four `selfhost/*.em` modules — by requiring
`run-bytecode` stdout to equal stage-0 `--emit=run` stdout.

## 2. What is (and isn't) serialized

The artifact the VM executes is `CompiledProgram` ([include/program.h:105](../../include/program.h)). The
container round-trips exactly that — nothing more.

**Persisted (needed to run):**

| Source | Field | Notes |
|--------|-------|-------|
| `CompiledProgram` | `main_index` | entry point; `-1` = none |
| | `result_enum_id`, `err_tag`, `option_enum_id`, `none_tag` | unhandled-`Err`/`None` → Fault detection |
| `Function[]` | `name`, `source_file`, `arity`, `chunk` | in **declaration order** (§5) |
| `Chunk` | `code[]` | raw opcode+operand byte stream, copied **verbatim** |
| | `lines[]`, `cols[]` | parallel to `code`; Fault/tape positions |
| | `consts[]` | `INT_VAL`/`FLOAT_VAL` only (codegen.c:325,1456) — never an object |
| | `strings[]` | `StringConst.data` + `length`; exact bytes, no transcoding |
| `StructType[]` | `name`, `field_count`, per-field `kind`/`field_struct`/`field_names`, `is_rc`, `is_resource`, `drop_fn` | field **geometry** (`offset[]`, `total_size`) is recomputed by the loader — §4 |
| `EnumVariantInfo[]` | `name`, `enum_id`, `variant_index`, `field_count` | Fault value rendering (`Err("io")` not `Enum(1,…)`) |

**NOT persisted:**

- `Function`'s `--check` fuzz metadata (`checkable`, `param_kind`, `param_leaves`, `leaf_*`, `leaf_count`).
  Recomputed only by `--emit=check`; the loader zeroes them (`checkable = 0`).
- `Chunk.strings[].cached` — the lazily-interned runtime `ObjString`. Set to `NULL` at load; the first
  `OP_STRING` interns it, identical to a freshly-compiled program.
- **Any VM execution state** (stack, call frames, `ip`, `sp`, fibers). The container is the *static
  compiled program*, not a running-VM checkpoint. `vm_create`/`vm_run` build all execution state from the
  `CompiledProgram` exactly as the compile path does. (The recon's facet-1 "serialize stack/frames"
  suggestion is checkpoint/replay scope and is explicitly out.)

## 3. Container layout

Little-endian throughout (host is arm64/x86-64; a fixed endianness keeps the loader trivial). Integers
that are naturally small use unsigned LEB128 (written `uvarint`); fixed-width fields are noted.

```
Header
  magic        4 bytes   "EMB\x01"           (0x45 0x4D 0x42 0x01)
  format_ver   u32 LE    container format version (starts at 1)
  vm_abi       u32 LE    = EMBER_BYTECODE_ABI (bumped when opcodes/native-ids/AEK change) — §6
  flags        u32 LE    reserved (0 for now)

Program header
  main_index   svarint   (-1 encoded as a signed LEB128)
  result_enum_id, err_tag, option_enum_id, none_tag   svarint ×4
  func_count   uvarint
  struct_count uvarint
  variant_count uvarint

String-blob section (dedup of all names + string constants — see note)
  blob_len     uvarint
  bytes        blob_len raw bytes
  (every name/string below is a {uvarint offset, uvarint length} into this blob)

Struct table   (struct_count entries)
  per struct:
    name             strref
    flags            u8   bit0 is_rc, bit1 is_resource
    drop_fn          svarint
    field_count      uvarint
    per field:
      kind           uvarint   (ArrayElemKind)
      field_struct   svarint   (nested struct id, or -1)
      name           strref    (empty strref = hidden witness field)

Enum-variant table   (variant_count entries)
  per variant: name strref, enum_id uvarint, variant_index uvarint, field_count uvarint

Function table   (func_count entries)
  per function:
    name         strref
    source_file  strref
    arity        uvarint
    // chunk:
    code_len     uvarint
    code         code_len raw bytes          (verbatim opcode/operand stream)
    line/col     RLE runs: run_count uvarint, then run_count × {len uvarint, line uvarint, col uvarint}
    const_count  uvarint
    per const:   tag u8 (0=int,1=float), then 8 bytes LE (int64 two's-complement / IEEE-754 double)
    string_count uvarint
    per string:  strref
```

Notes:

- **`strref` + string blob.** Names and string constants are pooled into one blob and referenced by
  `{offset,length}`. This keeps every string emission uniform, lets the loader do one allocation pass, and
  naturally supports embedded NUL / arbitrary bytes (string constants are raw byte buffers, not C strings).
- **`code` is copied verbatim.** The operand codec (fixed big-endian `OPK_U8/U16/U24/OFF16` + unsigned
  LEB128 `OPK_IDX`, the single source of truth at [include/opcode.h:172](../../include/opcode.h)) is
  *intrinsic to the byte stream*. We never re-encode operands — we store and restore the exact bytes, so
  there is zero chance of codec drift between serializer and VM.
- **line/col RLE.** `lines[]`/`cols[]` are one entry per code byte and highly repetitive (a whole
  instruction shares a position). Run-length encoding collapses them; the loader expands back to the
  per-byte parallel arrays `Chunk` expects. (Phase 1 may emit `col = 0` if the self-hosted codegen doesn't
  yet track columns — stdout parity is unaffected; see §7.)
- **const precision.** Full `int64`/`double` bits are preserved; the VM narrows per the numeric-kind
  operand at run time (the checker's width tracking is not in the value — facet 3).

## 4. Struct geometry: the loader packs, not the serializer

`StructType` needs `offset[]` and `total_size` — the *packed byte layout*. Stage-0 computes these in the
checker's `build_layouts` from field types. The self-hosted codegen tracks field *kinds* but not packed
byte offsets (the disassembly differential never needed them).

**Decision: the container stores per-field `kind` (`ArrayElemKind`) + nested `field_struct`; the C loader
computes `offset[]` and `total_size`** by running the canonical packing algorithm. Rationale:

- The offsets are then produced by the **same C code** stage-0 uses ⇒ guaranteed identical layout, no
  second implementation to drift.
- The Ember serializer only needs each field's `ArrayElemKind`, derivable from the field's **type
  annotation** in the parsed AST (`int`→`AEK_I64`, `i32`→`AEK_I32`, `u8`→`AEK_U8`, `bool`→`AEK_BOOL`,
  `f64`→`AEK_F64`; `string`/enum/array/generic-param → `AEK_BOXED`; all-scalar nested struct →
  `AEK_INLINE_STRUCT` + its id). This mirrors the checker's annotation→AEK mapping and is the one bounded
  new bit of serializer logic.
- Implementation: factor stage-0's packing loop into a small reusable helper
  (`struct_layout_pack(kind[], field_struct[], field_count) -> {offset[], total_size}`) callable by both
  `build_layouts` (unchanged behavior) and the new loader.

## 5. The serializer (Ember side)

Lives next to codegen — a new `selfhost/serialize.em` (or a `write_container` entry in `codegen.em`) that
replaces `disassemble()` in the emit driver. It emits **from** the existing Ember data model: the per-
function `Chunk` (parallel arrays `code`/`lines`/`const_int`/`const_float`/`strings`) plus the
`StructTable`/`EnumTable`/`fn_names`/globals/instances tables `emberc.em` already builds.

Two invariants it must preserve (facet 5):

1. **Function order is load-bearing.** `build_fn_names` walks decls in order, emitting `Struct.method`
   entries when the struct decl is reached, then free functions — and `CALL <index>` operands are resolved
   against exactly this order. The serializer emits functions in the same walk (`emberc.em`'s `emit_program`
   already iterates this way; it just calls `write_container` instead of `disassemble`).
2. **Monomorphized-instance and prelude ordering** (struct instance id = `struct_count + inst_index`;
   prelude `Option`/`Result` appended after user enums) must be emitted as-numbered so the loader's tables
   line up with the baked-in operands.

New builtin required — **the one Phase 1 prerequisite**:

```
from_bytes(bytes: [u8]) -> string     // pack a byte array into a string's raw buffer (no UTF-8 re-encode)
```

`write_file` already writes a string's exact bytes by length in `"wb"` mode
([src/runtime.c:2116](../../src/runtime.c)), so `from_bytes(buf) |> write_file(path, _)` emits arbitrary
binary. `from_bytes` is needed because `from_char_code(0x80…)` UTF-8-encodes to multiple bytes — it cannot
produce a single high byte. Added at the same sites `byte_slice` was (builtin.h/builtin.c/vm.c/runtime.c/
check.c + vocab.def + the cgen native band) — a known, bounded pattern.

## 6. The loader (C side)

A new `--run-bytecode <file.emb>` mode in `src/main.c`, mirroring `emit_run` (main.c:529):

1. `fread` the whole file; validate `magic`, `format_ver`, and **`vm_abi`** (reject a mismatch loudly —
   the bytecode bakes in native-builtin ids and opcode numbers, so a container is pinned to the VM ABI
   that produced it; §7).
2. Deserialize into a `CompiledProgram` (inverse of §3), `struct_layout_pack` to fill `offset[]`/
   `total_size`, `cached = NULL` on every string, fuzz metadata zeroed.
3. `VM *vm = vm_create(&prog); vm_run(vm, &result, NULL);` — then the identical tail as `emit_run`:
   `report_unhandled_error` (main.c:480) for an `Err`/`None` reaching `main`, and the `exit(code)` /
   returned-value exit semantics.

A tiny `emberc --emit=bytecode-bin <file.em> -o out.emb` mode (stage-0) is added too, so the container can
be produced by stage-0 *and* by the self-hosted compiler — giving the gate a stage-0 oracle container to
diff structure against, independent of execution.

## 7. Risks & resolutions

- **ABI pinning (facet 4).** `CALL_NATIVE <id>`, opcode numbers, and `ArrayElemKind` values are baked into
  the byte stream. A `.emb` is therefore valid only for the VM build that matches `vm_abi`. Resolution: a
  single `EMBER_BYTECODE_ABI` constant (bumped whenever opcodes / native ids / AEK renumber — tie it to the
  existing `make opcheck` surface), checked at load. This is expected for a bytecode format and is not a
  distribution goal in Phase 1 (same-tree produce+run).
- **String interning across load (facets 2/3/4).** `cached` must be `NULL` at load or the first `OP_STRING`
  use-after-frees. Handled by construction (§6.2). No cross-run pointer identity is assumed (there is none
  today either).
- **Column info.** If the self-hosted codegen doesn't yet emit `cols`, Phase 1 stores `0`. Faults go to
  **stderr**; the gate compares **stdout**, so parity holds. Exact columns land when the codegen tracks
  them (shared with the `--emit=bytecode` col surface), not a Phase 1 blocker.
- **`source_file` paths.** Persisted verbatim; sufficient for multi-module Fault reporting (OFI-111a) with
  no `ModuleSet` reconstruction (facet 1).

## 8. The Phase 1 gate

Added to `tests/run-selfhost.sh` after Stage 5. For each module the self-hosted codegen already compiles
byte-identically (`lexer`/`parser`/`checker`/`codegen`, and any small runnable fixtures):

1. self-hosted `emberc` → `.emb` container;
2. stage-0 `--run-bytecode container.emb` → stdout **A**;
3. stage-0 `--emit=run module.em` → stdout **B**;
4. **PASS iff A == B**, byte-for-byte.

This proves the serialized bytecode *runs* and produces identical observable behavior to stage-0's
in-memory execution — the Phase 1 finish line. Round-trip structural equality (stage-0-produced `.emb`
re-emitted) is an additional cheaper check.

## 9. Open questions for review

1. **Container extension**: `.emb`? (Analogous to `.pyc`/`.class`/`.wasm`.)
2. **Serializer home**: a new `selfhost/serialize.em`, or a `write_container` section inside
   `codegen.em`? (Leaning `serialize.em` — keeps `codegen.em` focused and the differential surfaces
   unchanged.)
3. **`from_bytes` vs `write_bytes(path,[u8])`**: I recommend `from_bytes` (orthogonal string constructor,
   reuses `write_file`), but a direct `write_bytes` avoids materializing the intermediate string. Either is
   ~one builtin.
4. **Do we also want `read_bytes`/deserialize in Ember now?** Not needed for Phase 1 (loader is C). Deferred
   unless we later want a self-hosted `--run-bytecode`.
