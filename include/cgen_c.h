#ifndef EMBER_CGEN_C_H
#define EMBER_CGEN_C_H

#include <stdio.h>

#include "ast.h"
#include "module.h"
#include "program.h"
#include "mono.h"

// The native backend (docs/architecture.md "Decision: native backend"): a SECOND
// lowering of the same checked AST — alongside codegen_program's AST→bytecode — that
// emits a self-contained C translation unit. The C links the runtime in
// include/ember_rt.h and runs as a standalone binary (`emberc -o`), with the
// bytecode VM kept as the reference semantics the generated code is diffed against.
//
// Milestone M1 covers the scalar walking skeleton: int/float/bool, the operators,
// locals, if/loop/for-range/break/continue, direct (non-generic) calls, return.
// Anything outside that slice (structs, strings, arrays, generics, closures, FFI,
// concurrency, builtins) is reported as an error rather than mis-compiled, so the
// frontier is always honest. Returns 1 on error, 0 on success.
//
// Assumes `ast` already passed check_program (it reads the checker's resolved_fn /
// num_kind annotations); `modules`/`layouts` are accepted for parity with
// codegen_program and to carry the later milestones.
// `out_concurrency` (may be NULL) is set to 1 if the program uses spawn/nursery, so the driver
// links the parallel runtime (-DEMBER_PARALLEL -lpthread); 0 otherwise.
int cgen_c_program(const Program *ast, const ModuleSet *modules,
                   const MonoPlan *plan, const StructLayout *layouts,
                   int layout_count, FILE *out, const char *source_name,
                   int *out_concurrency);

#endif // EMBER_CGEN_C_H
