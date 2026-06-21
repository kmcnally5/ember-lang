#ifndef EMBER_CHECK_H
#define EMBER_CHECK_H

#include "arena.h"
#include "ast.h"
#include "module.h"
#include "mono.h"
#include "program.h"
#include "semindex.h"

// Type-checks `program` for the current build slice. Per the walking-skeleton
// method (MANIFESTO §5c), the slice that compiles is intentionally small:
// functions whose bodies are integer-valued `return` statements. Anything
// outside the slice is reported as a clear, located error rather than silently
// accepted — the slice grows feature by feature.
//
// Returns 1 if any error was reported to stderr (located with source_name),
// 0 if the program is well-typed for this slice. On success, `out_plan` is
// filled with the monomorphization plan codegen consumes, and `*out_layouts` is
// set to a malloc'd array of `*out_layout_count` packed struct layouts (one per
// struct type id). The caller releases the plan with mono_plan_free and frees
// `*out_layouts`. On error both are left empty.
//
// `program` is mutated: lifted lambda functions are appended to its decl array
// (which the caller must allocate with EMBER_MAX_LAMBDAS slots of slack), and
// `arena` is used to allocate those synthetic declarations.
// `out_index`, when non-NULL, is filled with a position-keyed semantic index
// (identifier → inferred type + definition site) for the language server; pass
// NULL in batch compilation to skip building it at no cost. See semindex.h.
int check_program(Program *program, const ModuleSet *modules, Arena *arena,
                  const char *source_name, MonoPlan *out_plan,
                  StructLayout **out_layouts, int *out_layout_count,
                  SemanticIndex *out_index);

#endif // EMBER_CHECK_H
