#ifndef EMBER_MODULE_H
#define EMBER_MODULE_H

#include "ast.h"

// A program is one or more modules (source files) merged for whole-program
// compilation. The merged Program holds every module's declarations end to end;
// a ModuleInfo records each module's slice of that array plus its import aliases
// (each `import "path" as name` binds `name` to another module's index). The
// checker and codegen use this to scope name resolution: an unqualified name
// resolves within its own module; a qualified `name.foo` resolves the alias to a
// module, then looks up `foo` there (public only — a leading `_` means private).

#define MAX_MODULES 64
#define MAX_MODULE_IMPORTS 32

typedef struct {
    const char *path;        // canonical path (used for dedup and diagnostics)
    int         decl_start;  // index of this module's first decl in the merged Program
    int         decl_count;
    const char *aliases[MAX_MODULE_IMPORTS];
    int         targets[MAX_MODULE_IMPORTS];   // module index each alias resolves to
    int         import_count;
} ModuleInfo;

typedef struct {
    ModuleInfo modules[MAX_MODULES];
    int        count;
    int        prelude_module;   // index of the always-in-scope prelude module, or -1
} ModuleSet;

// is_global_module reports whether module `m` is the prelude module, whose types
// (Option/Result) are visible unqualified from every module — like Rust's prelude.
static inline int is_global_module(const ModuleSet *set, int m) {
    return set->prelude_module >= 0 && m == set->prelude_module;
}

// module_of_decl returns the module index that owns the declaration at `decl_idx`
// in the merged program, or 0 if out of range (the entry module).
static inline int module_of_decl(const ModuleSet *set, int decl_idx) {
    for (int i = 0; i < set->count; i++) {
        if (decl_idx >= set->modules[i].decl_start &&
            decl_idx < set->modules[i].decl_start + set->modules[i].decl_count) {
            return i;
        }
    }
    return 0;
}

// is_public reports whether a top-level declaration name is exported: a leading
// underscore marks it module-private (the FROG-style convention).
static inline int is_public_name(const char *name) {
    return name != NULL && name[0] != '_';
}

#endif // EMBER_MODULE_H
