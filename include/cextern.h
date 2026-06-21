#ifndef EMBER_CEXTERN_H
#define EMBER_CEXTERN_H

#include "value.h"

// Foreign (C) functions exposed to Ember through an `extern "c"` block (MANIFESTO §5h, the FFI).
// Dispatch is through this in-tree registry of typed wrappers (no libffi, no dlopen).
//
// The boundary is defined by the **leaf scalar sequence**: a struct argument is flattened to its
// scalar leaves on the Ember side (it is held as a flat run of slots already — value-types), and
// the wrapper reassembles a *concrete C struct* from those leaves and passes it BY VALUE, so the
// system C compiler generates the platform's exact aggregate calling convention (the C ABI). A
// struct result is flattened back to leaves the same way. A `kind` codes one leaf:
//   'f' = float  (f32/f64)
//   'i' = int    (i8..i64 / u8..u64)
//   'p' = const char*  — the leaf is an Ember `string` Value; the wrapper reads AS_CSTRING (its
//         bytes are NUL-terminated). Borrowed for the call's duration (§5h pointers).
//   'b' = buffer — the leaf is a packed scalar array (`[u8]`/`[i32]`/…) Value; the wrapper reads
//         ((ObjArray*)AS_OBJ(v))->data and ->length. Borrowed; a `mut` buffer may be written in
//         place. Never a `[string]`/`[struct]` (those are boxed, not a C buffer).
//   'P' = opaque Ptr — the leaf carries a C pointer/handle (FILE*, void*, …) in the int64 slot;
//         the wrapper round-trips it with the PTR_VAL/AS_CPTR helpers in cextern.c.
#define CEXTERN_MAX_LEAVES 8

typedef struct {
    const char *name;
    int         in_leaves;                 // total scalar leaves across all args (structs flat)
    char        in_kind[CEXTERN_MAX_LEAVES];
    int         out_leaves;                // result leaves (1 for a scalar, N for a struct)
    char        out_kind[CEXTERN_MAX_LEAVES];
    int         ret_is_struct;            // 1 if the C function returns a struct (reassemble)
    int         ret_is_string;            // 1 if the wrapper returns a malloc'd char* that the FFI
                                          // COPIES into an Ember string, then frees (the §5h / OFI-043
                                          // copy-on-return rule). The pointer is delivered in out[0]
                                          // as a PTR_VAL; the VM/native marshalling does copy + free.
} CExternSig;

// cextern_lookup returns the registry index for `name`, or -1 if it is not a known C function.
int cextern_lookup(const char *name);

// cextern_sig returns the signature for a valid registry index (from cextern_lookup).
const CExternSig *cextern_sig(int index);

// cextern_call invokes C function `index`: it reads `in` (the flattened scalar leaves of all
// arguments, in order) and writes the result leaves to `out`, returning how many it wrote.
int cextern_call(int index, const Value *in, Value *out);

#endif // EMBER_CEXTERN_H
