#ifndef EMBER_CODEGEN_H
#define EMBER_CODEGEN_H

#include "ast.h"
#include "module.h"
#include "program.h"
#include "mono.h"

// Lowers a checked program into a CompiledProgram: one bytecode function per
// top-level `fn`, with `main` marked as the entry point. Calls are resolved to
// function-table indices.
//
// Assumes the program already passed check_program for the current slice, so
// forms outside the slice are treated as internal invariant violations. Returns
// 1 on error (e.g. there is no `main`), 0 on success. On success the caller owns
// `out` and must release it with compiled_program_free.
int codegen_program(const Program *ast, const ModuleSet *modules,
                    const MonoPlan *plan, const StructLayout *layouts,
                    int layout_count, CompiledProgram *out,
                    const char *source_name);

// Build profile (MANIFESTO §5e). When 1 (a `--release` build), codegen ELIDES the
// debug-only contract checks (`requires`/`ensures`) so release runs at zero cost;
// the default 0 (debug) emits them. Set by the driver before compiling. A whole-
// compilation setting, like g_std_dir — the compiler is a single-threaded batch.
extern int codegen_release_profile;

#endif // EMBER_CODEGEN_H
