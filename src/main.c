#include "lexer.h"
#include "parser.h"
#include "arena.h"
#include "ast.h"
#include "module.h"
#include "check.h"
#include "codegen.h"
#include "cgen_c.h"
#include "chunk.h"
#include "program.h"
#include "vm.h"
#include "prove.h"
#include "docgen.h"
#include "driver.h"
#include "lsp.h"
#include "diag.h"
#include "trace.h"
#include "fault.h"
#include "version.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>

// read_file slurps an entire file into a NUL-terminated, heap-allocated buffer
// the caller must free. Returns NULL (after printing why) if the file cannot be
// opened or read. The lexer needs the whole source resident anyway, since every
// token is a view into this buffer.
static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        fprintf(stderr, "emberc: cannot open '%s'\n", path);
        return NULL;
    }

    if (fseek(f, 0, SEEK_END) != 0) {
        fprintf(stderr, "emberc: cannot seek '%s'\n", path);
        fclose(f);
        return NULL;
    }
    long size = ftell(f);
    if (size < 0) {
        fprintf(stderr, "emberc: cannot size '%s'\n", path);
        fclose(f);
        return NULL;
    }
    rewind(f);

    char *buffer = malloc((size_t)size + 1);
    if (buffer == NULL) {
        fprintf(stderr, "emberc: out of memory reading '%s'\n", path);
        fclose(f);
        return NULL;
    }

    size_t read = fread(buffer, 1, (size_t)size, f);
    fclose(f);
    buffer[read] = '\0';
    return buffer;
}





// emit_tokens prints the token stream, one per line, as `line:col  TYPE  lexeme`.
static void emit_tokens(const TokenList *tokens) {
    for (size_t i = 0; i < tokens->count; i++) {
        Token t = tokens->tokens[i];
        printf("%4d:%-3d  %-10s  %.*s\n",
               t.line, t.col, token_type_name(t.type),
               (int)t.length, t.start);
    }
}





// emit_ast parses the tokens and prints the resulting tree. Returns 1 if a parse
// error occurred. The whole tree lives in a single arena, freed on return.
static int emit_ast(const TokenList *tokens, const char *name) {
    Arena arena;
    arena_init(&arena, 0);

    int parse_error = 0;
    Program program = parser_parse(tokens->tokens, tokens->count,
                                   &arena, name, &parse_error);
    ast_print(&program);

    arena_free(&arena);
    return parse_error;
}





// g_std_dir is the directory holding the standard library's `.em` files. The
// `std/` import prefix is reserved: `import "std/string"` resolves to a file in
// this directory regardless of the importer's location. Set once in main() from
// $EMBER_STD or, failing that, relative to the compiler binary.
static const char *g_std_dir = NULL;

// resolve_import_path joins an import path against the importing file's directory
// and appends ".em" — e.g. importer "dir/a.em" + import "b/c" -> "dir/b/c.em".
// The reserved `std/` prefix instead resolves against g_std_dir, so the standard
// library is found the same way from any source file.
static const char *resolve_import_path(Arena *arena, const char *importer,
                                       const char *import_path) {
    if (g_std_dir != NULL && strncmp(import_path, "std/", 4) == 0) {
        const char *rel = import_path + 4;   // the part after "std/"
        size_t dlen = strlen(g_std_dir);
        size_t rlen = strlen(rel);
        char *out = arena_alloc(arena, dlen + 1 + rlen + 4);  // dir + '/' + rel + ".em"
        memcpy(out, g_std_dir, dlen);
        out[dlen] = '/';
        memcpy(out + dlen + 1, rel, rlen);
        memcpy(out + dlen + 1 + rlen, ".em", 3);
        out[dlen + 1 + rlen + 3] = '\0';
        return out;
    }
    size_t dirlen = 0;
    for (size_t i = 0; importer[i] != '\0'; i++) {
        if (importer[i] == '/') {
            dirlen = i + 1;
        }
    }
    size_t plen = strlen(import_path);
    char *out = arena_alloc(arena, dirlen + plen + 4);   // dir + path + ".em" + NUL
    memcpy(out, importer, dirlen);
    memcpy(out + dirlen, import_path, plen);
    memcpy(out + dirlen + plen, ".em", 3);
    out[dirlen + plen + 3] = '\0';
    return out;
}





// init_std_dir locates the standard library: $EMBER_STD wins (installed toolchains), else
// `<dir-of-binary>/../std` — both the repo layout (build/emberc -> ../std) and a central install
// (~/.ember/bin/emberc -> ~/.ember/std). Called before any mode (including --lsp, which would
// otherwise resolve `std/` imports against a NULL directory).
static void init_std_dir(const char *argv0) {
    static char std_buf[4096];
    const char *env_std = getenv("EMBER_STD");
    if (env_std != NULL && env_std[0] != '\0') {
        g_std_dir = env_std;
        return;
    }
    size_t dirlen = 0;
    for (size_t i = 0; argv0[i] != '\0'; i++) {
        if (argv0[i] == '/') {
            dirlen = i + 1;
        }
    }
    int n = snprintf(std_buf, sizeof std_buf, "%.*s../std", (int)dirlen, argv0);
    if (n > 0 && (size_t)n < sizeof std_buf) {
        g_std_dir = std_buf;
    }
}





// The prelude — types every program gets for free, so `Option`/`Result` need not
// be redeclared (the `?` operator, `recv`, and `parse_int` all resolve them by
// name). It is ordinary Ember source, parsed like any module; a program that
// declares its own enum of the same name keeps its version (the prelude's is
// skipped), so existing code is unaffected.
#define MAX_PRELUDE_DECLS 32

static const char *PRELUDE_SOURCE =
    "enum Option<T> {\n"
    "    Some(value: T)\n"
    "    None\n"
    "}\n"
    "enum Result<T, E> {\n"
    "    Ok(value: T)\n"
    "    Err(error: E)\n"
    "}\n"
    // Hash and Eq: the bounds a hash map's key must satisfy. Built-in scalar/string
    // types satisfy them automatically (via native hashing/equality); a user struct
    // satisfies them by `implements Hash, Eq` and providing the methods. `Eq` uses
    // `Self`, so it is a bound only (not object-safe / a value type).
    "interface Hash {\n"
    "    fn hash(self) -> int\n"
    "}\n"
    "interface Eq {\n"
    "    fn eq(self, other: Self) -> bool\n"
    "}\n";


// program_declares_enum reports whether any already-parsed module declares a
// top-level enum named `name` — used to let a user's definition win over the
// prelude's (and so avoid a duplicate-variant clash).
static int program_declares_enum(const Program *progs, int count, const char *name) {
    for (int m = 0; m < count; m++) {
        for (size_t d = 0; d < progs[m].count; d++) {
            const Decl *decl = progs[m].decls[d];
            if (decl->kind == DECL_ENUM &&
                strcmp(decl->as.enum_.name, name) == 0) {
                return 1;
            }
        }
    }
    return 0;
}





// load_modules parses the entry module and every module it transitively imports,
// merging their declarations into one Program and recording module boundaries and
// import aliases in `set`. Modules are deduped by resolved path. Returns 1 on any
// load or parse error.
static int load_modules(const TokenList *entry_tokens, const char *entry_path,
                        Arena *arena, Program *merged, ModuleSet *set) {
    Program progs[MAX_MODULES];
    int error = 0;

    set->count = 1;
    set->prelude_module = -1;
    set->modules[0].path = entry_path;
    set->modules[0].import_count = 0;
    progs[0] = parser_parse(entry_tokens->tokens, entry_tokens->count,
                            arena, entry_path, &error);

    // Breadth-first over modules, discovering and loading imports.
    for (int m = 0; m < set->count; m++) {
        for (size_t d = 0; d < progs[m].count; d++) {
            Decl *decl = progs[m].decls[d];
            if (decl->kind != DECL_IMPORT) {
                continue;
            }
            const char *resolved =
                resolve_import_path(arena, set->modules[m].path, decl->as.import.path);
            int target = -1;
            for (int k = 0; k < set->count; k++) {
                if (strcmp(set->modules[k].path, resolved) == 0) {
                    target = k;
                    break;
                }
            }
            if (target < 0) {
                // Reserve one slot for the synthetic prelude module added below, so
                // a program that maxes out user modules never loses Option/Result.
                if (set->count >= MAX_MODULES - 1) {
                    fprintf(stderr, "emberc: too many modules\n");
                    error = 1;
                    continue;
                }
                char *src = read_file(resolved);
                if (src == NULL) {
                    error = 1;
                    continue;
                }
                TokenList toks = lexer_scan(src, resolved);
                int perr = 0;
                target = set->count;
                set->modules[target].path = resolved;
                set->modules[target].import_count = 0;
                progs[target] = parser_parse(toks.tokens, toks.count, arena,
                                             resolved, &perr);
                set->count++;
                if (toks.had_error || perr) {
                    error = 1;
                }
                token_list_free(&toks);
                free(src);
            }
            ModuleInfo *mi = &set->modules[m];
            if (mi->import_count < MAX_MODULE_IMPORTS) {
                mi->aliases[mi->import_count] = decl->as.import.alias;
                mi->targets[mi->import_count] = target;
                mi->import_count++;
            }
        }
    }

    int user_count = set->count;   // module count before the synthetic prelude module

    // Parse the prelude and keep only the types the program hasn't defined itself.
    // These (Option/Result) go in their own always-in-scope module so every module
    // — entry and imported alike — sees them unqualified, like Rust's prelude.
    int prelude_err = 0;
    TokenList ptoks = lexer_scan(PRELUDE_SOURCE, "<prelude>");
    Program prelude = parser_parse(ptoks.tokens, ptoks.count, arena, "<prelude>",
                                   &prelude_err);
    token_list_free(&ptoks);
    if (prelude_err) {
        error = 1;   // a malformed prelude is a compiler bug, not the user's
    }
    Decl *prelude_decls[MAX_PRELUDE_DECLS];
    int prelude_count = 0;
    for (size_t d = 0; d < prelude.count && prelude_count < MAX_PRELUDE_DECLS; d++) {
        Decl *decl = prelude.decls[d];
        if (decl->kind == DECL_ENUM &&
            program_declares_enum(progs, user_count, decl->as.enum_.name)) {
            continue;   // the program defines its own — let it win
        }
        prelude_decls[prelude_count++] = decl;
    }

    // The rest of the standard library (string functions, Map) now lives in real
    // files under std/ and is pulled in with `import "std/…"`, not auto-injected.

    // Append a synthetic module for the global prelude, after the user's modules.
    // Its types resolve from anywhere (see is_global_module). Import discovery
    // reserves a slot for it (caps user modules at MAX_MODULES - 1), so this fits
    // whenever there is a prelude to add; if it somehow cannot, fail loudly rather
    // than silently drop Option/Result.
    int pm = -1;
    if (prelude_count > 0) {
        if (set->count >= MAX_MODULES) {
            fprintf(stderr, "emberc: too many modules (no room for the prelude)\n");
            error = 1;
        } else {
            pm = set->count++;
            set->prelude_module = pm;
            set->modules[pm].path = "<prelude>";
            set->modules[pm].import_count = 0;
        }
    }

    // Concatenate every module's declarations into one array, recording ranges.
    // The prelude is its own always-in-scope module appended at the end.
    size_t total = (size_t)prelude_count;
    for (int m = 0; m < user_count; m++) {
        total += progs[m].count;
    }
    // Extra slack: the checker appends lifted lambda functions as DECL_FN entries
    // here, so mono and codegen pick them up like any other function.
    Decl **decls = arena_alloc(arena, (total + EMBER_MAX_LAMBDAS) * sizeof(Decl *));
    size_t idx = 0;
    for (int m = 0; m < user_count; m++) {
        set->modules[m].decl_start = (int)idx;
        for (size_t d = 0; d < progs[m].count; d++) {
            decls[idx++] = progs[m].decls[d];
        }
        set->modules[m].decl_count = (int)idx - set->modules[m].decl_start;
    }
    if (pm >= 0) {
        set->modules[pm].decl_start = (int)idx;
        for (int k = 0; k < prelude_count; k++) {
            decls[idx++] = prelude_decls[k];
        }
        set->modules[pm].decl_count = (int)idx - set->modules[pm].decl_start;
    }
    merged->decls = decls;
    merged->count = total;
    return error;
}





// compile_program runs the full front end — load all modules, type-check, lower —
// producing a CompiledProgram. Returns 1 if any stage reported an error. The AST
// arena is released before returning; the program owns its own storage.
int compile_program(const TokenList *tokens, const char *name,
                    CompiledProgram *out) {
    Arena arena;
    arena_init(&arena, 0);

    Program program;
    ModuleSet set;
    MonoPlan plan = {0};
    StructLayout *layouts = NULL;
    int layout_count = 0;
    int error = load_modules(tokens, name, &arena, &program, &set);
    if (!error) {
        error = check_program(&program, &set, &arena, name, &plan, &layouts,
                              &layout_count, NULL);
    }
    if (!error) {
        error = codegen_program(&program, &set, &plan, layouts, layout_count,
                                out, name);
    }

    mono_plan_free(&plan);
    free(layouts);
    arena_free(&arena);
    return error;
}





// collect_semantic_index runs the front end up to (and including) type-checking — load all
// modules, then check with the semantic index switched on — and leaves the position-keyed index
// in `out_index` for the language server (hover, go-to-definition). It stops before codegen: the
// index is about meaning, not bytecode. The index owns its strings, so it outlives the AST arena
// this releases. Returns 1 if the front end reported an error (the partial index is still usable —
// the checker records what it resolved before the error).
int collect_semantic_index(const TokenList *tokens, const char *name, SemanticIndex *out_index) {
    Arena arena;
    arena_init(&arena, 0);

    Program program;
    ModuleSet set;
    MonoPlan plan = {0};
    StructLayout *layouts = NULL;
    int layout_count = 0;
    int error = load_modules(tokens, name, &arena, &program, &set);
    if (!error) {
        error = check_program(&program, &set, &arena, name, &plan, &layouts,
                              &layout_count, out_index);
    }

    mono_plan_free(&plan);
    free(layouts);
    arena_free(&arena);
    return error;
}





// check_diagnostics type-checks `tokens` (no index, no codegen), leaving diagnostics in the diag
// buffer for the caller to read. It is collect_semantic_index without the index — the language
// server's diagnostic path, so it reports semantic errors only and can check programs (e.g. graphics)
// the running build cannot lower.
int check_diagnostics(const TokenList *tokens, const char *name) {
    return collect_semantic_index(tokens, name, NULL);
}





// emit_bytecode compiles and disassembles every function. Returns 1 on error.
static int emit_bytecode(const TokenList *tokens, const char *name) {
    CompiledProgram prog;
    compiled_program_init(&prog);
    int error = compile_program(tokens, name, &prog);
    if (!error) {
        for (int i = 0; i < prog.count; i++) {
            printf("== fn %s (arity %d) ==\n",
                   prog.functions[i].name, prog.functions[i].arity);
            chunk_disassemble(&prog.functions[i].chunk);
        }
    }
    compiled_program_free(&prog);
    return error;
}





// render_scalar_into stringifies a scalar/string Value into `buf` for a Fault value field.
static void render_scalar_into(char *buf, size_t n, Value v) {
    if (IS_INT(v)) {
        snprintf(buf, n, "%lld", (long long)AS_INT(v));
    } else if (IS_FLOAT(v)) {
        snprintf(buf, n, "%g", AS_FLOAT(v));
    } else if (IS_STRING(v)) {
        snprintf(buf, n, "%s", AS_CSTRING(v));
    } else {
        snprintf(buf, n, "<obj>");
    }
}




// report_unhandled_error detects an Err/None that `main` returned without handling and reports
// it as a Fault (FCAT_UNHANDLED_ERR) — closing the wart where an unhandled Err exited 0 with a
// bare `=> <obj>`. Identity is the prelude Result/Option failure variant recorded at codegen
// (docs/faults.md). Returns 1 (and renders) if it was an unhandled Err/None, else 0. Must run
// before vm_destroy frees the value. (The `?`-propagation route is layered on by OFI-108.)
static int report_unhandled_error(const char *path, const CompiledProgram *prog,
                                  const VM *vm, Value result) {
    if (!IS_STRUCT(result) || !AS_STRUCT(result)->is_enum) {
        return 0;
    }
    ObjStruct *e = AS_STRUCT(result);
    int is_err  = prog->result_enum_id >= 0 &&
                  e->type_id == prog->result_enum_id && e->tag == prog->err_tag;
    int is_none = prog->option_enum_id >= 0 &&
                  e->type_id == prog->option_enum_id && e->tag == prog->none_tag;
    if (!is_err && !is_none) {
        return 0;
    }
    Fault f;
    memset(&f, 0, sizeof f);
    f.severity = FSEV_ERROR;
    f.category = FCAT_UNHANDLED_ERR;
    f.file     = path;
    f.fn       = "main";
    if (is_err) {
        f.code    = "unhandled_error";
        f.message = "an Err returned by main was never handled";
        f.why     = "a Result that reaches main must be handled (match its Err), not left to propagate out";
        f.hint    = "match the Result and handle the Err arm (or have main do something with the error)";
        if (e->field_count >= 1) {
            Value payload;
            memcpy(&payload, e->data, sizeof(Value));   // an enum field is a 16-byte boxed Value
            f.values[0].name = "error";
            render_scalar_into(f.values[0].rendered, sizeof f.values[0].rendered, payload);
            f.value_count = 1;
        }
    } else {
        f.code    = "unhandled_none";
        f.message = "a None returned by main was never handled";
        f.why     = "an Option that reaches main must be handled (match its None), not left to propagate out";
        f.hint    = "match the Option and handle the None arm";
    }
    // The `?`-propagation route (OFI-108): how the Err/None travelled here. The synchronous call
    // stack is empty by now (the propagating frames returned), so this recorded chain is the route.
    vm_route(vm, f.route, &f.route_count);
    fault_render(&f, stderr);
    return 1;
}




// emit_run compiles and executes the program, printing the value main returns as
// `=> N`. Returns 1 on a compile or runtime error.
static int emit_run(const TokenList *tokens, const char *name) {
    CompiledProgram prog;
    compiled_program_init(&prog);
    int error = compile_program(tokens, name, &prog);
    if (!error) {
        VM *vm = vm_create(&prog);
        Value result = INT_VAL(0);
        if (vm_run(vm, &result, NULL) == VM_OK) {
            int code;
            if (vm_exited(vm, &code)) {
                // The program called exit(code): terminate with that code, no `=> N`.
                vm_destroy(vm);
                compiled_program_free(&prog);
                fflush(stdout);
                exit(code);
            }
            if (report_unhandled_error(name, &prog, vm, result)) {
                error = 1;   // an unhandled Err/None reached main → Fault on stderr, non-zero exit
            } else if (IS_INT(result)) {
                printf("=> %lld\n", (long long)AS_INT(result));
            } else if (IS_FLOAT(result)) {
                printf("=> %g\n", AS_FLOAT(result));
            } else if (IS_STRING(result)) {
                printf("=> %s\n", AS_CSTRING(result));
            } else {
                printf("=> <obj>\n");
            }
        } else {
            error = 1;
        }
        vm_destroy(vm);   // frees the result's heap objects (after we used them)
    }
    compiled_program_free(&prog);
    return error;
}





// emit_c lowers the program to a C translation unit via the native backend
// (docs/architecture.md "Decision: native backend") and writes it to `out`. It runs
// the same front end as compile_program but keeps the AST alive — the C emitter
// reads it directly — so it can't reuse compile_program (which frees the arena).
// Returns 1 on error.
static int emit_c(const TokenList *tokens, const char *name, FILE *out,
                  int *out_concurrency) {
    Arena arena;
    arena_init(&arena, 0);

    Program program;
    ModuleSet set;
    MonoPlan plan = {0};
    StructLayout *layouts = NULL;
    int layout_count = 0;
    int error = load_modules(tokens, name, &arena, &program, &set);
    if (!error) {
        error = check_program(&program, &set, &arena, name, &plan, &layouts,
                              &layout_count, NULL);
    }
    if (!error) {
        error = cgen_c_program(&program, &set, &plan, layouts, layout_count, out, name,
                               out_concurrency);
    }

    mono_plan_free(&plan);
    free(layouts);
    arena_free(&arena);
    return error;
}





// compile_native is the `emberc -o <bin> file.em` path: emit the program's C next to
// the target, then invoke the system C compiler to link it against the runtime
// (include/ember_rt.h, found relative to the emberc executable) into a standalone
// binary. The generated C is removed on success and kept on failure for inspection.
// Returns 1 on any error.
static int compile_native(const TokenList *tokens, const char *name,
                          const char *out_path, const char *argv0) {
    char cpath[4096];
    snprintf(cpath, sizeof cpath, "%s.c", out_path);

    FILE *cf = fopen(cpath, "w");
    if (cf == NULL) {
        fprintf(stderr, "emberc: cannot write '%s'\n", cpath);
        return 1;
    }
    int concurrent = 0;
    int error = emit_c(tokens, name, cf, &concurrent);
    fclose(cf);
    if (error) {
        return 1;   // keep cpath so the failing C can be inspected
    }

    // The runtime header and static library live next to the compiler: the header at
    // <dir-of-emberc>/../include, the library (libember_rt.a) at <dir-of-emberc>.
    char incdir[2048];
    char libdir[2048];
    const char *slash = strrchr(argv0, '/');
    if (slash != NULL) {
        int n = (int)(slash - argv0);
        snprintf(incdir, sizeof incdir, "%.*s/../include", n, argv0);
        snprintf(libdir, sizeof libdir, "%.*s", n, argv0);
    } else {
        snprintf(incdir, sizeof incdir, "include");
        snprintf(libdir, sizeof libdir, "build");
    }

    // A concurrent program needs the THREADED runtime: build with -DEMBER_PARALLEL (atomic
    // refcounts + the channel/nursery pthread machinery) and link the parallel runtime variant
    // + pthread. A serial program links the default runtime with no threading cost.
    //   -D_DEFAULT_SOURCE: expose the POSIX functions the runtime uses under strict -std=c17 on
    //                      glibc (no-op on macOS).  -lm: libm is a separate library on Linux
    //                      (folded into libc on macOS) — it must follow the objects on the link
    //                      line.  -pthread (portable spelling, both platforms) for the parallel rt.
    char cmd[16384];
    if (concurrent) {
        snprintf(cmd, sizeof cmd,
                 "cc -std=c17 -O2 -D_DEFAULT_SOURCE -DEMBER_PARALLEL=1 -I'%s' '%s' "
                 "'%s/libember_rt_par.a' -pthread -lm -o '%s'",
                 incdir, cpath, libdir, out_path);
    } else {
        snprintf(cmd, sizeof cmd,
                 "cc -std=c17 -O2 -D_DEFAULT_SOURCE -I'%s' '%s' '%s/libember_rt.a' -lm -o '%s'",
                 incdir, cpath, libdir, out_path);
    }
    int rc = system(cmd);
    if (rc != 0) {
        fprintf(stderr, "emberc: C compilation failed (cc exit %d); kept %s\n", rc, cpath);
        return 1;
    }
    remove(cpath);
    return 0;
}




// emit_check compiles the program and runs property-based contract checking (§5j): every
// fuzzable function (a free, non-generic function with an `ensures` and all-scalar params) is
// exercised on generated inputs, and the first input that falsifies a postcondition / `assert`
// (or crashes) is reported as a counterexample. Returns 1 on a compile error or any failure.
static int emit_check(const TokenList *tokens, const char *name) {
    CompiledProgram prog;
    compiled_program_init(&prog);
    int error = compile_program(tokens, name, &prog);
    if (!error) {
        VM *vm = vm_create(&prog);
        if (vm_check(vm, NULL) > 0) {
            error = 1;
        }
        vm_destroy(vm);
    }
    compiled_program_free(&prog);
    return error;
}





// emit_replay compiles the program and runs deterministic record-replay (§5j): it executes the
// program once recording every nondeterministic scalar (`random`, the clock) and then again
// replaying those values, verifying the two runs are byte-for-byte identical. Returns 1 on a
// compile error or if the replay diverges.
static int emit_replay(const TokenList *tokens, const char *name) {
    CompiledProgram prog;
    compiled_program_init(&prog);
    int error = compile_program(tokens, name, &prog);
    if (!error) {
        if (vm_replay(&prog, NULL) != 0) {
            error = 1;
        }
    }
    compiled_program_free(&prog);
    return error;
}





// emit_prove runs the front end (parse + check) and then statically proves what it can of every
// function's `ensures` postconditions in the linear-integer fragment (§5j brick 4), printing a
// per-clause report. The AST arena must outlive the proof, so this mirrors compile_program's
// setup but stops before codegen. Returns 1 only on a front-end error (proving is informational).
static int emit_prove(const TokenList *tokens, const char *name) {
    Arena arena;
    arena_init(&arena, 0);

    Program program;
    ModuleSet set;
    MonoPlan plan = {0};
    StructLayout *layouts = NULL;
    int layout_count = 0;
    int error = load_modules(tokens, name, &arena, &program, &set);
    if (!error) {
        error = check_program(&program, &set, &arena, name, &plan, &layouts, &layout_count, NULL);
    }
    if (!error) {
        prove_program(&program);
    }

    mono_plan_free(&plan);
    free(layouts);
    arena_free(&arena);
    return error;
}





// emit_docs parses the file and writes Markdown API documentation to stdout, built from the
// `///` doc comments the source carries (the same prose the LSP shows on hover — source feeds
// both). Like emit_ast it stops after parsing; docs are about surface API, not semantics.
// Returns 1 on a parse error.
static int emit_docs(const TokenList *tokens, const char *name) {
    Arena arena;
    arena_init(&arena, 0);

    int parse_error = 0;
    Program program = parser_parse(tokens->tokens, tokens->count,
                                   &arena, name, &parse_error);

    // Title the page with the file's base name, sans directory and ".em".
    const char *base = name;
    for (const char *q = name; *q != '\0'; q++) {
        if (*q == '/') { base = q + 1; }
    }
    char title[256];
    size_t tn = 0;
    for (const char *q = base; *q != '\0' && tn < sizeof title - 1; q++) {
        if (q[0] == '.' && q[1] == 'e' && q[2] == 'm' && q[3] == '\0') { break; }
        title[tn++] = *q;
    }
    title[tn] = '\0';

    docgen_emit(&program, title, stdout);

    arena_free(&arena);
    return parse_error;
}




// emit_trace compiles and runs the program with the JSON-Lines tape sink
// attached, writing one event per executed instruction to stdout (the
// execution "tape"). Returns 1 on a compile or runtime error.
static int emit_trace(const TokenList *tokens, const char *name) {
    CompiledProgram prog;
    compiled_program_init(&prog);
    int error = compile_program(tokens, name, &prog);
    if (!error) {
        VM *vm = vm_create(&prog);
        Value result = INT_VAL(0);
        Tracer tracer = tracer_json_lines(stdout);
        if (vm_run(vm, &result, &tracer) != VM_OK) {
            error = 1;
        }
        vm_destroy(vm);
    }
    compiled_program_free(&prog);
    return error;
}





// run_doctor is `emberc --doctor`: a one-command setup health-check (the flutter-doctor pattern).
// The LSP setup/install phase is where newcomers bounce — one unexplained failure and they give up —
// so this verifies the pieces a working language server needs (the binary, the stdlib, a healthy
// shared frontend) and prints the EXACT fix for anything wrong, then the editor next-steps. Returns
// 0 when the essentials pass, 1 otherwise.
static int run_doctor(const char *argv0) {
    printf("emberc doctor — checking your Ember setup\n\n");
    int ok = 1;

    // 1. The binary itself — we are running, so this is informational (shows which emberc this is).
    printf("[ok]   emberc            %s\n", argv0);

    // 2. The standard library must resolve, or every `import \"std/...\"` fails (the LSP resolves it
    //    too). g_std_dir was set by init_std_dir from $EMBER_STD or <bin>/../std.
    int  std_ok = 0;
    char probe[4096];
    if (g_std_dir != NULL) {
        snprintf(probe, sizeof probe, "%s/string.em", g_std_dir);
        FILE *f = fopen(probe, "rb");
        if (f != NULL) {
            fclose(f);
            std_ok = 1;
        }
    }
    if (std_ok) {
        printf("[ok]   standard library  %s\n", g_std_dir);
    } else {
        ok = 0;
        printf("[!!]   standard library  NOT FOUND (looked in %s)\n",
               g_std_dir != NULL ? g_std_dir : "<unset>");
        printf("       fix: run `make install`, or set EMBER_STD to the directory holding std/*.em\n");
    }

    // 3. The frontend (lexer + parser + checker) must be healthy — the LSP shares it, so a broken
    //    build shows up as nonsense diagnostics in the editor. Type-check a trivial program in-process.
    diag_reset();
    TokenList toks = lexer_scan("fn main() -> int { return 0 }\n", "<doctor>");
    check_diagnostics(&toks, "<doctor>");
    int frontend_errs = diag_count();
    token_list_free(&toks);
    diag_reset();
    if (frontend_errs == 0) {
        printf("[ok]   compiler frontend  self-test passed (lex + parse + type-check)\n");
    } else {
        ok = 0;
        printf("[!!]   compiler frontend  self-test FAILED — this build is broken; rebuild with `make`\n");
    }

    // 4. The language server is this very binary (one frontend, no second process).
    printf("[ok]   language server    %s --lsp  (ready)\n", argv0);

    // 5. The editor's LSP runs the INSTALLED binary (~/.ember/bin/emberc), not build/emberc — so a
    //    rebuild that wasn't re-installed leaves the editor on STALE code (phantom errors, missing
    //    features; the gotcha behind Zed/VS Code showing old behaviour after a change). Compare the
    //    installed binary's version to this one. Advisory — it never changes the exit code.
    const char *home = getenv("HOME");
    char        installed[4096];
    snprintf(installed, sizeof installed, "%s/.ember/bin/emberc", home != NULL ? home : "");
    char run_real[PATH_MAX]  = "";
    char inst_real[PATH_MAX] = "";
    int  have_run  = realpath(argv0, run_real) != NULL;
    int  have_inst = realpath(installed, inst_real) != NULL;
    if (have_inst && have_run && strcmp(run_real, inst_real) == 0) {
        printf("[ok]   installed binary   you are running it (v%s)\n", EMBER_VERSION);
    } else if (have_inst) {
        char cmd[5000];
        snprintf(cmd, sizeof cmd, "\"%s\" --version 2>/dev/null", installed);
        char  ver[256] = "";
        FILE *p        = popen(cmd, "r");
        if (p != NULL) {
            if (fgets(ver, sizeof ver, p) == NULL) {
                ver[0] = '\0';
            }
            pclose(p);
        }
        ver[strcspn(ver, "\r\n")] = '\0';                 // trim the trailing newline
        if (strstr(ver, EMBER_VERSION) != NULL) {
            printf("[ok]   installed binary   %s (v%s — your editor's LSP matches this build)\n",
                   installed, EMBER_VERSION);
        } else {
            printf("[! ]   installed binary   STALE — your editor's LSP runs %s\n", installed);
            printf("       it reports \"%s\" but this build is v%s; the editor won't see recent\n",
                   ver[0] != '\0' ? ver : "an older/unknown version", EMBER_VERSION);
            printf("       changes until you run `make install` (then reload the editor).\n");
        }
    } else {
        printf("[--]   installed binary   none at %s\n", installed);
        printf("       run `make install` so your editor can find emberc on the default path.\n");
    }

    // Editor setup — the friction phase. Spell it out so no one gets stuck on the steps we hit.
    printf("\nEditor setup:\n");
    printf("  VS Code:  make install-vscode    then reload the window\n");
    printf("  Zed:      Rust via rustup, NOT Homebrew:   rustup target add wasm32-wasip1\n");
    printf("            make build-zed    then  palette -> 'zed: install dev extension' -> editors/zed/\n");
    printf("  After ANY change to emberc:  make install   then reload your editor\n");
    printf("            (your editor runs the INSTALLED binary, not build/emberc)\n");

    printf("\n%s\n", ok
        ? "All essential checks passed — the Ember LSP is ready."
        : "Some checks failed — fix the [!!] item(s) above, then re-run `emberc --doctor`.");
    return ok ? 0 : 1;
}



// main is the compiler driver. It tokenizes one .em file and, depending on the
// optional --emit mode, prints the token stream (default), the parsed AST, the
// compiled bytecode, or runs the program. Exit codes follow the BSD sysexits
// convention: 64 = usage, 65 = the source had an error, 66 = unreadable file.
int main(int argc, char **argv) {
    init_std_dir(argv[0]);   // locate the stdlib before ANY mode (the LSP resolves std/ too)

    // The language server (MANIFESTO §5: tooling) takes over stdio entirely, so handle it before
    // the file-oriented driver: `emberc --lsp` speaks JSON-RPC, no source file argument.
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--lsp") == 0) {
            return lsp_main();
        }
        if (strcmp(argv[i], "--doctor") == 0) {
            return run_doctor(argv[0]);
        }
        if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-v") == 0) {
            printf("emberc %s\n", EMBER_VERSION);
            return 0;
        }
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf(
                "emberc %s — the Ember compiler & language server\n\n"
                "usage:\n"
                "  emberc <file.em>                inspect/compile a source file (default --emit=tokens)\n"
                "  emberc --emit=<mode> <file.em>  mode: run|ast|bytecode|c|docs|prove|check|replay|trace|tokens\n"
                "  emberc -o <bin> <file.em>       compile to a native binary (C backend)\n"
                "  emberc --tape <file.em>         record the execution tape (alias for --emit=trace)\n"
                "  emberc --lsp                    run the language server (JSON-RPC over stdio)\n"
                "  emberc --doctor                 check your setup and print the fix for anything wrong\n"
                "  emberc --version                print the version\n"
                "  emberc --help                   show this help\n\n"
                "flags:\n"
                "  --release                       elide debug-only contract checks\n"
                "  --diagnostics=json              structured (LLM-friendly) error output\n\n"
                "Building Ember itself? Run `make help` for the build / test / install commands.\n",
                EMBER_VERSION);
            return 0;
        }
    }

    const char *emit = "tokens";
    const char *path = NULL;
    const char *out_path = NULL;   // `-o <bin>`: compile to a native binary (native backend)
    int release = 0;
    int   prog_argc = 0;        // the Ember PROGRAM's args: everything after the source file
    char **prog_argv = NULL;
    for (int i = 1; i < argc; i++) {
        if (path != NULL) {
            // Once the source file is seen, the rest belong to the program (`args()`),
            // so `emberc --emit=run app.em foo bar` passes ["foo","bar"] to app.em.
            prog_argv = &argv[i];
            prog_argc = argc - i;
            break;
        }
        if (strcmp(argv[i], "--release") == 0) {
            release = 1;                  // elide debug-only contract checks (§5e)
        } else if (strcmp(argv[i], "--diagnostics=json") == 0) {
            diag_set_json(1);             // structured errors for an LLM author
        } else if (strncmp(argv[i], "--faults=", 9) == 0) {
            const char *m = argv[i] + 9;  // how a RUNTIME fault renders (docs/faults.md)
            if (strcmp(m, "agent") == 0 || strcmp(m, "json") == 0) {
                fault_set_mode(FAULT_RENDER_AGENT);   // terse JSON Lines for an LLM/tool
            } else if (strcmp(m, "human") == 0) {
                fault_set_mode(FAULT_RENDER_HUMAN);   // the default teacher-voice render
            } else {
                fprintf(stderr, "emberc: --faults= must be 'human' or 'agent'\n");
                return 64;
            }
        } else if (strncmp(argv[i], "--emit=", 7) == 0) {
            emit = argv[i] + 7;
        } else if (strcmp(argv[i], "--tape") == 0) {
            emit = "trace";               // FROG-style alias: record the execution tape
        } else if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "emberc: -o requires an output path\n");
                return 64;
            }
            out_path = argv[++i];         // native backend: compile to a standalone binary
        } else if (argv[i][0] == '-') {
            path = NULL;                  // unknown flag before the source file
            break;
        } else {
            path = argv[i];
        }
    }
    vm_set_program_args(prog_argc, prog_argv);
    vm_set_source_path(path);   // a runtime Fault's `where.file` (NULL → file-less, still line-precise)
    if (path == NULL) {
        fprintf(stderr,
                "usage: %s [--emit=tokens|ast|bytecode|run|trace|check|replay|prove|docs|c] [--release] <file.em>\n"
                "       %s -o <bin> <file.em>   (compile to a native binary via the C backend)\n"
                "       %s --tape <file.em>     (alias for --emit=trace)\n"
                "       %s --lsp | --doctor | --version | --help\n",
                argv[0], argv[0], argv[0], argv[0]);
        return 64;
    }
    // Whole-compilation build profile: release elides contract checks (codegen.h).
    codegen_release_profile = release;

    char *source = read_file(path);
    if (source == NULL) {
        return 66;
    }

    TokenList tokens = lexer_scan(source, path);

    int rc;
    if (out_path != NULL) {
        // Native backend: `emberc -o <bin> file.em` compiles to a standalone binary,
        // regardless of any --emit mode given.
        int error = compile_native(&tokens, path, out_path, argv[0]);
        rc = (tokens.had_error || error) ? 65 : 0;
    } else if (strcmp(emit, "c") == 0) {
        int error = emit_c(&tokens, path, stdout, NULL);
        rc = (tokens.had_error || error) ? 65 : 0;
    } else if (strcmp(emit, "tokens") == 0) {
        emit_tokens(&tokens);
        rc = tokens.had_error ? 65 : 0;
    } else if (strcmp(emit, "ast") == 0) {
        int parse_error = emit_ast(&tokens, path);
        rc = (tokens.had_error || parse_error) ? 65 : 0;
    } else if (strcmp(emit, "bytecode") == 0) {
        int error = emit_bytecode(&tokens, path);
        rc = (tokens.had_error || error) ? 65 : 0;
    } else if (strcmp(emit, "run") == 0) {
        int error = emit_run(&tokens, path);
        rc = (tokens.had_error || error) ? 65 : 0;
    } else if (strcmp(emit, "trace") == 0) {
        int error = emit_trace(&tokens, path);
        rc = (tokens.had_error || error) ? 65 : 0;
    } else if (strcmp(emit, "check") == 0) {
        int error = emit_check(&tokens, path);
        rc = (tokens.had_error || error) ? 65 : 0;
    } else if (strcmp(emit, "replay") == 0) {
        int error = emit_replay(&tokens, path);
        rc = (tokens.had_error || error) ? 65 : 0;
    } else if (strcmp(emit, "prove") == 0) {
        int error = emit_prove(&tokens, path);
        rc = (tokens.had_error || error) ? 65 : 0;
    } else if (strcmp(emit, "docs") == 0) {
        int parse_error = emit_docs(&tokens, path);
        rc = (tokens.had_error || parse_error) ? 65 : 0;
    } else {
        fprintf(stderr, "emberc: unknown emit mode '%s' (expected tokens or ast)\n", emit);
        rc = 64;
    }

    // Under --diagnostics=json the errors were collected, not printed; emit them now
    // as JSON Lines (to stderr, leaving stdout for program/tape output).
    if (diag_json_enabled()) {
        diag_flush_json(stderr);
        diag_reset();
    }

    token_list_free(&tokens);
    free(source);
    return rc;
}
