#include "codegen.h"
#include "opcode.h"
#include "token.h"
#include "builtin.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_LOOP_DEPTH 64
#define MAX_BREAKS     64

// One active loop's codegen state: where `continue` jumps back to, and the
// list of `break` jump operands awaiting patching to the loop's exit.
typedef struct {
    size_t start;
    int    locals_at_entry;   // local count when the loop began (break/continue pop down to this)
    int    breaks[MAX_BREAKS];
    int    break_count;
} LoopCtx;

// A struct type's compile-time layout: its name and field names in declared
// order. The index in the table is the runtime struct-type id. Field names let
// codegen place struct-literal fields in declared order regardless of source order.
typedef struct {
    const char *name;
    const char **field_names;   // dynamic, sized to field_count (no cap); malloc'd per struct in
                                // codegen_program and freed via free_cg_structs
    int         field_count;
} CgStruct;

#define MAX_MATCH_CASES 64

// An enum variant's compile-time descriptor, resolved by its (globally unique)
// name. `enum_id` is the OP_NEW_ENUM type id; `variant_index` is the tag.
typedef struct {
    const char *name;
    int         enum_id;
    int         variant_index;
    int         field_count;
} CgVariant;

typedef struct {
    Chunk                 *chunk;
    const char            *src;
    int                    had_error;
    const CompiledProgram *prog;        // function table, for resolving calls by name
    const CgStruct        *structs;     // struct layouts, for construction/field order
    int                    struct_count;
    const CgVariant       *variants;    // enum variants, for construction/match
    int                    variant_count;
    // Locals occupy fixed stack slots from the frame base, in declaration order
    // (parameters first, then the body's bindings). The checker has already
    // validated scoping; codegen only assigns and resolves slots.
    const char **locals;      // dynamic; grown on demand (no per-function cap — slots are OPK_IDX)
    int          locals_cap;  // allocated capacity of the parallel local_* vectors
    // Per-slot: does this binding own a struct to free when it leaves scope? Set
    // from the checker's `drop_at_scope_end` for `let`s, 0 for every other local
    // (params, match/for temporaries). Read at scope exits to emit OP_DROP.
    int        *local_drop;
    int         local_count;
    // Logical→physical slot map (value-types 3b). A binding occupies `local_span`
    // consecutive physical stack slots starting at `local_phys` — one slot for a
    // scalar/boxed value, more for a multi-slot struct value (its fields). With every
    // span == 1 (today) the physical slot equals the logical index, so this is
    // behaviour-preserving; multi-slot structs make them diverge. `phys_count` is the
    // total physical slots in use (the next free slot).
    int        *local_phys;
    int        *local_span;
    int        *local_struct;              // struct type id if this binding is a multi-slot
                                           // struct value (its fields exploded); -1 if not
    int         phys_count;
    int         ret_struct_id;  // value-types 3b.4b: struct id if the current function
                                // RETURNS an all-scalar struct MULTI-SLOT, else -1
    int         current_line;   // source line of the node currently being lowered
    LoopCtx     loops[MAX_LOOP_DEPTH];
    int         loop_depth;
    const MonoPlan *plan;       // monomorphization plan: resolves generic calls
    int             cur_slot;   // the function-table slot being compiled
    // The current function's postconditions (MANIFESTO §5e), emitted at every return
    // with `result` bound to the return value. fn_name labels the violation message.
    const char     *fn_name;
    Expr          **ensures_clauses;
    size_t          ensures_count;
} Codegen;

// internal_error reports a violated invariant: codegen received something the
// checker should already have rejected. It is not a user error, so it names the
// stage — if one ever fires, the checker and codegen have fallen out of step.
// Build profile (see codegen.h). 0 = debug (emit contract checks), 1 = release
// (elide them). The driver sets it before compiling; defaults to debug.
int codegen_release_profile = 0;

static void internal_error(Codegen *cg, const char *what) {
    fprintf(stderr, "%s: internal error: codegen reached %s "
                    "(should have been rejected by the checker)\n",
            cg->src, what);
    cg->had_error = 1;
}





static void emit(Codegen *cg, uint8_t byte) {
    chunk_write(cg->chunk, byte, cg->current_line);
}





// emit_jump writes a jump opcode followed by a two-byte placeholder operand and
// returns the operand's position, to be filled in later by patch_jump once the
// destination is known (forward jumps are backpatched).
static int emit_jump(Codegen *cg, uint8_t op) {
    emit(cg, op);
    emit(cg, 0xff);
    emit(cg, 0xff);
    return (int)(cg->chunk->code_len - 2);
}





// patch_jump writes the distance from just after a jump's operand to the current
// end of code into the placeholder left by emit_jump.
static void patch_jump(Codegen *cg, int operand_pos) {
    size_t dist = cg->chunk->code_len - (size_t)operand_pos - 2;
    if (dist > 0xffff) {
        fprintf(stderr, "%s: error: jump distance too large for this slice\n",
                cg->src);
        cg->had_error = 1;
        return;
    }
    cg->chunk->code[operand_pos]     = (uint8_t)((dist >> 8) & 0xff);
    cg->chunk->code[operand_pos + 1] = (uint8_t)(dist & 0xff);
}





// emit_loop writes an OP_LOOP whose operand is the backward distance from just
// after the operand to `loop_start` — so the VM lands back at the loop top.
static void emit_loop(Codegen *cg, size_t loop_start) {
    emit(cg, OP_LOOP);
    size_t dist = cg->chunk->code_len - loop_start + 2;
    if (dist > 0xffff) {
        fprintf(stderr, "%s: error: loop body too large for this slice\n",
                cg->src);
        cg->had_error = 1;
        return;
    }
    emit(cg, (uint8_t)((dist >> 8) & 0xff));
    emit(cg, (uint8_t)(dist & 0xff));
}





// cg_ensure_locals_cap grows the parallel local_* vectors to hold at least `need` bindings.
// There is no per-function cap (the slot operands are LEB128 OPK_IDX and cannot overflow); the
// vectors realloc on demand and are freed when the function finishes compiling.
static void cg_ensure_locals_cap(Codegen *cg, int need) {
    if (need <= cg->locals_cap) {
        return;
    }
    int cap = cg->locals_cap ? cg->locals_cap * 2 : 64;
    while (cap < need) {
        cap *= 2;
    }
    cg->locals       = realloc(cg->locals,       (size_t)cap * sizeof(*cg->locals));
    cg->local_drop   = realloc(cg->local_drop,   (size_t)cap * sizeof(*cg->local_drop));
    cg->local_phys   = realloc(cg->local_phys,   (size_t)cap * sizeof(*cg->local_phys));
    cg->local_span   = realloc(cg->local_span,   (size_t)cap * sizeof(*cg->local_span));
    cg->local_struct = realloc(cg->local_struct, (size_t)cap * sizeof(*cg->local_struct));
    if (cg->locals == NULL || cg->local_drop == NULL || cg->local_phys == NULL ||
        cg->local_span == NULL || cg->local_struct == NULL) {
        fprintf(stderr, "emberc: out of memory growing the codegen locals table\n");
        exit(70);
    }
    cg->locals_cap = cap;
}


// cg_declare registers a binding `name` occupying `span` physical slots (drop = does it
// own a struct/refcounted value to free at scope exit). Returns its physical base slot.
// All declaration sites go through this so the logical→physical slot map stays correct.
static int cg_declare(Codegen *cg, const char *name, int drop, int span) {
    cg_ensure_locals_cap(cg, cg->local_count + 1);
    int base = cg->phys_count;
    cg->locals[cg->local_count]      = name;
    cg->local_drop[cg->local_count]  = drop;
    cg->local_phys[cg->local_count]  = base;
    cg->local_span[cg->local_count]  = span;
    cg->local_struct[cg->local_count] = -1;   // set by the caller for a multi-slot struct
    cg->local_count++;
    cg->phys_count += span;
    return base;
}


// resolve_local_logical returns the LOGICAL index of a name (for local_phys/span/struct
// lookups), innermost-first; -1 if not a local. (resolve_local returns the physical slot.)
static int resolve_local_logical(Codegen *cg, const char *name) {
    for (int i = cg->local_count - 1; i >= 0; i--) {
        if (strcmp(cg->locals[i], name) == 0) {
            return i;
        }
    }
    return -1;
}


// cg_unwind discards every binding from logical index `from` upward, restoring the
// physical slot count to where `from` began. Use at scope exits / save-restore points.
static void cg_unwind(Codegen *cg, int from) {
    cg->phys_count = (from > 0) ? cg->local_phys[from - 1] + cg->local_span[from - 1]
                                : 0;
    cg->local_count = from;
}


// resolve_local returns the physical base slot for a name, searching innermost-first so
// a shadowing binding wins. The checker guarantees the name resolves, so -1 here
// is an internal invariant break.
static int resolve_local(Codegen *cg, const char *name) {
    for (int i = cg->local_count - 1; i >= 0; i--) {
        if (strcmp(cg->locals[i], name) == 0) {
            return cg->local_phys[i];
        }
    }
    return -1;
}






// resolve_cgvariant returns an enum variant's descriptor by name, or NULL.
static const CgVariant *resolve_cgvariant(Codegen *cg, const char *name) {
    for (int i = 0; i < cg->variant_count; i++) {
        if (strcmp(cg->variants[i].name, name) == 0) {
            return &cg->variants[i];
        }
    }
    return NULL;
}





static void emit_idx(Codegen *cg, size_t value);   // defined below; the cap-free operand primitive

// emit_fn_index appends a callee's whole-program function-table index (OP_CALL / OP_SPAWN /
// OP_MAKE_CLOSURE fn slot) as an unbounded LEB128 OPK_IDX operand. The table holds free functions
// AND every struct method plus lifted lambdas, which together once overflowed the one-byte index and
// dispatched to the WRONG function (OFI-007); LEB128 can't overflow, so the ceiling — and the old
// fixed-width overflow guard — are gone. (Kept as a named wrapper so call sites still read as "a
// function index".)
static void emit_fn_index(Codegen *cg, int idx) {
    emit_idx(cg, (size_t)idx);
}






// emit_u8_id appends a type/variant/function id (OP_NEW_STRUCT struct id, OP_NEW_ENUM enum id,
// closure fn index, recv/parse_int Option enum id) as an unbounded LEB128 OPK_IDX operand. Several of
// these id spaces are SUMS of separately-capped pools (struct ids = base structs + monomorphized
// generic instances; closure fn ids = the function table + lifted lambdas), so an id could exceed 255
// and wrap a one-byte operand into the WRONG type/closure (OFI-047). LEB128 removes that ceiling;
// `what` is retained only for call-site self-documentation now that there is no overflow message.
static void emit_u8_id(Codegen *cg, int id, const char *what) {
    (void)what;
    emit_idx(cg, (size_t)id);
}






// emit_idx appends an unsigned LEB128 index/count/slot/id operand (OPK_IDX) through the shared
// codec, so the encoding can never disagree with what the VM and disassembler decode (proved by
// `make opcheck`). It is unbounded — a value as small as it needs to be, never an overflow — which
// is what lets the pools, slots, ids and counts have NO per-function/per-program ceiling (the
// modern replacement for the OFI-007/047/056 fixed-width guards and the OP_CONST_LONG hack).
static void emit_idx(Codegen *cg, size_t value) {
    uint8_t buf[10];
    uint8_t *p = buf;
    operand_write(&p, OPK_IDX, (uint32_t)value);
    for (uint8_t *b = buf; b < p; b++) {
        emit(cg, *b);
    }
}


// emit_constant adds a value to the constant pool and emits the load (OP_CONST + a LEB128 index).
static void emit_constant(Codegen *cg, Value value) {
    emit(cg, OP_CONST);
    emit_idx(cg, chunk_add_const(cg->chunk, value));
}





// emit_const is the integer convenience wrapper (used for literals and the
// fall-through `return 0`).
static void emit_const(Codegen *cg, int64_t value) {
    emit_constant(cg, INT_VAL(value));
}





// emit_binop maps a non-short-circuiting binary operator to its opcode. Logical
// && / || are not here — they compile to jumps (see gen_expr). The checker has
// already validated operand types, so an unexpected operator is an internal
// error. The default arm stays because TokenType is far wider than these.
// The arithmetic opcodes carry a numeric-kind byte (the checker's int_kind) so the
// VM range-checks at the operand width; comparisons need no width (signed-int64
// order is correct for every supported width).
static void emit_binop(Codegen *cg, TokenType op, int num_kind) {
    switch (op) {
        case TOK_PLUS:    emit(cg, OP_ADD); emit(cg, (uint8_t)num_kind); break;
        case TOK_MINUS:   emit(cg, OP_SUB); emit(cg, (uint8_t)num_kind); break;
        case TOK_STAR:    emit(cg, OP_MUL); emit(cg, (uint8_t)num_kind); break;
        case TOK_SLASH:   emit(cg, OP_DIV); emit(cg, (uint8_t)num_kind); break;
        case TOK_PERCENT: emit(cg, OP_MOD); emit(cg, (uint8_t)num_kind); break;
        case TOK_EQ:      emit(cg, OP_EQ);  break;   // equality is bit-compare:
        case TOK_NEQ:     emit(cg, OP_NEQ); break;   // no width needed
        case TOK_LT:      emit(cg, OP_LT);  emit(cg, (uint8_t)num_kind); break;
        case TOK_LE:      emit(cg, OP_LE);  emit(cg, (uint8_t)num_kind); break;
        case TOK_GT:      emit(cg, OP_GT);  emit(cg, (uint8_t)num_kind); break;
        case TOK_GE:      emit(cg, OP_GE);  emit(cg, (uint8_t)num_kind); break;
        case TOK_AMP:     emit(cg, OP_BITAND); break;   // & | ^ are width-transparent:
        case TOK_PIPE:    emit(cg, OP_BITOR);  break;   // a bit op on two in-width values
        case TOK_CARET:   emit(cg, OP_BITXOR); break;   // stays in width (no kind byte)
        case TOK_SHL:     emit(cg, OP_SHL); emit(cg, (uint8_t)num_kind); break;
        case TOK_SHR:     emit(cg, OP_SHR); emit(cg, (uint8_t)num_kind); break;
        default:          internal_error(cg, "an unexpected binary operator");
    }
}





// mono_resolve returns the function-table slot a *generic* call targets in the
// current slot, per the monomorphization plan (the appended instance), or -1 if
// the call has no plan resolution (a non-generic call, or a generic call inside a
// dead generic base slot).
static int mono_resolve(const Codegen *cg, const Expr *call) {
    if (cg->plan == NULL) {
        return -1;
    }
    for (int i = 0; i < cg->plan->res_count; i++) {
        if (cg->plan->res[i].caller_slot == cg->cur_slot &&
            cg->plan->res[i].call == call) {
            return cg->plan->res[i].callee_fi;
        }
    }
    return -1;
}

// is_numeric_typename recognises a bare numeric type name used as a conversion
// call (the checker validates it and records the target kind in num_kind).
static int is_numeric_typename(const char *n) {
    return strcmp(n, "i8") == 0 || strcmp(n, "i16") == 0 || strcmp(n, "i32") == 0 ||
           strcmp(n, "i64") == 0 || strcmp(n, "int") == 0 || strcmp(n, "u8") == 0 ||
           strcmp(n, "u16") == 0 || strcmp(n, "u32") == 0 || strcmp(n, "u64") == 0 ||
           strcmp(n, "f32") == 0 || strcmp(n, "f64") == 0;
}

static int gen_arg(Codegen *cg, const Expr *arg, int psid);
static void emit_call_result_box(Codegen *cg, const Expr *e);
static void gen_nested_store(Codegen *cg, const Expr *target, int val_slot,
                            const Expr *val_expr);
static int  expr_reads_as_copy(const Expr *r);
static void gen_array_append_writeback(Codegen *cg, const Expr *call);


// aek_fuzz_kind maps a packed field's ArrayElemKind to the `--check` fuzzer's scalar kind
// ('i' int, 'f' float, 'b' bool), or 0 for a non-scalar (boxed) field. §5j.
static char aek_fuzz_kind(int aek) {
    switch (aek) {
        case AEK_I8: case AEK_I16: case AEK_I32: case AEK_I64:
        case AEK_U8: case AEK_U16: case AEK_U32: case AEK_U64:
            return 'i';
        case AEK_F32: case AEK_F64:
            return 'f';
        case AEK_BOOL:
            return 'b';
        default:
            return 0;
    }
}


// fuzz_flatten_struct appends the leaf scalar kinds of all-scalar struct `sid` to `leaf[]`,
// recursing into inline nested structs — the same leaf order a multi-slot struct param arrives
// in (see cg_slot_span). Returns 0 (and leaves *n partial) if a field is non-scalar (boxed) or
// the leaf cap is exceeded, i.e. the struct is not fuzzable. §5j.
static int fuzz_flatten_struct(Codegen *cg, int sid, char *leaf, int *n, int cap) {
    const StructType *st = &cg->prog->structs[sid];
    for (int f = 0; f < st->field_count; f++) {
        if (st->field_struct[f] >= 0) {
            if (!fuzz_flatten_struct(cg, st->field_struct[f], leaf, n, cap)) {
                return 0;
            }
            continue;
        }
        char k = aek_fuzz_kind(st->kind[f]);
        if (k == 0 || *n >= cap) {
            return 0;
        }
        leaf[(*n)++] = k;
    }
    return 1;
}


// fuzz_array_elem reports whether `elem` is a FULL-WIDTH scalar the `--check` fuzzer can generate
// as an array element (int/i64, f64/float, bool — widths that pack without truncation). On success
// it returns 1 and sets *kind to the element's fuzz kind and *aek to its ArrayElemKind (matching
// the checker's array_elem_kind, value.h). Narrow ints/floats and non-scalar elements: 0. §5j.
static int fuzz_array_elem(const Type *elem, char *kind, unsigned char *aek) {
    if (elem == NULL || elem->kind != TYPE_NAME || elem->as.name.qualifier != NULL) {
        return 0;
    }
    const char *n = elem->as.name.name;
    if (strcmp(n, "int") == 0 || strcmp(n, "i64") == 0) {
        *kind = 'i';
        *aek  = AEK_I64;
        return 1;
    }
    if (strcmp(n, "f64") == 0 || strcmp(n, "float") == 0) {
        *kind = 'f';
        *aek  = AEK_F64;
        return 1;
    }
    if (strcmp(n, "bool") == 0) {
        *kind = 'b';
        *aek  = AEK_BOOL;
        return 1;
    }
    return 0;
}


// fuzz_param_kind maps a parameter's declared type to the scalar kind the `--check` fuzzer
// generates for it ('i' int, 'f' float, 'b' bool), or 0 if it is not a fuzzable scalar. Struct
// parameters are handled separately via their multi-slot leaves (fuzz_flatten_struct). §5j.
static char fuzz_param_kind(const Type *t) {
    if (t == NULL || t->kind != TYPE_NAME || t->as.name.qualifier != NULL) {
        return 0;
    }
    const char *n = t->as.name.name;
    if (strcmp(n, "int") == 0 || strcmp(n, "i8") == 0 || strcmp(n, "i16") == 0 ||
        strcmp(n, "i32") == 0 || strcmp(n, "i64") == 0 || strcmp(n, "u8") == 0 ||
        strcmp(n, "u16") == 0 || strcmp(n, "u32") == 0 || strcmp(n, "u64") == 0) {
        return 'i';
    }
    if (strcmp(n, "f32") == 0 || strcmp(n, "f64") == 0 || strcmp(n, "float") == 0) {
        return 'f';
    }
    if (strcmp(n, "bool") == 0) {
        return 'b';
    }
    return 0;
}


// cg_slot_span returns how many stack SLOTS a MULTI-SLOT struct value occupies — one per LEAF
// scalar, recursing into inline nested struct fields (value-types 3b.5-B). For a flat all-scalar
// struct this equals its field count.
static int cg_slot_span(Codegen *cg, int sid) {
    const StructType *st = &cg->prog->structs[sid];
    int n = 0;
    for (int f = 0; f < st->field_count; f++) {
        n += (st->field_struct[f] >= 0) ? cg_slot_span(cg, st->field_struct[f]) : 1;
    }
    return n;
}


// cg_field_slot_offset returns the slot offset of field `fi` within a multi-slot struct `sid`
// (the number of leaf slots that precede it).
static int cg_field_slot_offset(Codegen *cg, int sid, int fi) {
    const StructType *st = &cg->prog->structs[sid];
    int off = 0;
    for (int f = 0; f < fi; f++) {
        off += (st->field_struct[f] >= 0) ? cg_slot_span(cg, st->field_struct[f]) : 1;
    }
    return off;
}


// resolve_multislot_field walks a field-access chain rooted at a MULTI-SLOT local, accumulating
// the accessed field's slot offset (value-types 3b.5-B). Returns 1 with *base = the local's
// physical slot, *offset = the field's slot offset, and *sid = the field's struct id if it is
// itself a struct (a sub-range to box on use) or -1 if it is a scalar leaf (a single slot).
// Returns 0 if `e` is not a field path rooted at a multi-slot local.
static int resolve_multislot_field(Codegen *cg, const Expr *e, int *base, int *offset, int *sid) {
    if (e->kind == EXPR_IDENT) {
        int lidx = resolve_local_logical(cg, e->as.ident);
        if (lidx < 0 || cg->local_struct[lidx] < 0) {
            return 0;
        }
        *base   = cg->local_phys[lidx];
        *offset = 0;
        *sid    = cg->local_struct[lidx];
        return 1;
    }
    if (e->kind == EXPR_GET && e->as.get.field_index >= 0) {
        int pbase, poff, psid;
        if (!resolve_multislot_field(cg, e->as.get.object, &pbase, &poff, &psid) || psid < 0) {
            return 0;
        }
        const StructType *st = &cg->prog->structs[psid];
        int fi = e->as.get.field_index;
        if (fi >= st->field_count) {
            return 0;
        }
        *base   = pbase;
        *offset = poff + cg_field_slot_offset(cg, psid, fi);
        *sid    = (st->field_struct[fi] >= 0) ? st->field_struct[fi] : -1;
        return 1;
    }
    return 0;
}

static void gen_expr_raw(Codegen *cg, const Expr *e);
static void emit_return_drops(Codegen *cg);   // defined below; used by `?` early-return
static void emit_ensures_checks(Codegen *cg); // defined below; the `?` path checks ensures too (OFI-046)

// gen_expr generates an expression's value, then applies any interface upcast the
// checker recorded on it: a struct value produced where an interface type was expected
// is boxed into an interface value {receiver, vtable}. The vtable is the impl's method
// fn-indices, built like a bounds witness (an enum record); OP_MAKE_DYN boxes the pair.
// Wrapping here means EVERY value site (bindings, args, returns, array elements, fields)
// upcasts uniformly, since they all route through gen_expr.
static void gen_expr(Codegen *cg, const Expr *e) {
    gen_expr_raw(cg, e);
    if (e->coerce_witness != NULL) {
        for (int m = 0; m < e->coerce_witness_count; m++) {
            emit_const(cg, e->coerce_witness[m]);
        }
        emit(cg, OP_NEW_ENUM);          // vtable: an all-boxed record of fn-indices
        emit_idx(cg, 0);                    // dummy type id
        emit_idx(cg, 0);                    // dummy variant tag
        emit_idx(cg, e->coerce_witness_count);
        emit(cg, OP_MAKE_DYN);          // pops [receiver, vtable] → interface value
    }
}

static void gen_expr_raw(Codegen *cg, const Expr *e) {
    cg->current_line = e->line;
    switch (e->kind) {
        case EXPR_INT:
            emit_const(cg, e->as.int_lit);
            break;

        case EXPR_BOOL:
            emit(cg, e->as.bool_lit ? OP_TRUE : OP_FALSE);
            break;

        case EXPR_UNARY:
            gen_expr(cg, e->as.unary.operand);
            if (e->as.unary.op == TOK_MINUS) {
                emit(cg, OP_NEG);
                emit(cg, (uint8_t)e->num_kind);
            } else if (e->as.unary.op == TOK_BANG) {
                emit(cg, OP_NOT);
            } else if (e->as.unary.op == TOK_TILDE) {
                emit(cg, OP_BITNOT);
                emit(cg, (uint8_t)e->num_kind);   // width: narrow unsigned types mask
            } else {
                internal_error(cg, "an unsupported unary operator");
            }
            break;

        case EXPR_BINARY:
            // Logical operators short-circuit, so they compile to jumps, not a
            // single opcode. The non-popping OP_JUMP_IF_FALSE leaves the deciding
            // operand on the stack as the expression's value.
            if (e->as.binary.op == TOK_AND) {
                gen_expr(cg, e->as.binary.left);
                int end = emit_jump(cg, OP_JUMP_IF_FALSE);  // left false: keep it
                emit(cg, OP_POP);                            // left true: take right
                gen_expr(cg, e->as.binary.right);
                patch_jump(cg, end);
            } else if (e->as.binary.op == TOK_OR) {
                gen_expr(cg, e->as.binary.left);
                int else_jump = emit_jump(cg, OP_JUMP_IF_FALSE); // left false: eval right
                int end = emit_jump(cg, OP_JUMP);                // left true: keep it
                patch_jump(cg, else_jump);
                emit(cg, OP_POP);                                // take right
                gen_expr(cg, e->as.binary.right);
                patch_jump(cg, end);
            } else {
                gen_expr(cg, e->as.binary.left);
                gen_expr(cg, e->as.binary.right);
                emit_binop(cg, e->as.binary.op, e->num_kind);
            }
            break;

        case EXPR_IDENT: {
            int lidx = resolve_local_logical(cg, e->as.ident);
            if (lidx >= 0 && cg->local_struct[lidx] >= 0) {
                // A multi-slot struct local read as a whole value: re-box it (read its N
                // field slots, then BOX_STRUCT) so it crosses the seam into boxed
                // territory (assignment, argument, return, copy). (value-types 3b)
                int sid  = cg->local_struct[lidx];
                int base = cg->local_phys[lidx];
                int n    = cg->local_span[lidx];
                for (int f = 0; f < n; f++) {
                    emit(cg, OP_GET_LOCAL);
                    emit_idx(cg, base + f);
                }
                emit(cg, OP_BOX_STRUCT);
                emit_idx(cg, sid);
                break;
            }
            int slot = resolve_local(cg, e->as.ident);
            if (slot >= 0) {
                emit(cg, OP_GET_LOCAL);
                emit_idx(cg, slot);
                // If this read moves the binding's struct out (moves_local == 1),
                // clear the slot so a later scope-exit OP_DROP is a no-op (the
                // moved value's new owner frees it). The moved value stays on the
                // stack for its consumer. A string read (== 2) is an alias, not a
                // move — the refcount bump is emitted generically below.
                if (e->moves_local == 1) {
                    emit_const(cg, 0);            // a non-heap placeholder
                    emit(cg, OP_SET_LOCAL);
                    emit_idx(cg, slot);
                    emit(cg, OP_POP);             // SET_LOCAL leaves the value; drop it
                }
                break;
            }
            // A bare name that is not a local is a zero-field enum variant. Prefer the enum id + tag
            // the checker resolved (variant names are no longer globally unique, so a by-name lookup
            // here could pick a same-named variant of the wrong enum — OFI-073); fall back to by-name
            // only for paths the checker didn't stamp.
            {
                int venum = e->variant_enum_id, vtag = e->variant_tag;
                if (venum < 0) {
                    const CgVariant *v = resolve_cgvariant(cg, e->as.ident);
                    if (v != NULL) { venum = v->enum_id; vtag = v->variant_index; }
                }
                if (venum >= 0) {
                    emit(cg, OP_NEW_ENUM);
                    emit_u8_id(cg, venum, "enum types");
                    emit_idx(cg, vtag);
                    emit_idx(cg, 0);   // no fields
                } else {
                    internal_error(cg, "an unresolved identifier");
                }
            }
            break;
        }

        case EXPR_FN_VALUE: {
            // A named function as a value: a closure over the function with no
            // captures. The checker stored its function-table index.
            emit(cg, OP_MAKE_CLOSURE);
            emit_u8_id(cg, e->as.fn_value, "functions for closures");
            emit_idx(cg, 0);   // zero captures
            break;
        }

        case EXPR_RANGE:
            // Unreachable: the checker rejects a range as a value, and a `for`'s
            // range iterator is lowered directly in the STMT_FOR codegen.
            internal_error(cg, "a range reached codegen outside a 'for' iterator");
            break;

        case EXPR_LAMBDA: {
            // Build the closure: push each captured local (the checker recorded their
            // enclosing slots), then OP_MAKE_CLOSURE over the lifted function. The
            // closure's lifted function sees [captures..., params...] as its locals.
            for (int i = 0; i < e->as.lambda.capture_count; i++) {
                emit(cg, OP_GET_LOCAL);
                emit_idx(cg, e->as.lambda.capture_slots[i]);
            }
            emit(cg, OP_MAKE_CLOSURE);
            emit_u8_id(cg, e->as.lambda.lifted_fn_index, "functions for closures");
            emit_idx(cg, e->as.lambda.capture_count);
            break;
        }

        case EXPR_CALL: {
            const Expr *callee = e->as.call.callee;

            // Enum variant construction the checker resolved — bare `Circle(2.0)` OR a cross-module
            // qualified `json.Obj([…])`. Build it from the threaded enum id + tag BEFORE any method/
            // function dispatch, since the callee may be an EXPR_GET that would otherwise look like a
            // method call (OFI-073).
            if (e->variant_enum_id >= 0) {
                for (size_t i = 0; i < e->as.call.arg_count; i++) {
                    gen_expr(cg, e->as.call.args[i]);
                }
                emit(cg, OP_NEW_ENUM);
                emit_u8_id(cg, e->variant_enum_id, "enum types");
                emit_idx(cg, e->variant_tag);
                emit_idx(cg, e->as.call.arg_count);
                break;
            }

            // Foreign (C) call (FFI, §5h / 3b.6): push each argument as its scalar LEAVES (a
            // struct arg is flattened via gen_arg, like a multi-slot param), then dispatch through
            // the C registry by index. The 16-bit operand is the return struct id (0xFFFF for a
            // scalar return) so the VM can reassemble a struct result from the wrapper's leaves.
            if (e->as.call.cextern_index >= 0) {
                const int *ais = e->as.call.arg_inline_struct;
                int argc = (int)e->as.call.arg_count;
                int rsid = e->as.call.cextern_ret_sid;
                int op   = (rsid < 0) ? 0xFFFF : rsid;
                int mask = e->as.call.drop_mask;
                // Borrowed heap args that are fresh owning temps (e.g. the literals in
                // fopen("f","r")) must be released after the call — Ember keeps ownership across
                // the borrow (§5h pointers). Keep a copy of each below the arg region, re-fetch
                // it as a borrow alias with OP_PICK, call, then OP_DROP_UNDER it from under the
                // single-slot result. Mirrors the direct-call drop path (OFI-027).
                if (mask != 0) {
                    int keep = 0;
                    for (int i = 0; i < argc; i++) {
                        if (mask & (1 << i)) {
                            gen_expr(cg, e->as.call.args[i]);   // kept temp, source order
                            keep++;
                        }
                    }
                    int built = 0, t_seen = 0;
                    for (int i = 0; i < argc; i++) {
                        if (mask & (1 << i)) {
                            emit(cg, OP_PICK);
                            emit_idx(cg, (keep + built - 1) - t_seen);
                            t_seen++;
                            built++;
                        } else {
                            built += gen_arg(cg, e->as.call.args[i], ais ? ais[i] : -1);
                        }
                    }
                    emit(cg, OP_CALL_C);
                    emit_idx(cg, e->as.call.cextern_index);
                    emit_idx(cg, op);
                    for (int k = 0; k < keep; k++) {
                        emit(cg, OP_DROP_UNDER);
                    }
                } else {
                    for (int i = 0; i < argc; i++) {
                        gen_arg(cg, e->as.call.args[i], ais ? ais[i] : -1);
                    }
                    emit(cg, OP_CALL_C);
                    emit_idx(cg, e->as.call.cextern_index);
                    emit_idx(cg, op);
                }
                break;
            }

            // Call through a function value: push the args, then evaluate the callee
            // (which leaves a closure on top), then dispatch indirectly. The closure
            // splices its captures in ahead of the args at run time.
            if (e->as.call.closure_call) {
                for (size_t i = 0; i < e->as.call.arg_count; i++) {
                    gen_expr(cg, e->as.call.args[i]);
                }
                gen_expr(cg, callee);
                emit(cg, OP_CALL_CLOSURE);
                emit_idx(cg, e->as.call.arg_count);
                break;
            }

            // Method call: `object.method(args)`. Push the receiver as the
            // implicit self (arg 0), then the explicit args. The checker stored
            // the method's function-table index in the callee's field_index.
            // (A module-qualified call `mod.foo` also has an EXPR_GET callee but
            // carries resolved_fn — it falls through to the direct-call path.)
            // Struct method with a fresh owned-temp receiver and/or borrow-temp args:
            // keep copies of every owned temp below the call region and OP_DROP_UNDER
            // them after (OFI-027). The flags are only set for struct methods, so the
            // array/string/bound intrinsics below are never taken here. Mirrors the
            // direct-call temps-first scheme, with the receiver as the leading value.
            if (callee->kind == EXPR_GET && e->as.call.resolved_fn < 0 &&
                (e->as.call.drop_first || e->as.call.drop_mask)) {
                int argc = (int)e->as.call.arg_count;
                int mask = e->as.call.drop_mask;
                const int *ais = e->as.call.arg_inline_struct;
                int keep = 0;
                if (e->as.call.drop_first) {
                    gen_expr(cg, callee->as.get.object);   // kept temp receiver
                    keep++;
                }
                for (int i = 0; i < argc; i++) {
                    if (mask & (1 << i)) {
                        gen_expr(cg, e->as.call.args[i]);  // kept temp arg, source order
                        keep++;
                    }
                }
                // `built` counts SLOTS: self (boxed) is 1, a masked temp re-fetched by PICK is
                // 1, a multi-slot struct arg is its field count (value-types 3b.4d).
                int built = 0, t_seen = 0;
                if (e->as.call.drop_first) {
                    emit(cg, OP_PICK);
                    emit_idx(cg, (keep + built - 1) - t_seen);   // re-fetch receiver
                    t_seen++;
                } else {
                    gen_expr(cg, callee->as.get.object);
                }
                built++;
                for (int i = 0; i < argc; i++) {
                    if (mask & (1 << i)) {
                        emit(cg, OP_PICK);
                        emit_idx(cg, (keep + built - 1) - t_seen);
                        t_seen++;
                        built++;
                    } else {
                        built += gen_arg(cg, e->as.call.args[i], ais ? ais[i] : -1);
                    }
                }
                int midx = callee->as.get.field_index;
                if (e->as.call.mono_arg_count > 0) {
                    int mono = mono_resolve(cg, e);
                    if (mono >= 0) {
                        midx = mono;
                    }
                }
                if (midx < 0) {
                    internal_error(cg, "an unresolved method call");
                } else {
                    emit(cg, OP_CALL);
                    emit_fn_index(cg, midx);
                    emit_idx(cg, built);   // self + explicit-arg slots
                    // Box a multi-slot result to one slot BEFORE dropping the kept temps from
                    // under it — OP_DROP_UNDER assumes a single-slot result. (In a drop-path
                    // box_result is always 1, so the result is never taken raw here.)
                    emit_call_result_box(cg, e);
                    for (int k = 0; k < keep; k++) {
                        emit(cg, OP_DROP_UNDER);
                    }
                }
                break;
            }
            // `place.append(x)` where `place` is reached through an index or a value-struct field
            // reads a COPY of the array (OP_INDEX / inline-field boxing clones it), so the plain
            // "push receiver, OP_ARRAY_APPEND" path below would grow that copy and discard it —
            // silently losing the element (OFI-072). Lower it as read-modify-write instead: append
            // into the copy, then write the whole array back into the place. (A plain local/global
            // receiver shares the array handle, so append mutates it in place — no write-back.)
            if (callee->kind == EXPR_GET && e->as.call.resolved_fn < 0 &&
                callee->as.get.array_op == 1 &&
                expr_reads_as_copy(callee->as.get.object)) {
                gen_array_append_writeback(cg, e);
                break;
            }
            if (callee->kind == EXPR_GET && e->as.call.resolved_fn < 0) {
                // Self (boxed for now) then the explicit args; an all-scalar struct arg to a
                // non-generic struct method is pushed as its field slots (value-types 3b.4d),
                // so `built` counts SLOTS. The intrinsic branches below ignore it.
                const int *ais = e->as.call.arg_inline_struct;
                int built = 0;
                gen_expr(cg, callee->as.get.object);
                built++;
                for (size_t i = 0; i < e->as.call.arg_count; i++) {
                    built += gen_arg(cg, e->as.call.args[i], ais ? ais[i] : -1);
                }
                if (callee->as.get.clone_op != 0) {
                    // `.clone()` — a deep copy (OFI-082). The receiver is on the stack. If it
                    // reads as a COPY (an index / inline value-struct field), the read already
                    // produced an independent owned value (OP_INDEX clones an aggregate element,
                    // OFI-062/063), so leave it as the result. A borrow (a plain binding, a boxed
                    // field) shares the owner's live handle, so deep-clone it with OP_INCREF —
                    // which is own_into_slot: clone a value-struct/array, retain a refcounted leaf.
                    if (!expr_reads_as_copy(callee->as.get.object)) {
                        emit(cg, OP_INCREF);
                    }
                    break;
                }
                if (callee->as.get.array_op != ARR_OP_NONE) {
                    // Intrinsic array method. Receiver (and the args) are already on the stack;
                    // emit the matching opcode (codes are the shared ARR_OP_* in ast.h).
                    if (callee->as.get.array_op == ARR_OP_APPEND) {
                        emit(cg, OP_ARRAY_APPEND);
                    } else if (callee->as.get.array_op == ARR_OP_REMOVE_LAST) {
                        emit(cg, OP_ARRAY_POP);
                    } else if (callee->as.get.array_op == ARR_OP_REMOVE_AT) {
                        emit(cg, OP_ARRAY_REMOVE_AT);   // .remove_at(i) — receiver,index on the stack
                    } else if (callee->as.get.array_op == ARR_OP_SLICE) {
                        emit(cg, OP_SLICE_COPY);   // .slice(lo,hi) — receiver,lo,hi on the stack
                    } else {
                        emit(cg, OP_ARRAY_LEN);
                    }
                    break;
                }
                if (callee->as.get.string_op != 0) {
                    // Intrinsic string method. Receiver (and split's separator) are
                    // on the stack.
                    if (callee->as.get.string_op == 1) {
                        emit(cg, OP_STR_LEN);
                    } else if (callee->as.get.string_op == 2) {
                        emit(cg, OP_STR_CHARS);
                    } else if (callee->as.get.string_op == 3) {
                        emit(cg, OP_STR_SPLIT);
                    } else if (callee->as.get.string_op == 5) {
                        emit(cg, OP_STR_CHAR_COUNT);
                    } else if (callee->as.get.string_op == 6) {
                        emit(cg, OP_STR_BYTES);
                    } else {
                        // parse_int builds Option<int> — carry the Some/None tags,
                        // as recv does. The checker verified Option is in scope.
                        const CgVariant *some = resolve_cgvariant(cg, "Some");
                        const CgVariant *none = resolve_cgvariant(cg, "None");
                        if (some == NULL || none == NULL) {
                            internal_error(cg, "parse_int with no Option in scope");
                        } else {
                            emit(cg, OP_STR_PARSE_INT);
                            emit_u8_id(cg, some->enum_id, "enum types");
                            emit_idx(cg, some->variant_index);
                            emit_idx(cg, none->variant_index);
                        }
                    }
                    break;
                }
                if (callee->as.get.bound_method >= 0) {
                    // Bound-method call: read the bound's witness vtable, then its method
                    // fn-index, then call. The witness is either a hidden local (free
                    // function) or — for a bounded generic struct — a field of `self`
                    // (instance-storage; self is local 0 of the method).
                    // Stack: [receiver, args..., fn_index].
                    if (callee->as.get.bound_via_self) {
                        emit(cg, OP_GET_LOCAL);
                        emit_idx(cg, 0);                              // the method's self
                        emit(cg, OP_GET_FIELD);
                        emit_idx(cg, callee->as.get.bound_witness);  // witness field
                    } else {
                        emit(cg, OP_GET_LOCAL);
                        emit_idx(cg, callee->as.get.bound_witness);  // witness local
                    }
                    emit(cg, OP_GET_FIELD);
                    emit_idx(cg, callee->as.get.bound_method);
                    emit(cg, OP_CALL_INDIRECT);
                    // `built` is the SLOT count (self + explicit args, multi-slot struct args
                    // expanded by gen_arg above) — not arg_count+1, which would undercount a
                    // multi-slot struct argument and desync the callee frame. Matches the
                    // direct method-call paths, which also pass `built`.
                    emit_idx(cg, built);
                    break;
                }
                if (callee->as.get.dyn_method >= 0) {
                    // Dynamic dispatch on an interface value (already on the stack as
                    // the receiver, args above it): the VM reads the method's fn-index
                    // from the value's vtable and calls it with the unboxed receiver.
                    emit(cg, OP_CALL_DYN);
                    emit_idx(cg, callee->as.get.dyn_method);   // vtable slot
                    emit_idx(cg, e->as.call.arg_count);        // explicit args
                    break;
                }
                int midx = callee->as.get.field_index;
                if (e->as.call.mono_arg_count > 0) {
                    int mono = mono_resolve(cg, e);   // method on a generic struct
                    if (mono >= 0) {
                        midx = mono;
                    }
                }
                if (midx < 0) {
                    internal_error(cg, "an unresolved method call");
                } else {
                    emit(cg, OP_CALL);
                    emit_fn_index(cg, midx);
                    emit_idx(cg, built);   // self + explicit-arg slots
                    emit_call_result_box(cg, e);   // re-box a multi-slot return unless taken raw
                }
                break;
            }

            // Built-in native call (print/println/read_line/read_file/write_file):
            // push the arguments and dispatch by native id; the result is left on
            // the stack (a unit placeholder for the statement-only ones).
            if (callee->kind == EXPR_IDENT) {
                int nid = native_id_for_name(callee->as.ident);
                if (nid >= 0) {
                    for (size_t i = 0; i < e->as.call.arg_count; i++) {
                        gen_expr(cg, e->as.call.args[i]);
                    }
                    // A u64 argument prints unsigned: render it to a string first
                    // (the native print itself is width-erased). Kind 7 == u64.
                    if (e->num_kind == 7) {
                        emit(cg, OP_TO_STRING);
                        emit(cg, 7);
                    }
                    emit(cg, OP_CALL_NATIVE);
                    emit_idx(cg, nid);
                    emit_idx(cg, e->as.call.arg_count);
                    break;
                }
            }

            // Built-in `len(array)` — an intrinsic, not a native call.
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "len") == 0 &&
                e->as.call.arg_count == 1) {
                gen_expr(cg, e->as.call.args[0]);
                emit(cg, OP_ARRAY_LEN);
                break;
            }

            // Built-in numeric conversions — intrinsics over the tagged value.
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "to_float") == 0 &&
                e->as.call.arg_count == 1) {
                gen_expr(cg, e->as.call.args[0]);
                emit(cg, OP_INT_TO_FLOAT);
                break;
            }
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "to_int") == 0 &&
                e->as.call.arg_count == 1) {
                gen_expr(cg, e->as.call.args[0]);
                emit(cg, OP_FLOAT_TO_INT);
                break;
            }
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "clock") == 0 &&
                e->as.call.arg_count == 0) {
                emit(cg, OP_CLOCK);
                break;
            }
            // Built-in wrapping arithmetic (OFI-041): wrapping_add/sub/mul(a, b) —
            // push both operands, then a wrap opcode carrying the operand width kind.
            if (callee->kind == EXPR_IDENT && e->as.call.arg_count == 2) {
                int wop = -1;
                if (strcmp(callee->as.ident, "wrapping_add") == 0)      { wop = OP_WRAP_ADD; }
                else if (strcmp(callee->as.ident, "wrapping_sub") == 0) { wop = OP_WRAP_SUB; }
                else if (strcmp(callee->as.ident, "wrapping_mul") == 0) { wop = OP_WRAP_MUL; }
                if (wop >= 0) {
                    gen_expr(cg, e->as.call.args[0]);
                    gen_expr(cg, e->as.call.args[1]);
                    emit(cg, (uint8_t)wop);
                    emit(cg, (uint8_t)e->num_kind);
                    break;
                }
            }

            // Numeric width conversion: a type-name call (u8(x), i32(x), int(x)).
            if (callee->kind == EXPR_IDENT && e->as.call.arg_count == 1 &&
                is_numeric_typename(callee->as.ident)) {
                gen_expr(cg, e->as.call.args[0]);
                emit(cg, OP_CONV);
                emit(cg, (uint8_t)e->num_kind);
                break;
            }

            // Channel built-ins: channel(N), send(ch, v), recv(ch).
            if (callee->kind == EXPR_IDENT &&
                strcmp(callee->as.ident, "channel") == 0 &&
                e->as.call.arg_count == 1) {
                gen_expr(cg, e->as.call.args[0]);
                emit(cg, OP_CHANNEL_NEW);
                break;
            }
            if (callee->kind == EXPR_IDENT &&
                strcmp(callee->as.ident, "send") == 0 &&
                e->as.call.arg_count == 2) {
                gen_expr(cg, e->as.call.args[0]);   // channel
                gen_expr(cg, e->as.call.args[1]);   // value
                emit(cg, OP_SEND);
                break;
            }
            if (callee->kind == EXPR_IDENT &&
                strcmp(callee->as.ident, "recv") == 0 &&
                e->as.call.arg_count == 1) {
                // recv builds Option<elem> at runtime — Some(v) or None — so it
                // carries the enum's type id and the two variant tags. The checker
                // already verified a matching Option is in scope.
                const CgVariant *some = resolve_cgvariant(cg, "Some");
                const CgVariant *none = resolve_cgvariant(cg, "None");
                if (some == NULL || none == NULL) {
                    internal_error(cg, "recv with no Option/Some/None in scope");
                    break;
                }
                gen_expr(cg, e->as.call.args[0]);   // channel
                emit(cg, OP_RECV);
                emit_u8_id(cg, some->enum_id, "enum types");
                emit_idx(cg, some->variant_index);
                emit_idx(cg, none->variant_index);
                break;
            }
            if (callee->kind == EXPR_IDENT &&
                strcmp(callee->as.ident, "try_recv") == 0 &&
                e->as.call.arg_count == 1) {
                // try_recv: non-blocking poll → Some(v) or None. Same Option tags as recv.
                const CgVariant *some = resolve_cgvariant(cg, "Some");
                const CgVariant *none = resolve_cgvariant(cg, "None");
                if (some == NULL || none == NULL) {
                    internal_error(cg, "try_recv with no Option/Some/None in scope");
                    break;
                }
                gen_expr(cg, e->as.call.args[0]);   // channel
                emit(cg, OP_TRY_RECV);
                emit_u8_id(cg, some->enum_id, "enum types");
                emit_idx(cg, some->variant_index);
                emit_idx(cg, none->variant_index);
                break;
            }
            if (callee->kind == EXPR_IDENT &&
                strcmp(callee->as.ident, "close") == 0 &&
                e->as.call.arg_count == 1) {
                gen_expr(cg, e->as.call.args[0]);   // channel
                emit(cg, OP_CLOSE);
                break;
            }
            // `assert(cond [, "msg"])` (verification loop, §5j) — lowers to the contract-check
            // machinery so a failure is a structured tape event, not a bare crash; release-elided
            // like a contract. Leaves a unit placeholder for the statement context to pop.
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "assert") == 0 &&
                e->as.call.arg_count >= 1) {
                if (!codegen_release_profile) {
                    gen_expr(cg, e->as.call.args[0]);   // the condition (bool on the stack)
                    char autobuf[64];
                    const char *mtext;
                    size_t mlen;
                    const Expr *m = e->as.call.arg_count >= 2 ? e->as.call.args[1] : NULL;
                    if (m != NULL && m->kind == EXPR_STRING && m->as.str.part_count == 1 &&
                        m->as.str.parts[0].expr == NULL) {
                        mtext = m->as.str.parts[0].text;
                        mlen  = m->as.str.parts[0].len;
                    } else {
                        int n = snprintf(autobuf, sizeof autobuf,
                                         "assertion failed (line %d)", e->line);
                        mtext = autobuf;
                        mlen  = (size_t)(n > 0 ? n : 0);
                    }
                    size_t midx = chunk_add_string(cg->chunk, mtext, mlen);
                    emit(cg, OP_CONTRACT_CHECK);
                    emit_idx(cg, midx);
                }
                emit_const(cg, 0);   // unit placeholder (the statement context pops one value)
                break;
            }

            // Data-carrying variant construction: `Circle(2.0)`. Prefer the checker's resolved enum
            // id + tag over a by-name lookup (no longer globally unique — OFI-073).
            if (callee->kind == EXPR_IDENT) {
                int venum = e->variant_enum_id, vtag = e->variant_tag;
                if (venum < 0) {
                    const CgVariant *v = resolve_cgvariant(cg, callee->as.ident);
                    if (v != NULL) { venum = v->enum_id; vtag = v->variant_index; }
                }
                if (venum >= 0) {
                    for (size_t i = 0; i < e->as.call.arg_count; i++) {
                        gen_expr(cg, e->as.call.args[i]);
                    }
                    emit(cg, OP_NEW_ENUM);
                    emit_u8_id(cg, venum, "enum types");
                    emit_idx(cg, vtag);
                    emit_idx(cg, e->as.call.arg_count);
                    break;
                }
            }

            // Direct function call — free (`foo`) or module-qualified (`mod.foo`).
            // The checker resolved the base function-table index; a generic call
            // is redirected to its monomorphized instance's slot.
            int idx = e->as.call.resolved_fn;
            if (e->as.call.mono_arg_count > 0) {
                int mono = mono_resolve(cg, e);
                if (mono >= 0) {
                    idx = mono;
                }
            }
            if (idx < 0) {
                internal_error(cg, "a call to an unresolved function");
                break;
            }
            // A bounded generic call passes one witness per (type parameter, bound) as
            // hidden leading arguments, in callee order. Each is a synthetic record of
            // method fn-indices, built as an enum (all-boxed 16-byte slots, no struct
            // descriptor); a method index is later read with OP_GET_FIELD.
            int extra = 0;
            for (int w = 0; w < e->as.call.witness_total; w++) {
                const Witness *wit = &e->as.call.witnesses[w];
                for (int m = 0; m < wit->count; m++) {
                    emit_const(cg, wit->fns[m]);
                }
                emit(cg, OP_NEW_ENUM);
                emit_idx(cg, 0);                                  // dummy type id
                emit_idx(cg, 0);                                  // dummy variant tag
                emit_idx(cg, wit->count);
                extra++;
            }
            // Push the arguments left to right; they become the callee's locals (after
            // any witness). OP_CALL carries the index and arg count.
            int argc = (int)e->as.call.arg_count;
            // Borrow-temp args (fresh owned structs) must be dropped by the caller — the
            // callee can't (no refcount) — or they leak (OFI-027). Keep a copy of each
            // BELOW the arg region: evaluate the marked temps first (their copies sit at
            // the bottom, in source order), build the args (a temp re-fetched with
            // OP_PICK as a borrow alias, a non-temp freshly), call, then OP_DROP_UNDER
            // each kept temp from under the result. Skipped when a witness is present
            // (the kept copies wouldn't sit directly under the result — rare).
            // Per-arg multi-slot struct id (value-types 3b.4): a plain all-scalar struct
            // arg is pushed as its N field slots, so `built` below counts SLOTS, not args,
            // and that slot total is the callee's frame size. A masked (drop) arg is never
            // multi-slot (the checker excluded it), so it stays a single boxed slot.
            const int *ais = e->as.call.arg_inline_struct;
            int mask = (extra == 0) ? e->as.call.drop_mask : 0;
            if (mask != 0) {
                int keep = 0;
                for (int i = 0; i < argc; i++) {
                    if (mask & (1 << i)) {
                        gen_expr(cg, e->as.call.args[i]);   // kept temp, in source order
                        keep++;
                    }
                }
                int built = 0, t_seen = 0;
                for (int i = 0; i < argc; i++) {
                    if (mask & (1 << i)) {
                        emit(cg, OP_PICK);
                        emit_idx(cg, (keep + built - 1) - t_seen);
                        t_seen++;
                        built++;
                    } else {
                        built += gen_arg(cg, e->as.call.args[i], ais ? ais[i] : -1);
                    }
                }
                emit(cg, OP_CALL);
                emit_fn_index(cg, idx);
                emit_idx(cg, built + extra);
                // Box a multi-slot result to one slot BEFORE dropping the kept temps from
                // under it (OP_DROP_UNDER assumes a single-slot result; in a drop-path
                // box_result is always 1, so the result is never taken raw here).
                emit_call_result_box(cg, e);
                for (int k = 0; k < keep; k++) {
                    emit(cg, OP_DROP_UNDER);
                }
            } else {
                int built = 0;
                for (int i = 0; i < argc; i++) {
                    built += gen_arg(cg, e->as.call.args[i], ais ? ais[i] : -1);
                }
                emit(cg, OP_CALL);
                emit_fn_index(cg, idx);
                emit_idx(cg, built + extra);
                emit_call_result_box(cg, e);   // re-box a multi-slot return unless taken raw
            }
            break;
        }

        case EXPR_GET: {
            // A field path rooted at a MULTI-SLOT struct local reads from its slots directly —
            // no boxing, no whole-struct copy (value-types 3b). A scalar leaf (`p.x`, `line.a.x`)
            // is one slot; a whole nested struct field (`line.a`) is its slot sub-range, boxed on
            // use so it crosses the seam into boxed territory.
            {
                int base, offset, sid;
                if (resolve_multislot_field(cg, e, &base, &offset, &sid)) {
                    if (sid < 0) {
                        emit(cg, OP_GET_LOCAL);
                        emit_idx(cg, base + offset);
                    } else {
                        int span = cg_slot_span(cg, sid);
                        for (int f = 0; f < span; f++) {
                            emit(cg, OP_GET_LOCAL);
                            emit_idx(cg, base + offset + f);
                        }
                        emit(cg, OP_BOX_STRUCT);
                        emit_idx(cg, sid);
                    }
                    break;
                }
            }
            gen_expr(cg, e->as.get.object);
            if (e->as.get.field_index < 0) {
                internal_error(cg, "an unresolved field access");
            } else if (e->as.get.drop_object) {
                // The object is a fresh owned struct temporary: read the field, then
                // drop the receiver (retaining a boxed field first) so it can't leak.
                emit(cg, OP_GET_FIELD_OWNED);
                emit_idx(cg, e->as.get.field_index);
            } else {
                emit(cg, OP_GET_FIELD);
                emit_idx(cg, e->as.get.field_index);
            }
            break;
        }

        case EXPR_STRUCT_LIT: {
            // The checker resolved the struct-type id — for a concrete generic
            // struct (Box<int>) this is its own monomorphized instance id, with its
            // own packed layout; field names come from the base struct.
            int sid = e->as.struct_lit.resolved_struct;
            if (sid < 0) {
                internal_error(cg, "construction of an unknown struct");
                break;
            }
            const CgStruct *cs = &cg->structs[sid];
            // cs->field_count is the USER (named) field count; a bounded generic struct
            // also has `witness_total` hidden witness fields appended at construction.
            int user_fields = cs->field_count;
            // Emit field values in *declared* order (the literal may list them
            // in any order); the checker guarantees each is present exactly once.
            for (int j = 0; j < user_fields; j++) {
                Expr *value = NULL;
                for (size_t i = 0; i < e->as.struct_lit.field_count; i++) {
                    if (strcmp(e->as.struct_lit.fields[i].name,
                               cs->field_names[j]) == 0) {
                        value = e->as.struct_lit.fields[i].value;
                        break;
                    }
                }
                if (value == NULL) {
                    internal_error(cg, "a struct field missing at construction");
                    return;
                }
                gen_expr(cg, value);
            }
            // Instance-storage: append the key witnesses as hidden trailing fields — one
            // vtable per (bounded param, bound), built as an enum of method fn-indices
            // (the same shape a bounds witness uses), so a method can read self.<field>.
            for (int w = 0; w < e->as.struct_lit.witness_total; w++) {
                const Witness *wit = &e->as.struct_lit.witnesses[w];
                for (int m = 0; m < wit->count; m++) {
                    emit_const(cg, wit->fns[m]);
                }
                emit(cg, OP_NEW_ENUM);
                emit_idx(cg, 0);                       // dummy type id
                emit_idx(cg, 0);                       // dummy variant tag
                emit_idx(cg, wit->count);
            }
            // Multi-slot construction (value-types 3b.4c): when a consumer takes the value
            // as slots (box_result == 0 — a `let` binding or a `return`), the N field values
            // just pushed ARE the struct; skip the box. Otherwise box them as before.
            // (A bounded struct has witnesses, so inline_sid is -1 and this never fires.)
            if (e->as.struct_lit.inline_sid >= 0 && e->as.struct_lit.box_result == 0) {
                break;
            }
            emit(cg, OP_NEW_STRUCT);
            emit_u8_id(cg, sid, "struct types");
            emit_idx(cg, cs->field_count + e->as.struct_lit.witness_total);
            break;
        }

        case EXPR_FLOAT:
            emit_constant(cg, FLOAT_VAL(e->as.float_lit));
            break;

        case EXPR_STRING: {
            // Emit each part (a literal run, or `to_string` of a hole expression)
            // and fold them left-to-right with string concatenation.
            for (size_t i = 0; i < e->as.str.part_count; i++) {
                const StrPart *part = &e->as.str.parts[i];
                if (part->expr != NULL) {
                    gen_expr(cg, part->expr);
                    emit(cg, OP_TO_STRING);
                    emit(cg, (uint8_t)part->render_kind);
                } else {
                    emit(cg, OP_STRING);
                    emit_idx(cg, chunk_add_string(cg->chunk, part->text, part->len));
                }
                if (i > 0) {
                    // OP_CONCAT (not OP_ADD): a consuming concat that releases both operands, so
                    // the intermediate results of a multi-part interpolation are freed rather than
                    // leaked (OFI-059). Sound because OP_TO_STRING and OP_STRING both leave OWNED
                    // references here.
                    emit(cg, OP_CONCAT);
                }
            }
            break;
        }

        case EXPR_TRY: {
            // expr? — if the value is the success variant (Ok/Some), unwrap its
            // payload; otherwise return it (Err/None) from the function early.
            gen_expr(cg, e->as.try_.operand);   // [v]
            emit(cg, OP_DUP);                    // [v, v]
            emit(cg, OP_GET_TAG);                // [v, tag]
            emit_const(cg, e->as.try_.success_variant);
            emit(cg, OP_EQ);                     // [v, matched]
            int fail = emit_jump(cg, OP_JUMP_IF_FALSE);
            emit(cg, OP_POP);                    // success: drop the test result [v]
            emit(cg, OP_GET_FIELD);
            emit_idx(cg, 0);                     // success: unwrap payload [payload]
            int done = emit_jump(cg, OP_JUMP);
            patch_jump(cg, fail);                // failure: [v, matched]
            emit(cg, OP_POP);                    // drop the test result [v]
            // Postconditions are checked on the propagation exit too (OFI-046), so a `?`-return is
            // held to the same `ensures` contract as an explicit `return`. The wrinkle: `result`
            // binds at a fixed slot just above the locals (emit_ensures_checks), which is `v`'s
            // position only when the stack is canonical — but a mid-expression `?` (e.g. the 2nd in
            // `Ok(a()? + b()?)`) leaves abandoned temporaries below `v`. Fix without a stack-depth
            // tracker: park `v` (the stack TOP) into the `result` slot with OP_SET_LOCAL, clobbering
            // a now-dead temporary (the frame is about to reset). `v` stays on top for OP_RETURN. On
            // the canonical path (no temporaries) the slot IS the top, so it is a harmless self-copy.
            if (cg->ensures_count > 0 && !codegen_release_profile && cg->ret_struct_id < 0) {
                emit(cg, OP_SET_LOCAL);
                emit_idx(cg, cg->phys_count);    // result slot = v (the Err/None being returned)
                emit_ensures_checks(cg);
            }
            // Early-return on Err/None must release the function's owning locals just like an
            // explicit `return` (STMT_RETURN), or every owning binding live at the `?` leaks on the
            // error path. OP_DROP targets fixed local slots, so this stays correct under a
            // mid-expression `?` (OP_RETURN resets the frame and returns the top). (The temporaries
            // below `v` are a separate, pre-existing early-return leak — see OFI-046's residual.)
            emit_return_drops(cg);
            emit(cg, OP_RETURN);                 // return the Err/None early
            patch_jump(cg, done);                // success continues [payload]
            break;
        }

        case EXPR_ARRAY: {
            for (size_t i = 0; i < e->as.array.count; i++) {
                gen_expr(cg, e->as.array.elems[i]);
            }
            if (e->as.array.elem_struct_id >= 0) {
                // All-scalar struct elements stored inline: the elements are ObjStructs
                // on the stack; OP_NEW_STRUCT_ARRAY copies their bytes into the packed
                // buffer and reclaims them. Carries the struct id (16-bit) to size it.
                emit(cg, OP_NEW_STRUCT_ARRAY);
                emit_idx(cg, e->as.array.count);
                emit_idx(cg, e->as.array.elem_struct_id);
            } else {
                emit(cg, OP_NEW_ARRAY);
                emit_idx(cg, e->as.array.count);
                emit(cg, (uint8_t)e->num_kind);   // element storage kind (checker-set)
            }
            break;
        }

        case EXPR_INDEX:
            // `arr[lo..hi]` → a borrowed Slice<T> view (OP_SLICE); `arr[i]` → an element.
            if (e->as.index.index->kind == EXPR_RANGE) {
                gen_expr(cg, e->as.index.object);
                gen_expr(cg, e->as.index.index->as.range.lo);
                gen_expr(cg, e->as.index.index->as.range.hi);
                emit(cg, OP_SLICE);
            } else {
                gen_expr(cg, e->as.index.object);
                gen_expr(cg, e->as.index.index);
                emit(cg, OP_INDEX);
            }
            break;
    }
    // A string read from an existing owner (binding / field / element) aliased
    // into a new owning slot: bump the refcount for the new owner. The checker
    // marks exactly these reads (moves_local == 2); the value is on the stack.
    if (e->moves_local == 2) {
        emit(cg, OP_INCREF);
    }
}


// gen_arg emits one call/spawn argument. When the matching parameter is a plain all-scalar
// struct passed MULTI-SLOT (psid >= 0), it produces the struct's N field slots: a multi-slot
// local/parameter source copies its slots in place (no allocation); any other struct value
// is materialised boxed and exploded with OP_UNBOX_STRUCT (which frees the shell). Otherwise
// it emits the single boxed value. Returns the number of physical slots pushed (3b.4).
static int gen_arg(Codegen *cg, const Expr *arg, int psid) {
    if (psid < 0) {
        gen_expr(cg, arg);
        return 1;
    }
    int n = cg_slot_span(cg, psid);
    if (arg->kind == EXPR_IDENT) {
        int lidx = resolve_local_logical(cg, arg->as.ident);
        if (lidx >= 0 && cg->local_struct[lidx] >= 0) {
            int base = cg->local_phys[lidx];
            for (int f = 0; f < n; f++) {
                emit(cg, OP_GET_LOCAL);
                emit_idx(cg, base + f);
            }
            return n;
        }
    }
    // A producer the checker marked box_result == 0 (a call returning multi-slot, or a
    // multi-slot construction) leaves its N field slots directly — no box to explode.
    if ((arg->kind == EXPR_CALL && arg->as.call.ret_struct_id >= 0 &&
         arg->as.call.box_result == 0) ||
        (arg->kind == EXPR_STRUCT_LIT && arg->as.struct_lit.inline_sid >= 0 &&
         arg->as.struct_lit.box_result == 0)) {
        gen_expr(cg, arg);
        return n;
    }
    gen_expr(cg, arg);
    // A BORROWED named-local struct (moves_local != 1: the slot is NOT nilled, so its scope-exit
    // OP_DROP still frees it) must be exploded WITHOUT reclaiming the shell — otherwise the live
    // local is freed here and double-freed at scope exit (OFI-058). A fresh temp / moved-out local
    // (moves_local == 1, slot nilled) is consumed, so the reclaiming unbox is correct.
    if (arg->kind == EXPR_IDENT && arg->moves_local != 1) {
        emit(cg, OP_UNBOX_STRUCT_BORROW);
    } else {
        emit(cg, OP_UNBOX_STRUCT);
    }
    emit_idx(cg, psid);
    return n;
}


// emit_call_result_box re-boxes a MULTI-SLOT struct call result (value-types 3b.4b). A call
// whose callee returns multi-slot leaves N field slots on the stack; unless a consumer takes
// them directly (a `let` binding, marked box_result == 0), box them back into one value so
// every ordinary consumer (arg, field access, discard, …) sees a single struct as before.
static void emit_call_result_box(Codegen *cg, const Expr *e) {
    int sid = e->as.call.ret_struct_id;
    if (sid >= 0 && e->as.call.box_result) {
        emit(cg, OP_BOX_STRUCT);
        emit_idx(cg, sid);
    }
}





static void gen_block(Codegen *cg, const Block *b);

// emit_return_drops releases every in-scope binding that still owns a value
// (struct or refcounted) before a function returns. The return value already sits
// on the stack and is excluded: a returned struct/string was moved/incref'd by the
// checker, so its slot is either nilled or balanced. Used at every `return` and at
// the implicit fall-off-the-end return.
static void emit_return_drops(Codegen *cg) {
    for (int i = 0; i < cg->local_count; i++) {
        if (cg->local_drop[i]) {
            emit(cg, OP_DROP);
            emit_idx(cg, cg->local_phys[i]);
        }
    }
}

// emit_ensures_checks checks the current function's postconditions at a return. The
// return value is already on the stack top — it lands at slot `local_count`, so we
// bind the name `result` there for the duration of the checks (the predicates read
// it via GET_LOCAL), then unbind, leaving the value on the stack for OP_RETURN.
// `result` borrows the value (drop flag 0) — it is not reclaimed here. Each false
// postcondition aborts via OP_CONTRACT_CHECK. (Debug profile; release elides.)
static void emit_ensures_checks(Codegen *cg) {
    if (cg->ensures_count == 0 || codegen_release_profile) {
        return;   // release elides postcondition checks (zero cost)
    }
    int saved_lc = cg->local_count, saved_pc = cg->phys_count;
    if (cg->ret_struct_id >= 0) {
        // A multi-slot struct return: `result` binds the N field slots on top, so an
        // `ensures result.field …` reads a slot directly (value-types 3b.4b).
        int n = cg_slot_span(cg, cg->ret_struct_id);
        cg_declare(cg, "result", 0, n);
        cg->local_struct[cg->local_count - 1] = cg->ret_struct_id;
    } else {
        cg_declare(cg, "result", 0, 1);   // binds the return value (on the stack top)
    }
    for (size_t i = 0; i < cg->ensures_count; i++) {
        gen_expr(cg, cg->ensures_clauses[i]);
        char msg[200];
        int n = snprintf(msg, sizeof msg,
                         "postcondition failed in '%s' (ensures, line %d)",
                         cg->fn_name, cg->ensures_clauses[i]->line);
        size_t midx = chunk_add_string(cg->chunk, msg, (size_t)(n > 0 ? n : 0));
        emit(cg, OP_CONTRACT_CHECK);
        emit_idx(cg, midx);
    }
    // Unbind 'result'; the return value remains on the stack top for OP_RETURN.
    cg->local_count = saved_lc;
    cg->phys_count  = saved_pc;
}

// emit_drops_and_pops releases and pops the locals from the top of the stack down
// to `from`: an owning binding (a struct, or a refcounted value) is freed before
// its slot is discarded. Used at every scope exit that unwinds locals — block end,
// a loop body's back-edge, `break`/`continue`, and `match` case bodies — so a value
// declared in any of those is reclaimed, not leaked. Leaves cg->local_count for the
// caller to reset (a fall-through resets it; a break/continue jumps away).
static void emit_drops_and_pops(Codegen *cg, int from) {
    for (int i = cg->local_count - 1; i >= from; i--) {
        if (cg->local_drop[i]) {
            emit(cg, OP_DROP);
            emit_idx(cg, cg->local_phys[i]);
        }
        for (int s = 0; s < cg->local_span[i]; s++) {
            emit(cg, OP_POP);   // one pop per physical slot the binding occupies
        }
    }
}


// gen_nested_store lowers a field assignment `target = value` (target = EXPR_GET(obj, leaf)).
// If `obj` reads a nested struct field stored INLINE, reading it materialises a value COPY, so
// a plain SET_FIELD would mutate the copy and lose it (value-types 3b.5). Instead it
// materialises `obj` into a scratch local, sets the leaf on the copy, then RECURSIVELY assigns
// the modified copy back into `obj`'s place (which memcpy's it into the parent). The base case
// — `obj` is a local or a boxed place — is the ordinary push-receiver, push-value, SET_FIELD.
// Exactly one of (val_slot >= 0) / (val_expr != NULL) supplies the value to store.
static void gen_nested_store(Codegen *cg, const Expr *target, int val_slot,
                             const Expr *val_expr) {
    const Expr *obj = target->as.get.object;
    int leaf = target->as.get.field_index;
    int writeback = (obj->kind == EXPR_GET && obj->as.get.inline_field);
    if (writeback) {
        int saved = cg->local_count;
        gen_expr(cg, obj);                          // materialise a COPY of obj
        int scratch = cg_declare(cg, "", 0, 1);     // bind the copy to a scratch slot
        emit(cg, OP_GET_LOCAL);
        emit_idx(cg, scratch);
        if (val_slot >= 0) {
            emit(cg, OP_GET_LOCAL);
            emit_idx(cg, val_slot);
        } else {
            gen_expr(cg, val_expr);
        }
        emit(cg, OP_SET_FIELD);                     // scratch.leaf = value
        emit_idx(cg, leaf);
        gen_nested_store(cg, obj, scratch, NULL);   // obj = scratch (writes back into the parent)
        emit(cg, OP_POP);                           // discard the scratch (reclaimed by the writeback)
        cg_unwind(cg, saved);
        return;
    }
    if (obj->kind == EXPR_INDEX) {
        // `arr[i].leaf = value` into an INLINE-struct array (OFI-061). Reading `arr[i]` (OP_INDEX)
        // materialises a COPY whose boxed leaves are retained, so a plain SET_FIELD would mutate a
        // copy that is then discarded. Instead: set the leaf on that copy, then write the whole
        // element back with OP_SET_INDEX (which releases the old element's leaves and moves the copy
        // in). The refcounts balance to exactly one owner — OP_INDEX retains, OP_SET_FIELD releases
        // the old boxed leaf, OP_SET_INDEX releases the old element.
        int saved = cg->local_count;
        gen_expr(cg, obj);                          // materialise a COPY of arr[i] (leaves retained)
        int scratch = cg_declare(cg, "", 0, 1);
        emit(cg, OP_GET_LOCAL);
        emit_idx(cg, scratch);
        if (val_slot >= 0) {
            emit(cg, OP_GET_LOCAL);
            emit_idx(cg, val_slot);
        } else {
            gen_expr(cg, val_expr);
        }
        emit(cg, OP_SET_FIELD);                     // scratch.leaf = value
        emit_idx(cg, leaf);
        gen_expr(cg, obj->as.index.object);         // write the modified copy back: arr ...
        gen_expr(cg, obj->as.index.index);          // ... [i] ...
        emit(cg, OP_GET_LOCAL);
        emit_idx(cg, scratch);                 // ... = scratch
        emit(cg, OP_SET_INDEX);
        emit(cg, OP_POP);                           // discard the scratch (reclaimed by SET_INDEX)
        cg_unwind(cg, saved);
        return;
    }
    gen_expr(cg, obj);
    if (val_slot >= 0) {
        emit(cg, OP_GET_LOCAL);
        emit_idx(cg, val_slot);
    } else {
        gen_expr(cg, val_expr);
    }
    emit(cg, OP_SET_FIELD);
    emit_idx(cg, leaf);
}


// expr_reads_as_copy reports whether reading `r` materialises a COPY disconnected from storage
// (so mutating it in place would be lost) rather than the live handle. Indexing an array clones
// the element (OP_INDEX), and reading a nested INLINE value-struct field boxes a copy; a field of
// either is therefore a copy too. A plain variable, or a boxed (array/string/map) field of a live
// struct, yields the shared handle. Mirrors gen_nested_store's own write-back detection (OFI-072).
static int expr_reads_as_copy(const Expr *r) {
    if (r->kind == EXPR_INDEX) {
        return 1;
    }
    if (r->kind == EXPR_GET) {
        if (r->as.get.inline_field) {
            return 1;
        }
        return expr_reads_as_copy(r->as.get.object);
    }
    return 0;
}






// gen_array_append_writeback lowers `place.append(value)` when `place` reads as a copy (OFI-072):
// read the array out of the place, append into it in place, then write the whole array back into
// the place using the same store path an assignment uses (gen_nested_store for a field, OP_SET_INDEX
// for an element). Leaves a unit result, exactly like the direct OP_ARRAY_APPEND it replaces. The
// ops are refcount-neutral on the stack (OP_GET_LOCAL / OP_POP don't retain/release); ownership
// balances through OP_ARRAY_APPEND's move-in and the store's release-old, as in the assignment path.
static void gen_array_append_writeback(Codegen *cg, const Expr *call) {
    const Expr *callee = call->as.call.callee;
    const Expr *place  = callee->as.get.object;          // the array lvalue
    const int  *ais    = call->as.call.arg_inline_struct;
    int saved = cg->local_count;

    gen_expr(cg, place);                                 // [.. A]   a copy of place's array
    int scratch = cg_declare(cg, "", 0, 1);              // name the slot holding A
    emit(cg, OP_GET_LOCAL);
    emit_idx(cg, scratch);                               // [.. A, A]
    gen_arg(cg, call->as.call.args[0], ais ? ais[0] : -1);  // [.. A, A, value]
    emit(cg, OP_ARRAY_APPEND);                           // grow A in place → [.. A, unit]
    emit(cg, OP_POP);                                    // drop the unit   → [.. A]

    if (place->kind == EXPR_INDEX) {                     // place = A  (element write-back)
        gen_expr(cg, place->as.index.object);            // [.. A, arr]
        gen_expr(cg, place->as.index.index);             // [.. A, arr, i]
        emit(cg, OP_GET_LOCAL);
        emit_idx(cg, scratch);                           // [.. A, arr, i, A]
        emit(cg, OP_SET_INDEX);                          // → [.. A]
    } else {                                             // place = A  (field write-back)
        gen_nested_store(cg, place, scratch, NULL);      // → [.. A]
    }
    emit(cg, OP_POP);                                    // drop scratch alias (A now owned by storage) → [..]
    cg_unwind(cg, saved);
    emit_const(cg, 0);                                   // unit result (the statement context pops one)
}






static void gen_stmt(Codegen *cg, const Stmt *s) {
    cg->current_line = s->line;
    switch (s->kind) {
        case STMT_RETURN:
            if (cg->ret_struct_id >= 0 && s->as.ret.value != NULL) {
                // The function returns a struct MULTI-SLOT: produce the value's N field
                // slots (gen_arg copies a multi-slot local/param's slots, or boxes-then-
                // explodes any other value), then move them into the caller's frame with
                // OP_RETURN_STRUCT (value-types 3b.4b).
                int n = gen_arg(cg, s->as.ret.value, cg->ret_struct_id);
                emit_ensures_checks(cg);
                emit_return_drops(cg);
                emit(cg, OP_RETURN_STRUCT);
                emit_idx(cg, n);
                break;
            }
            if (s->as.ret.value != NULL) {
                gen_expr(cg, s->as.ret.value);
            } else {
                emit_const(cg, 0);
            }
            emit_ensures_checks(cg);   // postconditions, with `result` = this value
            emit_return_drops(cg);
            emit(cg, OP_RETURN);
            break;

        case STMT_LET: {
            // The initialiser's result occupies the local's stack slot; no
            // store instruction is needed. Register the name at that slot.
            gen_expr(cg, s->as.let.value);
            const Expr *rhs = s->as.let.value;
            int direct_sid = -1;   // a producer that left its N field slots raw (box_result 0)
            if (rhs->kind == EXPR_CALL && rhs->as.call.ret_struct_id >= 0 &&
                rhs->as.call.box_result == 0) {
                direct_sid = rhs->as.call.ret_struct_id;
            } else if (rhs->kind == EXPR_STRUCT_LIT && rhs->as.struct_lit.inline_sid >= 0 &&
                       rhs->as.struct_lit.box_result == 0) {
                direct_sid = rhs->as.struct_lit.resolved_struct;
            }
            if (direct_sid >= 0) {
                // The initialiser left its struct's N field slots on the stack (no box) —
                // bind them directly, no UNBOX round-trip (value-types 3b.4b/4c). All-scalar
                // ⇒ drop flag 0.
                int n = cg_slot_span(cg, direct_sid);
                cg_declare(cg, s->as.let.name, 0, n);
                cg->local_struct[cg->local_count - 1] = direct_sid;
            } else if (s->as.let.inline_struct_id >= 0) {
                // Multi-slot struct binding from a BOXED initialiser: explode it into its
                // fields (N stack slots). All-scalar ⇒ nothing to drop, just pop N at
                // scope exit (drop flag 0). (value-types 3b)
                int sid = s->as.let.inline_struct_id;
                int n = cg_slot_span(cg, sid);
                emit(cg, OP_UNBOX_STRUCT);
                emit_idx(cg, sid);
                cg_declare(cg, s->as.let.name, 0, n);
                cg->local_struct[cg->local_count - 1] = sid;
            } else {
                cg_declare(cg, s->as.let.name, s->as.let.drop_at_scope_end, 1);
            }
            break;
        }

        case STMT_ASSIGN: {
            const Expr *target = s->as.assign.target;
            if (target->kind == EXPR_GET) {
                // Field mutation `o.f = v` (and nested `o.i.v = v`, which writes back through
                // inline struct fields — value-types 3b.5). OP_SET_FIELD consumes receiver +
                // value (a statement, leaves nothing).
                gen_nested_store(cg, target, -1, s->as.assign.value);
                break;
            }
            if (target->kind == EXPR_INDEX) {
                // Element mutation `a[i] = v`: push the array, the index, then the
                // value; OP_SET_INDEX bounds-checks, releases the old element, and
                // stores the new one (a statement — it leaves nothing behind).
                gen_expr(cg, target->as.index.object);
                gen_expr(cg, target->as.index.index);
                gen_expr(cg, s->as.assign.value);
                emit(cg, OP_SET_INDEX);
                break;
            }
            int slot = resolve_local(cg, target->as.ident);
            gen_expr(cg, s->as.assign.value);
            if (slot < 0) {
                internal_error(cg, "assignment to an unresolved variable");
            } else {
                // Release the value the slot held before overwriting it, so
                // reassigning a `var` that owns a struct/refcounted value does not
                // leak the old one. The new value is already on the stack (computed
                // first, so `s = s + x` still reads the old `s`); a moved-out slot
                // was nilled, making this a no-op there.
                if (cg->local_drop[slot]) {
                    emit(cg, OP_DROP);
                    emit_idx(cg, slot);
                }
                emit(cg, OP_SET_LOCAL);
                emit_idx(cg, slot);
                emit(cg, OP_POP);   // assignment is a statement: discard the value
            }
            break;
        }

        case STMT_IF: {
            // cond on stack; jump over the then-branch if it is false. The
            // non-popping JUMP_IF_FALSE means each path pops the condition.
            gen_expr(cg, s->as.if_.cond);
            int else_jump = emit_jump(cg, OP_JUMP_IF_FALSE);
            emit(cg, OP_POP);                       // true path: discard cond
            gen_block(cg, &s->as.if_.then_blk);
            int end_jump = emit_jump(cg, OP_JUMP);
            patch_jump(cg, else_jump);
            emit(cg, OP_POP);                       // false path: discard cond
            if (s->as.if_.else_branch != NULL) {
                gen_stmt(cg, s->as.if_.else_branch);
            }
            patch_jump(cg, end_jump);
            break;
        }

        case STMT_BLOCK:
            gen_block(cg, &s->as.block.body);
            break;

        case STMT_LOOP: {
            if (cg->loop_depth >= MAX_LOOP_DEPTH) {
                internal_error(cg, "loops nested too deeply");
                break;
            }
            LoopCtx *ctx = &cg->loops[cg->loop_depth++];
            ctx->start           = cg->chunk->code_len;   // `continue` target
            ctx->break_count     = 0;
            ctx->locals_at_entry = cg->local_count;
            gen_block(cg, &s->as.loop.body);
            emit_loop(cg, ctx->start);                 // back-edge
            // Patch every `break` to land just past the back-edge (loop exit).
            for (int i = 0; i < ctx->break_count; i++) {
                patch_jump(cg, ctx->breaks[i]);
            }
            cg->loop_depth--;
            break;
        }

        case STMT_BREAK: {
            if (cg->loop_depth == 0) {
                internal_error(cg, "break outside a loop");
                break;
            }
            LoopCtx *ctx = &cg->loops[cg->loop_depth - 1];
            if (ctx->break_count >= MAX_BREAKS) {
                internal_error(cg, "too many breaks in one loop");
                break;
            }
            // Release and pop any loop-body locals in scope before leaving the loop.
            emit_drops_and_pops(cg, ctx->locals_at_entry);
            ctx->breaks[ctx->break_count++] = emit_jump(cg, OP_JUMP);
            break;
        }

        case STMT_CONTINUE:
            if (cg->loop_depth == 0) {
                internal_error(cg, "continue outside a loop");
            } else {
                LoopCtx *ctx = &cg->loops[cg->loop_depth - 1];
                // Release and pop loop-body locals before jumping back to the top.
                emit_drops_and_pops(cg, ctx->locals_at_entry);
                emit_loop(cg, ctx->start);
            }
            break;

        case STMT_MATCH: {
            // Evaluate the scrutinee once into an anonymous "subject" slot the
            // case tests and field bindings read from.
            gen_expr(cg, s->as.match.value);
            int subj_lc = cg->local_count;            // logical index, for unwind
            int subject = cg_declare(cg, "", 0, 1);   // physical slot of the subject

            int end_jumps[MAX_MATCH_CASES];
            int end_count = 0;
            for (size_t k = 0; k < s->as.match.case_count; k++) {
                MatchCase *mc = &s->as.match.cases[k];
                if (mc->pattern.wildcard) {
                    // A catch-all always matches: no tag test. Reaching here means
                    // no earlier case matched, so run the body and jump to the end.
                    int wbase = cg->local_count;
                    for (size_t i = 0; i < mc->body.count; i++) {
                        gen_stmt(cg, mc->body.stmts[i]);
                    }
                    emit_drops_and_pops(cg, wbase);
                    cg_unwind(cg, wbase);
                    if (end_count < MAX_MATCH_CASES) {
                        end_jumps[end_count++] = emit_jump(cg, OP_JUMP);
                    }
                    continue;
                }
                // Dispatch on the checker-resolved tag (scrutinee-directed; not a by-name lookup
                // that could hit a same-named variant of another enum — OFI-073).
                int vtag = mc->pattern.variant_index;
                if (vtag < 0) {
                    const CgVariant *v = resolve_cgvariant(cg, mc->pattern.variant);
                    if (v == NULL) {
                        internal_error(cg, "an unresolved match variant");
                        continue;
                    }
                    vtag = v->variant_index;
                }
                // if subject.tag == this variant:
                emit(cg, OP_GET_LOCAL);
                emit_idx(cg, subject);
                emit(cg, OP_GET_TAG);
                emit_const(cg, vtag);
                emit(cg, OP_EQ);
                int next = emit_jump(cg, OP_JUMP_IF_FALSE);
                emit(cg, OP_POP);   // matched (true path)

                // Bind the variant's fields positionally as case-local values.
                int bind_base = cg->local_count;
                for (size_t b = 0; b < mc->pattern.binding_count; b++) {
                    emit(cg, OP_GET_LOCAL);
                    emit_idx(cg, subject);
                    emit(cg, OP_GET_FIELD);
                    emit_idx(cg, b);
                    // A pattern binding borrows a field of the subject (which still
                    // owns it) — never freed here, else it double-frees.
                    cg_declare(cg, mc->pattern.bindings[b], 0, 1);
                }
                for (size_t i = 0; i < mc->body.count; i++) {
                    gen_stmt(cg, mc->body.stmts[i]);
                }
                // Release and pop the pattern bindings and any case-body locals.
                emit_drops_and_pops(cg, bind_base);
                cg_unwind(cg, bind_base);

                if (end_count < MAX_MATCH_CASES) {
                    end_jumps[end_count++] = emit_jump(cg, OP_JUMP);
                }
                patch_jump(cg, next);
                emit(cg, OP_POP);   // matched (false path)
            }
            for (int j = 0; j < end_count; j++) {
                patch_jump(cg, end_jumps[j]);
            }
            // A scrutinee that was a fresh refcounted temporary (e.g. `match
            // recv(ch)`) is released here, on the fall-through path, before its
            // slot is popped — reclaiming the value the channel handed over.
            if (s->as.match.subject_drop) {
                emit(cg, OP_DROP);
                emit_idx(cg, subject);
            }
            emit(cg, OP_POP);   // drop the subject
            cg_unwind(cg, subj_lc);
            break;
        }

        case STMT_EXPR:
            // Run the call for its effect, then discard the value it leaves —
            // releasing it if it was a fresh refcounted temporary.
            gen_expr(cg, s->as.expr.expr);
            emit(cg, s->as.expr.release_temp ? OP_RELEASE : OP_POP);
            break;

        case STMT_FOR: {
            // Two forms, each lowered to a *fused* iteration opcode so the per-
            // iteration overhead is one instruction (increment + bound check, and
            // for arrays the element fetch) rather than the ~10 of a hand-written
            // loop. The loop variable is the index for a range; for an array it is a
            // hidden slot the opcode rebinds each step. The index is initialised to
            // lo-1 / -1 and pre-incremented, so `continue` (a back-edge to the fused
            // op) advances it correctly.
            if (cg->loop_depth >= MAX_LOOP_DEPTH) {
                internal_error(cg, "for nested too deeply");
                break;
            }
            int range_form = (s->as.for_.iter->kind == EXPR_RANGE);
            int hidden;        // number of hidden slots to pop after the loop
            int exit_jump;
            LoopCtx *ctx;
            int loop_base = cg->local_count;   // logical index to unwind to after the loop

            if (range_form) {
                // i = lo - 1   (the loop variable doubles as the index)
                gen_expr(cg, s->as.for_.iter->as.range.lo);
                emit_const(cg, 1);
                emit(cg, OP_SUB);  emit(cg, 0);   // lo - 1 (i64; traps if lo==INT64_MIN)
                int i_slot = cg_declare(cg, s->as.for_.var, 0, 1);   // loop var = index
                gen_expr(cg, s->as.for_.iter->as.range.hi);          // end
                int end_slot = cg_declare(cg, "", 0, 1);
                hidden = 2;

                ctx = &cg->loops[cg->loop_depth++];
                ctx->break_count     = 0;
                ctx->locals_at_entry = cg->local_count;
                ctx->start           = cg->chunk->code_len;   // loop top / `continue`

                emit(cg, OP_FOR_RANGE);
                emit_idx(cg, i_slot);
                emit_idx(cg, end_slot);
                emit(cg, 0xff); emit(cg, 0xff);
                exit_jump = (int)(cg->chunk->code_len - 2);
            } else {
                gen_expr(cg, s->as.for_.iter);                    // the array
                int arr_slot = cg_declare(cg, "", 0, 1);
                emit_const(cg, -1);                               // index
                // For `for (i, x) in arr` the index is the user's `i`; OP_FOR_ARRAY
                // increments it each step (it starts at -1, so the body sees 0, 1, …).
                int idx_slot = cg_declare(cg,
                    s->as.for_.index_var ? s->as.for_.index_var : "", 0, 1);
                emit(cg, OP_GET_LOCAL); emit_idx(cg, arr_slot);
                emit(cg, OP_ARRAY_LEN);                           // length, cached once
                int len_slot = cg_declare(cg, "", 0, 1);
                emit_const(cg, 0);                                // loop-var placeholder
                int var_slot = cg_declare(cg, s->as.for_.var, 0, 1);  // borrowed element
                hidden = 4;

                ctx = &cg->loops[cg->loop_depth++];
                ctx->break_count     = 0;
                ctx->locals_at_entry = cg->local_count;
                ctx->start           = cg->chunk->code_len;

                emit(cg, OP_FOR_ARRAY);
                emit_idx(cg, arr_slot);
                emit_idx(cg, idx_slot);
                emit_idx(cg, len_slot);
                emit_idx(cg, var_slot);
                emit(cg, 0xff); emit(cg, 0xff);
                exit_jump = (int)(cg->chunk->code_len - 2);
            }

            for (size_t i = 0; i < s->as.for_.body.count; i++) {
                gen_stmt(cg, s->as.for_.body.stmts[i]);
            }
            // Release and pop any body locals before the back-edge, so a value built
            // each iteration is reclaimed each iteration.
            emit_drops_and_pops(cg, ctx->locals_at_entry);
            cg_unwind(cg, ctx->locals_at_entry);
            emit_loop(cg, ctx->start);   // back to the fused op (which `continue` targets)

            patch_jump(cg, exit_jump);
            for (int i = 0; i < ctx->break_count; i++) {
                patch_jump(cg, ctx->breaks[i]);
            }
            cg->loop_depth--;
            for (int i = 0; i < hidden; i++) {
                emit(cg, OP_POP);   // drop the loop var + hidden index/end/len/array
            }
            cg_unwind(cg, loop_base);
            break;
        }

        case STMT_NURSERY:
            // Open a task group, run the body (which spawns into it), then join.
            emit(cg, OP_NURSERY_BEGIN);
            gen_block(cg, &s->as.nursery.body);
            emit(cg, OP_NURSERY_END);
            break;

        case STMT_SPAWN: {
            // spawn f(args) — push any witnesses + the arguments, then create a task fiber
            // for f. A spawn uses the SAME calling convention as a direct OP_CALL, so it must
            // mirror its generic handling: resolve a generic target to its monomorphized slot
            // and push the bound witnesses. Without this, spawning a bounded generic function
            // spawned the base slot with no witnesses and the fiber crashed (read garbage).
            const Expr *call = s->as.spawn.call;
            int idx = call->as.call.resolved_fn;   // resolved by the checker
            if (call->as.call.mono_arg_count > 0) {
                int mono = mono_resolve(cg, call);
                if (mono >= 0) {
                    idx = mono;
                }
            }
            if (idx < 0) {
                internal_error(cg, "spawn of an unresolved function");
                break;
            }
            // Bounded generic: one witness per (type parameter, bound) as hidden leading
            // arguments, in callee order — identical to the direct-call path's witness build.
            int extra = 0;
            for (int w = 0; w < call->as.call.witness_total; w++) {
                const Witness *wit = &call->as.call.witnesses[w];
                for (int m = 0; m < wit->count; m++) {
                    emit_const(cg, wit->fns[m]);
                }
                emit(cg, OP_NEW_ENUM);
                emit_idx(cg, 0);                                  // dummy type id
                emit_idx(cg, 0);                                  // dummy variant tag
                emit_idx(cg, wit->count);
                extra++;
            }
            // Args follow the same multi-slot convention as a direct call: a plain all-scalar
            // struct arg is pushed as its field slots, so the spawned fiber's frame size (the
            // count below) is the SLOT total — witnesses + arg slots — not the arg count (3b.4).
            // No drop-mask: the fiber takes ownership of the arguments, so the spawner never
            // drops them (unlike a direct call, which keeps borrowing temps live past the call).
            const int *ais = call->as.call.arg_inline_struct;
            int built = 0;
            for (size_t i = 0; i < call->as.call.arg_count; i++) {
                built += gen_arg(cg, call->as.call.args[i], ais ? ais[i] : -1);
            }
            emit(cg, OP_SPAWN);
            emit_fn_index(cg, idx);
            emit_idx(cg, built + extra);
            break;
        }
    }
}





// gen_block lowers a block's statements, then pops any block-local bindings it
// declared so the value stack returns to its pre-block depth. (A `return` or
// `break` inside the block jumps away first, making these trailing pops dead
// code on those paths — those statements emit their own pops.)
static void gen_block(Codegen *cg, const Block *b) {
    int saved = cg->local_count;
    for (size_t i = 0; i < b->count; i++) {
        gen_stmt(cg, b->stmts[i]);
    }
    // Bindings leave scope at the closing brace; free any that own a value before
    // discarding their slots. On a path that returned out of this block these are
    // unreachable, so nothing is freed twice — the return emitted its own drops.
    emit_drops_and_pops(cg, saved);
    cg_unwind(cg, saved);
}





// dup_str returns a heap copy of `s`; the CompiledProgram owns function names so
// it does not depend on the parse arena outliving it. Fatal on OOM.
static char *dup_str(const char *s) {
    size_t n = strlen(s);
    char *p = malloc(n + 1);
    if (p == NULL) {
        fprintf(stderr, "emberc: out of memory\n");
        exit(70);
    }
    memcpy(p, s, n + 1);
    return p;
}





// mangle returns a heap "Struct.method" name for a method's function-table slot,
// so disassembly and traces show which type a method belongs to. Fatal on OOM.
static char *mangle(const char *type_name, const char *method_name) {
    size_t a = strlen(type_name);
    size_t b = strlen(method_name);
    char *p = malloc(a + 1 + b + 1);
    if (p == NULL) {
        fprintf(stderr, "emberc: out of memory\n");
        exit(70);
    }
    memcpy(p, type_name, a);
    p[a] = '.';
    memcpy(p + a + 1, method_name, b + 1);
    return p;
}





// compile_function lowers one function body into program->functions[index].chunk.
// Parameters are registered as locals 0..arity-1 (no init code — they arrive on
// the stack as the call's arguments). A trailing `return 0` guarantees the
// function always halts even if control falls off the end.
static int compile_function(CompiledProgram *program, int index,
                            const FnDecl *fn, const char *src,
                            const CgStruct *structs, int struct_count,
                            const CgVariant *variants, int variant_count,
                            const MonoPlan *plan) {
    Codegen cg;
    cg.chunk         = &program->functions[index].chunk;
    cg.src           = src;
    cg.had_error     = 0;
    cg.prog          = program;
    cg.structs       = structs;
    cg.struct_count  = struct_count;
    cg.variants      = variants;
    cg.variant_count = variant_count;
    cg.locals        = NULL;
    cg.locals_cap    = 0;
    cg.local_drop    = NULL;
    cg.local_phys    = NULL;
    cg.local_span    = NULL;
    cg.local_struct  = NULL;
    cg.local_count   = 0;
    cg.phys_count    = 0;
    cg.ret_struct_id = fn->ret_struct_id;   // value-types 3b.4b: multi-slot struct return
    cg.current_line  = fn->line;
    cg.loop_depth    = 0;
    cg.plan          = plan;
    cg.cur_slot      = index;
    cg.fn_name         = fn->name;
    cg.ensures_clauses = fn->ensures_clauses;
    cg.ensures_count   = fn->ensures_count;

    // A bounded generic function receives one witness (the bound interface's method
    // table for the concrete type) per (type parameter, bound) as hidden leading
    // arguments, in order: param0's bounds, then param1's, … The real parameters shift
    // up by that many slots. The call site pushes them in the same order.
    for (size_t g = 0; g < fn->generic_count; g++) {
        for (int b = 0; b < fn->generics[g].bound_count; b++) {
            cg_declare(&cg, "$witness", 0, 1);   // unmatchable name
        }
    }

    // A refcounted parameter (string/array/enum) carries a reference the callee
    // releases on return; the checker marks it. Other params (borrows, or `move`
    // structs owned by the caller's transfer) are not freed here.
    for (size_t i = 0; i < fn->param_count; i++) {
        int psid = fn->params[i].inline_struct_id;
        if (psid >= 0) {
            // A multi-slot struct parameter: it arrives as its N field slots (the caller
            // pushed them), declared like a multi-slot local — field access reads a slot,
            // a whole-value read boxes on use, and all-scalar ⇒ nothing to drop (3b.4).
            int n = cg_slot_span(&cg, psid);
            cg_declare(&cg, fn->params[i].name, 0, n);
            cg.local_struct[cg.local_count - 1] = psid;
        } else {
            cg_declare(&cg, fn->params[i].is_self ? "self" : fn->params[i].name,
                       fn->params[i].release_at_exit, 1);
        }
    }

    // Preconditions (MANIFESTO §5e): check each `requires` predicate on entry, with
    // the parameters in scope and before the body runs. Evaluating the bool leaves it
    // on the stack; OP_CONTRACT_CHECK pops it and aborts with the message if it is
    // false. A release build elides the whole check (zero cost).
    for (size_t i = 0; !codegen_release_profile && i < fn->requires_count; i++) {
        gen_expr(&cg, fn->requires_clauses[i]);
        char msg[200];
        int n = snprintf(msg, sizeof msg,
                         "precondition failed in '%s' (requires, line %d)",
                         fn->name, fn->requires_clauses[i]->line);
        size_t midx = chunk_add_string(cg.chunk, msg, (size_t)(n > 0 ? n : 0));
        emit(&cg, OP_CONTRACT_CHECK);
        emit_idx(&cg, midx);
    }

    for (size_t i = 0; i < fn->body.count; i++) {
        gen_stmt(&cg, fn->body.stmts[i]);
    }
    // Falling off the end is an implicit `return 0`; like any return it must first
    // check postconditions (a unit `mut self` method asserting a state invariant
    // reaches its `ensures` here, not via an explicit return), then release the
    // still-owned bindings in scope (params and body locals). A multi-slot-returning
    // function emits the matching multi-slot form (N dummy field slots) so the calling
    // convention stays consistent even on this safety-net path (value-types 3b.4b).
    if (cg.ret_struct_id >= 0) {
        int n = cg_slot_span(&cg, cg.ret_struct_id);
        for (int i = 0; i < n; i++) {
            emit_const(&cg, 0);
        }
        emit_ensures_checks(&cg);
        emit_return_drops(&cg);
        emit(&cg, OP_RETURN_STRUCT);
        emit_idx(&cg, n);
    } else {
        emit_const(&cg, 0);
        emit_ensures_checks(&cg);
        emit_return_drops(&cg);
        emit(&cg, OP_RETURN);
    }

    // Verification loop (§5j): mark this function fuzzable by `--check` if it is a free,
    // non-generic function with a falsifiable postcondition (`ensures`) whose 1..N parameters are
    // each a scalar or an all-scalar (multi-slot) struct. Record the flat leaf kinds to generate
    // and the per-parameter grouping (kind + leaf count) so the reporter can rebuild arguments.
    Function *F = &program->functions[index];
    F->checkable   = 0;
    F->param_count = 0;
    F->leaf_count  = 0;
    if (fn->ensures_count > 0 && fn->generic_count == 0 && fn->param_count >= 1 &&
        fn->param_count <= CHECK_MAX_PARAMS && !fn->params[0].is_self) {
        int ok     = 1;
        int leaves = 0;
        for (size_t i = 0; i < fn->param_count; i++) {
            int psid = fn->params[i].inline_struct_id;
            const Type *pt = fn->params[i].type;
            char ek; unsigned char eaek;
            if (psid >= 0) {
                int before = leaves;
                if (!fuzz_flatten_struct(&cg, psid, F->leaf_kind, &leaves, CHECK_MAX_LEAVES)) {
                    ok = 0;
                    break;
                }
                F->param_kind[i]   = 's';
                F->param_leaves[i] = leaves - before;
            } else if (pt != NULL && pt->kind == TYPE_ARRAY &&
                       fn->params[i].qual == OWN_NONE &&
                       fuzz_array_elem(pt->as.array.elem, &ek, &eaek)) {
                // An immutable-borrow array of full-width scalars: a single boxed-slot leaf the
                // fuzzer fills with a generated array (borrow ⇒ not freed/mutated across re-runs).
                if (leaves >= CHECK_MAX_LEAVES) {
                    ok = 0;
                    break;
                }
                F->param_kind[i]       = 'a';
                F->param_leaves[i]     = 1;
                F->leaf_elem[leaves]   = ek;
                F->leaf_aek[leaves]    = eaek;
                F->leaf_kind[leaves++] = 'a';
            } else {
                char k = fuzz_param_kind(pt);
                if (k == 0 || leaves >= CHECK_MAX_LEAVES) {
                    ok = 0;
                    break;
                }
                F->param_kind[i]       = k;
                F->param_leaves[i]     = 1;
                F->leaf_kind[leaves++] = k;
            }
        }
        if (ok) {
            F->checkable   = 1;
            F->param_count = (int)fn->param_count;
            F->leaf_count  = leaves;
        }
    }

    free(cg.locals);
    free(cg.local_drop);
    free(cg.local_phys);
    free(cg.local_span);
    free(cg.local_struct);
    return cg.had_error;
}





// structtype_alloc_fields mallocs a runtime StructType's per-field layout arrays, sized to `n` (no
// EMBER_MAX_FIELDS cap). Owned by the CompiledProgram; released by compiled_program_free.
static void structtype_alloc_fields(StructType *st, int n) {
    int m = n > 0 ? n : 1;
    st->offset       = malloc((size_t)m * sizeof(int));
    st->kind         = malloc((size_t)m * sizeof(int));
    st->field_struct = malloc((size_t)m * sizeof(int));
    if (st->offset == NULL || st->kind == NULL || st->field_struct == NULL) {
        fprintf(stderr, "emberc: out of memory building a struct layout\n");
        exit(70);
    }
}


// alloc_field_names mallocs a CgStruct's field-name vector, sized to `n` (no cap).
static const char **alloc_field_names(int n) {
    const char **names = malloc((size_t)(n > 0 ? n : 1) * sizeof(const char *));
    if (names == NULL) {
        fprintf(stderr, "emberc: out of memory building a struct's field names\n");
        exit(70);
    }
    return names;
}


// free_cg_structs releases the compile-time struct table and each entry's field-name vector.
static void free_cg_structs(CgStruct *cg_structs, int n) {
    if (cg_structs == NULL) {
        return;
    }
    for (int i = 0; i < n; i++) {
        free(cg_structs[i].field_names);
    }
    free(cg_structs);
}


int codegen_program(const Program *ast, const ModuleSet *modules,
                    const MonoPlan *plan, const StructLayout *layouts,
                    int layout_count, CompiledProgram *out,
                    const char *source_name) {
    (void)modules;   // codegen uses the checker's resolved_fn; merged decls suffice
    compiled_program_init(out);

    // Functions and struct methods share one table, numbered together in
    // declaration order (the checker uses the same order to resolve method calls).
    int total_functions = 0;
    int struct_count = 0;
    int total_variants = 0;
    for (size_t i = 0; i < ast->count; i++) {
        const Decl *d = ast->decls[i];
        if (d->kind == DECL_FN) {
            total_functions++;
        } else if (d->kind == DECL_STRUCT) {
            struct_count++;
            total_functions += (int)d->as.struct_.method_count;
        } else if (d->kind == DECL_ENUM) {
            total_variants += (int)d->as.enum_.variant_count;
        }
    }
    if (total_functions == 0) {
        fprintf(stderr, "%s: error: program has no functions\n", source_name);
        return 1;
    }

    // Monomorphization (append model): the table holds the declared functions
    // (slots 0..total_functions-1) plus one appended slot per generic instance.
    int total_slots = plan->total_slots > total_functions ? plan->total_slots
                                                           : total_functions;
    out->functions = malloc((size_t)total_slots * sizeof(Function));
    if (out->functions == NULL) {
        fprintf(stderr, "emberc: out of memory\n");
        exit(70);
    }
    memset(out->functions, 0, (size_t)total_slots * sizeof(Function));   // checkable=0 default
    out->count = total_slots;

    // The struct-type table: runtime descriptors in `out->structs` (owned names),
    // and the compile-time layout `cg_structs` (field names, borrowed from the
    // AST — used only during this call). Indices match across both and the
    // checker, since all are built in DECL_STRUCT order.
    // The table holds the declared structs plus the appended monomorphized generic
    // struct instances (Box<int>) the checker found — layout_count covers both.
    int total_structs = layout_count > struct_count ? layout_count : struct_count;
    CgStruct *cg_structs = NULL;
    if (total_structs > 0) {
        out->structs = malloc((size_t)total_structs * sizeof(StructType));
        cg_structs   = malloc((size_t)total_structs * sizeof(CgStruct));
        if (out->structs == NULL || cg_structs == NULL) {
            fprintf(stderr, "emberc: out of memory\n");
            exit(70);
        }
        out->struct_count = total_structs;
    }

    int si = 0;
    for (size_t i = 0; i < ast->count; i++) {
        const Decl *d = ast->decls[i];
        if (d->kind != DECL_STRUCT) {
            continue;
        }
        int nf = (int)d->as.struct_.field_count;   // DECLARED (named) fields
        // The runtime layout's field_count may EXCEED nf: a bounded generic struct has
        // hidden witness fields appended (instance-storage). Use the layout's count so the
        // VM allocates/fills/drops every slot; cg_structs keeps the user count for naming.
        int lf = (si < layout_count) ? layouts[si].field_count : nf;
        out->structs[si].name        = dup_str(d->as.struct_.name);
        out->structs[si].field_count = lf;
        structtype_alloc_fields(&out->structs[si], lf);
        // Copy the checker's packed layout (same struct-id order).
        if (si < layout_count) {
            out->structs[si].total_size = layouts[si].total_size;
            for (int f = 0; f < lf; f++) {
                out->structs[si].offset[f]       = layouts[si].offset[f];
                out->structs[si].kind[f]         = layouts[si].kind[f];
                out->structs[si].field_struct[f] = layouts[si].field_struct[f];
            }
        }
        cg_structs[si].name          = d->as.struct_.name;
        cg_structs[si].field_count   = nf;   // user fields only (the named ones)
        cg_structs[si].field_names   = alloc_field_names(nf);
        for (int f = 0; f < nf; f++) {
            cg_structs[si].field_names[f] = d->as.struct_.fields[f].name;
        }
        si++;
    }

    // Appended monomorphized generic struct instances: same name + field names as
    // the base struct (layouts[id].base_id), but the instance's own packed layout.
    for (int id = struct_count; id < layout_count; id++) {
        int b = layouts[id].base_id;
        out->structs[id].name        = dup_str(out->structs[b].name);
        out->structs[id].field_count = layouts[id].field_count;
        out->structs[id].total_size  = layouts[id].total_size;
        structtype_alloc_fields(&out->structs[id], layouts[id].field_count);
        for (int f = 0; f < layouts[id].field_count; f++) {
            out->structs[id].offset[f]       = layouts[id].offset[f];
            out->structs[id].kind[f]         = layouts[id].kind[f];
            out->structs[id].field_struct[f] = layouts[id].field_struct[f];
        }
        cg_structs[id].name        = cg_structs[b].name;
        cg_structs[id].field_count = cg_structs[b].field_count;
        cg_structs[id].field_names = alloc_field_names(cg_structs[b].field_count);
        for (int f = 0; f < cg_structs[b].field_count; f++) {
            cg_structs[id].field_names[f] = cg_structs[b].field_names[f];
        }
    }

    // The enum variant table (compile-time only): every variant of every enum,
    // numbered by DECL_ENUM order — `enum_id` matches the checker and is the
    // OP_NEW_ENUM type id.
    CgVariant *cg_variants = NULL;
    if (total_variants > 0) {
        cg_variants = malloc((size_t)total_variants * sizeof(CgVariant));
        if (cg_variants == NULL) {
            fprintf(stderr, "emberc: out of memory\n");
            exit(70);
        }
    }
    int ei = 0;   // enum id (DECL_ENUM order)
    int vix = 0;  // running index into cg_variants
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

    // Map each base function-table index (free functions + struct methods, in
    // declaration order) to its FnDecl and — for a method — its struct name, so
    // both base slots and the appended generic-instance slots can be filled.
    const FnDecl **fn_by_fi    = malloc((size_t)total_functions * sizeof(FnDecl *));
    const char   **struct_of   = malloc((size_t)total_functions * sizeof(char *));
    if (fn_by_fi == NULL || struct_of == NULL) {
        fprintf(stderr, "emberc: out of memory\n");
        exit(70);
    }
    int fi = 0;
    for (size_t i = 0; i < ast->count; i++) {
        const Decl *d = ast->decls[i];
        if (d->kind == DECL_FN) {
            fn_by_fi[fi]  = &d->as.fn;
            struct_of[fi] = NULL;
            fi++;
        } else if (d->kind == DECL_STRUCT) {
            for (size_t m = 0; m < d->as.struct_.method_count; m++) {
                fn_by_fi[fi]  = &d->as.struct_.methods[m];
                struct_of[fi] = d->as.struct_.name;
                fi++;
            }
        }
    }

    // Populate every slot — declared functions in place, generic instances in the
    // appended slots (each compiles its base FnDecl; the body's call targets are
    // redirected per the plan). A method's name is mangled "Struct.method".
    for (int s = 0; s < total_slots; s++) {
        int b = plan->base_of[s];
        const FnDecl *fn = fn_by_fi[b];
        out->functions[s].name  = struct_of[b] != NULL ? mangle(struct_of[b], fn->name)
                                                       : dup_str(fn->name);
        out->functions[s].arity = (int)fn->param_count;
        chunk_init(&out->functions[s].chunk);
    }
    out->main_index = plan->main_index;
    if (out->main_index < 0) {
        fprintf(stderr, "%s: error: no 'main' function to run\n", source_name);
        free_cg_structs(cg_structs, total_structs);
        free(cg_variants);
        free(fn_by_fi);
        free(struct_of);
        return 1;
    }

    // Compile every slot's body, redirecting generic calls to instance slots.
    int error = 0;
    for (int s = 0; s < total_slots; s++) {
        error |= compile_function(out, s, fn_by_fi[plan->base_of[s]], source_name,
                                  cg_structs, total_structs,
                                  cg_variants, total_variants, plan);
    }

    free_cg_structs(cg_structs, total_structs);   // OFI-104: also frees each entry's field_names (matches the error path)
    free(cg_variants);
    free(fn_by_fi);
    free(struct_of);
    return error;
}
