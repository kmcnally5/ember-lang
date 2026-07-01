// The native backend's C emitter (docs/architecture.md "Decision: native backend").
// A second lowering of the checked AST — the counterpart to src/codegen.c's AST→
// bytecode — that writes a self-contained C translation unit linking include/
// ember_rt.h. The bytecode VM stays the reference semantics; this output is held to
// it by the differential test in tests/native/.
//
// Milestone M1 — the scalar walking skeleton. Each Ember function becomes a C
// function over the uniform `Value` (mirroring the VM's stack discipline, which is
// what makes results bit-identical); native-typed scalars are a later optimisation.
// Covered: int/float/bool literals, the operators, locals, assignment, if/else,
// loop, for-over-range, break/continue, blocks, direct (non-generic) calls, return.
// Everything else is reported as an error so the implemented frontier stays honest.

#include "cgen_c.h"

#include "ast.h"
#include "token.h"
#include "builtin.h"    // native_id_for_name + the NATIVE_* registry ids (M5 builtins)
#include "cextern.h"    // cextern_sig — the FFI return-struct flag (M5)

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// One in-scope binding: the Ember name and the C identifier it lowered to (a
// parameter "a<i>" or a local "v<n>"). `drop` marks an owned value (a struct/array/
// string the binding must release at scope exit). Lookups scan from the top so an
// inner `let` shadows an outer binding of the same name.
typedef struct {
    const char *name;
    char        cname[40];
    int         drop;
    int         multislot_sid;   // a value-type struct binding's type id, else -1
    int         scalar_kind;     // OFI-123: a sized numeric binding's width kind (int_kind 0..9),
                                 // so it lowers to a typed C scalar (uint8_t/…/float) stored at
                                 // width; reads box back to a Value. -1 for a non-numeric binding.
} CgcBinding;

// Declared (user) field names of a struct, indexed by struct type id — so a struct
// literal's named fields can be emitted in DECLARED order (the literal may list them
// in any order), matching the packed layout.
typedef struct {
    const char  *sname;        // the struct's own name (to resolve a param/return type)
    int          field_count;
    const char **names;        // dynamic, sized to field_count (no cap). An instance id shallow-aliases
                               // its base struct's array, so only declared structs own/free it.
} CgcStructNames;

// An enum variant by name: its enum's type id, its tag (variant index), and how many
// payload fields it carries. Drives boxed-enum construction and match dispatch.
typedef struct {
    const char *name;
    int         enum_id;
    int         variant_index;
    int         field_count;
} CgcVariant;

typedef struct {
    FILE       *out;
    const char *src_name;
    int         had_error;
    int         indent;
    int         next_var;                  // per-function fresh-temp counter
    int         scope_len;
    int         scope_cap;        // allocated capacity of `scope`
    CgcBinding *scope;            // dynamic; no cap on bindings per function (matches the VM)
    // Struct tables: the checker's packed layouts (offset/kind/field_struct per sid) and
    // the declared field names. A value-type (all-scalar) struct lowers to a real C struct
    // `em_s<sid>` (value semantics, no heap), so these drive the typedefs, construction
    // (compound literals), field access (.f<idx>), and per-binding C typing.
    const StructLayout   *layouts;
    int                   struct_count;
    const CgcStructNames *snames;
    const FnDecl        **fn_by_fi;        // function-table slot -> FnDecl (for method self typing)
    int                   total_functions;
    // OFI-167: `extern "c"` functions NOT in the hosted FFI registry — the native backend forward-
    // declares each and emits a DIRECT call to its C symbol (linker-resolved against a freestanding
    // shim), instead of the registry trampoline `em_ffi`. Populated from the AST's extern blocks.
    const FnDecl        **direct_externs;
    int                   direct_extern_count;
    // Per fn slot: the OWNING struct's generic params (NULL/0 for a free fn), so a method's
    // param/return type named after the struct's type parameter (Box<T>'s `T`) is recognised as
    // ERASED, not resolved to a same-named user struct — the checker makes the same scope
    // distinction; the cgen must too, or it mis-types the param (OFI-053).
    const GenericParam  **owner_generics;
    const int            *owner_generic_count;
    const CgcVariant     *variants;        // enum variants, for construction + match
    int                   variant_count;
    int                   concurrent;      // program uses spawn/nursery (M4): thread-local g_em
    int                   nursery_id[16];  // enclosing nursery's emit id, for STMT_SPAWN to append
    int                   nursery_depth;
} CgcGen;


// An enum variant's descriptor by name, or NULL if `name` is not a variant.
static const CgcVariant *resolve_variant(CgcGen *g, const char *name) {
    for (int i = 0; i < g->variant_count; i++) {
        if (strcmp(g->variants[i].name, name) == 0) {
            return &g->variants[i];
        }
    }
    return NULL;
}


static void cgc_error(CgcGen *g, int line, const char *fmt, ...) {
    if (!g->had_error) {
        va_list ap;
        va_start(ap, fmt);
        fprintf(stderr, "%s:%d: error: ", g->src_name, line);
        vfprintf(stderr, fmt, ap);
        fputc('\n', stderr);
        va_end(ap);
    }
    g->had_error = 1;
}





static void cgc_indent(CgcGen *g) {
    for (int i = 0; i < g->indent; i++) {
        fputs("    ", g->out);
    }
}





// Bind `name` to the C identifier `cname` in the current scope. The caller has
// already emitted the declaration; this only records the mapping for later lookups.
static void cgc_push(CgcGen *g, const char *name, const char *cname, int drop, int multislot_sid) {
    if (g->scope_len >= g->scope_cap) {
        int nc = g->scope_cap ? g->scope_cap * 2 : 64;
        g->scope = realloc(g->scope, (size_t)nc * sizeof(CgcBinding));
        if (g->scope == NULL) {
            fprintf(stderr, "emberc: out of memory growing the native scope table\n");
            exit(70);
        }
        g->scope_cap = nc;
    }
    g->scope[g->scope_len].name = name;
    snprintf(g->scope[g->scope_len].cname, sizeof g->scope[g->scope_len].cname,
             "%s", cname);
    g->scope[g->scope_len].drop = drop;
    g->scope[g->scope_len].multislot_sid = multislot_sid;
    g->scope[g->scope_len].scalar_kind = -1;   // default; STMT_LET marks a sized-numeric binding (OFI-123)
    g->scope_len++;
}





// The scope index a name resolves to (innermost binding wins), or -1 if unbound.
static int cgc_lookup_idx(CgcGen *g, const char *name) {
    for (int i = g->scope_len - 1; i >= 0; i--) {
        if (strcmp(g->scope[i].name, name) == 0) {
            return i;
        }
    }
    return -1;
}






// The C identifier a name resolves to, or NULL if unbound.
static const char *cgc_lookup(CgcGen *g, const char *name) {
    int i = cgc_lookup_idx(g, name);
    return i < 0 ? NULL : g->scope[i].cname;
}






// The value-type struct id a name is bound to (a C `em_s<sid>`), or -1 for a scalar/
// boxed binding. Used to type field access and to emit a struct ident as a plain copy.
static int cgc_lookup_sid(CgcGen *g, const char *name) {
    int i = cgc_lookup_idx(g, name);
    return i < 0 ? -1 : g->scope[i].multislot_sid;
}


// ---- OFI-123: width-accurate scalar locals ----
// A sized numeric local lowers to a typed C scalar stored at its declared width; every READ boxes it
// back to a Value (so all downstream codegen is unchanged), and every WRITE unboxes + truncates to
// width. The width kind is the checker's int_kind (0 i64, 1 i8, 2 i16, 3 i32, 4 u8, 5 u16, 6 u32,
// 7 u64, 8 f32, 9 f64). Arithmetic still flows through the Value-world em_add/em_sub/em_mul (width via
// num_kind), so this is purely a storage change — the C compiler folds the box/unbox round-trips away.

// scalar_ctype maps a width kind to its C storage type.
static const char *scalar_ctype(int kind) {
    switch (kind) {
        case 1: return "int8_t";
        case 2: return "int16_t";
        case 3: return "int32_t";
        case 4: return "uint8_t";
        case 5: return "uint16_t";
        case 6: return "uint32_t";
        case 7: return "uint64_t";
        case 8: return "float";
        case 9: return "double";
        default: return "int64_t";   // 0 = i64
    }
}

// The width kind a name is bound to (a typed C scalar), or -1 for a Value/struct binding.
static int cgc_lookup_scalar_kind(CgcGen *g, const char *name) {
    int i = cgc_lookup_idx(g, name);
    return i < 0 ? -1 : g->scope[i].scalar_kind;
}

// Mark the most-recently-pushed binding as a sized scalar of `kind` (set by STMT_LET right after push).
static void cgc_mark_top_scalar(CgcGen *g, int kind) {
    if (g->scope_len > 0) {
        g->scope[g->scope_len - 1].scalar_kind = kind;
    }
}

// emit_scalar_box writes the C expression that boxes a typed scalar local `cn` (width `kind`) back to a
// Value: a float kind widens to double via FLOAT_VAL; an integer kind reinterprets its bits via INT_VAL
// (a u64 with the high bit set lands as the correct negative-i64 in-slot pattern; narrower signed types
// sign-extend, unsigned zero-extend — both via the int64_t cast).
static void emit_scalar_box(CgcGen *g, int kind, const char *cn) {
    if (kind == 8 || kind == 9) {
        fprintf(g->out, "FLOAT_VAL((double)%s)", cn);
    } else {
        fprintf(g->out, "INT_VAL((int64_t)%s)", cn);
    }
}






// A struct is a VALUE TYPE — lowered to a real C `em_s<sid>` with value semantics and no drop
// — iff it is all-scalar RECURSIVELY: no heap (AEK_BOXED) field anywhere, only scalars and
// nested value-type structs. A struct with a string/array/enum/closure/interface field (a
// Config, or Map/Set with their bucket array + witness fields) is instead BOXED and refcounted,
// exactly as the VM treats it, so drop_value releases its heap fields. This mirrors the
// checker's all-scalar rule (nested_inline_sid / struct_all_scalar_id) and is the single
// predicate that decides value-vs-boxed everywhere below. (Recursion terminates: a struct
// cannot contain itself by value.)
static int is_value_struct(CgcGen *g, int sid) {
    if (sid < 0 || sid >= g->struct_count) {
        return 0;
    }
    const StructLayout *L = &g->layouts[sid];
    if (L->is_rc || L->is_resource) {
        return 0;   // an `rc struct` (refcounted) or `resource struct` (drop-bearing) is BOXED, never a C value-type
    }
    // A monomorphized generic-struct instance (base_id != its own sid — e.g. Box<int>) is NEVER
    // a value-type here: the native backend ERASES generics (one body per method over a uniform
    // Value), so a generic struct's methods take a BOXED self and return a boxed result. Giving
    // an all-scalar instance like Box<int> a C value-struct rep would clash with those erased
    // signatures (em_s passed where Value is expected). So box every generic instance — uniform
    // with how Map/Set (heap-field generics) are already boxed; the differential output is
    // unchanged, only the in-memory rep differs. (Declared structs have base_id == sid.)
    if (L->base_id != sid) {
        return 0;
    }
    for (int f = 0; f < L->field_count; f++) {
        if (L->field_struct[f] >= 0) {
            if (!is_value_struct(g, L->field_struct[f])) {
                return 0;
            }
        } else if (L->kind[f] == AEK_BOXED) {
            return 0;
        }
    }
    return 1;
}


// Is `name` a generic type-parameter in `fn`'s scope — its OWN generics, or (for a method) the
// owning struct's generics? Such a name is ERASED (a boxed Value); it must NOT resolve to a same-
// named user struct. The checker makes exactly this scope distinction (annotation_type resolves an
// in-scope type-param name before any struct name); the cgen mirrors it so it stops guessing purely
// by name (OFI-053). The fn's OWN generics are normally caught upstream by the generic_count gate in
// param_struct_sid/ret_struct_sid, but the struct_sid_of call path has no such gate — so check both.
static int type_name_is_generic_param(CgcGen *g, const FnDecl *fn, const char *name) {
    if (fn == NULL) {
        return 0;
    }
    for (size_t k = 0; k < fn->generic_count; k++) {
        if (strcmp(fn->generics[k].name, name) == 0) {
            return 1;
        }
    }
    if (g->owner_generics != NULL && g->fn_by_fi != NULL) {
        for (int s = 0; s < g->total_functions; s++) {
            if (g->fn_by_fi[s] == fn) {
                const GenericParam *og = g->owner_generics[s];
                for (int k = 0; k < g->owner_generic_count[s]; k++) {
                    if (strcmp(og[k].name, name) == 0) {
                        return 1;
                    }
                }
                return 0;
            }
        }
    }
    return 0;
}






// The struct type id named by a type node IF it is a value-type struct, else -1. The checker
// only flags BORROW struct params multi-slot (inline_struct_id); mut/move/self struct params
// are typed from their declared type here so they too become C structs — but only when the
// struct is a value type (a boxed struct stays a uniform Value). `fn` is the function whose
// signature/body is being emitted (may be NULL): a type name that is one of its (or its owning
// struct's) generic parameters is ERASED — returns -1 BEFORE the by-name lookup, so a user
// `struct T` can never capture a generic param `T` (OFI-053).
static int sid_of_struct_type(CgcGen *g, const FnDecl *fn, const Type *t) {
    if (t == NULL || t->kind != TYPE_NAME || t->as.name.qualifier != NULL) {
        return -1;
    }
    if (type_name_is_generic_param(g, fn, t->as.name.name)) {
        return -1;
    }
    for (int sid = 0; sid < g->struct_count; sid++) {
        if (g->snames[sid].sname != NULL &&
            strcmp(g->snames[sid].sname, t->as.name.name) == 0) {
            return is_value_struct(g, sid) ? sid : -1;
        }
    }
    return -1;
}






// The value-type struct id a function RETURNS (em_s<sid>), or -1. A GENERIC function keeps its
// return boxed (uniform Value) — the erased convention the VM, the call-site bridge, and
// em_invoke all agree on — so the by-name fallback is gated on a non-generic function (the
// checker's ret_multislot_sid does the same: it bails when generic_count != 0).
static int ret_struct_sid(CgcGen *g, const FnDecl *fn) {
    if (fn->ret_struct_id >= 0) {
        return is_value_struct(g, fn->ret_struct_id) ? fn->ret_struct_id : -1;
    }
    if (fn->generic_count > 0) {
        return -1;
    }
    return sid_of_struct_type(g, fn, fn->return_type);   // gated on is_value_struct
}






// The value-type struct id of param `i` (self resolves to `owner_sid`), or -1. As with the
// return, a non-self param of a GENERIC function stays boxed (uniform Value), so the by-name
// fallback is gated on a non-generic function — otherwise a concrete value-struct param of a
// generic fn would be emitted unboxed (em_s) while every call path passes it boxed.
static int param_struct_sid(CgcGen *g, const FnDecl *fn, int owner_sid, int i) {
    const Param *p = &fn->params[i];
    if (p->is_self) {
        return is_value_struct(g, owner_sid) ? owner_sid : -1;   // boxed-struct self is a Value
    }
    if (p->inline_struct_id >= 0) {
        return is_value_struct(g, p->inline_struct_id) ? p->inline_struct_id : -1;
    }
    if (fn->generic_count > 0) {
        return -1;
    }
    return sid_of_struct_type(g, fn, p->type);   // gated on is_value_struct
}






// The value-type struct id an EXPRESSION evaluates to (a C `em_s<sid>`), or -1. Built
// from the checker's flags: a struct literal is its resolved_struct; a call its callee's
// return struct; an ident its binding's struct; a field read the parent layout's
// field_struct[idx] (a nested inline struct). Used to type `let`/`var` struct bindings
// the checker doesn't flag (mutable `var`, or a value whose inline_struct_id is unset).
static int struct_sid_of(CgcGen *g, const Expr *e) {
    switch (e->kind) {
        case EXPR_STRUCT_LIT:
            return is_value_struct(g, e->as.struct_lit.resolved_struct)
                       ? e->as.struct_lit.resolved_struct : -1;
        case EXPR_IDENT: {
            int s = cgc_lookup_sid(g, e->as.ident);
            return is_value_struct(g, s) ? s : -1;
        }
        case EXPR_CALL: {
            if (e->as.call.cextern_index >= 0) {
                // An `extern "c"` call: emit_ffi_call already unboxes a struct return into an em_s,
                // so its value-struct id is the cextern return sid (not ret_struct_id).
                int rs = e->as.call.cextern_ret_sid;
                return (rs >= 0 && is_value_struct(g, rs)) ? rs : -1;
            }
            if (e->as.call.ret_struct_id >= 0) {
                return is_value_struct(g, e->as.call.ret_struct_id)
                           ? e->as.call.ret_struct_id : -1;
            }
            const Expr *callee = e->as.call.callee;
            int slot = e->as.call.resolved_fn;
            if (slot < 0 && callee->kind == EXPR_GET) {
                slot = callee->as.get.field_index;   // a method call's slot
            }
            if (slot < 0 || slot >= g->total_functions) {
                return -1;
            }
            const FnDecl *cf = g->fn_by_fi[slot];
            // The CONCRETE struct the call's result is (for binding typing + the unbox in
            // emit_generic_call) — read directly, NOT via the generic-gated ret_struct_sid:
            // a generic fn returns a boxed Value in its C SIGNATURE, but its result is still a
            // concrete value struct the caller unboxes into.
            int r = (cf->ret_struct_id >= 0) ? cf->ret_struct_id
                                             : sid_of_struct_type(g, cf, cf->return_type);
            if (r >= 0 && is_value_struct(g, r)) {
                return r;
            }
            // A generic call whose return type is a bare type parameter (`-> T`): resolve the
            // concrete struct through the call's mono_args. A struct SemType is its own sid
            // (the checker's [0, ENUM_BASE) band; ENUM_BASE == 1000000), so a value below that
            // is the instantiation's return struct id; a type-param/non-struct stays erased.
            if (cf->return_type != NULL && cf->return_type->kind == TYPE_NAME &&
                cf->return_type->as.name.qualifier == NULL) {
                for (size_t gi = 0; gi < cf->generic_count &&
                                    (int)gi < e->as.call.mono_arg_count; gi++) {
                    if (strcmp(cf->generics[gi].name, cf->return_type->as.name.name) == 0) {
                        int st = e->as.call.mono_args[gi];
                        return (st >= 0 && st < 1000000 && is_value_struct(g, st)) ? st : -1;
                    }
                }
            }
            return -1;
        }
        case EXPR_GET: {
            int fi = e->as.get.field_index;
            if (fi < 0) {
                return -1;
            }
            int obj_sid = struct_sid_of(g, e->as.get.object);
            if (obj_sid >= 0 && obj_sid < g->struct_count) {
                int fs = g->layouts[obj_sid].field_struct[fi];   // nested inline struct sid, or -1
                return is_value_struct(g, fs) ? fs : -1;
            }
            // A nested inline-struct field read off a BOXED receiver materialises an em_s COPY
            // (OFI-054 A1) — the checker stamped the field's struct id.
            int es = e->as.get.inline_struct_id;
            return is_value_struct(g, es) ? es : -1;
        }
        case EXPR_INDEX: {
            // `arr[i]` of an inline value-struct array reads out a value COPY (an em_s); the
            // checker stamped the element struct id. (A slice/scalar/boxed element is -1.)
            int es = e->as.index.inline_struct_id;
            return is_value_struct(g, es) ? es : -1;
        }
        default:
            return -1;
    }
}


// is_addressable_vstruct reports whether `e` (already known to be a value struct) is a C LVALUE — a
// value-struct local reached only through inline value-struct fields, so `<e>.fN = v` is a valid C
// assignment that mutates in place. It is NOT addressable when reaching `e` requires unboxing a
// value-struct field out of a boxed parent (a non-flat struct stores its value-struct fields boxed):
// `em_struct_field_inline` then materialises a COPY, so a direct member-assign would mutate a
// throwaway and isn't even an lvalue. Those need the read-modify-writeback path (OFI-155).
static int is_addressable_vstruct(CgcGen *g, const Expr *e) {
    if (struct_sid_of(g, e) < 0) {
        return 0;                                  // not a value struct at all
    }
    if (e->kind == EXPR_IDENT) {
        return 1;                                  // a value-struct local: a real C lvalue
    }
    if (e->kind == EXPR_GET) {
        return is_addressable_vstruct(g, e->as.get.object);
    }
    return 0;                                       // a call/index/temp result is an rvalue
}






// A value-type struct is "flat" when it has no nested inline-struct fields — its C layout is
// then a contiguous Value[] (one Value per declared field), so it can be boxed/unboxed with
// the generic em_box_struct/em_unbox_struct bridge. Nested-struct fields would break the
// flat-Value-array assumption, so they are excluded (bridged structs error cleanly).
static int struct_is_flat(CgcGen *g, int sid) {
    if (sid < 0 || sid >= g->struct_count) {
        return 0;
    }
    const StructLayout *L = &g->layouts[sid];
    for (int f = 0; f < L->field_count; f++) {
        if (L->field_struct[f] >= 0) {
            return 0;
        }
    }
    return 1;
}






// The number of hidden interface-witness parameters a bounded generic function carries — one
// per (type parameter, interface bound), matching the VM's hidden `$witness` locals. They are
// emitted as leading `Value w0, w1, …` C parameters and passed by every bounded call site.
static int fn_witness_count(const FnDecl *fn) {
    int n = 0;
    for (size_t g = 0; g < fn->generic_count; g++) {
        n += fn->generics[g].bound_count;
    }
    return n;
}






// Does the program use concurrency? A channel is useless without a spawn/nursery (it would
// deadlock single-threaded), so the presence of a spawn or nursery in ANY function body is the
// signal that this program needs the threaded build (-DEMBER_PARALLEL + pthread + thread-local
// context). Walks statements recursively; channel built-ins ride along inside concurrent code.
static int block_has_concurrency(const Block *b);

static int stmt_has_concurrency(const Stmt *s) {
    switch (s->kind) {
        case STMT_SPAWN:
        case STMT_NURSERY:
            return 1;
        case STMT_IF: {
            if (block_has_concurrency(&s->as.if_.then_blk)) {
                return 1;
            }
            const Stmt *eb = s->as.if_.else_branch;
            return eb != NULL && stmt_has_concurrency(eb);
        }
        case STMT_LOOP:  return block_has_concurrency(&s->as.loop.body);
        case STMT_FOR:   return block_has_concurrency(&s->as.for_.body);
        case STMT_BLOCK: return block_has_concurrency(&s->as.block.body);
        case STMT_MATCH: {
            for (size_t k = 0; k < s->as.match.case_count; k++) {
                if (block_has_concurrency(&s->as.match.cases[k].body)) {
                    return 1;
                }
            }
            return 0;
        }
        default:
            return 0;
    }
}

static int block_has_concurrency(const Block *b) {
    for (size_t i = 0; i < b->count; i++) {
        if (stmt_has_concurrency(b->stmts[i])) {
            return 1;
        }
    }
    return 0;
}

static int program_uses_concurrency(const Program *ast) {
    for (size_t i = 0; i < ast->count; i++) {
        const Decl *d = ast->decls[i];
        if (d->kind == DECL_FN && block_has_concurrency(&d->as.fn.body)) {
            return 1;
        }
        if (d->kind == DECL_STRUCT) {
            for (size_t m = 0; m < d->as.struct_.method_count; m++) {
                if (block_has_concurrency(&d->as.struct_.methods[m].body)) {
                    return 1;
                }
            }
        }
    }
    return 0;
}






// Whether any binding from index `from` up to the current scope top owns a value that
// must be dropped (so a `return` knows whether to wrap its value in a temp first).
static int scope_has_drops(CgcGen *g, int from) {
    for (int i = g->scope_len - 1; i >= from; i--) {
        if (g->scope[i].drop) {
            return 1;
        }
    }
    return 0;
}






// Emit drop_value calls for every owned binding in [from, scope_len), innermost first
// — the order the VM releases scope-exit owners. Used at block exit, before a return,
// and at the function-end implicit return.
static void emit_drops(CgcGen *g, int from) {
    for (int i = g->scope_len - 1; i >= from; i--) {
        if (g->scope[i].drop) {
            cgc_indent(g);
            fprintf(g->out, "drop_value(&g_em, %s);\n", g->scope[i].cname);
        }
    }
}





static void emit_expr(CgcGen *g, const Expr *e);
static void emit_expr_raw(CgcGen *g, const Expr *e);
static void emit_stmt(CgcGen *g, const Stmt *s);
static void emit_c_string_literal(CgcGen *g, const char *bytes, size_t len);


// Box a value-type struct EXPRESSION into a heap ObjStruct Value (for an interface receiver
// or an erased-generic argument). The struct value is evaluated into a C temporary so its
// contiguous fields can be read as a Value[] by em_box_struct. `sid` must be a flat struct.
static void emit_box_struct(CgcGen *g, const Expr *e, int sid) {
    int t = g->next_var++;
    int n = g->layouts[sid].field_count;
    fprintf(g->out, "({ em_s%d v%d = ", sid, t);
    emit_expr_raw(g, e);   // RAW: emit the struct value itself, not its interface upcast
    fprintf(g->out, "; em_box_struct(&g_em, %d, (Value*)&v%d, %d); })", sid, t, n);
}


// Emit an expression that must become a uniform boxed `Value` because it flows INTO a boxed
// container — an enum variant payload, an array element. A bare value-type struct is boxed
// first (the heap rep the container stores). An expression already destined to be a Value —
// anything that's not a value struct, OR a struct being UPCAST to an interface (coerce_witness,
// which emit_expr turns into an interface value) — is emitted through emit_expr unchanged.
static void emit_value_arg(CgcGen *g, const Expr *e) {
    if (e->coerce_witness == NULL) {
        int sid = struct_sid_of(g, e);
        if (sid >= 0) {
            // Box the value struct for the container. em_box_struct handles NON-FLAT structs (a
            // nested inline-struct field) via a recursive leaf walk, and the boxed field-READ /
            // boxed CONSTRUCTION paths are wired (OFI-054), so no flatness gate is needed.
            emit_box_struct(g, e, sid);
            return;
        }
    }
    emit_expr(g, e);
}


// emit_expr wraps emit_expr_raw with the interface UPCAST: when the checker marked an
// expression with a coercion witness (a struct used where an interface is expected), box the
// receiver and bundle it with its vtable (an enum record of the impl's method fn-indices) into
// an interface value — the VM's gen_expr/OP_MAKE_DYN wrapper. Every value site flows through
// here, so the upcast applies uniformly (call args, let initialisers, returns, …).
static void emit_expr(CgcGen *g, const Expr *e) {
    if (e->coerce_witness != NULL) {
        // The receiver is either a value-type struct (struct_sid_of >= 0 → box it into a heap
        // ObjStruct) or already a BOXED struct (a Config/heap-bearing struct, already a Value →
        // use it directly). em_box_struct/em_unbox_struct handle a NON-FLAT struct (nested
        // inline-struct field) recursively, so no flatness gate (OFI-054).
        int sid = struct_sid_of(g, e);
        // A `mut self` method can't be reached through the vtable yet: em_invoke dispatches on
        // an unboxed COPY of the receiver, so mutations wouldn't reach the boxed interface
        // value. The runtime would hit em_invoke's panic; reject cleanly at the upcast instead.
        for (int m = 0; m < e->coerce_witness_count; m++) {
            int fi = e->coerce_witness[m];
            if (fi >= 0 && fi < g->total_functions) {
                const FnDecl *mf = g->fn_by_fi[fi];
                if (mf->param_count > 0 && mf->params[0].is_self &&
                    mf->params[0].qual == OWN_MUT) {
                    cgc_error(g, e->line,
                              "native backend (M3): an interface with a `mut self` method "
                              "cannot be used as a dynamic value yet");
                    fputs("INT_VAL(0)", g->out);
                    return;
                }
            }
        }
        fputs("alloc_interface(&g_em, ", g->out);
        if (sid >= 0) {
            emit_box_struct(g, e, sid);   // value struct → box it into the receiver
        } else {
            emit_expr_raw(g, e);          // already a boxed struct Value → the receiver as-is
        }
        fprintf(g->out, ", em_enum(&g_em, 0, 0, %d", e->coerce_witness_count);
        for (int m = 0; m < e->coerce_witness_count; m++) {
            fprintf(g->out, ", INT_VAL(%d)", e->coerce_witness[m]);
        }
        fputs("))", g->out);
        return;
    }
    emit_expr_raw(g, e);
}


// A lexical block: its `let`s extend the current scope, which is rolled back on exit
// so siblings don't see each other's bindings.
static void emit_block_scoped(CgcGen *g, const Block *b) {
    int mark = g->scope_len;
    for (size_t i = 0; i < b->count; i++) {
        emit_stmt(g, b->stmts[i]);
    }
    emit_drops(g, mark);     // release owned locals declared in this block on normal exit
    g->scope_len = mark;
}





static void emit_unary(CgcGen *g, const Expr *e) {
    const Expr *x = e->as.unary.operand;
    switch (e->as.unary.op) {
        case TOK_MINUS:
            fputs("em_neg(", g->out); emit_expr(g, x);
            fprintf(g->out, ", %d)", e->num_kind);
            break;
        case TOK_BANG:
            fputs("em_not(", g->out); emit_expr(g, x); fputc(')', g->out);
            break;
        case TOK_TILDE:
            fputs("em_bitnot(", g->out); emit_expr(g, x);
            fprintf(g->out, ", %d)", e->num_kind);
            break;
        default:
            cgc_error(g, e->line, "native backend: unsupported unary operator");
            fputs("INT_VAL(0)", g->out);
            break;
    }
}





// Emit an operand of a CONSUMING string op (em_add, which drops both operands). A BORROWED
// operand — a binding read as a borrow, or a struct field read — is retained so the consume
// balances and the owner keeps its reference; a temporary (literal/call/concat result, or a
// move/alias read, which emit_expr already makes owned) is passed as-is for the consume to free.
// Scalar operands of a numeric `+` are unaffected (retain is a no-op, em_add doesn't drop them).
static void emit_concat_operand(CgcGen *g, const Expr *e) {
    // A borrow that yields a HEAP Value (not a value-type struct, which has no heap to retain):
    // a binding read as a borrow, a boxed struct's field read (em_enum_field borrows), or an
    // array element read `arr[i]` (em_index returns the element WITHOUT retaining — the array
    // still owns it). The runtime IS_OBJ guard makes the retain a no-op for scalar elements.
    int borrow = struct_sid_of(g, e) < 0 &&
                 ((e->kind == EXPR_IDENT && e->moves_local == 0) ||
                  (e->kind == EXPR_GET && !e->as.get.drop_object) ||
                  (e->kind == EXPR_INDEX && e->as.index.index->kind != EXPR_RANGE));
    if (borrow) {
        int v = g->next_var++;
        fprintf(g->out, "({ Value v%d = ", v);
        emit_expr(g, e);
        fprintf(g->out, "; if (IS_OBJ(v%d)) OBJ_RETAIN(AS_OBJ(v%d)); v%d; })", v, v, v);
    } else {
        emit_expr(g, e);
    }
}


// A method/intrinsic receiver is a BORROW (the callee reads it; something else owns it) when it
// is a binding read, a non-consuming field read, or an array-element read (`arr[i]` — em_index
// returns the element WITHOUT retaining, so the array still owns it). Anything else (a computed
// temporary like `(a + b)` or `mk()`) is OWNED and must be dropped after the borrowing call.
static int recv_is_borrow(const Expr *recv) {
    return (recv->kind == EXPR_IDENT && recv->moves_local == 0) ||
           recv->kind == EXPR_GET ||
           (recv->kind == EXPR_INDEX && recv->as.index.index->kind != EXPR_RANGE);
}






// Emit `<helper>(<recv>)` for an intrinsic that BORROWS its receiver (e.g. `.len()`) and
// returns a scalar; if the receiver is an owned TEMPORARY (a computed value, not a borrowed
// binding/field), drop it afterward so it doesn't leak (`(a + b).len()`). The length is read
// before the drop.
static void emit_borrow_recv_call(CgcGen *g, const char *helper, const Expr *recv) {
    int temp = !recv_is_borrow(recv);
    if (temp) {
        int t  = g->next_var++;
        int rv = g->next_var++;
        fprintf(g->out, "({ Value v%d = ", t);
        emit_expr(g, recv);
        fprintf(g->out, "; Value v%d = %s(v%d); drop_value(&g_em, v%d); v%d; })",
                rv, helper, t, t, rv);
    } else {
        fprintf(g->out, "%s(", helper);
        emit_expr(g, recv);
        fputc(')', g->out);
    }
}






// Like emit_borrow_recv_call but for a ctx-taking runtime helper `helper(&g_em, recv, …)` with
// extra trailing arguments (M5 string/array methods that allocate a fresh result). The receiver
// and the trailing args are all BORROWED reads; a fresh-temporary receiver is evaluated, used,
// then dropped (the method reads it, it does not consume it).
static void emit_borrow_recv_ctx_call(CgcGen *g, const char *helper, const Expr *recv,
                                      Expr *const *args, size_t argc) {
    int temp = !recv_is_borrow(recv);
    if (temp) {
        int t  = g->next_var++;
        int rv = g->next_var++;
        fprintf(g->out, "({ Value v%d = ", t);
        emit_expr(g, recv);
        fprintf(g->out, "; Value v%d = %s(&g_em, v%d", rv, helper, t);
        for (size_t i = 0; i < argc; i++) {
            fputs(", ", g->out);
            emit_expr(g, args[i]);
        }
        fprintf(g->out, "); drop_value(&g_em, v%d); v%d; })", t, rv);
    } else {
        fprintf(g->out, "%s(&g_em, ", helper);
        emit_expr(g, recv);
        for (size_t i = 0; i < argc; i++) {
            fputs(", ", g->out);
            emit_expr(g, args[i]);
        }
        fputc(')', g->out);
    }
}


static void emit_binary(CgcGen *g, const Expr *e) {
    TokenType op = e->as.binary.op;
    const Expr *l = e->as.binary.left;
    const Expr *r = e->as.binary.right;

    // Logical operators short-circuit; C's && / || do too, and Ember's operands are
    // always bools (int 0/1), so the operand-value result the VM keeps is exactly the
    // 0/1 these produce.
    if (op == TOK_AND || op == TOK_OR) {
        fputs("INT_VAL((em_truthy(", g->out);
        emit_expr(g, l);
        fprintf(g->out, ") %s em_truthy(", op == TOK_AND ? "&&" : "||");
        emit_expr(g, r);
        fputs(")) ? 1 : 0)", g->out);
        return;
    }

    const char *fn = NULL;
    int has_nk = 0;
    int wants_ctx = 0;   // em_add takes the runtime ctx (for string concatenation)
    switch (op) {
        case TOK_PLUS:    fn = "em_add";    has_nk = 1; wants_ctx = 1; break;
        case TOK_MINUS:   fn = "em_sub";    has_nk = 1; break;
        case TOK_STAR:    fn = "em_mul";    has_nk = 1; break;
        case TOK_SLASH:   fn = "em_div";    has_nk = 1; break;
        case TOK_PERCENT: fn = "em_mod";    has_nk = 1; break;
        case TOK_EQ:      fn = "em_eq_op";  wants_ctx = 1; break;
        case TOK_NEQ:     fn = "em_neq_op"; wants_ctx = 1; break;
        case TOK_LT:      fn = "em_lt";     has_nk = 1; break;
        case TOK_LE:      fn = "em_le";     has_nk = 1; break;
        case TOK_GT:      fn = "em_gt";     has_nk = 1; break;
        case TOK_GE:      fn = "em_ge";     has_nk = 1; break;
        case TOK_AMP:     fn = "em_bitand"; break;
        case TOK_PIPE:    fn = "em_bitor";  break;
        case TOK_CARET:   fn = "em_bitxor"; break;
        case TOK_SHL:     fn = "em_shl";    has_nk = 1; break;
        case TOK_SHR:     fn = "em_shr";    has_nk = 1; break;
        default:
            cgc_error(g, e->line, "native backend: unsupported binary operator");
            fputs("INT_VAL(0)", g->out);
            return;
    }
    fprintf(g->out, "%s(", fn);
    if (wants_ctx) {
        fputs("&g_em, ", g->out);
    }
    // em_add consumes its operands, so retain a borrowed one (emit_concat_operand); the other
    // operators only read, so emit operands directly.
    if (wants_ctx) {
        emit_concat_operand(g, l);
        fputs(", ", g->out);
        emit_concat_operand(g, r);
    } else {
        emit_expr(g, l);
        fputs(", ", g->out);
        emit_expr(g, r);
    }
    if (has_nk) {
        fprintf(g->out, ", %d", e->num_kind);
    }
    fputc(')', g->out);
}





// Does a generic call need the value-struct<->boxed bridge? — i.e. it returns a value-struct
// instantiation, or passes a value-struct where the erased body's parameter is a boxed Value.
// A purely scalar/Value unbounded generic call needs no bridge and lowers like a direct call.
static int generic_call_needs_bridge(CgcGen *g, const Expr *e) {
    if (struct_sid_of(g, e) >= 0) {
        return 1;   // returns a value-struct (incl. an erased `-> T` resolved via mono_args)
    }
    int fi = e->as.call.resolved_fn;
    const FnDecl *cf = (fi >= 0 && fi < g->total_functions) ? g->fn_by_fi[fi] : NULL;
    for (size_t i = 0; i < e->as.call.arg_count; i++) {
        int asid = struct_sid_of(g, e->as.call.args[i]);
        int psid = (cf != NULL && i < cf->param_count) ? param_struct_sid(g, cf, -1, (int)i) : -1;
        if (asid >= 0 && psid < 0) {
            return 1;
        }
    }
    return 0;
}


// Emit a generic FREE call (`resolved_fn` names the erased base body): prepend any interface
// witnesses (each an enum record of the impl's method fn-indices) as leading arguments, BOX a
// value-struct argument that flows into an erased `Value` parameter, and UNBOX the result when
// the instantiation returns a value-struct. This is the call-site half of dictionary passing
// plus the value-struct<->boxed bridge; the bound-method dispatch inside the body is the other.
static void emit_generic_call(CgcGen *g, const Expr *e) {
    int fi      = e->as.call.resolved_fn;
    int retsid  = struct_sid_of(g, e);   // instantiation's return struct (erased `-> T` resolved), or -1
    const FnDecl *cf = (fi >= 0 && fi < g->total_functions) ? g->fn_by_fi[fi] : NULL;
    int unbox_ret = (retsid >= 0);   // em_box/unbox_struct handle non-flat returns (OFI-054)
    // Always a statement-expression: hoist each interface witness (an enum record of method
    // fn-indices) into a local so it can be DROPPED after the call (it's an owned temporary the
    // callee only borrows — leaking it otherwise), then call, drop the witnesses, and unbox a
    // value-struct return.
    int wt = e->as.call.witness_total;
    int rv = g->next_var++;
    int wbase = g->next_var;
    g->next_var += (wt > 0) ? wt : 0;
    fputs("({ ", g->out);
    for (int w = 0; w < wt; w++) {
        const Witness *wit = &e->as.call.witnesses[w];
        fprintf(g->out, "Value w%d = em_enum(&g_em, 0, 0, %d", wbase + w, wit->count);
        for (int m = 0; m < wit->count; m++) {
            fprintf(g->out, ", INT_VAL(%d)", wit->fns[m]);
        }
        fputs("); ", g->out);
    }
    fprintf(g->out, "Value v%d = em_fn_%d(", rv, fi);
    int first = 1;
    for (int w = 0; w < wt; w++) {
        fprintf(g->out, "%sw%d", first ? "" : ", ", wbase + w);
        first = 0;
    }
    for (size_t i = 0; i < e->as.call.arg_count; i++) {
        if (!first) {
            fputs(", ", g->out);
        }
        first = 0;
        const Expr *arg = e->as.call.args[i];
        int asid = struct_sid_of(g, arg);
        int psid = (cf != NULL && i < cf->param_count) ? param_struct_sid(g, cf, -1, (int)i) : -1;
        if (asid >= 0 && psid < 0 && arg->coerce_witness == NULL) {  // value-struct into erased Value param
            emit_box_struct(g, arg, asid);   // em_box_struct handles non-flat structs (OFI-054)
        } else {
            emit_expr(g, arg);
        }
    }
    fputs("); ", g->out);
    for (int w = 0; w < wt; w++) {
        fprintf(g->out, "drop_value(&g_em, w%d); ", wbase + w);
    }
    if (unbox_ret) {
        // Unbox the boxed value-struct result into a C struct, then DROP the boxed temporary
        // (a value struct is all-scalar, so em_unbox_struct copied it out — the box owns no
        // heap fields to lose). Otherwise the boxed return leaks per call.
        fprintf(g->out,
                "em_s%d r%d; em_unbox_struct(&g_em, %d, v%d, (Value*)&r%d, %d); "
                "drop_value(&g_em, v%d); r%d; })",
                retsid, rv, retsid, rv, rv, g->layouts[retsid].field_count, rv, rv);
    } else {
        fprintf(g->out, "v%d; })", rv);
    }
}


// A bare numeric type name used as a width-conversion call (`u8(x)`, `i32(x)`, `f64(x)`, …) —
// the checker validated it and recorded the target kind in the call's num_kind. Mirrors
// is_numeric_typename in src/codegen.c.
static int cgc_is_numeric_typename(const char *n) {
    return strcmp(n, "i8") == 0 || strcmp(n, "i16") == 0 || strcmp(n, "i32") == 0 ||
           strcmp(n, "i64") == 0 || strcmp(n, "int") == 0 || strcmp(n, "u8") == 0 ||
           strcmp(n, "u16") == 0 || strcmp(n, "u32") == 0 || strcmp(n, "u64") == 0 ||
           strcmp(n, "f32") == 0 || strcmp(n, "f64") == 0;
}






// OFI-167 (native direct-extern): the exact C type a direct-extern parameter/return crosses as. The
// boundary is scalar-or-Ptr (the checker's collect_direct_extern enforces it), so each maps to a
// fixed-width C type and the emitted forward declaration matches the freestanding shim's definition
// byte-for-byte — no prototype/definition mismatch, no UB. A NULL type is the unit return -> `void`.
static const char *ember_ctype_of(const Type *t) {
    if (t == NULL) {
        return "void";
    }
    if (t->kind != TYPE_NAME || t->as.name.qualifier != NULL) {
        return NULL;
    }
    const char *n = t->as.name.name;
    if (strcmp(n, "i8")  == 0) { return "int8_t"; }
    if (strcmp(n, "i16") == 0) { return "int16_t"; }
    if (strcmp(n, "i32") == 0) { return "int32_t"; }
    if (strcmp(n, "i64") == 0 || strcmp(n, "int") == 0) { return "int64_t"; }
    if (strcmp(n, "u8")  == 0) { return "uint8_t"; }
    if (strcmp(n, "u16") == 0) { return "uint16_t"; }
    if (strcmp(n, "u32") == 0) { return "uint32_t"; }
    if (strcmp(n, "u64") == 0) { return "uint64_t"; }
    if (strcmp(n, "f32") == 0) { return "float"; }
    if (strcmp(n, "f64") == 0) { return "double"; }
    if (strcmp(n, "bool") == 0) { return "int"; }        // Ember bool crosses as a 0/1 int
    if (strcmp(n, "Ptr")  == 0) { return "void *"; }
    return NULL;
}


// A direct-extern type crosses as a float (AS_FLOAT / FLOAT_VAL) rather than an integer/Ptr.
static int direct_type_is_float(const Type *t) {
    return t != NULL && t->kind == TYPE_NAME && t->as.name.qualifier == NULL &&
           (strcmp(t->as.name.name, "f32") == 0 || strcmp(t->as.name.name, "f64") == 0);
}


// A direct-extern type crosses as an opaque Ptr (a C pointer carried in the Value int64 slot).
static int direct_type_is_ptr(const Type *t) {
    return t != NULL && t->kind == TYPE_NAME && t->as.name.qualifier == NULL &&
           strcmp(t->as.name.name, "Ptr") == 0;
}


// The FnDecl of the direct-extern named `name` (registered in the preamble pass), or NULL.
static const FnDecl *find_direct_extern(CgcGen *g, const char *name) {
    for (int i = 0; i < g->direct_extern_count; i++) {
        if (strcmp(g->direct_externs[i]->name, name) == 0) {
            return g->direct_externs[i];
        }
    }
    return NULL;
}


// OFI-167: emit a native DIRECT call to an `extern "c"` symbol not in the hosted registry (a kernel
// MMIO helper, say). Each argument is unboxed from its Value to the C scalar/Ptr the forward
// declaration expects; the C result is re-boxed into a Value. A unit-returning extern is called for
// effect and yields INT_VAL(0), so the call is still a Value expression like every other.
static void emit_direct_extern_call(CgcGen *g, const Expr *e) {
    const char   *cname = e->as.call.extern_cname;
    const FnDecl *fn    = find_direct_extern(g, cname);
    if (fn == NULL) {
        cgc_error(g, e->line, "internal: no direct-extern declaration for '%s'", cname);
        return;
    }
    const Type *rt      = fn->return_type;
    int         ret_unit = (rt == NULL);
    if (ret_unit) {
        fputc('(', g->out);                              // (call(...), INT_VAL(0))
    } else if (direct_type_is_float(rt)) {
        fputs("FLOAT_VAL((double)", g->out);
    } else if (direct_type_is_ptr(rt)) {
        fputs("INT_VAL((int64_t)(intptr_t)", g->out);
    } else {
        fputs("INT_VAL((int64_t)", g->out);
    }
    fprintf(g->out, "%s(", cname);
    size_t argc = e->as.call.arg_count;
    for (size_t i = 0; i < argc; i++) {
        if (i > 0) { fputs(", ", g->out); }
        const Type *pt = (i < fn->param_count) ? fn->params[i].type : NULL;
        if (direct_type_is_float(pt)) {
            fputs("AS_FLOAT(", g->out);
        } else if (direct_type_is_ptr(pt)) {
            fputs("(void *)(intptr_t)AS_INT(", g->out);
        } else {
            fputs("AS_INT(", g->out);
        }
        emit_expr(g, e->as.call.args[i]);
        fputc(')', g->out);
    }
    fputc(')', g->out);                                  // close the C call's argument list
    fputs(ret_unit ? ", INT_VAL(0))" : ")", g->out);     // close the (…,INT_VAL(0)) or the box macro
}


// emit_ffi_call — an `extern "c"` FFI call (M5). The arguments are pushed as their flattened
// scalar LEAVES into a Value[] for em_ffi, which dispatches through the in-tree C registry
// (cextern_call) and reassembles a scalar or struct result. Single-leaf args only (scalar,
// string→const char*, packed array→buffer, opaque Ptr); a struct-by-value argument would need
// multi-leaf flattening and is reported honestly. A struct RESULT is unboxed into its C struct.
// Emit the scalar LEAVES of a value-struct C lvalue `base` (an `em_s<sid>` path) into the FFI
// leaf array, in declared field order — recursing into nested inline-struct fields. A scalar
// field `.f<idx>` is already a Value; a nested-struct field is an em_s read leaf-by-leaf
// (`base.f<idx>.f<j>`…). Mirrors the VM's gen_arg/cg_slot_span flattening. `*first` tracks the
// leading-comma state so leaves splice into the same `(Value[]){ … }` literal.
static void emit_struct_leaves(CgcGen *g, int sid, const char *base, int *first) {
    const StructLayout *L = &g->layouts[sid];
    for (int f = 0; f < L->field_count; f++) {
        char path[256];
        snprintf(path, sizeof path, "%s.f%d", base, f);
        if (L->field_struct[f] >= 0) {
            emit_struct_leaves(g, L->field_struct[f], path, first);   // nested value struct
        } else {
            if (!*first) { fputs(", ", g->out); }
            *first = 0;
            fputs(path, g->out);                                      // a scalar leaf (a Value)
        }
    }
}






// The total scalar-leaf count of a value struct (recursing nested inline structs) — the per-arg
// leaf span; summed across args it gives em_ffi's TOTAL leaf count.
static int struct_leaf_count(CgcGen *g, int sid) {
    const StructLayout *L = &g->layouts[sid];
    int n = 0;
    for (int f = 0; f < L->field_count; f++) {
        n += (L->field_struct[f] >= 0) ? struct_leaf_count(g, L->field_struct[f]) : 1;
    }
    return n;
}






static void emit_ffi_call(CgcGen *g, const Expr *e) {
    int idx  = e->as.call.cextern_index;
    int rsid = e->as.call.cextern_ret_sid;
    const int *ais = e->as.call.arg_inline_struct;
    size_t argc = e->as.call.arg_count;

    // Total scalar-leaf count: a struct arg contributes its flattened leaves, every other arg one.
    int leaves = 0;
    for (size_t i = 0; i < argc; i++) {
        int asid = (ais != NULL) ? ais[i] : -1;
        leaves += (asid >= 0) ? struct_leaf_count(g, asid) : 1;
    }

    // Hoist each struct arg into an em_s<sid> temp (evaluate ONCE, like the VM), then read its
    // leaves. A value struct crossing the C boundary is all-scalar (a heap-field struct is boxed,
    // never multi-slot), so there is no heap to retain/drop per struct arg. A struct RESULT
    // (rsid >= 0) additionally unboxes the boxed return into its C value struct.
    int argtmp[16];
    int rv = g->next_var++;
    fputs("({ ", g->out);
    for (size_t i = 0; i < argc && i < 16; i++) {
        int asid = (ais != NULL) ? ais[i] : -1;
        if (asid >= 0) {
            int t = g->next_var++;
            argtmp[i] = t;
            fprintf(g->out, "em_s%d v%d = ", asid, t);
            emit_expr(g, e->as.call.args[i]);   // the struct value, evaluated once (borrowed)
            fputs("; ", g->out);
        } else {
            argtmp[i] = -1;
        }
    }
    fprintf(g->out, "Value v%d = em_ffi(&g_em, %d, %d, %d, ", rv, idx, rsid, leaves);
    if (leaves == 0) {
        fputs("0", g->out);
    } else {
        fputs("(Value[]){ ", g->out);
        int first = 1;
        for (size_t i = 0; i < argc && i < 16; i++) {
            if (argtmp[i] >= 0) {
                char base[32];
                snprintf(base, sizeof base, "v%d", argtmp[i]);
                emit_struct_leaves(g, ais[i], base, &first);
            } else {
                if (!first) { fputs(", ", g->out); }
                first = 0;
                emit_expr(g, e->as.call.args[i]);   // one borrowed scalar/string/buffer/Ptr leaf
            }
        }
        fputs(" }", g->out);
    }
    fputs("); ", g->out);

    if (rsid >= 0) {
        fprintf(g->out,
                "em_s%d r%d; em_unbox_struct(&g_em, %d, v%d, (Value*)&r%d, %d); "
                "drop_value(&g_em, v%d); r%d; })",
                rsid, rv, rsid, rv, rv, g->layouts[rsid].field_count, rv, rv);
    } else {
        fprintf(g->out, "v%d; })", rv);
    }
}






// cgc_reads_as_copy reports whether reading `r` materialises a COPY disconnected from storage
// (em_index clones a boxed element, an inline value-struct field is boxed as a copy) rather than a
// live handle, so a mutating method on it would be lost. Mirror of codegen.c's expr_reads_as_copy.
static int cgc_reads_as_copy(const Expr *r) {
    if (r->kind == EXPR_INDEX) {
        return 1;
    }
    if (r->kind == EXPR_GET) {
        if (r->as.get.inline_field) {
            return 1;
        }
        return cgc_reads_as_copy(r->as.get.object);
    }
    return 0;
}






// emit_array_append_writeback lowers `place.append(value)` where `place` reads as a copy (OFI-072):
// it would otherwise grow a clone and discard it. As a C statement-expression, clone the place out,
// append into the clone, then write the whole array back with the same em_set_field/em_set_index
// path an assignment uses (em_field_owned / em_set_field / em_set_index own/drop so refcounts
// balance, mirroring the VM). Yields unit. Covers the index (`g[i]`) and `arr[i].field` shapes; the
// rarer inline value-struct field chains are not yet supported in native (loud error, never silent).
static void emit_array_append_writeback(CgcGen *g, const Expr *e) {
    const Expr *place = e->as.call.callee->as.get.object;
    if (place->kind == EXPR_INDEX) {                          // g[i].append(x)
        int va = g->next_var++, vj = g->next_var++, vA = g->next_var++;
        fprintf(g->out, "({ Value v%d = ", va);
        emit_expr(g, place->as.index.object);
        fprintf(g->out, "; Value v%d = ", vj);
        emit_expr(g, place->as.index.index);
        fprintf(g->out, "; Value v%d = em_index(&g_em, v%d, v%d); em_array_append(&g_em, v%d, ",
                vA, va, vj, vA);
        emit_value_arg(g, e->as.call.args[0]);
        fprintf(g->out, "); em_set_index(&g_em, v%d, v%d, v%d); INT_VAL(0); })", va, vj, vA);
        return;
    }
    if (place->kind == EXPR_GET && place->as.get.object->kind == EXPR_INDEX) {  // arr[i].field.append(x)
        const Expr *ix = place->as.get.object;
        int fidx = place->as.get.field_index;
        int va = g->next_var++, vj = g->next_var++, ve = g->next_var++, vF = g->next_var++;
        fprintf(g->out, "({ Value v%d = ", va);
        emit_expr(g, ix->as.index.object);
        fprintf(g->out, "; Value v%d = ", vj);
        emit_expr(g, ix->as.index.index);
        fprintf(g->out, "; Value v%d = em_index(&g_em, v%d, v%d); Value v%d = em_field_owned(&g_em, v%d, %d); "
                        "em_array_append(&g_em, v%d, ", ve, va, vj, vF, ve, fidx, vF);
        emit_value_arg(g, e->as.call.args[0]);
        fprintf(g->out, "); em_set_field(&g_em, v%d, %d, v%d); em_set_index(&g_em, v%d, v%d, v%d); INT_VAL(0); })",
                ve, fidx, vF, va, vj, ve);
        return;
    }
    cgc_error(g, e->line, "native backend: append through this place is not yet supported (OFI-072) "
                          "— copy the element out and assign the whole array back");
    fputs("INT_VAL(0)", g->out);
}






static void emit_call(CgcGen *g, const Expr *e) {
    // Enum variant construction the checker resolved — bare `Circle(2.0)` OR a cross-module qualified
    // `json.Obj([…])`. Build it from the threaded enum id + tag before any method/function dispatch,
    // since the callee may be an EXPR_GET that would otherwise look like a method call (OFI-073).
    if (e->variant_enum_id >= 0) {
        fprintf(g->out, "em_enum(&g_em, %d, %d, %zu",
                e->variant_enum_id, e->variant_tag, e->as.call.arg_count);
        for (size_t i = 0; i < e->as.call.arg_count; i++) {
            fputs(", ", g->out);
            emit_value_arg(g, e->as.call.args[i]);
        }
        fputc(')', g->out);
        return;
    }
    if (e->as.call.extern_direct) {          // OFI-167: direct call to a non-registry C symbol
        emit_direct_extern_call(g, e);
        return;
    }
    if (e->as.call.cextern_index >= 0) {
        emit_ffi_call(g, e);
        return;
    }
    if (e->as.call.closure_call) {
        // An indirect call through a closure/function value: evaluate the callee to an
        // ObjClosure, then dispatch through rt_call_closure, which splices the captures
        // ahead of the arguments and routes the closure's function index to the concrete
        // em_fn_<k> via the generated em_invoke trampoline. The arguments are emitted as
        // borrows (rt_call_closure retains heap args at runtime, mirroring OP_CALL_CLOSURE).
        fputs("rt_call_closure(&g_em, ", g->out);
        emit_expr(g, e->as.call.callee);
        fprintf(g->out, ", %zu, ", e->as.call.arg_count);
        if (e->as.call.arg_count == 0) {
            fputs("0", g->out);
        } else {
            fputs("(Value[]){ ", g->out);
            for (size_t i = 0; i < e->as.call.arg_count; i++) {
                if (i > 0) {
                    fputs(", ", g->out);
                }
                emit_value_arg(g, e->as.call.args[i]);   // box a value-struct arg (callee is erased)
            }
            fputs(" }", g->out);
        }
        fputs(", em_invoke)", g->out);
        return;
    }
    // A generic FREE call (resolved_fn >= 0) that carries interface witnesses, or passes/returns
    // a value-struct through the erased body, routes to emit_generic_call (witness dictionary
    // passing + the value-struct<->boxed bridge). A generic METHOD call (resolved_fn < 0) falls
    // through to the method path below, which handles its self/args (witnesses are instance-
    // stored for a generic struct, not passed). A purely scalar/Value unbounded call also falls
    // through to the plain direct path — its instances collapse to the one erased base body.
    if (e->as.call.resolved_fn >= 0 &&
        (e->as.call.witness_total > 0 ||
         (e->as.call.mono_arg_count > 0 && generic_call_needs_bridge(g, e)))) {
        emit_generic_call(g, e);
        return;
    }
    const Expr *callee = e->as.call.callee;
    if (callee->kind == EXPR_IDENT) {
        // Data-carrying enum variant construction `Circle(2.0)` → a boxed enum value. Prefer the
        // checker's resolved enum id + tag over a by-name lookup (no longer globally unique — OFI-073).
        int venum = e->variant_enum_id, vtag = e->variant_tag;
        if (venum < 0) {
            const CgcVariant *v = resolve_variant(g, callee->as.ident);
            if (v != NULL) { venum = v->enum_id; vtag = v->variant_index; }
        }
        if (venum >= 0) {
            fprintf(g->out, "em_enum(&g_em, %d, %d, %zu",
                    venum, vtag, e->as.call.arg_count);
            for (size_t i = 0; i < e->as.call.arg_count; i++) {
                fputs(", ", g->out);
                emit_value_arg(g, e->as.call.args[i]);   // box a value-struct payload
            }
            fputc(')', g->out);
            return;
        }
        // The print / println builtins write their argument to stdout (and consume it).
        const char *nm = callee->as.ident;
        if (e->as.call.arg_count == 1 &&
            (strcmp(nm, "print") == 0 || strcmp(nm, "println") == 0)) {
            fprintf(g->out, "em_%s(&g_em, ", nm);
            emit_expr(g, e->as.call.args[0]);
            fputc(')', g->out);
            return;
        }
        // Channel built-ins (M4). channel(n) → a buffered channel; send(ch, v) enqueues
        // (transferring ownership of v into the channel); recv(ch) → Option<elem>; close(ch).
        if (e->as.call.arg_count == 1 && strcmp(nm, "channel") == 0) {
            fputs("em_channel_new(&g_em, AS_INT(", g->out);
            emit_expr(g, e->as.call.args[0]);
            fputs("))", g->out);
            return;
        }
        if (e->as.call.arg_count == 2 && strcmp(nm, "send") == 0) {
            fputs("em_channel_send(&g_em, ", g->out);
            emit_expr(g, e->as.call.args[0]);
            fputs(", ", g->out);
            emit_value_arg(g, e->as.call.args[1]);   // box a value-struct element; move it in
            fputc(')', g->out);
            return;
        }
        if (e->as.call.arg_count == 1 && strcmp(nm, "recv") == 0) {
            const CgcVariant *some = resolve_variant(g, "Some");
            const CgcVariant *none = resolve_variant(g, "None");
            if (some == NULL || none == NULL) {
                cgc_error(g, e->line, "native backend: recv with no Option/Some/None in scope");
                fputs("INT_VAL(0)", g->out);
                return;
            }
            fputs("em_channel_recv(&g_em, ", g->out);
            emit_expr(g, e->as.call.args[0]);
            fprintf(g->out, ", %d, %d, %d)",
                    some->enum_id, some->variant_index, none->variant_index);
            return;
        }
        if (e->as.call.arg_count == 1 && strcmp(nm, "close") == 0) {
            fputs("em_channel_close(", g->out);
            emit_expr(g, e->as.call.args[0]);
            fputc(')', g->out);
            return;
        }
        // Numeric conversions (M5). to_float/to_int are the int↔float intrinsics; a bare
        // numeric type name is a width cast carrying the target kind in num_kind.
        if (e->as.call.arg_count == 1 && strcmp(nm, "to_float") == 0) {
            fputs("em_to_float(", g->out);
            emit_expr(g, e->as.call.args[0]);
            fputc(')', g->out);
            return;
        }
        if (e->as.call.arg_count == 1 && strcmp(nm, "to_int") == 0) {
            fputs("em_to_int(", g->out);
            emit_expr(g, e->as.call.args[0]);
            fputc(')', g->out);
            return;
        }
        if (e->as.call.newtype_ctor) {   // OFI-149: newtype construction is a no-op (value IS the base)
            emit_expr(g, e->as.call.args[0]);
            return;
        }
        if (e->as.call.arg_count == 1 && cgc_is_numeric_typename(nm)) {
            fprintf(g->out, "em_conv(");
            emit_expr(g, e->as.call.args[0]);
            fprintf(g->out, ", %d)", e->num_kind);
            return;
        }
        // clock() → monotonic seconds (M5).
        if (e->as.call.arg_count == 0 && strcmp(nm, "clock") == 0) {
            fputs("em_clock()", g->out);
            return;
        }
        // Wrapping arithmetic (OFI-041): wrapping_add/sub/mul(a, b) — modulo 2^width, no trap.
        if (e->as.call.arg_count == 2 &&
            (strcmp(nm, "wrapping_add") == 0 || strcmp(nm, "wrapping_sub") == 0 ||
             strcmp(nm, "wrapping_mul") == 0)) {
            fprintf(g->out, "em_wrap_%s(", nm + 9);   // skip the "wrapping_" prefix
            emit_expr(g, e->as.call.args[0]);
            fputs(", ", g->out);
            emit_expr(g, e->as.call.args[1]);
            fprintf(g->out, ", %d)", e->num_kind);
            return;
        }
        // len(array) — the free-function form of the array length intrinsic (a borrow read).
        if (e->as.call.arg_count == 1 && strcmp(nm, "len") == 0) {
            fputs("em_array_len(", g->out);
            emit_expr(g, e->as.call.args[0]);
            fputc(')', g->out);
            return;
        }
        // assert(cond [, "msg"]) — a hard runtime check (contracts are release-elided in native,
        // but a bare assert stays, matching --emit=run). The message, if a string literal, is
        // emitted as a C string for the failure report.
        if (e->as.call.arg_count >= 1 && strcmp(nm, "assert") == 0) {
            fputs("em_assert(", g->out);
            emit_expr(g, e->as.call.args[0]);
            const Expr *m = e->as.call.arg_count >= 2 ? e->as.call.args[1] : NULL;
            if (m != NULL && m->kind == EXPR_STRING && m->as.str.part_count == 1 &&
                m->as.str.parts[0].expr == NULL) {
                fputs(", ", g->out);
                emit_c_string_literal(g, m->as.str.parts[0].text, m->as.str.parts[0].len);
            } else {
                fputs(", 0", g->out);   // only shown on failure (which diverges anyway)
            }
            fputc(')', g->out);
            return;
        }
        // Any remaining native builtin (read_line, file I/O, libm math, char/parse helpers,
        // concat, args/env/exit) → the em_native dispatcher. print/println keep their own path
        // above; the verification-only and graphics ids are not part of the native runtime.
        int nid = native_id_for_name(nm);
        // The real native-runtime builtins go through em_native. That's the contiguous READ_LINE..EXIT
        // band plus byte_slice (id 22, past the witness-only HASH_ANY/VALUE_EQ which are NOT runtime
        // calls), so it's named explicitly rather than by widening the range over those two.
        if ((nid >= NATIVE_READ_LINE && nid <= NATIVE_EXIT) || nid == NATIVE_BYTE_SLICE) {
            fprintf(g->out, "em_native(&g_em, %d, %zu, ", nid, e->as.call.arg_count);
            if (e->as.call.arg_count == 0) {
                fputs("0)", g->out);
                return;
            }
            fputs("(Value[]){ ", g->out);
            for (size_t i = 0; i < e->as.call.arg_count; i++) {
                if (i > 0) { fputs(", ", g->out); }
                emit_expr(g, e->as.call.args[i]);   // builtins read their args (borrows)
            }
            fputs(" })", g->out);
            return;
        }
    }
    if (callee->kind == EXPR_GET && e->as.call.resolved_fn < 0) {
        // A struct method call `recv.m(args)` — the receiver is self (arg 0), then the
        // explicit args. The checker stored the method's function-table index in the
        // callee's field_index. (A module-qualified call `mod.foo` is also an EXPR_GET
        // but carries resolved_fn, so it falls through to the direct-call path below.)
        if (callee->as.get.clone_op != 0) {
            const Expr *recv = callee->as.get.object;
            if (callee->as.get.clone_op == 2) {
                // A value-struct deep clone needs em_s↔boxed bridging that the native backend
                // does not do yet (a value-struct expression is an unboxed em_s, but an
                // independent owned copy is most naturally a boxed Value). VM-only for now;
                // loud error rather than a silent miscompile (OFI-082 native follow-up).
                cgc_error(g, e->line,
                    "native backend: .clone() of a value-struct isn't supported yet (OFI-082); "
                    "it works on the VM (the default). For native, rebuild the struct from its "
                    "fields, or clone an array.");
                fputs("INT_VAL(0)", g->out);
                return;
            }
            // clone_op == 1: deep-copy an array (always a boxed Value in native, so no em_s
            // duality). A reads-as-copy receiver (`m[i]` of an aggregate element) is ALREADY an
            // owned clone via em_index — emit it directly. A borrow is a live handle, deep-cloned
            // by own_into_slot. An owned temporary is cloned, then the temporary is dropped.
            if (cgc_reads_as_copy(recv)) {
                emit_expr(g, recv);
                return;
            }
            if (recv_is_borrow(recv)) {
                fputs("own_into_slot(&g_em, ", g->out);
                emit_expr(g, recv);
                fputc(')', g->out);
                return;
            }
            int t = g->next_var++, rv = g->next_var++;
            fprintf(g->out, "({ Value v%d = ", t);
            emit_expr(g, recv);
            fprintf(g->out,
                    "; Value v%d = own_into_slot(&g_em, v%d); drop_value(&g_em, v%d); v%d; })",
                    rv, t, t, rv);
            return;
        }
        if (callee->as.get.array_op != ARR_OP_NONE) {
            // Intrinsic array methods — codes are the shared ARR_OP_* in ast.h.
            int op = callee->as.get.array_op;
            if (op == ARR_OP_LEN) {     // arr.len()
                emit_borrow_recv_call(g, "em_array_len", callee->as.get.object);
                return;
            }
            if (op == ARR_OP_APPEND) {  // arr.append(x) — mutates through the array header
                // A receiver reached through an index / value-struct field reads a COPY (em_index
                // clones), so a plain append would grow the clone and lose it — write it back (OFI-072).
                if (cgc_reads_as_copy(callee->as.get.object)) {
                    emit_array_append_writeback(g, e);
                    return;
                }
                fputs("em_array_append(&g_em, ", g->out);
                emit_expr(g, callee->as.get.object);
                fputs(", ", g->out);
                emit_value_arg(g, e->as.call.args[0]);   // box a value-struct element
                fputc(')', g->out);
                return;
            }
            if (op == ARR_OP_REMOVE_LAST) {   // arr.remove_last() — pops + returns the last element
                emit_borrow_recv_ctx_call(g, "em_array_pop", callee->as.get.object, NULL, 0);
                return;
            }
            if (op == ARR_OP_REMOVE_AT) {     // arr.remove_at(i) — remove + return element i
                emit_borrow_recv_ctx_call(g, "em_array_remove_at", callee->as.get.object,
                                          e->as.call.args, 1);
                return;
            }
            if (op == ARR_OP_SLICE) {   // arr.slice(lo, hi) — fresh owned copy of the range
                emit_borrow_recv_ctx_call(g, "em_array_slice", callee->as.get.object,
                                          e->as.call.args, 2);
                return;
            }
            cgc_error(g, e->line, "native backend: unknown array method");
            fputs("INT_VAL(0)", g->out);
            return;
        }
        if (callee->as.get.string_op != 0) {
            // Intrinsic string methods (checker: 1 len, 2 chars, 3 split, 4 parse_int,
            // 5 char_count, 6 bytes). Each reads the receiver (a borrow) and allocates fresh.
            int op = callee->as.get.string_op;
            if (op == 1) {              // s.len() — byte length, O(1)
                emit_borrow_recv_call(g, "em_str_len", callee->as.get.object);
                return;
            }
            if (op == 5) {              // s.char_count() — code-point count
                emit_borrow_recv_call(g, "em_str_char_count", callee->as.get.object);
                return;
            }
            if (op == 2) {              // s.chars() → [string] of code points
                emit_borrow_recv_ctx_call(g, "em_str_chars", callee->as.get.object, NULL, 0);
                return;
            }
            if (op == 6) {              // s.bytes() → [u8]
                emit_borrow_recv_ctx_call(g, "em_str_bytes", callee->as.get.object, NULL, 0);
                return;
            }
            if (op == 3) {              // s.split(sep) → [string]
                emit_borrow_recv_ctx_call(g, "em_str_split", callee->as.get.object,
                                          e->as.call.args, 1);
                return;
            }
            if (op == 4) {              // s.parse_int() → Option<int> (Some/None tags carried)
                const CgcVariant *some = resolve_variant(g, "Some");
                const CgcVariant *none = resolve_variant(g, "None");
                if (some == NULL || none == NULL) {
                    cgc_error(g, e->line,
                              "native backend: parse_int with no Option/Some/None in scope");
                    fputs("INT_VAL(0)", g->out);
                    return;
                }
                const Expr *recv = callee->as.get.object;
                int temp = !recv_is_borrow(recv);
                if (temp) {
                    int t  = g->next_var++;
                    int rv = g->next_var++;
                    fprintf(g->out, "({ Value v%d = ", t);
                    emit_expr(g, recv);
                    fprintf(g->out, "; Value v%d = em_str_parse_int(&g_em, v%d, %d, %d, %d); "
                                    "drop_value(&g_em, v%d); v%d; })",
                            rv, t, some->enum_id, some->variant_index, none->variant_index,
                            t, rv);
                } else {
                    fputs("em_str_parse_int(&g_em, ", g->out);
                    emit_expr(g, recv);
                    fprintf(g->out, ", %d, %d, %d)",
                            some->enum_id, some->variant_index, none->variant_index);
                }
                return;
            }
            cgc_error(g, e->line, "native backend: unknown string method");
            fputs("INT_VAL(0)", g->out);
            return;
        }
        if (callee->as.get.dyn_method >= 0) {
            // Dynamic dispatch through an interface value's vtable: read the method's
            // function index from vtable[slot], then call it via em_invoke with the boxed
            // receiver (self, a borrow) followed by the arguments. em_invoke unboxes a
            // struct receiver/args and boxes a struct result as the method signature needs.
            int iv = g->next_var++;
            fprintf(g->out, "({ Value v%d = ", iv);
            emit_expr(g, callee->as.get.object);
            fprintf(g->out,
                    "; em_invoke(&g_em, AS_INT(em_enum_field(&g_em, AS_INTERFACE(v%d)->vtable, %d)), "
                    "(Value[]){ AS_INTERFACE(v%d)->receiver",
                    iv, callee->as.get.dyn_method, iv);
            for (size_t i = 0; i < e->as.call.arg_count; i++) {
                fputs(", ", g->out);
                emit_value_arg(g, e->as.call.args[i]);   // box a value-struct arg (em_invoke unboxes)
            }
            fputs(" }); })", g->out);
            return;
        }
        if (callee->as.get.bound_method >= 0) {
            // Bounded-generic method dispatch (`a.compare(b)` / `self.k.eq(other)` on an erased
            // `T: Bound`): read the method's fn-index out of the witness (a hidden `w<n>` of the
            // enclosing bounded function, or a trailing field of `self`), then dispatch through
            // rt_call_indirect with [receiver, args]. em_invoke UNBOXES a value-struct operand
            // into an em_s (a copy), so an OWNED boxed operand — a fresh em_box_struct, or an
            // erased field read materialised/retained by em_field_owned — would leak (the VM has
            // no such leak: it passes value structs multi-slot). So each owned operand is hoisted
            // into a temp and dropped after the call; a borrow (a binding / scalar / the param it
            // came from) is left to its owner. (OFI-054 — closes the value-struct-key leak.)
            int bw = callee->as.get.bound_witness;
            int bm = callee->as.get.bound_method;
            size_t nops = e->as.call.arg_count + 1;
            if (nops > 24) {
                cgc_error(g, e->line, "native backend: too many bound-method operands");
                fputs("INT_VAL(0)", g->out);
                return;
            }
            int opv[24];
            int opown[24];
            fputs("({ ", g->out);
            for (size_t i = 0; i < nops; i++) {
                const Expr *op = (i == 0) ? callee->as.get.object : e->as.call.args[i - 1];
                int ov = g->next_var++;
                opv[i] = ov;
                if (struct_sid_of(g, op) >= 0) {
                    fprintf(g->out, "Value v%d = ", ov);
                    emit_value_arg(g, op);              // a fresh owned box
                    fputs("; ", g->out);
                    opown[i] = 1;
                } else if (op->kind == EXPR_GET && op->as.get.field_index >= 0) {
                    // an erased type-param field read (`self.k`): read OWNED so its runtime kind
                    // (materialised inline / retained heap / copied scalar) is uniformly droppable.
                    fprintf(g->out, "Value v%d = em_field_owned(&g_em, ", ov);
                    emit_expr(g, op->as.get.object);
                    fprintf(g->out, ", %d); ", op->as.get.field_index);
                    opown[i] = 1;
                } else {
                    fprintf(g->out, "Value v%d = ", ov);
                    emit_value_arg(g, op);              // a borrow (binding / scalar): owner drops it
                    fputs("; ", g->out);
                    opown[i] = 0;
                }
            }
            int rv = g->next_var++;
            fprintf(g->out, "Value v%d = rt_call_indirect(&g_em, AS_INT(em_enum_field(&g_em, ", rv);
            if (callee->as.get.bound_via_self) {
                const char *sn = cgc_lookup(g, "self");
                if (cgc_lookup_sid(g, "self") >= 0) {
                    fprintf(g->out, "%s.f%d", sn != NULL ? sn : "INT_VAL(0)", bw);
                } else {
                    fprintf(g->out, "em_enum_field(&g_em, %s, %d)",
                            sn != NULL ? sn : "INT_VAL(0)", bw);
                }
            } else {
                fprintf(g->out, "w%d", bw);
            }
            fprintf(g->out, ", %d)), %zu, (Value[]){ ", bm, nops);
            for (size_t i = 0; i < nops; i++) {
                if (i > 0) {
                    fputs(", ", g->out);
                }
                fprintf(g->out, "v%d", opv[i]);
            }
            fputs(" }, em_invoke); ", g->out);
            for (size_t i = 0; i < nops; i++) {
                if (opown[i]) {
                    fprintf(g->out, "drop_value(&g_em, v%d); ", opv[i]);
                }
            }
            fprintf(g->out, "v%d; })", rv);
            return;
        }
        int midx = callee->as.get.field_index;
        if (midx < 0) {
            cgc_error(g, e->line, "native backend (M2): unresolved method call");
            fputs("INT_VAL(0)", g->out);
            return;
        }
        if (callee->as.get.object->kind != EXPR_IDENT) {
            // A temporary receiver (`mk().m()`, `a.scaled(3).add(b)`): evaluate it ONCE into a C
            // temp, call (the method borrows self), then DROP it if it is an owned BOXED value
            // (the VM's drop_first / OP_DROP_UNDER). A value-struct temp is an em_s with no heap —
            // the VM boxes-then-frees, native skips both, nothing to drop. `move self` consumes it
            // (drop_first is 0 then). A `mut self` temp needs an lvalue, so it is materialised into
            // the C local (the mutation is harmlessly discarded — a temp isn't a place). Statement-
            // expression keeps it usable in expression position; chained calls recurse through here.
            const Expr  *recv = callee->as.get.object;
            const FnDecl *mfn = (midx < g->total_functions) ? g->fn_by_fi[midx] : NULL;
            int rsid    = struct_sid_of(g, e);      // value-struct RETURN, or -1
            int recv_vs = struct_sid_of(g, recv);   // value-struct RECEIVER sid, or -1
            int mut_self = (mfn != NULL && mfn->param_count > 0 && mfn->params[0].is_self &&
                            mfn->params[0].qual == OWN_MUT && recv_vs >= 0);
            int tv = g->next_var++;
            int rv = g->next_var++;
            fputs("({ ", g->out);
            if (recv_vs >= 0) {
                fprintf(g->out, "em_s%d v%d = ", recv_vs, tv);
            } else {
                fprintf(g->out, "Value v%d = ", tv);
            }
            emit_expr(g, recv);
            fputs("; ", g->out);
            if (rsid >= 0) {
                fprintf(g->out, "em_s%d v%d = em_fn_%d(", rsid, rv, midx);
            } else {
                fprintf(g->out, "Value v%d = em_fn_%d(", rv, midx);
            }
            fprintf(g->out, (recv_vs >= 0 && mut_self) ? "&v%d" : "v%d", tv);
            for (size_t i = 0; i < e->as.call.arg_count; i++) {
                fputs(", ", g->out);
                if (mfn != NULL && param_struct_sid(g, mfn, -1, (int)i + 1) >= 0) {
                    emit_expr(g, e->as.call.args[i]);
                } else {
                    emit_value_arg(g, e->as.call.args[i]);
                }
            }
            fputs("); ", g->out);
            if (recv_vs < 0 && e->as.call.drop_first) {
                fprintf(g->out, "drop_value(&g_em, v%d); ", tv);   // owned boxed temp receiver
            }
            fprintf(g->out, "v%d; })", rv);
            return;
        }
        // `mut self` on a VALUE-type struct is passed by pointer so the method's mutations
        // reach the caller's struct. A BOXED struct (Map/Set) is a shared heap object, so its
        // `mut self` method takes the boxed Value directly — mutations reach the same object.
        int recv_value_struct = (struct_sid_of(g, callee->as.get.object) >= 0);
        int mut_self = (g->fn_by_fi != NULL && midx < g->total_functions &&
                        g->fn_by_fi[midx]->param_count > 0 &&
                        g->fn_by_fi[midx]->params[0].is_self &&
                        g->fn_by_fi[midx]->params[0].qual == OWN_MUT &&
                        recv_value_struct);
        const FnDecl *mfn = (midx >= 0 && midx < g->total_functions) ? g->fn_by_fi[midx] : NULL;
        int mmask = e->as.call.drop_mask;
        if (mmask != 0 && e->as.call.arg_count <= 64) {
            // Owned-temporary arguments (a fresh boxed value-struct passed by borrow to an erased
            // method param) must be dropped by the caller after the call, or they leak (OFI-027) —
            // exactly as the free-call path does, but with self as the implicit first parameter.
            int margid[64];
            int mrsid = (mfn != NULL) ? ret_struct_sid(g, mfn) : -1;
            int mrid  = g->next_var++;
            fputs("({ ", g->out);
            for (size_t i = 0; i < e->as.call.arg_count; i++) {
                int psid = (mfn != NULL) ? param_struct_sid(g, mfn, -1, (int)i + 1) : -1;
                margid[i] = g->next_var++;
                if (psid >= 0) {
                    fprintf(g->out, "em_s%d c%d = ", psid, margid[i]);
                    emit_expr(g, e->as.call.args[i]);
                } else {
                    fprintf(g->out, "Value c%d = ", margid[i]);
                    emit_value_arg(g, e->as.call.args[i]);
                }
                fputs("; ", g->out);
            }
            if (mrsid >= 0) {
                fprintf(g->out, "em_s%d c%d = em_fn_%d(", mrsid, mrid, midx);
            } else {
                fprintf(g->out, "Value c%d = em_fn_%d(", mrid, midx);
            }
            if (mut_self) {
                const char *rn = cgc_lookup(g, callee->as.get.object->as.ident);
                fprintf(g->out, "&%s", rn != NULL ? rn : "INT_VAL(0)");
            } else {
                emit_expr(g, callee->as.get.object);
            }
            for (size_t i = 0; i < e->as.call.arg_count; i++) {
                fprintf(g->out, ", c%d", margid[i]);
            }
            fputs("); ", g->out);
            for (size_t i = 0; i < e->as.call.arg_count; i++) {
                // Only a boxed Value temp is dropped; an em_s value-struct arg (psid >= 0) is
                // passed by value and owns no heap, so it is never dropped (and isn't a Value).
                int psid = (mfn != NULL) ? param_struct_sid(g, mfn, -1, (int)i + 1) : -1;
                if ((mmask & (1 << i)) && psid < 0) {
                    fprintf(g->out, "drop_value(&g_em, c%d); ", margid[i]);
                }
            }
            fprintf(g->out, "c%d; })", mrid);
            return;
        }
        fprintf(g->out, "em_fn_%d(", midx);
        if (mut_self) {
            const char *rn = cgc_lookup(g, callee->as.get.object->as.ident);
            fprintf(g->out, "&%s", rn != NULL ? rn : "INT_VAL(0)");
        } else {
            emit_expr(g, callee->as.get.object);   // self by value (or the boxed self Value)
        }
        for (size_t i = 0; i < e->as.call.arg_count; i++) {
            fputs(", ", g->out);
            // A value-struct parameter takes an em_s directly; an erased / Value parameter
            // (e.g. a generic struct method's `V`) takes a boxed Value, so box a struct arg.
            if (mfn != NULL && param_struct_sid(g, mfn, -1, (int)i + 1) >= 0) {
                emit_expr(g, e->as.call.args[i]);
            } else {
                emit_value_arg(g, e->as.call.args[i]);
            }
        }
        fputc(')', g->out);
        return;
    }
    int fi = e->as.call.resolved_fn;
    if (fi < 0) {
        const Expr *callee = e->as.call.callee;
        const char *nm = (callee->kind == EXPR_IDENT) ? callee->as.ident : "<expr>";
        cgc_error(g, e->line,
                  "native backend (M1): unsupported call '%s' (builtins, methods, "
                  "constructors not yet supported)", nm);
        fputs("INT_VAL(0)", g->out);
        return;
    }
    const FnDecl *cf = g->fn_by_fi[fi];
    int mask = e->as.call.drop_mask;
    if (mask != 0 && e->as.call.arg_count <= 64) {
        // Owned-temporary arguments (the checker's drop_mask — e.g. a fresh interface/string/
        // boxed-struct value passed by borrow) must be dropped by the CALLER after the call, or
        // they leak (OFI-027). Hoist every argument into a C local (preserving left-to-right
        // evaluation), call, drop each masked local (always a single boxed Value), then yield
        // the result. A statement-expression keeps it usable in expression position.
        int argid[64];
        int rsid = ret_struct_sid(g, cf);
        int rid  = g->next_var++;
        fputs("({ ", g->out);
        for (size_t i = 0; i < e->as.call.arg_count; i++) {
            int psid = param_struct_sid(g, cf, -1, (int)i);
            argid[i] = g->next_var++;
            if (psid >= 0) {
                fprintf(g->out, "em_s%d c%d = ", psid, argid[i]);
                emit_expr(g, e->as.call.args[i]);
            } else {
                fprintf(g->out, "Value c%d = ", argid[i]);
                emit_value_arg(g, e->as.call.args[i]);
            }
            fputs("; ", g->out);
        }
        if (rsid >= 0) {
            fprintf(g->out, "em_s%d c%d = em_fn_%d(", rsid, rid, fi);
        } else {
            fprintf(g->out, "Value c%d = em_fn_%d(", rid, fi);
        }
        for (size_t i = 0; i < e->as.call.arg_count; i++) {
            fprintf(g->out, "%sc%d", i > 0 ? ", " : "", argid[i]);
        }
        fputs("); ", g->out);
        for (size_t i = 0; i < e->as.call.arg_count; i++) {
            if (mask & (1 << i)) {
                fprintf(g->out, "drop_value(&g_em, c%d); ", argid[i]);
            }
        }
        fprintf(g->out, "c%d; })", rid);
        return;
    }
    fprintf(g->out, "em_fn_%d(", fi);
    for (size_t i = 0; i < e->as.call.arg_count; i++) {
        if (i > 0) {
            fputs(", ", g->out);
        }
        emit_expr(g, e->as.call.args[i]);
    }
    fputc(')', g->out);
}






// The `?` operator (EXPR_TRY): evaluate the Result/Option operand into a temp; on the
// success variant, MOVE its payload out (field 0, retained) and free the now-empty shell;
// otherwise run the function's owning-local drops and `return` the Err/None early. This is
// the VM's EXPR_TRY (OP_GET_TAG test fused with emit_return_drops). A GCC/clang statement-
// expression lets the early `return` — which exits the enclosing C function — sit in
// expression position; a function containing `?` always returns a boxed enum (Value), so
// returning the operand value type-checks. The operand is consumed (the checker moves it
// in: on the failure path it is the returned value), so there is no aliasing with a source
// binding's scope-exit drop.
static void emit_try(CgcGen *g, const Expr *e) {
    int v = g->next_var++;
    int p = g->next_var++;
    fprintf(g->out, "({ Value v%d = ", v);
    emit_expr(g, e->as.try_.operand);
    fputs(";\n", g->out);
    g->indent++;
    cgc_indent(g);
    fprintf(g->out, "if (em_tag(v%d) != %d) {\n", v, e->as.try_.success_variant);
    g->indent++;
    emit_drops(g, 0);
    cgc_indent(g);
    fprintf(g->out, "return v%d;\n", v);
    g->indent--;
    cgc_indent(g);
    fputs("}\n", g->out);
    cgc_indent(g);
    // OFI-122: TAKE the payload (move a unique-owner aggregate out by nil'ing the enum slot; share a
    // refcounted one via retain) so the shell-drop below cannot also release it. The old em_enum_field
    // + blanket OBJ_RETAIN double-dropped a unique-owner payload — a crash for a `resource` (its drop
    // ran on the enum-drop, then again at the extracted binding's scope exit).
    fprintf(g->out, "Value v%d = em_enum_take(&g_em, v%d, 0);\n", p, v);
    cgc_indent(g);
    fprintf(g->out, "drop_value(&g_em, v%d);\n", v);
    cgc_indent(g);
    fprintf(g->out, "v%d; })", p);
    g->indent--;
}






// A lambda or bare function value lowers to an ObjClosure built by em_closure: the lifted
// function's table index, then its captured values. The lifted function's leading params ARE
// the captures — the checker names them after the enclosing locals — so each capture is read
// from the enclosing C local of the same name (a borrow; em_closure retains the heap ones).
// A bare function value (EXPR_FN_VALUE) is just a zero-capture closure.
static void emit_lambda(CgcGen *g, const Expr *e) {
    int fi = e->as.lambda.lifted_fn_index;
    int cc = e->as.lambda.capture_count;
    fprintf(g->out, "em_closure(&g_em, %d, %d", fi, cc);
    const FnDecl *lf = (fi >= 0 && fi < g->total_functions) ? g->fn_by_fi[fi] : NULL;
    for (int i = 0; i < cc; i++) {
        fputs(", ", g->out);
        const char *nm = (lf != NULL && (size_t)i < lf->param_count) ? lf->params[i].name : NULL;
        const char *cn = nm != NULL ? cgc_lookup(g, nm) : NULL;
        if (cn == NULL) {
            fputs("INT_VAL(0)", g->out);
        } else {
            int sk = cgc_lookup_scalar_kind(g, nm);
            if (sk >= 0) {
                emit_scalar_box(g, sk, cn);   // a width-typed scalar capture boxes to a Value (OFI-123)
            } else {
                fputs(cn, g->out);            // a Value/struct capture (em_closure retains heap ones)
            }
        }
    }
    fputc(')', g->out);
}





// A field read `obj.field` → direct C member access `<obj>.f<idx>`. A value-type struct
// has no heap or drop, so reading a field of a temporary (a call/construction result) is
// just member access on an rvalue; a nested inline-struct field yields a value copy.
static void emit_field_get(CgcGen *g, const Expr *e) {
    if (e->as.get.field_index < 0) {
        cgc_error(g, e->line,
                  "native backend (M2): unsupported field/method access "
                  "(method values, module-qualified access not yet supported)");
        fputs("INT_VAL(0)", g->out);
        return;
    }
    if (struct_sid_of(g, e->as.get.object) >= 0) {
        // A value-type struct (all-scalar): a direct C field read, no heap, no ownership.
        emit_expr(g, e->as.get.object);
        fprintf(g->out, ".f%d", e->as.get.field_index);
    } else if (e->as.get.inline_struct_id >= 0) {
        // A nested INLINE-STRUCT field read off a BOXED receiver (OFI-054 A1): materialise a boxed
        // COPY of the field (value semantics, the VM's OP_GET_FIELD inline branch), unbox it into
        // an em_s, then drop the box. A fresh owned-temporary receiver (drop_object) is read BEFORE
        // it is dropped — the VM's OP_GET_FIELD_OWNED; a binding whose field escapes is nilled.
        int nsid = e->as.get.inline_struct_id;
        int ov = g->next_var++, mv = g->next_var++, rv = g->next_var++;
        fprintf(g->out, "({ Value v%d = ", ov);
        emit_expr(g, e->as.get.object);
        fprintf(g->out, "; Value v%d = em_struct_field_inline(&g_em, v%d, %d); ",
                mv, ov, e->as.get.field_index);
        if (e->as.get.drop_object) {
            fprintf(g->out, "drop_value(&g_em, v%d); ", ov);
            if (e->as.get.object->kind == EXPR_IDENT) {
                const char *cn = cgc_lookup(g, e->as.get.object->as.ident);
                if (cn != NULL) {
                    fprintf(g->out, "%s = INT_VAL(0); ", cn);
                }
            }
        }
        fprintf(g->out, "em_s%d r%d; em_unbox_struct(&g_em, %d, v%d, (Value*)&r%d, %d); "
                        "drop_value(&g_em, v%d); r%d; })",
                nsid, rv, nsid, mv, rv, g->layouts[nsid].field_count, mv, rv);
    } else if (e->as.get.drop_object) {
        // OWNED read of a boxed struct field (the VM's OP_GET_FIELD_OWNED): the receiver is a
        // fresh owned temporary, or a binding whose field ESCAPES (e.g. `return c.host`). Read
        // the field, RETAIN it (so it survives the receiver's drop), then drop the receiver. If
        // the receiver is a binding, nil its slot so its later scope-exit drop is a no-op.
        int o = g->next_var++;
        int f = g->next_var++;
        fprintf(g->out, "({ Value v%d = ", o);
        emit_expr(g, e->as.get.object);
        fprintf(g->out,
                "; Value v%d = em_enum_field(&g_em, v%d, %d); if (IS_OBJ(v%d)) OBJ_RETAIN(AS_OBJ(v%d)); "
                "drop_value(&g_em, v%d); ",
                f, o, e->as.get.field_index, f, f, o);
        if (e->as.get.object->kind == EXPR_IDENT) {
            const char *cn = cgc_lookup(g, e->as.get.object->as.ident);
            if (cn != NULL) {
                fprintf(g->out, "%s = INT_VAL(0); ", cn);
            }
        }
        fprintf(g->out, "v%d; })", f);
    } else {
        // A borrowed read of a boxed struct field (e.g. a transient use, or a match-pattern
        // field bind): the box still owns it.
        fputs("em_enum_field(&g_em, ", g->out);
        emit_expr(g, e->as.get.object);
        fprintf(g->out, ", %d)", e->as.get.field_index);
    }
}






// A struct literal `Name{...}` → a C compound literal `((em_s<sid>){ f0, f1, … })` with
// the fields in DECLARED order (the literal may list them in any order), mirroring
// codegen's name-matching. A value-type struct: no heap, copied by value.
static void emit_struct_lit(CgcGen *g, const Expr *e) {
    int sid = e->as.struct_lit.resolved_struct;
    if (sid < 0 || sid >= g->struct_count) {
        cgc_error(g, e->line, "native backend (M2): construction of an unresolved struct");
        fputs("INT_VAL(0)", g->out);
        return;
    }
    const CgcStructNames *sn = &g->snames[sid];
    // A value-type struct is a C compound literal `((em_s<sid>){ … })`; a BOXED struct (one
    // with a heap field — a Config, a Map/Set bucket array, …) is a heap object built by
    // em_struct (so its fields are dropped by drop_value). A boxed struct must be flat (no
    // nested value-struct field), since em_struct passes each field as one Value.
    int boxed = !is_value_struct(g, sid);
    int total = sn->field_count + e->as.struct_lit.witness_total;
    if (boxed && !struct_is_flat(g, sid)) {
        // A boxed struct with a nested INLINE-STRUCT field — em_struct (varargs, one Value per
        // field) can't place it. Build-then-place per field (the VM's OP_NEW_STRUCT): an inline
        // field is boxed then its packed bytes are copied into the inline slot; a scalar/heap
        // field (and the trailing witnesses) MOVE in. (OFI-054 A2.)
        int sv = g->next_var++;
        fprintf(g->out, "({ Value v%d = em_struct_empty(&g_em, %d); ", sv, sid);
        for (int j = 0; j < sn->field_count; j++) {
            const Expr *value = NULL;
            for (size_t i = 0; i < e->as.struct_lit.field_count; i++) {
                if (strcmp(e->as.struct_lit.fields[i].name, sn->names[j]) == 0) {
                    value = e->as.struct_lit.fields[i].value;
                    break;
                }
            }
            if (value == NULL) {
                cgc_error(g, e->line, "native backend: a struct field is missing at construction");
                continue;
            }
            if (g->layouts[sid].field_struct[j] >= 0) {
                fprintf(g->out, "em_struct_put_inline(&g_em, v%d, %d, ", sv, j);
                emit_value_arg(g, value);   // box the nested value struct; its bytes are placed
            } else {
                fprintf(g->out, "em_struct_put_field(&g_em, v%d, %d, ", sv, j);
                emit_value_arg(g, value);   // move a scalar/heap field in
            }
            fputs("); ", g->out);
        }
        for (int w = 0; w < e->as.struct_lit.witness_total; w++) {
            const Witness *wit = &e->as.struct_lit.witnesses[w];
            fprintf(g->out, "em_struct_put_field(&g_em, v%d, %d, em_enum(&g_em, 0, 0, %d",
                    sv, sn->field_count + w, wit->count);
            for (int m = 0; m < wit->count; m++) {
                fprintf(g->out, ", INT_VAL(%d)", wit->fns[m]);
            }
            fputs(")); ", g->out);
        }
        fprintf(g->out, "v%d; })", sv);
        return;
    }
    if (boxed) {
        fprintf(g->out, "em_struct(&g_em, %d, %d", sid, total);
    } else {
        fprintf(g->out, "((em_s%d){ ", sid);
    }
    int first = 1;
    for (int j = 0; j < sn->field_count; j++) {
        const Expr *value = NULL;
        for (size_t i = 0; i < e->as.struct_lit.field_count; i++) {
            if (strcmp(e->as.struct_lit.fields[i].name, sn->names[j]) == 0) {
                value = e->as.struct_lit.fields[i].value;
                break;
            }
        }
        if (boxed || !first) {
            fputs(", ", g->out);
        }
        first = 0;
        if (value == NULL) {
            cgc_error(g, e->line, "native backend: a struct field is missing at construction");
            fputs("INT_VAL(0)", g->out);
        } else if (boxed) {
            emit_value_arg(g, value);   // box a value-struct field; move scalars/heap in
        } else {
            emit_expr(g, value);
        }
    }
    // A bounded generic struct (e.g. `Map<K: Hash+Eq, V>`) stores its key/value witnesses as
    // hidden TRAILING fields, appended at construction (the VM's instance-storage). Each is an
    // enum record of the concrete type's method fn-indices, read later via `self.f<n>` for a
    // bound method call. They fill the layout fields after the declared ones.
    for (int w = 0; w < e->as.struct_lit.witness_total; w++) {
        const Witness *wit = &e->as.struct_lit.witnesses[w];
        if (boxed || !first) {
            fputs(", ", g->out);
        }
        first = 0;
        fprintf(g->out, "em_enum(&g_em, 0, 0, %d", wit->count);
        for (int m = 0; m < wit->count; m++) {
            fprintf(g->out, ", INT_VAL(%d)", wit->fns[m]);
        }
        fputc(')', g->out);
    }
    if (boxed) {
        fputc(')', g->out);
    } else {
        fputs(" })", g->out);
    }
}






// An array literal `[e0, e1, …]` → em_array(ctx, n, elem_kind, …). The element storage
// kind is the checker's ArrayElemKind, carried on the node's num_kind. (Arrays of inline
// structs are not emitted yet.)
static void emit_array_lit(CgcGen *g, const Expr *e) {
    if (e->as.array.elem_struct_id >= 0) {
        // Inline-struct array: each element is boxed (em_box_struct for an all-scalar value
        // struct, em_struct for a heap-bearing one — emit_value_arg does both), and em_struct_array
        // copies each packed ObjStruct->data into the buffer (the VM's OP_NEW_STRUCT_ARRAY).
        fprintf(g->out, "em_struct_array(&g_em, %zu, %d",
                e->as.array.count, e->as.array.elem_struct_id);
        for (size_t i = 0; i < e->as.array.count; i++) {
            fputs(", ", g->out);
            emit_value_arg(g, e->as.array.elems[i]);   // box the element struct
        }
        fputc(')', g->out);
        return;
    }
    fprintf(g->out, "em_array(&g_em, %zu, %d", e->as.array.count, e->num_kind);
    for (size_t i = 0; i < e->as.array.count; i++) {
        fputs(", ", g->out);
        emit_value_arg(g, e->as.array.elems[i]);   // box a value-struct element
    }
    fputc(')', g->out);
}






// An index read `arr[i]` → em_index(arr, i) (bounds-checked). A slice `arr[lo..hi]` →
// em_slice(arr, lo, hi): a borrowed zero-copy view (the checker froze the source and forbids
// the view escaping, so the borrow is safe; drop_value frees only the slice header).
static void emit_index(CgcGen *g, const Expr *e) {
    if (e->as.index.index->kind == EXPR_RANGE) {
        const Expr *r = e->as.index.index;
        fputs("em_slice(&g_em, ", g->out);
        emit_expr(g, e->as.index.object);
        fputs(", ", g->out);
        emit_expr(g, r->as.range.lo);
        fputs(", ", g->out);
        emit_expr(g, r->as.range.hi);
        fputc(')', g->out);
        return;
    }
    int es = e->as.index.inline_struct_id;
    if (is_value_struct(g, es)) {
        // An inline value-struct element: em_index returns an owned boxed COPY; unbox it into the
        // C value struct and drop the box (an inline-eligible struct is all-scalar — no heap to
        // lose). The result is an em_s, matching how the binding/field-read typing sees `arr[i]`.
        int bv = g->next_var++;
        int rv = g->next_var++;
        fprintf(g->out, "({ Value v%d = em_index(&g_em, ", bv);
        emit_expr(g, e->as.index.object);
        fputs(", ", g->out);
        emit_expr(g, e->as.index.index);
        fprintf(g->out, "); em_s%d r%d; em_unbox_struct(&g_em, %d, v%d, (Value*)&r%d, %d); "
                        "drop_value(&g_em, v%d); r%d; })",
                es, rv, es, bv, rv, g->layouts[es].field_count, bv, rv);
        return;
    }
    fputs("em_index(&g_em, ", g->out);
    emit_expr(g, e->as.index.object);
    fputs(", ", g->out);
    emit_expr(g, e->as.index.index);
    fputc(')', g->out);
}






// Emit `bytes[0..len)` as a C string literal, escaping quotes/backslash/controls and
// emitting any non-ASCII (UTF-8) byte as a 3-digit octal escape (unambiguous, unlike \x).
// The literal has exactly `len` bytes, which em_str copies.
static void emit_c_string_literal(CgcGen *g, const char *bytes, size_t len) {
    fputc('"', g->out);
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)bytes[i];
        if (c == '"' || c == '\\') {
            fprintf(g->out, "\\%c", c);
        } else if (c == '\n') {
            fputs("\\n", g->out);
        } else if (c == '\t') {
            fputs("\\t", g->out);
        } else if (c == '\r') {
            fputs("\\r", g->out);
        } else if (c >= 0x20 && c < 0x7f) {
            fputc((int)c, g->out);
        } else {
            fprintf(g->out, "\\%03o", c);
        }
    }
    fputc('"', g->out);
}






// One piece of a string literal: a literal run → em_str(ctx, "bytes", len); an
// interpolation hole `{expr}` → em_to_string(ctx, expr, render_kind).
// A string literal is INTERNED at its emit site: allocated once (a permanent reference held by
// the function-static `_li`) and returned retained on every use, so a literal evaluated in a
// loop is ONE object, not one per iteration — bounding memory exactly as the VM's interned
// literals do. (A use as a borrowed operand never drops its transient retain, which only
// inflates the single object's refcount, never allocates.) NOTE: the lazy init is not
// thread-safe — revisit for native concurrency (M4).
static void emit_interned_str(CgcGen *g, const char *bytes, size_t len) {
    fputs("({ static Value _li; static char _ls; if (!_ls) { _ls = 1; _li = em_str(&g_em, ",
          g->out);
    emit_c_string_literal(g, bytes, len);
    fprintf(g->out, ", %zu); } if (IS_OBJ(_li)) OBJ_RETAIN(AS_OBJ(_li)); _li; })", len);
}


static void emit_str_part(CgcGen *g, const StrPart *part) {
    if (part->expr != NULL) {
        if (part->string_temp) {
            // An owned-temp string hole (a call/concat result, incl. a desugared `.show()`)
            // already yields an owned reference the fold's em_add consumes — wrapping it in
            // the retaining em_to_string would leak that reference (OFI-146). Emit it raw.
            emit_expr(g, part->expr);
        } else {
            fputs("em_to_string(&g_em, ", g->out);
            emit_expr(g, part->expr);
            fprintf(g->out, ", %d)", part->render_kind);
        }
    } else {
        emit_interned_str(g, part->text, part->len);
    }
}






// A string literal (possibly interpolated) → its parts folded left-to-right with em_add
// (string concatenation). em_add consumes each operand; the result is a fresh owned string.
static void emit_string(CgcGen *g, const Expr *e) {
    size_t n = e->as.str.part_count;
    if (n == 0) {
        emit_interned_str(g, "", 0);
        return;
    }
    for (size_t i = 1; i < n; i++) {
        fputs("em_add(&g_em, ", g->out);
    }
    emit_str_part(g, &e->as.str.parts[0]);
    for (size_t i = 1; i < n; i++) {
        fputs(", ", g->out);
        emit_str_part(g, &e->as.str.parts[i]);
        fputs(", 0)", g->out);
    }
}






static void emit_expr_dispatch(CgcGen *g, const Expr *e) {
    switch (e->kind) {
        case EXPR_INT:
            // A full-range u64 literal (OFI-123) lands in the signed slot; one bit pattern — INT64_MIN
            // (the value 2⁶³, written as a `u64`) — would emit `-9223372036854775808LL`, whose MAGNITUDE
            // overflows signed long long, so clang warns. Emit its bits directly. Every other value's
            // decimal form is exact and warning-free (e.g. u64-max prints `-1LL`).
            if (e->as.int_lit == INT64_MIN) {
                fputs("INT_VAL((int64_t)0x8000000000000000ULL)", g->out);
            } else {
                fprintf(g->out, "INT_VAL(%lldLL)", (long long)e->as.int_lit);
            }
            break;
        case EXPR_FLOAT:
            // 17 significant digits round-trips an IEEE-754 double exactly.
            fprintf(g->out, "FLOAT_VAL(%.17g)", e->as.float_lit);
            break;
        case EXPR_BOOL:
            fprintf(g->out, "INT_VAL(%d)", e->as.bool_lit ? 1 : 0);
            break;
        case EXPR_IDENT: {
            const char *cn = cgc_lookup(g, e->as.ident);
            if (cn == NULL) {
                // A bare name that is not a local is a zero-field enum variant (`Red`). Prefer the
                // checker's resolved enum id + tag over a by-name lookup (OFI-073).
                int venum = e->variant_enum_id, vtag = e->variant_tag;
                if (venum < 0) {
                    const CgcVariant *v = resolve_variant(g, e->as.ident);
                    if (v != NULL) { venum = v->enum_id; vtag = v->variant_index; }
                }
                if (venum >= 0) {
                    fprintf(g->out, "em_enum(&g_em, %d, %d, 0)", venum, vtag);
                } else {
                    cgc_error(g, e->line,
                              "native backend (M2): unsupported reference '%s' "
                              "(globals not yet supported)", e->as.ident);
                    fputs("INT_VAL(0)", g->out);
                }
            } else if (cgc_lookup_sid(g, e->as.ident) >= 0) {
                // A value-type struct binding: emit the plain C name. C copies the struct
                // by value on use/pass/assignment, so a move (`let q = p`) and a borrow are
                // both independent copies — the language's value semantics, with no heap,
                // no drop, and no move-nil needed.
                fputs(cn, g->out);
            } else if (cgc_lookup_scalar_kind(g, e->as.ident) >= 0) {
                // OFI-123: a sized numeric local is stored at width — box it back to a Value so every
                // downstream consumer is unchanged. A scalar never moves/aliases (it is copied), so the
                // moves_local paths below don't apply.
                emit_scalar_box(g, cgc_lookup_scalar_kind(g, e->as.ident), cn);
            } else if (e->moves_local == 1) {
                // A MOVE out of the binding: read its value and NIL the slot, so the
                // binding's later scope-exit drop is a no-op (the new owner frees it).
                // This mirrors the VM nilling a moved-from slot (Expr.moves_local) and is
                // what keeps `let q = p` / a move argument from double-freeing. The GCC/
                // clang statement-expression keeps it usable in expression position.
                int m = g->next_var++;
                fprintf(g->out, "({ Value v%d = %s; %s = INT_VAL(0); v%d; })", m, cn, cn, m);
            } else {
                // A plain read (a borrow, or a refcounted alias). The moves_local==2 RETAIN of
                // an aliased read is applied generically in emit_expr_raw, mirroring the VM's
                // trailing OP_INCREF — so it covers GET/INDEX reads too, not just this binding.
                fputs(cn, g->out);
            }
            break;
        }
        case EXPR_UNARY:       emit_unary(g, e);      break;
        case EXPR_BINARY:      emit_binary(g, e);     break;
        case EXPR_CALL:        emit_call(g, e);       break;
        case EXPR_GET:         emit_field_get(g, e);  break;
        case EXPR_STRUCT_LIT:  emit_struct_lit(g, e); break;
        case EXPR_ARRAY:       emit_array_lit(g, e);  break;
        case EXPR_INDEX:       emit_index(g, e);      break;
        case EXPR_STRING:      emit_string(g, e);     break;
        case EXPR_TRY:         emit_try(g, e);        break;
        case EXPR_LAMBDA:      emit_lambda(g, e);     break;
        case EXPR_FN_VALUE:
            // A named function used as a value: a zero-capture closure over its slot.
            fprintf(g->out, "em_closure(&g_em, %d, 0)", e->as.fn_value);
            break;
        default:
            cgc_error(g, e->line,
                      "native backend (M3): unsupported expression "
                      "(lambdas / closures not yet supported)");
            fputs("INT_VAL(0)", g->out);
            break;
    }
}






// emit_expr_raw emits an expression and applies the moves_local==2 RETAIN generically — the
// counterpart of the VM's trailing OP_INCREF in gen_expr. The checker marks a read moves_local==2
// when an ERASED type-parameter value (which may be refcounted at run time) is read from an
// existing owner — a local binding, a struct/enum field (GET), or an array element (INDEX) — and
// aliased into a NEW owning slot (append, let, a store, a moved arg, a return). Both owners then
// release independently. The IS_OBJ guard makes it a no-op for a scalar (e.g. an `int` instance),
// matching the VM. A value-type struct (struct_sid_of >= 0) is a C-struct rvalue, not a Value, and
// owns no heap, so it is excluded (wrapping it as a Value would not even typecheck). An EXPR_IDENT
// move (moves_local==1) is handled in the dispatch and never reaches here as a 2.
static void emit_expr_raw(CgcGen *g, const Expr *e) {
    if (e->moves_local == 2 && struct_sid_of(g, e) < 0) {
        // Own an aliased value into a NEW slot: clone a unique-owner aggregate (value struct OR
        // array), retain a refcounted one. A bare OBJ_RETAIN double-frees a shared aggregate, since
        // structs/arrays are unique-owner not refcounted (OFI-062/063, the VM's OP_INCREF).
        fprintf(g->out, "own_into_slot(&g_em, ");
        emit_expr_dispatch(g, e);
        fprintf(g->out, ")");
        return;
    }
    emit_expr_dispatch(g, e);
}





// Emit an `if`/`else` chain with NO leading indentation and NO trailing newline, so
// it composes as the `else if` tail of an enclosing if (the caller supplies both).
static void emit_if_inline(CgcGen *g, const Stmt *s) {
    fputs("if (em_truthy(", g->out);
    emit_expr(g, s->as.if_.cond);
    fputs(")) {\n", g->out);
    g->indent++;
    emit_block_scoped(g, &s->as.if_.then_blk);
    g->indent--;
    cgc_indent(g);
    fputc('}', g->out);

    const Stmt *eb = s->as.if_.else_branch;
    if (eb == NULL) {
        return;
    }
    if (eb->kind == STMT_IF) {
        fputs(" else ", g->out);
        emit_if_inline(g, eb);
    } else if (eb->kind == STMT_BLOCK) {
        fputs(" else {\n", g->out);
        g->indent++;
        emit_block_scoped(g, &eb->as.block.body);
        g->indent--;
        cgc_indent(g);
        fputc('}', g->out);
    } else {
        // The parser only ever produces STMT_IF or STMT_BLOCK here.
        cgc_error(g, eb->line, "native backend: malformed else branch");
    }
}





// A `match` lowers to: evaluate the scrutinee into an anonymous subject local, then a C
// `switch` on its variant tag. Each case binds the variant's payload fields positionally
// as BORROWS (em_enum_field — the subject keeps ownership), runs the body, and breaks; a
// `case _` is the `default`. The subject is dropped at the end iff it was a fresh
// refcounted temporary (subject_drop) — and on a return inside a case via its drop flag.
static void emit_match(CgcGen *g, const Stmt *s) {
    cgc_indent(g);
    fputs("{\n", g->out);
    g->indent++;
    int mark = g->scope_len;

    int sv = g->next_var++;
    cgc_indent(g);
    fprintf(g->out, "Value v%d = ", sv);
    emit_expr(g, s->as.match.value);
    fputs(";\n", g->out);
    char scn[24];
    snprintf(scn, sizeof scn, "v%d", sv);
    cgc_push(g, "", scn, s->as.match.subject_drop, -1);   // anonymous subject

    // Dispatch on the variant tag with an if / else-if CHAIN, not a C `switch`: an Ember
    // `break`/`continue` in a case body must target the enclosing loop, but a C `switch` would
    // swallow `break` (e.g. `loop { match recv(c) { case None { break } } }` — the channel-drain
    // idiom). The chain has no switch to swallow it.
    int tv = g->next_var++;
    cgc_indent(g);
    fprintf(g->out, "int v%d = em_tag(v%d);\n", tv, sv);
    int first = 1;
    for (size_t k = 0; k < s->as.match.case_count; k++) {
        const MatchCase *mc = &s->as.match.cases[k];
        cgc_indent(g);
        if (mc->pattern.wildcard) {
            fputs(first ? "if (1) {\n" : "} else {\n", g->out);
        } else {
            // Dispatch on the checker-resolved tag, not a by-name lookup (OFI-073).
            int vi = mc->pattern.variant_index;
            if (vi < 0) {
                const CgcVariant *v = resolve_variant(g, mc->pattern.variant);
                vi = v != NULL ? v->variant_index : -1;
                if (v == NULL) {
                    cgc_error(g, mc->pattern.line, "native backend (M2): unresolved match variant");
                }
            }
            if (first) {
                fprintf(g->out, "if (v%d == %d) {\n", tv, vi);
            } else {
                fprintf(g->out, "} else if (v%d == %d) {\n", tv, vi);
            }
        }
        first = 0;
        g->indent++;
        int cmark = g->scope_len;
        for (size_t b = 0; b < mc->pattern.binding_count; b++) {
            int es = ((int)b < 16) ? mc->pattern.binding_struct[b] : -1;
            char bcn[24];
            if (is_value_struct(g, es)) {
                // A value-struct payload is stored BOXED in the enum; unbox the bound copy into an
                // em_s so it can be used as a value struct (field reads, method receiver, …). The
                // box is the enum's (a borrow), so we do NOT drop it — only copy out (all-scalar).
                int bv = g->next_var++;
                cgc_indent(g);
                fprintf(g->out, "em_s%d v%d; em_unbox_struct(&g_em, %d, "
                                "em_enum_field(&g_em, v%d, %zu), (Value*)&v%d, %d);\n",
                        es, bv, es, sv, b, bv, g->layouts[es].field_count);
                snprintf(bcn, sizeof bcn, "v%d", bv);
                cgc_push(g, mc->pattern.bindings[b], bcn, 0, es);   // an em_s value-struct binding
            } else {
                int bv = g->next_var++;
                cgc_indent(g);
                fprintf(g->out, "Value v%d = em_enum_field(&g_em, v%d, %zu);\n", bv, sv, b);
                snprintf(bcn, sizeof bcn, "v%d", bv);
                cgc_push(g, mc->pattern.bindings[b], bcn, 0, -1);   // borrows a subject field
            }
        }
        for (size_t i = 0; i < mc->body.count; i++) {
            emit_stmt(g, mc->body.stmts[i]);
        }
        emit_drops(g, cmark);   // release any case-body owned locals
        g->scope_len = cmark;
        g->indent--;
    }
    if (!first) {
        cgc_indent(g);
        fputs("}\n", g->out);
    }

    emit_drops(g, mark);   // drop the subject iff it was a fresh temporary
    g->scope_len = mark;
    g->indent--;
    cgc_indent(g);
    fputs("}\n", g->out);
}





// A `nursery { … }` block: a task list the spawns inside it append to, then em_run_nursery
// launches one OS thread per task (each runs the em_task_main trampoline) and joins them all.
// The list is heap-allocated so a deeply nested nursery doesn't blow the stack.
static void emit_nursery(CgcGen *g, const Stmt *s) {
    int id = g->next_var++;
    cgc_indent(g);
    fputs("{\n", g->out);
    g->indent++;
    cgc_indent(g);
    fprintf(g->out, "EmTask *_nt%d = malloc(256 * sizeof(EmTask)); int _nc%d = 0;\n", id, id);
    if (g->nursery_depth < 16) {
        g->nursery_id[g->nursery_depth] = id;
    }
    g->nursery_depth++;
    int mark = g->scope_len;
    for (size_t i = 0; i < s->as.nursery.body.count; i++) {
        emit_stmt(g, s->as.nursery.body.stmts[i]);
    }
    emit_drops(g, mark);
    g->scope_len = mark;
    g->nursery_depth--;
    cgc_indent(g);
    fprintf(g->out, "em_run_nursery(_nt%d, _nc%d, em_task_main);\n", id, id);
    cgc_indent(g);
    fprintf(g->out, "for (int _i = 0; _i < _nc%d; _i++) { free(_nt%d[_i].args); }\n", id, id);
    cgc_indent(g);
    fprintf(g->out, "free(_nt%d);\n", id);
    g->indent--;
    cgc_indent(g);
    fputs("}\n", g->out);
}


// `spawn f(args)` inside a nursery: record a task (the callee's slot + an owned copy of the
// argument values) into the enclosing nursery's list; the nursery launches it. The task takes
// ownership of the arguments (a value-struct arg is boxed; a shared channel is passed as-is).
static void emit_spawn(CgcGen *g, const Stmt *s) {
    if (g->nursery_depth <= 0 || g->nursery_depth > 16) {
        cgc_error(g, s->line, "native backend: spawn outside a nursery");
        return;
    }
    int id = g->nursery_id[g->nursery_depth - 1];
    const Expr *call = s->as.spawn.call;
    if (call->kind != EXPR_CALL || call->as.call.resolved_fn < 0) {
        cgc_error(g, s->line, "native backend (M4): spawn of a method/closure is not yet supported");
        return;
    }
    // A bounded-generic spawn threads the interface WITNESSES (method dictionaries) as the
    // leading args, ahead of the real arguments — `[w0, …, arg0, …]` — matching how a normal
    // bounded call passes them and the order the em_invoke witnessed case (below) expects. The
    // task OWNS every slot (the nursery frees only the array, the fiber consumes them), so unlike
    // a synchronous bounded call the witnesses are NOT dropped here. (OFI-054.)
    int wt = call->as.call.witness_total;
    size_t argc = call->as.call.arg_count;
    size_t total = (size_t)wt + argc;
    cgc_indent(g);
    fputs("{\n", g->out);
    g->indent++;
    cgc_indent(g);
    fprintf(g->out, "Value *_a = malloc(%zu * sizeof(Value));\n", total > 0 ? total : 1);
    for (int w = 0; w < wt; w++) {
        const Witness *wit = &call->as.call.witnesses[w];
        cgc_indent(g);
        fprintf(g->out, "_a[%d] = em_enum(&g_em, 0, 0, %d", w, wit->count);
        for (int m = 0; m < wit->count; m++) {
            fprintf(g->out, ", INT_VAL(%d)", wit->fns[m]);
        }
        fputs(");\n", g->out);
    }
    for (size_t i = 0; i < argc; i++) {
        cgc_indent(g);
        fprintf(g->out, "_a[%zu] = ", (size_t)wt + i);
        emit_value_arg(g, call->as.call.args[i]);
        fputs(";\n", g->out);
    }
    cgc_indent(g);
    fprintf(g->out, "_nt%d[_nc%d].fn_index = %d; _nt%d[_nc%d].args = _a; _nt%d[_nc%d].argc = %zu; _nc%d++;\n",
            id, id, call->as.call.resolved_fn, id, id, id, id, total, id);
    g->indent--;
    cgc_indent(g);
    fputs("}\n", g->out);
}


static void emit_stmt(CgcGen *g, const Stmt *s) {
    switch (s->kind) {
        case STMT_LET: {
            cgc_indent(g);
            int id  = g->next_var++;
            // The binding's value-type struct id: the checker flags only immutable `let`
            // structs, so fall back to the initialiser's struct type (covers `var` and
            // move/method-returned structs).
            int sid = s->as.let.inline_struct_id;
            if (sid < 0) {
                sid = struct_sid_of(g, s->as.let.value);
            }
            if (s->as.let.value->coerce_witness != NULL) {
                // The initialiser is a struct UPCAST to an interface — emit_expr turns it into
                // a boxed interface Value, so the binding is a Value (owned, drops at scope),
                // not the underlying value struct.
                sid = -1;
            }
            if (sid >= 0 && struct_sid_of(g, s->as.let.value) < 0) {
                // The binding is a value struct (em_s) but the initialiser produced a BOXED
                // value-struct (a remove_last pop, an erased generic `-> T` result, …) — unbox it
                // into the em_s and drop the box (an inline-eligible struct is all-scalar, so the
                // box owns no heap fields). Centralises the boxed→em_s coercion at the binding.
                int bv = g->next_var++;
                int rv = g->next_var++;
                fprintf(g->out, "em_s%d v%d = ({ Value v%d = ", sid, id, bv);
                emit_expr(g, s->as.let.value);
                fprintf(g->out, "; em_s%d v%d; em_unbox_struct(&g_em, %d, v%d, (Value*)&v%d, %d); "
                                "drop_value(&g_em, v%d); v%d; });\n",
                        sid, rv, sid, bv, rv, g->layouts[sid].field_count, bv, rv);
            } else if (sid < 0 && s->as.let.scalar_kind >= 0) {
                // OFI-123: a sized numeric binding lowers to a typed C scalar stored AT WIDTH; the
                // initialiser (a Value) is unboxed + truncated to that width. Reads box it back.
                int k = s->as.let.scalar_kind;
                fprintf(g->out, "%s v%d = (%s)%s(", scalar_ctype(k), id, scalar_ctype(k),
                        (k == 8 || k == 9) ? "AS_FLOAT" : "AS_INT");
                emit_expr(g, s->as.let.value);
                fputs(");\n", g->out);
            } else {
                if (sid >= 0) {
                    fprintf(g->out, "em_s%d v%d = ", sid, id);
                } else {
                    fprintf(g->out, "Value v%d = ", id);
                }
                emit_concat_operand(g, s->as.let.value);   // own a borrowed heap field (retain)
                fputs(";\n", g->out);
            }
            char cn[24];
            snprintf(cn, sizeof cn, "v%d", id);
            // A value-type struct never drops (C handles its lifetime); only a heap value
            // (string/array, future) marked drop_at_scope_end frees at scope exit.
            int drop = (sid >= 0) ? 0 : s->as.let.drop_at_scope_end;
            cgc_push(g, s->as.let.name, cn, drop, sid);
            if (sid < 0 && s->as.let.scalar_kind >= 0) {
                cgc_mark_top_scalar(g, s->as.let.scalar_kind);   // reads/writes of this name box/unbox
            }
            break;
        }
        case STMT_ASSIGN: {
            const Expr *target = s->as.assign.target;
            if (target->kind == EXPR_GET) {
                // Field mutation `o.f = v` → direct C member assignment on the receiver
                // lvalue: `<o>.f<idx> = v`. Nested write-back (`line.a.x = v`) falls out
                // for free as `line.f0.f1 = v` (C mutates the embedded struct in place).
                if (target->as.get.field_index < 0) {
                    cgc_error(g, s->line, "native backend (M2): unsupported assignment target");
                    break;
                }
                if (target->as.get.object->kind == EXPR_INDEX) {
                    // `arr[i].leaf = v` (OFI-061). Reading a struct array element (em_index) ALWAYS
                    // returns a COPY — flat or not — so a direct `…[i].fN = v` would write a
                    // temporary. Mirror the VM's writeback: set the leaf on the copy, then
                    // em_set_index it back (releases the old element, moves the copy in). This must
                    // precede the boxed/value split below, because a non-flat element struct is not
                    // an is_value_struct yet is still stored inline. Array + index are hoisted to
                    // temps so each is evaluated exactly once.
                    // All three temps use the `v%d` prefix — the function's PARAMETERS are named
                    // a0,a1,… so an `a%d` temp would shadow `self`/args and read uninitialised memory.
                    const Expr *ix = target->as.get.object;
                    int a = g->next_var++, j = g->next_var++, v = g->next_var++;
                    cgc_indent(g);
                    fprintf(g->out, "{ Value v%d = ", a);
                    emit_expr(g, ix->as.index.object);
                    fprintf(g->out, "; Value v%d = ", j);
                    emit_expr(g, ix->as.index.index);
                    fprintf(g->out, "; Value v%d = em_index(&g_em, v%d, v%d);\n", v, a, j);
                    g->indent++;
                    cgc_indent(g);
                    fprintf(g->out, "em_set_field(&g_em, v%d, %d, ", v, target->as.get.field_index);
                    emit_value_arg(g, s->as.assign.value);
                    fputs(");\n", g->out);
                    cgc_indent(g);
                    fprintf(g->out, "em_set_index(&g_em, v%d, v%d, v%d);\n", a, j, v);
                    g->indent--;
                    cgc_indent(g);
                    fputs("}\n", g->out);
                    break;
                }
                if (struct_sid_of(g, target->as.get.object) < 0) {
                    // The receiver is a BOXED struct (Config / Map / Set), so the write goes
                    // through em_set_field: it drops the overwritten boxed field first (no leak
                    // — the VM's OP_SET_FIELD) and moves the new value in. (`self.count = …`,
                    // `self.buckets = grown` inside a mut-self method.)
                    cgc_indent(g);
                    fputs("em_set_field(&g_em, ", g->out);
                    emit_expr(g, target->as.get.object);
                    fprintf(g->out, ", %d, ", target->as.get.field_index);
                    emit_value_arg(g, s->as.assign.value);
                    fputs(");\n", g->out);
                    break;
                }
                if (!is_addressable_vstruct(g, target->as.get.object)) {
                    // `boxedParent.inlineField.leaf = v` — the receiver value struct lives BOXED inside
                    // a non-flat parent, so reading it materialises a copy (em_struct_field_inline);
                    // a direct member-assign would mutate that throwaway and isn't a C lvalue (OFI-155).
                    // Mirror the VM / the arr[i].leaf writeback: find the box boundary, unbox its inline
                    // field into an addressable temp, set the leaf via the C lvalue chain on the temp,
                    // then re-box and write it back with em_set_field (which now overwrites an inline
                    // field correctly). An inline value-struct field is all-scalar, so there is exactly
                    // one box boundary in the chain and the leaf is a scalar Value.
                    const Expr *boundary = target->as.get.object;
                    while (boundary->kind == EXPR_GET &&
                           struct_sid_of(g, boundary->as.get.object) >= 0) {
                        boundary = boundary->as.get.object;
                    }
                    const Expr *parent = boundary->as.get.object;
                    if (parent->kind != EXPR_IDENT) {
                        // The boxed parent is itself a field/index read (a fresh copy or a separate
                        // writeback level) — emitting it twice would touch different objects. Fail
                        // cleanly rather than silently mutate a copy; rebuild the struct immutably.
                        cgc_error(g, s->line,
                                  "native backend (OFI-155): nested value-struct field assignment "
                                  "through a non-local boxed parent is not supported — rebuild the "
                                  "struct immutably (Node{ …, field: Inner{ … } })");
                        break;
                    }
                    int bsid   = struct_sid_of(g, boundary);
                    int bn     = g->layouts[bsid].field_count;
                    int bfield = boundary->as.get.field_index;
                    // Field-index path from the leaf down to the boundary (leaf first).
                    int path[32];
                    int np = 0;
                    for (const Expr *cur = target; cur != boundary; cur = cur->as.get.object) {
                        if (np < 32) {
                            path[np++] = cur->as.get.field_index;
                        }
                    }
                    int tv = g->next_var++;
                    int fv = g->next_var++;
                    cgc_indent(g);
                    fprintf(g->out, "{ Value v%d = em_struct_field_inline(&g_em, ", fv);
                    emit_expr(g, parent);
                    fprintf(g->out, ", %d); em_s%d v%d; em_unbox_struct(&g_em, %d, v%d, (Value*)&v%d, %d);"
                                    " drop_value(&g_em, v%d); v%d",
                            bfield, bsid, tv, bsid, fv, tv, bn, fv, tv);
                    for (int i = np - 1; i >= 0; i--) {
                        fprintf(g->out, ".f%d", path[i]);
                    }
                    fputs(" = ", g->out);
                    emit_expr(g, s->as.assign.value);   // an all-scalar leaf is a Value
                    fputs("; em_set_field(&g_em, ", g->out);
                    emit_expr(g, parent);
                    fprintf(g->out, ", %d, em_box_struct(&g_em, %d, (Value*)&v%d, %d)); }\n",
                            bfield, bsid, tv, bn);
                    break;
                }
                cgc_indent(g);
                emit_expr(g, target->as.get.object);   // the receiver lvalue chain
                fprintf(g->out, ".f%d = ", target->as.get.field_index);
                int dsid = struct_sid_of(g, target->as.get.object);
                if (dsid >= 0 && g->layouts[dsid].field_struct[target->as.get.field_index] >= 0) {
                    // The target field is itself an inline value struct, so its C slot is an `em_s`,
                    // not a `Value`: assign the RAW struct value (`o.b = In{…}`, `o.b = o.c`). Using
                    // emit_value_arg here would box the struct into a Value and clang rejects
                    // `em_s = Value` (a whole value-struct field assign on an addressable local; a
                    // sibling of the OFI-155 boxed-parent case, pre-existing).
                    emit_expr_raw(g, s->as.assign.value);
                } else {
                    emit_value_arg(g, s->as.assign.value);   // a scalar/boxed field is a Value slot
                }
                fputs(";\n", g->out);
                break;
            }
            if (target->kind == EXPR_INDEX) {
                // Element mutation `arr[i] = v` → em_set_index (bounds-checked, drops the
                // old boxed element). A slice-target assignment is deferred.
                if (target->as.index.index->kind == EXPR_RANGE) {
                    cgc_error(g, s->line, "native backend (M2): slice assignment not yet supported");
                    break;
                }
                cgc_indent(g);
                fputs("em_set_index(&g_em, ", g->out);
                emit_expr(g, target->as.index.object);
                fputs(", ", g->out);
                emit_expr(g, target->as.index.index);
                fputs(", ", g->out);
                emit_expr(g, s->as.assign.value);
                fputs(");\n", g->out);
                break;
            }
            if (target->kind != EXPR_IDENT) {
                cgc_error(g, s->line,
                          "native backend (M2): only variable, struct-field, and array-element "
                          "assignment supported");
                break;
            }
            int bi = cgc_lookup_idx(g, target->as.ident);
            if (bi < 0) {
                cgc_error(g, s->line, "native backend (M2): assignment to unbound '%s'",
                          target->as.ident);
                break;
            }
            if (g->scope[bi].scalar_kind >= 0) {
                // OFI-123: store to a width-typed scalar local — unbox the RHS Value + truncate to its
                // declared width. A scalar never owns/drops, so this precedes the value-struct / drop paths.
                int sk = g->scope[bi].scalar_kind;
                char cn[sizeof g->scope[0].cname];          // copy before emit_expr (it may realloc scope)
                snprintf(cn, sizeof cn, "%s", g->scope[bi].cname);
                cgc_indent(g);
                fprintf(g->out, "%s = (%s)%s(", cn, scalar_ctype(sk),
                        (sk == 8 || sk == 9) ? "AS_FLOAT" : "AS_INT");
                emit_expr(g, s->as.assign.value);
                fputs(");\n", g->out);
                break;
            }
            int tsid = g->scope[bi].multislot_sid;
            if (tsid >= 0 && struct_sid_of(g, s->as.assign.value) < 0) {
                // The target is a value struct (em_s) but the RHS produced a BOXED value-struct
                // (e.g. a `match` case binding bound WHOLE out of a boxed enum payload, or a
                // `Map<_,struct>` get — OFI-064). Unbox it into the em_s and drop the box, mirroring
                // the `let` coercion above. em_unbox_struct copies the fields out, so the target is
                // an independent value; an inline-eligible struct owns no heap fields in the box.
                int bv = g->next_var++;
                int rv = g->next_var++;
                cgc_indent(g);
                fprintf(g->out, "%s = ({ Value v%d = ", g->scope[bi].cname, bv);
                emit_expr(g, s->as.assign.value);
                fprintf(g->out, "; em_s%d v%d; em_unbox_struct(&g_em, %d, v%d, (Value*)&v%d, %d); "
                                "drop_value(&g_em, v%d); v%d; });\n",
                        tsid, rv, tsid, bv, rv, g->layouts[tsid].field_count, bv, rv);
                break;
            }
            if (g->scope[bi].drop) {
                // Reassigning an owned binding: evaluate the new value (which may read the
                // old one), drop the old, then store — so the replaced value can't leak.
                int t = g->next_var++;
                // Copy the cname before emit_expr below (which may grow/realloc g->scope and
                // invalidate the pointer). Size it to the FULL cname field — a smaller buffer
                // truncates the generated C identifier into a different name (a latent miscompile
                // clang never flagged; gcc -Wformat-truncation does).
                char cn[sizeof g->scope[0].cname];
                snprintf(cn, sizeof cn, "%s", g->scope[bi].cname);
                cgc_indent(g);
                fprintf(g->out, "{ Value v%d = ", t);
                emit_expr(g, s->as.assign.value);
                fputs(";\n", g->out);
                g->indent++;
                cgc_indent(g);
                fprintf(g->out, "drop_value(&g_em, %s);\n", cn);
                cgc_indent(g);
                fprintf(g->out, "%s = v%d;\n", cn, t);
                g->indent--;
                cgc_indent(g);
                fputs("}\n", g->out);
            } else {
                cgc_indent(g);
                fprintf(g->out, "%s = ", g->scope[bi].cname);
                emit_expr(g, s->as.assign.value);
                fputs(";\n", g->out);
            }
            break;
        }
        case STMT_RETURN:
            if (scope_has_drops(g, 0)) {
                // Evaluate the value into a temp, drop the function's owned locals, then
                // return it — the VM's order (a moved-out value has drop==0, so a struct
                // returned by move is not dropped here).
                int r = g->next_var++;
                cgc_indent(g);
                fprintf(g->out, "{ Value v%d = ", r);
                if (s->as.ret.value != NULL) {
                    // Own the return value: a borrowed heap field (`return c.host`) is retained
                    // so it survives the owning-local drops below.
                    emit_concat_operand(g, s->as.ret.value);
                } else {
                    fputs("INT_VAL(0)", g->out);
                }
                fputs(";\n", g->out);
                g->indent++;
                emit_drops(g, 0);
                cgc_indent(g);
                fprintf(g->out, "return v%d;\n", r);
                g->indent--;
                cgc_indent(g);
                fputs("}\n", g->out);
            } else {
                cgc_indent(g);
                fputs("return ", g->out);
                if (s->as.ret.value != NULL) {
                    emit_expr(g, s->as.ret.value);
                } else {
                    fputs("INT_VAL(0)", g->out);   // a bare `return` yields unit (0), like the VM
                }
                fputs(";\n", g->out);
            }
            break;
        case STMT_EXPR:
            cgc_indent(g);
            if (s->as.expr.release_temp) {
                // OFI-096: the discarded result is a fresh OWNING temp (a string/array/struct/enum the
                // checker flagged via release_temp) — drop it, mirroring the VM's `OP_RELEASE` (codegen.c).
                // Without this the native backend leaked it (`(void)(E)` only) — a VM≠native divergence the
                // differential test couldn't see (it compares stdout). `drop_value` is the same call
                // emit_drops uses for every owned binding, so it releases a value-struct's heap fields too.
                fputs("{ Value _dis = (", g->out);
                emit_expr(g, s->as.expr.expr);
                fputs("); drop_value(&g_em, _dis); }\n", g->out);
            } else {
                fputs("(void)(", g->out);
                emit_expr(g, s->as.expr.expr);
                fputs(");\n", g->out);
            }
            break;
        case STMT_IF:
            cgc_indent(g);
            emit_if_inline(g, s);
            fputc('\n', g->out);
            break;
        case STMT_LOOP:
            cgc_indent(g);
            fputs("for (;;) {\n", g->out);
            g->indent++;
            emit_block_scoped(g, &s->as.loop.body);
            g->indent--;
            cgc_indent(g);
            fputs("}\n", g->out);
            break;
        case STMT_FOR: {
            const Expr *iter = s->as.for_.iter;
            if (s->as.for_.index_var != NULL && iter->kind == EXPR_RANGE) {
                // `for (i, x)` iterates an array, not a range — the checker already rejects this,
                // so the guard is defensive (documents the invariant for the array branch below).
                cgc_error(g, s->line, "native backend: `for (i, x)` iterates an array, not a range");
                break;
            }
            if (iter->kind == EXPR_RANGE) {
                int lo = g->next_var++, hi = g->next_var++, ix = g->next_var++;
                cgc_indent(g);
                fputs("{\n", g->out);
                g->indent++;
                cgc_indent(g);
                fprintf(g->out, "int64_t t%d = AS_INT(", lo);
                emit_expr(g, iter->as.range.lo);
                fputs(");\n", g->out);
                cgc_indent(g);
                fprintf(g->out, "int64_t t%d = AS_INT(", hi);
                emit_expr(g, iter->as.range.hi);
                fputs(");\n", g->out);
                cgc_indent(g);
                fprintf(g->out, "for (int64_t t%d = t%d; t%d < t%d; t%d++) {\n",
                        ix, lo, ix, hi, ix);
                g->indent++;
                int vid = g->next_var++;
                cgc_indent(g);
                fprintf(g->out, "Value v%d = INT_VAL(t%d);\n", vid, ix);
                char cn[24];
                snprintf(cn, sizeof cn, "v%d", vid);
                int mark = g->scope_len;
                cgc_push(g, s->as.for_.var, cn, 0, -1);   // the loop var is a fresh scalar each pass
                for (size_t i = 0; i < s->as.for_.body.count; i++) {
                    emit_stmt(g, s->as.for_.body.stmts[i]);
                }
                emit_drops(g, mark);   // release owned locals declared in the loop body, per pass
                g->scope_len = mark;
                g->indent--;
                cgc_indent(g);
                fputs("}\n", g->out);
                g->indent--;
                cgc_indent(g);
                fputs("}\n", g->out);
                break;
            }
            // Array iteration `for x in arr`: evaluate the array once, loop over indices,
            // bind each element as a borrow (the array owns it). A fresh temporary array
            // (a literal or a call result) is dropped after the loop; a named binding /
            // field is a borrow and is not dropped here.
            int av = g->next_var++, nv = g->next_var++, ix = g->next_var++;
            cgc_indent(g);
            fputs("{\n", g->out);
            g->indent++;
            cgc_indent(g);
            fprintf(g->out, "Value v%d = ", av);
            emit_expr(g, iter);
            fputs(";\n", g->out);
            cgc_indent(g);
            fprintf(g->out, "int64_t t%d = AS_INT(em_array_len(v%d));\n", nv, av);
            cgc_indent(g);
            fprintf(g->out, "for (int64_t t%d = 0; t%d < t%d; t%d++) {\n", ix, ix, nv, ix);
            g->indent++;
            int xv = g->next_var++;
            cgc_indent(g);
            fprintf(g->out, "Value v%d = em_index(&g_em, v%d, INT_VAL(t%d));\n", xv, av, ix);
            char cn[24];
            snprintf(cn, sizeof cn, "v%d", xv);
            int mark = g->scope_len;
            // `for (i, x) in arr`: bind i to the (fresh) int loop counter each pass — a scalar
            // Value, no drop. Pushed before the element so both are in scope for the body (and
            // for a lambda that captures either).
            if (s->as.for_.index_var != NULL) {
                int iv = g->next_var++;
                cgc_indent(g);
                fprintf(g->out, "Value v%d = INT_VAL(t%d);\n", iv, ix);
                char icn[24];
                snprintf(icn, sizeof icn, "v%d", iv);
                cgc_push(g, s->as.for_.index_var, icn, 0, -1);   // fresh int index, no drop
            }
            cgc_push(g, s->as.for_.var, cn, 0, -1);   // element borrow
            for (size_t i = 0; i < s->as.for_.body.count; i++) {
                emit_stmt(g, s->as.for_.body.stmts[i]);
            }
            emit_drops(g, mark);
            g->scope_len = mark;
            g->indent--;
            cgc_indent(g);
            fputs("}\n", g->out);
            if (iter->kind == EXPR_ARRAY || iter->kind == EXPR_CALL) {
                cgc_indent(g);
                fprintf(g->out, "drop_value(&g_em, v%d);\n", av);   // a fresh temporary array
            }
            g->indent--;
            cgc_indent(g);
            fputs("}\n", g->out);
            break;
        }
        case STMT_BREAK:
            cgc_indent(g);
            fputs("break;\n", g->out);
            break;
        case STMT_CONTINUE:
            cgc_indent(g);
            fputs("continue;\n", g->out);
            break;
        case STMT_BLOCK:
            cgc_indent(g);
            fputs("{\n", g->out);
            g->indent++;
            emit_block_scoped(g, &s->as.block.body);
            g->indent--;
            cgc_indent(g);
            fputs("}\n", g->out);
            break;
        case STMT_MATCH:
            emit_match(g, s);
            break;
        case STMT_NURSERY:
            emit_nursery(g, s);
            break;
        case STMT_SPAWN:
            emit_spawn(g, s);
            break;
    }
}





// The C type of a function's RESULT: a value-type struct returns `em_s<sid>`, else the
// uniform `Value`.
static void emit_ret_type(CgcGen *g, const FnDecl *fn) {
    int sid = ret_struct_sid(g, fn);
    if (sid >= 0) {
        fprintf(g->out, "em_s%d", sid);
    } else {
        fputs("Value", g->out);
    }
}


// The C parameter list. A value-type struct param is `em_s<sid> a<i>`; a `mut self`
// receiver is `em_s<sid> *a<i>` (by pointer, so mutations reach the caller); everything
// else is the uniform `Value a<i>`. Names match the bindings registered in cgc_function.
static void emit_param_list(CgcGen *g, const FnDecl *fn, int owner_sid) {
    int wc = fn_witness_count(fn);
    if (wc == 0 && fn->param_count == 0) {
        fputs("void", g->out);
        return;
    }
    int first = 1;
    for (int w = 0; w < wc; w++) {        // hidden leading interface-witness parameters
        if (!first) {
            fputs(", ", g->out);
        }
        first = 0;
        fprintf(g->out, "Value w%d", w);
    }
    for (size_t i = 0; i < fn->param_count; i++) {
        if (!first) {
            fputs(", ", g->out);
        }
        first = 0;
        const Param *p = &fn->params[i];
        int sid = param_struct_sid(g, fn, owner_sid, (int)i);
        if (sid >= 0 && p->is_self && p->qual == OWN_MUT) {
            fprintf(g->out, "em_s%d *a%zu", sid, i);
        } else if (sid >= 0) {
            fprintf(g->out, "em_s%d a%zu", sid, i);
        } else {
            fprintf(g->out, "Value a%zu", i);
        }
    }
}





static int cgc_function(CgcGen *g, int slot, const FnDecl *fn, int owner_sid) {
    // A generic function is ERASED: its body is type-agnostic over the uniform 16-byte
    // Value, so it lowers to exactly ONE C function over `Value` — the VM's single shared
    // body, with no per-type specialization. Unbounded type parameters need nothing here;
    // a bounded one's witness is threaded at the call site (a later slice). So there is no
    // generic-function guard: a `fn id<T>(x: T) -> T` is just `Value em_fn_N(Value a0)`.
    g->scope_len = 0;
    g->next_var  = 0;
    g->indent    = 1;

    fputs("static ", g->out);
    emit_ret_type(g, fn);
    fprintf(g->out, " em_fn_%d(", slot);
    emit_param_list(g, fn, owner_sid);
    fputs(") {\n", g->out);

    for (size_t i = 0; i < fn->param_count; i++) {
        const Param *p = &fn->params[i];
        int sid = param_struct_sid(g, fn, owner_sid, (int)i);
        char cn[40];
        if (sid >= 0 && p->is_self && p->qual == OWN_MUT) {
            // `mut self` arrives as a pointer; bind the name to the dereference so field
            // reads/writes go through it (`(*a0).f<idx>`) and reach the caller's struct.
            snprintf(cn, sizeof cn, "(*a%zu)", i);
        } else {
            snprintf(cn, sizeof cn, "a%zu", i);
        }
        // A value-type struct param never drops; only a refcounted heap param does.
        int drop = (sid >= 0) ? 0 : p->release_at_exit;
        cgc_push(g, p->is_self ? "self" : p->name, cn, drop, sid);
    }

    for (size_t i = 0; i < fn->body.count; i++) {
        emit_stmt(g, fn->body.stmts[i]);
    }

    // Falling off the end is an implicit return (the VM's safety net): drop the still-
    // owned bindings, then return a zero value of the function's type. Unreachable (and
    // harmless) when the body always returns — a mid-body return ran its own drops.
    emit_drops(g, 0);
    cgc_indent(g);
    int ret_sid = ret_struct_sid(g, fn);
    if (ret_sid >= 0) {
        fprintf(g->out, "return (em_s%d){0};\n", ret_sid);
    } else {
        fputs("return INT_VAL(0);\n", g->out);
    }
    fputs("}\n\n", g->out);
    return g->had_error;
}





// A layout is "flat" when it embeds no inline-struct field — its C typedef is then just
// `field_count` uniform Value members, so two flat layouts with the same field count are the
// identical C type.
static int layout_is_flat(const StructLayout *L) {
    for (int f = 0; f < L->field_count; f++) {
        if (L->field_struct[f] >= 0) {
            return 0;
        }
    }
    return 1;
}


// Emit the C typedef for struct `sid` (and, first, any struct it embeds by value, so a
// nested field's type is already defined). `done` guards against re-emitting. A field is
// `em_s<nsid>` for an inline nested struct, else the uniform `Value`. `declared` is the count
// of source-declared structs; ids beyond it are monomorphized instances.
static void emit_one_typedef(FILE *out, const StructLayout *layouts, int n, int declared,
                             int sid, char *done) {
    if (sid < 0 || sid >= n || done[sid]) {
        return;
    }
    const StructLayout *L = &layouts[sid];
    for (int f = 0; f < L->field_count; f++) {
        if (L->field_struct[f] >= 0) {
            emit_one_typedef(out, layouts, n, declared, L->field_struct[f], done);
        }
    }
    done[sid] = 1;
    // A monomorphized INSTANCE of a generic struct (Set<int> vs Set<string>) is erased — every
    // instance shares its BASE struct's flat {N × Value} layout. Alias the instance to its base
    // so they become ONE C type; then the single erased method (compiled against the base) type-
    // checks for every instance. Aliasing to the *base* (not just any same-shape struct) keeps
    // distinct generics apart even when their layouts coincide (e.g. Set and Map are both four
    // Value fields). Declared structs keep their own typedef.
    if (sid >= declared && layout_is_flat(L)) {
        int base = layouts[sid].base_id;
        if (base >= 0 && base < sid && done[base] && layout_is_flat(&layouts[base]) &&
            layouts[base].field_count == L->field_count) {
            fprintf(out, "typedef em_s%d em_s%d;\n\n", base, sid);
            return;
        }
    }
    fputs("typedef struct {\n", out);
    for (int f = 0; f < L->field_count; f++) {
        if (L->field_struct[f] >= 0) {
            fprintf(out, "    em_s%d f%d;\n", L->field_struct[f], f);
        } else {
            fprintf(out, "    Value f%d;\n", f);
        }
    }
    if (L->field_count == 0) {
        fputs("    Value _unit;\n", out);   // C forbids an empty struct
    }
    fprintf(out, "} em_s%d;\n\n", sid);
}


// Emit every struct typedef, nested ones first (topological by value-embedding).
static void emit_struct_typedefs(FILE *out, const StructLayout *layouts, int n, int declared) {
    if (n <= 0) {
        return;
    }
    char *done = calloc((size_t)n, 1);
    if (done == NULL) {
        fprintf(stderr, "emberc: out of memory\n");
        exit(70);
    }
    for (int sid = 0; sid < n; sid++) {
        emit_one_typedef(out, layouts, n, declared, sid, done);
    }
    free(done);
}


int cgen_c_program(const Program *ast, const ModuleSet *modules,
                   const MonoPlan *plan, const StructLayout *layouts,
                   int layout_count, FILE *out, const char *source_name,
                   int *out_concurrency) {
    (void)modules;

    // The function table is numbered exactly as codegen_program numbers it — free
    // functions and struct methods in declaration order — so the checker's
    // resolved_fn indices line up with our em_fn_<slot> names.
    int total_functions = 0;
    for (size_t i = 0; i < ast->count; i++) {
        const Decl *d = ast->decls[i];
        if (d->kind == DECL_FN) {
            total_functions++;
        } else if (d->kind == DECL_STRUCT) {
            total_functions += (int)d->as.struct_.method_count;
        }
    }
    if (total_functions == 0) {
        fprintf(stderr, "%s: error: program has no functions\n", source_name);
        return 1;
    }
    // No monomorphization gate: generics are ERASED, so each generic base function is
    // emitted once (over `Value`) and every instantiation's call routes to that one slot
    // via the call's `resolved_fn`. The instance slots the plan appends beyond
    // `total_functions` are never emitted or referenced (they would be byte-identical
    // bodies). `plan` is still consulted for `main_index`.
    if (plan->main_index < 0) {
        fprintf(stderr, "%s: error: no 'main' function to run\n", source_name);
        return 1;
    }

    const FnDecl **fn_by_fi      = malloc((size_t)total_functions * sizeof *fn_by_fi);
    int          *fn_owner_sid   = malloc((size_t)total_functions * sizeof *fn_owner_sid);
    // A method's owning struct's generic params (NULL for a free fn) — so the cgen can tell that a
    // type name like Box<T>'s `T` is an erased param, not a same-named user struct (OFI-053).
    const GenericParam **owner_generics    = malloc((size_t)total_functions * sizeof *owner_generics);
    int                 *owner_generic_ct  = malloc((size_t)total_functions * sizeof *owner_generic_ct);
    if (fn_by_fi == NULL || fn_owner_sid == NULL ||
        owner_generics == NULL || owner_generic_ct == NULL) {
        fprintf(stderr, "emberc: out of memory\n");
        exit(70);
    }
    int fi = 0, si = 0;
    for (size_t i = 0; i < ast->count; i++) {
        const Decl *d = ast->decls[i];
        if (d->kind == DECL_FN) {
            fn_by_fi[fi]    = &d->as.fn;
            fn_owner_sid[fi] = -1;
            owner_generics[fi]   = NULL;   // a free fn's own generics are read off its FnDecl
            owner_generic_ct[fi] = 0;
            fi++;
        } else if (d->kind == DECL_STRUCT) {
            for (size_t m = 0; m < d->as.struct_.method_count; m++) {
                fn_by_fi[fi]    = &d->as.struct_.methods[m];
                fn_owner_sid[fi] = si;   // the method's owning struct id (for self typing)
                owner_generics[fi]   = d->as.struct_.generics;
                owner_generic_ct[fi] = (int)d->as.struct_.generic_count;
                fi++;
            }
            si++;
        }
    }

    // Struct field-name tables: declared names per type id (for struct-literal field
    // ordering); a monomorphized instance id reuses its base struct's names.
    int declared_structs = 0;
    for (size_t i = 0; i < ast->count; i++) {
        if (ast->decls[i]->kind == DECL_STRUCT) {
            declared_structs++;
        }
    }
    CgcStructNames *snames = NULL;
    if (layout_count > 0) {
        snames = calloc((size_t)layout_count, sizeof *snames);
        if (snames == NULL) {
            fprintf(stderr, "emberc: out of memory\n");
            exit(70);
        }
        int sid = 0;
        for (size_t i = 0; i < ast->count; i++) {
            const Decl *d = ast->decls[i];
            if (d->kind != DECL_STRUCT) {
                continue;
            }
            int nf = (int)d->as.struct_.field_count;
            snames[sid].sname = d->as.struct_.name;
            snames[sid].field_count = nf;
            snames[sid].names = malloc((size_t)(nf > 0 ? nf : 1) * sizeof(const char *));
            if (snames[sid].names == NULL) {
                fprintf(stderr, "emberc: out of memory\n");
                exit(70);
            }
            for (int f = 0; f < nf; f++) {
                snames[sid].names[f] = d->as.struct_.fields[f].name;
            }
            sid++;
        }
        for (int s = declared_structs; s < layout_count; s++) {
            snames[s] = snames[layouts[s].base_id];     // instance reuses the base's names
        }
    }

    // Enum variant table (name -> enum id, tag, field count), in DECL_ENUM order — the
    // same `enum_id` the VM's OP_NEW_ENUM uses.
    int total_variants = 0;
    for (size_t i = 0; i < ast->count; i++) {
        if (ast->decls[i]->kind == DECL_ENUM) {
            total_variants += (int)ast->decls[i]->as.enum_.variant_count;
        }
    }
    CgcVariant *cg_variants = NULL;
    if (total_variants > 0) {
        cg_variants = malloc((size_t)total_variants * sizeof *cg_variants);
        if (cg_variants == NULL) {
            fprintf(stderr, "emberc: out of memory\n");
            exit(70);
        }
        int ei = 0, vix = 0;
        for (size_t i = 0; i < ast->count; i++) {
            const Decl *d = ast->decls[i];
            if (d->kind != DECL_ENUM) {
                continue;
            }
            for (size_t v = 0; v < d->as.enum_.variant_count; v++) {
                cg_variants[vix].name          = d->as.enum_.variants[v].name;
                cg_variants[vix].enum_id       = ei;
                cg_variants[vix].variant_index = (int)v;
                cg_variants[vix].field_count   = (int)d->as.enum_.variants[v].field_count;
                vix++;
            }
            ei++;
        }
    }

    fprintf(out, "// Generated by `emberc --emit=c` from %s. Do not edit.\n", source_name);
    fprintf(out, "// The bytecode VM is the reference semantics; tests/native diffs the two.\n");
    fputs("#include \"ember_rt.h\"\n\n", out);

    // Value-type structs become real C structs (value semantics, no heap), emitted
    // nested-first so an embedded field's type is defined before its use.
    emit_struct_typedefs(out, layouts, layout_count, declared_structs);

    // The struct-layout table the runtime reads via g_em.structs — a packed StructType
    // per type id, baked in so a standalone binary needs no CompiledProgram — followed by
    // the one process-wide runtime context.
    if (layout_count > 0) {
        // StructType's per-field layout is now POINTER-sized (no field-count cap), so emit one int
        // array per struct (offset/kind/field_struct) and point the table entries at them, rather
        // than brace-initialising fixed inline arrays. A 0-field struct points at NULL (never read).
        for (int s = 0; s < layout_count; s++) {
            const StructLayout *L = &layouts[s];
            if (L->field_count == 0) {
                continue;
            }
            const char *suf[3] = { "off", "knd", "fst" };
            for (int a = 0; a < 3; a++) {
                fprintf(out, "static int em_s%d_%s[] = {", s, suf[a]);
                for (int f = 0; f < L->field_count; f++) {
                    int v = a == 0 ? L->offset[f] : (a == 1 ? L->kind[f] : L->field_struct[f]);
                    fprintf(out, "%s%d", f ? ", " : "", v);
                }
                fputs("};\n", out);
            }
        }
        // DESIGNATED initializers (OFI-106): naming each field means a new StructType field (in
        // include/program.h) can never silently MISALIGN the emitted table — an omitted field just
        // zero-inits. Do NOT collapse this back to a positional `{ 0, fc, ... }`. `.name` is unused at
        // runtime (omitted → NULL); a field_count==0 struct omits the per-field pointers (→ NULL).
        fprintf(out, "static const StructType em_structs[%d] = {\n", layout_count);
        for (int s = 0; s < layout_count; s++) {
            const StructLayout *L = &layouts[s];
            if (L->field_count > 0) {
                fprintf(out, "    { .field_count = %d, .total_size = %d, .is_rc = %d, .is_resource = %d, .drop_fn = %d,"
                             " .offset = em_s%d_off, .kind = em_s%d_knd, .field_struct = em_s%d_fst },\n",
                        L->field_count, L->total_size, L->is_rc, L->is_resource, L->drop_fn, s, s, s);
            } else {
                fprintf(out, "    { .field_count = %d, .total_size = %d, .is_rc = %d, .is_resource = %d, .drop_fn = %d },\n",
                        L->field_count, L->total_size, L->is_rc, L->is_resource, L->drop_fn);
            }
        }
        fputs("};\n", out);
    }
    // A concurrent program (spawn/nursery) runs each task on its own thread, so the runtime
    // context is THREAD-LOCAL — each worker allocs into its own lock-free arena (shared values
    // are atomic-refcounted under EMBER_PARALLEL, which the parallel build enables). A serial
    // program keeps the single static context (no thread-local cost).
    int concurrent = program_uses_concurrency(ast);
    if (out_concurrency != NULL) {
        *out_concurrency = concurrent;
    }
    fputs(concurrent ? "_Thread_local EmberRt g_em;\n\n" : "static EmberRt g_em;\n\n", out);

    // OFI-167: collect the DIRECT externs (extern "c" fns not in the hosted FFI registry) from the
    // AST's extern blocks, so the preamble can forward-declare each and calls emit a direct C call.
    int direct_extern_count = 0;
    for (size_t i = 0; i < ast->count; i++) {
        const Decl *d = ast->decls[i];
        if (d->kind != DECL_EXTERN) {
            continue;
        }
        for (size_t k = 0; k < d->as.extern_.fn_count; k++) {
            if (cextern_lookup(d->as.extern_.fns[k].name) < 0) {
                direct_extern_count++;
            }
        }
    }
    const FnDecl **direct_externs = NULL;
    if (direct_extern_count > 0) {
        direct_externs = malloc((size_t)direct_extern_count * sizeof *direct_externs);
        if (direct_externs == NULL) {
            fprintf(stderr, "emberc: out of memory\n");
            exit(70);
        }
        int di = 0;
        for (size_t i = 0; i < ast->count; i++) {
            const Decl *d = ast->decls[i];
            if (d->kind != DECL_EXTERN) {
                continue;
            }
            for (size_t k = 0; k < d->as.extern_.fn_count; k++) {
                if (cextern_lookup(d->as.extern_.fns[k].name) < 0) {
                    direct_externs[di++] = &d->as.extern_.fns[k];
                }
            }
        }
    }

    CgcGen g;
    g.out             = out;
    g.src_name        = source_name;
    g.had_error       = 0;
    g.indent          = 0;
    g.next_var        = 0;
    g.scope_len       = 0;
    g.scope_cap       = 0;
    g.scope           = NULL;
    g.layouts         = layouts;
    g.struct_count    = layout_count;
    g.snames          = snames;
    g.fn_by_fi             = fn_by_fi;
    g.total_functions      = total_functions;
    g.owner_generics       = owner_generics;
    g.owner_generic_count  = owner_generic_ct;
    g.variants        = cg_variants;
    g.variant_count   = total_variants;
    g.concurrent      = concurrent;
    g.nursery_depth   = 0;
    g.direct_externs      = direct_externs;
    g.direct_extern_count = direct_extern_count;

    // OFI-167: forward-declare each direct extern with its EXACT C signature, so the emitted calls
    // link against the freestanding shim (or any C TU) that defines the symbol. `-Werror` requires a
    // prototype; matching the shim's definition byte-for-byte keeps the ABI well-defined (no UB).
    for (int i = 0; i < direct_extern_count; i++) {
        const FnDecl *fx  = direct_externs[i];
        const char   *crt = ember_ctype_of(fx->return_type);
        if (crt == NULL) {
            cgc_error(&g, fx->line,
                      "direct extern '%s' has an unsupported return type (scalar or Ptr only)",
                      fx->name);
            crt = "void";
        }
        fprintf(out, "extern %s %s(", crt, fx->name);
        if (fx->param_count == 0) {
            fputs("void", out);
        } else {
            for (size_t p = 0; p < fx->param_count; p++) {
                if (p > 0) { fputs(", ", out); }
                const char *cpt = ember_ctype_of(fx->params[p].type);
                if (cpt == NULL) {
                    cgc_error(&g, fx->line,
                              "direct extern '%s' parameter %zu has an unsupported type "
                              "(scalar or Ptr only)", fx->name, p + 1);
                    cpt = "int64_t";
                }
                fputs(cpt, out);
            }
        }
        fputs(");\n", out);
    }
    if (direct_extern_count > 0) {
        fputc('\n', out);
    }

    for (int s = 0; s < total_functions; s++) {
        fputs("static ", out);
        emit_ret_type(&g, fn_by_fi[s]);
        fprintf(out, " em_fn_%d(", s);
        emit_param_list(&g, fn_by_fi[s], fn_owner_sid[s]);
        fputs(");\n", out);
    }
    fputc('\n', out);

    // The uniform indirect-dispatch trampoline for closures, function values, dynamic
    // (interface) method calls, and bounded-generic method calls: given a function-table
    // index and a [receiver/captures…, args…] slot buffer, it calls the concrete em_fn_<k>.
    // A `Value` parameter is passed straight through; a flat value-struct parameter (e.g. an
    // interface receiver) is UNBOXED from its slot first, and a flat value-struct result is
    // BOXED — the value-struct<->boxed bridge that lets struct-typed methods be reached
    // through a witness/vtable that only carries Values. A function with a non-flat struct or
    // a `mut self` (by-pointer) signature gets no case (not reachable indirectly yet).
    // Non-static so a program that never references it does not trip -Wunused-function.
    fputs("Value em_invoke(EmberRt *ctx, int fn_index, Value *slots) {\n", out);
    fputs("    (void)ctx; (void)slots;\n", out);
    fputs("    switch (fn_index) {\n", out);
    for (int s = 0; s < total_functions; s++) {
        const FnDecl *f = fn_by_fi[s];
        // A bounded-generic function takes `wc` hidden interface WITNESSES as its leading params.
        // Normally it is called directly (synchronous bounded call), but a SPAWN dispatches it
        // through this trampoline, so it gets a witnessed case: the witnesses occupy slots[0..wc-1]
        // (passed straight through), the real params follow at slots[wc + i]. em_box_struct/
        // em_unbox_struct are recursive, so a NON-FLAT struct param/return is fine (OFI-054). Only
        // a `mut self` (by-pointer) signature stays unreachable indirectly — em_invoke dispatches
        // on an unboxed COPY, so mutations wouldn't reach the original.
        int wc = fn_witness_count(f);
        int rsid = ret_struct_sid(&g, f);
        int ok = 1;
        for (size_t i = 0; ok && i < f->param_count; i++) {
            int psid = param_struct_sid(&g, f, fn_owner_sid[s], (int)i);
            const Param *p = &f->params[i];
            if (psid >= 0 && p->is_self && p->qual == OWN_MUT) {
                ok = 0;
            }
        }
        if (!ok) {
            continue;
        }
        fprintf(out, "        case %d: {\n", s);
        for (size_t i = 0; i < f->param_count; i++) {
            int psid = param_struct_sid(&g, f, fn_owner_sid[s], (int)i);
            if (psid >= 0) {
                fprintf(out, "            em_s%d p%zu; em_unbox_struct(ctx, %d, slots[%d], "
                             "(Value*)&p%zu, %d);\n",
                        psid, i, psid, wc + (int)i, i, g.layouts[psid].field_count);
            }
        }
        if (rsid >= 0) {
            fprintf(out, "            em_s%d r = em_fn_%d(", rsid, s);
        } else {
            fprintf(out, "            Value _r = em_fn_%d(", s);
        }
        int wfirst = 1;
        for (int w = 0; w < wc; w++) {
            fprintf(out, "%sslots[%d]", wfirst ? "" : ", ", w);   // witnesses pass straight through
            wfirst = 0;
        }
        for (size_t i = 0; i < f->param_count; i++) {
            int psid = param_struct_sid(&g, f, fn_owner_sid[s], (int)i);
            if (!wfirst) {
                fputs(", ", out);
            }
            wfirst = 0;
            if (psid >= 0) {
                fprintf(out, "p%zu", i);
            } else {
                fprintf(out, "slots[%d]", wc + (int)i);
            }
        }
        fputs(");\n", out);
        // A spawned bounded generic OWNS its witness records (the fiber, not the caller, drops
        // them — the synchronous path drops at its own call site); mirror that here. wc == 0 for
        // every closure/dyn/bound target, so this is a no-op for them.
        for (int w = 0; w < wc; w++) {
            fprintf(out, "            drop_value(ctx, slots[%d]);\n", w);
        }
        if (rsid >= 0) {
            fprintf(out, "            return em_box_struct(ctx, %d, (Value*)&r, %d);\n",
                    rsid, g.layouts[rsid].field_count);
        } else {
            fputs("            return _r;\n", out);
        }
        fputs("        }\n", out);
    }
    fputs("        default: break;\n", out);
    fputs("    }\n", out);
    fputs("    em_panic(\"em_invoke: not a callable function\");\n", out);
    fputs("    return INT_VAL(0);\n", out);
    fputs("}\n\n", out);

    // The per-task thread trampoline (M4): set up this worker's thread-local context, run the
    // spawned function through em_invoke, then merge its arena into the shared graveyard.
    if (concurrent) {
        fputs("static void *em_task_main(void *p) {\n", out);
        fputs("    EmTask *t = (EmTask *)p;\n", out);
        fprintf(out, "    g_em.structs = %s;\n", layout_count > 0 ? "em_structs" : "0");
        fprintf(out, "    g_em.struct_count = %d;\n", layout_count);
        fputs("    g_em.invoke = em_invoke;\n", out);   // OFI-122: lets drop_value run a resource's drop
        fputs("    em_cur_nursery = t->nursery;\n", out);
        fputs("    em_cur_slot = t->slot;\n", out);
        fputs("    (void)em_invoke(&g_em, t->fn_index, t->args);\n", out);
        fputs("    em_merge(&g_em);\n", out);
        fputs("    return NULL;\n", out);
        fputs("}\n\n", out);
    }

    for (int s = 0; s < total_functions; s++) {
        cgc_function(&g, s, fn_by_fi[s], fn_owner_sid[s]);
        if (g.had_error) {
            break;
        }
    }

    if (!g.had_error) {
        // The entry shim seeds the runtime's struct-layout table, runs main, prints the
        // result exactly as emit_run does (src/main.c), then sweeps the heap at exit.
        const FnDecl *mainfn = fn_by_fi[plan->main_index];
        fprintf(out, "int main(int argc, char **argv) {\n");
        // args() = the args AFTER the program name, matching the VM (which returns everything
        // after the .em source file). So skip argv[0], the binary's own name.
        fprintf(out, "    em_argc = argc - 1; em_argv = argv + 1;\n");
        fprintf(out, "    g_em.structs = %s;\n", layout_count > 0 ? "em_structs" : "0");
        fprintf(out, "    g_em.struct_count = %d;\n", layout_count);
        fputs("    g_em.invoke = em_invoke;\n", out);   // OFI-122: lets drop_value run a resource's drop
        if (mainfn->ret_struct_id >= 0) {
            // main returns a value-type struct: the VM prints `=> <obj>` for it.
            fprintf(out, "    em_s%d r = em_fn_%d();\n", mainfn->ret_struct_id, plan->main_index);
            fprintf(out, "    (void)r;\n");
            fprintf(out, "    printf(\"=> <obj>\\n\");\n");
        } else {
            fprintf(out, "    Value r = em_fn_%d();\n", plan->main_index);
            fprintf(out, "    if (IS_INT(r)) printf(\"=> %%lld\\n\", (long long)AS_INT(r));\n");
            fprintf(out, "    else if (IS_FLOAT(r)) printf(\"=> %%g\\n\", AS_FLOAT(r));\n");
            fprintf(out, "    else if (IS_STRING(r)) printf(\"=> %%s\\n\", AS_CSTRING(r));\n");
            fprintf(out, "    else printf(\"=> <obj>\\n\");\n");
        }
        fprintf(out, "    rt_free_objects(&g_em);\n");
        if (concurrent) {
            fprintf(out, "    em_free_graveyard();\n");   // free finished workers' merged arenas
        }
        fprintf(out, "    return 0;\n");
        fprintf(out, "}\n");
    }

    if (snames != NULL) {
        for (int s = 0; s < declared_structs; s++) {
            free(snames[s].names);   // instances alias a base's array, so only declared structs free
        }
        free(snames);
    }
    free(cg_variants);
    free(fn_by_fi);
    free(fn_owner_sid);
    free(owner_generics);
    free(owner_generic_ct);
    free(direct_externs);   // OFI-167
    free(g.scope);
    return g.had_error;
}