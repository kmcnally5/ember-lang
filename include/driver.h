#ifndef EMBER_DRIVER_H
#define EMBER_DRIVER_H

#include "lexer.h"
#include "program.h"
#include "semindex.h"

// The compiler's full front-to-back pipeline as one call: load all modules, type-check, lower to
// bytecode. Diagnostics flow through diag.c (printed, or collected under diag_set_json). Returns 1
// if any stage reported an error. Lives in main.c; declared here so the language server can drive
// the very same pipeline (one source of truth — no second frontend, the rust-analyzer lesson).
int compile_program(const TokenList *tokens, const char *name, CompiledProgram *out);

// Runs load + type-check (no codegen) with the semantic index switched on, leaving a
// position-keyed identifier → {inferred type, definition site} index in `out_index` for the
// language server. Returns 1 on a front-end error; the partial index is still usable. The index
// owns its strings (release with semindex_free). See semindex.h and the LSP roadmap, Phase 2.
int collect_semantic_index(const TokenList *tokens, const char *name, SemanticIndex *out_index);

// Runs load + type-check ONLY (no codegen), leaving any diagnostics in the diag buffer for the
// caller to read. The language server reports SEMANTIC errors, not codegen results — and must
// type-check programs the running build cannot lower (e.g. graphics, whose signatures the checker
// always knows but whose implementation is opt-in). Returns 1 if an error was reported.
int check_diagnostics(const TokenList *tokens, const char *name);

#endif // EMBER_DRIVER_H
