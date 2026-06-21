#ifndef EMBER_MONO_H
#define EMBER_MONO_H

#include "ast.h"

// The monomorphization plan the checker hands to codegen (Step 1 of native
// layout — see memory `ember-native-layout-build`). In the "append" model,
// non-generic functions keep their declaration-order function-table slot
// (`fi`), and each generic instantiation is appended as an extra slot. The plan
// tells codegen how many slots to emit, which function body fills each slot, and
// how each generic call resolves to its callee's slot.

// A resolved generic call: while emitting `caller_slot`, the call expression
// `call` targets the function in `callee_fi`.
typedef struct {
    const Expr *call;
    int         caller_slot;
    int         callee_fi;
} MonoPlanRes;

typedef struct {
    int          total_slots;    // size of the compiled function table
    int          base_fn_count;  // slots 0..base_fn_count-1 are the declared fns
    int         *base_of;        // [total_slots] the base fi whose FnDecl fills a slot
    MonoPlanRes *res;            // generic-call resolutions (scanned by caller+call)
    int          res_count;
    int          main_index;     // slot of `main`
} MonoPlan;

// Releases a plan's heap arrays. Safe on a zero-initialised plan.
void mono_plan_free(MonoPlan *plan);

#endif // EMBER_MONO_H
