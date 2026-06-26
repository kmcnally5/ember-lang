#ifndef EMBER_PROGRAM_H
#define EMBER_PROGRAM_H

#include "chunk.h"

// A compiled function: its (owned) name, parameter count, and bytecode chunk.
// Each function has its own chunk; calls reference functions by index in the
// program's function table.
typedef struct {
    char *name;
    char *source_file;   // OFI-111a: canonical path of the module this fn was declared in (owned);
                         // a Fault uses it so a multi-module trap reports the right file, not the entry.
    int   arity;
    Chunk chunk;
    // Verification loop (§5j, `--check`): a free, non-generic function whose parameters are all
    // scalars or all-scalar (multi-slot) structs and that has a falsifiable postcondition
    // (`ensures`) is fuzzable. The fuzzer generates one scalar per LEAF and pushes them in slot
    // order, which is exactly how a multi-slot struct param arrives (its N field slots), so a
    // struct param is just its fields flattened. `leaf_kind[j]` ('i' int / 'f' float / 'b' bool)
    // drives generation + shrinking; `param_kind[i]` ('i'/'f'/'b' or 's' = struct) and
    // `param_leaves[i]` let the reporter group the flat leaves back into readable arguments.
    // `checkable == 0` means skip it.
    // A scalar or all-scalar-struct leaf has leaf_kind 'i'/'f'/'b'. An immutable-borrow array of
    // full-width scalars is ONE leaf with leaf_kind 'a': `leaf_elem[j]` is its element's fuzz kind
    // ('i'/'f'/'b') and `leaf_aek[j]` the element's ArrayElemKind (to allocate + pack it).
    int           checkable;
    int           param_count;
    char          param_kind[16];     // per param: 'i'/'f'/'b' scalar, 's' struct, 'a' array
    int           param_leaves[16];
    char          leaf_kind[32];
    char          leaf_elem[32];      // array leaf: element fuzz kind; 0 otherwise
    unsigned char leaf_aek[32];       // array leaf: element ArrayElemKind; 0 otherwise
    int           leaf_count;
} Function;

#define CHECK_MAX_PARAMS 16
#define CHECK_MAX_LEAVES 32

// A struct type's runtime descriptor: its (owned) name, field count, and PACKED
// LAYOUT. Each field lives at byte `offset` in a packed buffer, stored per its
// `kind` (an ArrayElemKind: a scalar packed at its natural width, or AEK_BOXED =
// a 16-byte boxed Value for aggregates/type-parameters). `total_size` is the
// buffer size. The VM reads this (by struct type id) to allocate, box/unbox
// fields, and drive drop. (Enums are not packed: their fields are all 16-byte
// boxed slots at offset index*16, so they need no entry.)
typedef struct {
    char *name;
    int   field_count;
    int   total_size;
    int   is_rc;         // `rc struct`: a shared, refcounted, deeply-immutable struct — drop_value
                         // reclaims it at the LAST owner (gated on the refcount) like an enum, and
                         // own_into_slot RETAINS rather than deep-clones it. 0 for an ordinary struct.
    int   is_resource;   // `resource struct` (OFI-122): a uniquely-owned, drop-bearing struct — at
                         // drop_value the runtime runs drop_fn (the user `drop`), then releases the
                         // boxed fields and reclaims. Always boxed (never a C value-type). 0 otherwise.
    int   drop_fn;       // the `drop` method's function-table index (resource only), else -1.
    // Per-field layout, dynamically sized to field_count (no EMBER_MAX_FIELDS cap — a struct may have
    // any number of fields; the field-index operands are LEB128 OPK_IDX). Owned by the CompiledProgram
    // and released by compiled_program_free. Accessed by index (offset[i]), identical to an array.
    int  *offset;
    int  *kind;          // ArrayElemKind per field (0 = boxed Value)
    int  *field_struct;  // for an AEK_INLINE_STRUCT field (value-types 3b.5): the nested struct's type
                         // id, so the VM can materialise a copy on read / size the inline bytes; -1 otherwise
    char **field_names;  // OFI-111b: per-field name (dup'd; sized to field_count; NULL for a hidden
                         // witness field), so the Fault value walker can render `Name { field: v, ... }`.
} StructType;

// The packed layout codegen copies into a StructType. The checker computes it
// (it knows field types); the index matches the struct type id. The first
// `struct_count` entries are the declared structs (DECL_STRUCT order); any further
// entries are appended *monomorphized* generic struct instances (e.g. Box<int>),
// each carrying `base_id` = the declared struct it specialises (for its field names).
typedef struct {
    int total_size;
    int field_count;
    int base_id;                    // declared struct this layout belongs to/specialises
    int is_rc;                      // `rc struct` (copied into StructType.is_rc); the native backend
                                    // reads it via is_value_struct to box rather than value-type it
    int is_resource;                // `resource struct` (copied into StructType.is_resource); also
                                    // forces boxing via is_value_struct so the drop hook can fire
    int drop_fn;                    // the `drop` method's fn-table index (resource only), else -1
    // Per-field layout, sized to field_count (no cap). The checker arena-allocates these in
    // build_layouts, so the StructLayout array can be freed with a plain free() and the per-entry
    // arrays are reclaimed wholesale at arena_free (which runs after codegen has read them).
    int *offset;
    int *kind;
    int *field_struct;              // nested struct id for an AEK_INLINE_STRUCT field, else -1
} StructLayout;

// OFI-111b: an enum variant's runtime identity + name, preserved so the Fault value walker can
// render an enum payload by name (Err("io"), NotFound("/x")) — codegen otherwise discards variant
// names after lowering. `enum_id` matches an enum instance's ObjStruct.type_id and `variant_index`
// its tag.
typedef struct {
    char *name;
    int   enum_id;
    int   variant_index;
    int   field_count;
} EnumVariantInfo;

// A whole compiled program: the function table, the struct-type table, and the
// index of the entry point `main`. This is the artifact codegen produces and the
// VM executes; it is self-contained (owns its names and chunks) and does not
// depend on the parse arena outliving it.
typedef struct {
    Function   *functions;
    int         count;
    StructType *structs;
    int         struct_count;
    int         main_index;   // -1 if there is no main
    // Runtime identity of the prelude Result/Option failure variants, so the driver can detect
    // an `Err`/`None` that reaches `main` unhandled and report it as a Fault (docs/faults.md,
    // FCAT_UNHANDLED_ERR). Each is the base enum id (an enum instance's ObjStruct.type_id) and
    // the failure variant's tag; -1 when that enum is absent from the program.
    int         result_enum_id;
    int         err_tag;
    int         option_enum_id;
    int         none_tag;
    // OFI-111b: enum variant table (variant name by enum_id+tag), owned, for Fault value rendering.
    EnumVariantInfo *variants;
    int          variant_count;
} CompiledProgram;

void compiled_program_init(CompiledProgram *prog);
void compiled_program_free(CompiledProgram *prog);

#endif // EMBER_PROGRAM_H
