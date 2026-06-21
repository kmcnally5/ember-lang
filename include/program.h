#ifndef EMBER_PROGRAM_H
#define EMBER_PROGRAM_H

#include "chunk.h"

// A compiled function: its (owned) name, parameter count, and bytecode chunk.
// Each function has its own chunk; calls reference functions by index in the
// program's function table.
typedef struct {
    char *name;
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
    // Per-field layout, dynamically sized to field_count (no EMBER_MAX_FIELDS cap — a struct may have
    // any number of fields; the field-index operands are LEB128 OPK_IDX). Owned by the CompiledProgram
    // and released by compiled_program_free. Accessed by index (offset[i]), identical to an array.
    int  *offset;
    int  *kind;          // ArrayElemKind per field (0 = boxed Value)
    int  *field_struct;  // for an AEK_INLINE_STRUCT field (value-types 3b.5): the nested struct's type
                         // id, so the VM can materialise a copy on read / size the inline bytes; -1 otherwise
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
    // Per-field layout, sized to field_count (no cap). The checker arena-allocates these in
    // build_layouts, so the StructLayout array can be freed with a plain free() and the per-entry
    // arrays are reclaimed wholesale at arena_free (which runs after codegen has read them).
    int *offset;
    int *kind;
    int *field_struct;              // nested struct id for an AEK_INLINE_STRUCT field, else -1
} StructLayout;

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
} CompiledProgram;

void compiled_program_init(CompiledProgram *prog);
void compiled_program_free(CompiledProgram *prog);

#endif // EMBER_PROGRAM_H
