#ifndef EMBER_RT_H
#define EMBER_RT_H

// The Ember native runtime, the support library that compiled-to-C Ember programs
// link against (the `emberc --emit=c` / `emberc -o` backend, docs/architecture.md
// "Decision: native backend"). It is the COUNTERPART to the bytecode VM: the VM is
// Ember's reference semantics, and this header re-expresses those same semantics as
// ordinary C so generated straight-line code produces bit-identical results (the
// differential test in tests/native/ is what holds the two in lockstep).
//
// Milestone M1 (the scalar walking skeleton) is header-only: it needs only the
// uniform `Value` and the width-aware arithmetic. Heap objects, drop, builtins, FFI
// and concurrency arrive with M2+ as a real libember_rt extracted from src/vm.c.
//
// Every helper here MIRRORS a VM opcode handler in src/vm.c — keep them in step:
//   em_add/sub/mul        ← OP_ADD/OP_SUB/OP_MUL          (ARITH, trap on overflow)
//   em_wrap_add/sub/mul   ← OP_WRAP_ADD/SUB/MUL           (WRAP, modulo 2^width)
//   em_div/em_mod         ← OP_DIV/OP_MOD                 (trap on /0 and width-leave)
//   em_neg/em_not/em_bitnot ← OP_NEG/OP_NOT/OP_BITNOT
//   em_bitand/or/xor      ← OP_BITAND/OP_BITOR/OP_BITXOR  (width-transparent)
//   em_shl/em_shr         ← OP_SHL/OP_SHR
//   em_eq/em_neq/em_lt/le/gt/ge ← OP_EQ/OP_NEQ/OP_LT/LE/GT/GE

#include "value.h"
#include "program.h"   // StructType (the struct-layout table EmberRt carries)

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

// ---- Object runtime model (shared by the VM and generated C; M2a) ----------
// The reference-count primitive and the recycle-pool size, authored ONCE here so
// the VM (src/vm.c) and the C backend's runtime (src/runtime.c) can't drift. Under
// -DEMBER_PARALLEL the count is atomic — the only contended heap field, since
// Ember's ownership model keeps user data race-free — else a plain inc/dec.
// OBJ_RELEASE returns the new count.
// EMBER_MN selects the M:N green-thread scheduler (OFI-071): many lightweight fibers multiplexed
// over a small worker pool, replacing the 1:1 pthread-per-spawn model. It is layered ON the
// EMBER_PARALLEL thread-safe heap (atomic refcounts, the shared graveyard), so it IMPLIES it — a
// lone -DEMBER_MN still gets the race-free heap. The `make mn` target passes both explicitly.
#ifndef EMBER_MN
#define EMBER_MN 0
#endif
#if EMBER_MN && !defined(EMBER_PARALLEL)
#define EMBER_PARALLEL 1
#endif
#ifndef EMBER_PARALLEL
#define EMBER_PARALLEL 0
#endif
#if EMBER_PARALLEL
#define OBJ_RETAIN(o)  ((void)__atomic_fetch_add(&(o)->refcount, 1, __ATOMIC_RELAXED))
#define OBJ_RELEASE(o) (__atomic_sub_fetch(&(o)->refcount, 1, __ATOMIC_ACQ_REL))
#else
#define OBJ_RETAIN(o)  ((void)((o)->refcount++))
#define OBJ_RELEASE(o) (--(o)->refcount)
#endif

#define POOL_CLASSES 16   // dead objects up to 16 * 16 = 256 bytes are pooled by size class

// EmberRt — the object runtime's per-context state: a private intrusive object list,
// a size-classed recycling pool, and the program's struct-layout table (which drives
// packed-field box/unbox and recursive drop). The VM embeds one (src/vm.c) and passes
// `&vm->rt`; a compiled program declares one global and passes `&g_em`. Carrying the
// struct table here — instead of reaching through a CompiledProgram — is what lets the
// extracted runtime link into a standalone binary with no front-end.
typedef struct EmberRt {
    Obj              *objects;             // this context's live-object list (lock-free, same-thread)
    Obj              *pool[POOL_CLASSES];  // size-classed recycle freelist
    const StructType *structs;             // struct-layout table (indexed by struct type id)
    int               struct_count;
    // OFI-122: invoke an Ember function by its table index — args[0..] are its arguments, the result
    // is returned. Each backend sets this at startup (VM: a re-entrant interpreter call; native:
    // em_invoke). drop_value uses it to run a `resource`'s user `drop(self)` during teardown. NULL
    // when unset (a program with no resources never needs it).
    Value           (*invoke)(struct EmberRt *ctx, int fn_index, Value *args);
} EmberRt;

// The object runtime (src/runtime.c). Allocators thread onto ctx->objects; drop and
// reclaim recycle into ctx->pool. All take an EmberRt, so one implementation serves
// both the VM (&vm->rt) and a generated binary (&g_em).
void           register_object(EmberRt *ctx, Obj *o);
void          *pooled_alloc(EmberRt *ctx, size_t size);
void           pooled_free(EmberRt *ctx, Obj *o);
void           unlink_object(EmberRt *ctx, Obj *o);
void           reclaim(EmberRt *ctx, Obj *o);
void           drop_value(EmberRt *ctx, Value v);
unsigned char *field_loc(EmberRt *ctx, ObjStruct *s, int index, int *kind);
int            field_inline_sid(EmberRt *ctx, const ObjStruct *s, int index);
void           struct_elem_retain(EmberRt *ctx, int struct_id, unsigned char *p);
void           struct_elem_release(EmberRt *ctx, int struct_id, unsigned char *p);
// Give a value to a NEW owner: clone a unique-owner aggregate (struct/array), retain a refcounted
// value (own_into_slot) or leave it a borrow (clone_owned_else_borrow). See runtime.c (OFI-062/063).
Value          own_into_slot(EmberRt *ctx, Value v);
Value          clone_owned_else_borrow(EmberRt *ctx, Value v);
Value          alloc_instance(EmberRt *ctx, int type_id, int tag, int is_enum, int field_count);
ObjString     *make_string(EmberRt *ctx, size_t length);
Value          alloc_array(EmberRt *ctx, size_t length, uint8_t elem_kind);
Value          alloc_slice(EmberRt *ctx, ObjArray *src, size_t lo, size_t hi);
Value          alloc_struct_array(EmberRt *ctx, size_t length, int struct_id);
Value          alloc_interface(EmberRt *ctx, Value receiver, Value vtable);
void           free_list(Obj *o);
void           drain_pool(Obj *pool[POOL_CLASSES]);
void           rt_free_objects(EmberRt *ctx);

// Boxed enum aggregates the C backend emits calls to: em_enum constructs a variant
// (refcounted); em_enum_field borrows a payload field for a match binding. The variant
// tag for match dispatch is read inline.
Value          em_enum(EmberRt *ctx, int enum_id, int variant, int n, ...);
Value          em_enum_field(EmberRt *ctx, Value v, int index);
// Like em_enum_field but TRANSFERS ownership (the native `?`-extract, OFI-122): a unique-owner
// aggregate payload is moved out (the enum slot nil'd); a refcounted one is shared via a retain.
Value          em_enum_take(EmberRt *ctx, Value v, int index);
// Read a NESTED INLINE-STRUCT field of a boxed struct — materialises a fresh OWNED boxed copy
// (value semantics; the caller drops it). Mirrors the VM's OP_GET_FIELD inline-struct branch.
Value          em_struct_field_inline(EmberRt *ctx, Value v, int index);
// Read field `index` as an OWNED value (materialise inline / retain heap / copy scalar) so an
// erased bound-method operand can be uniformly dropped after an indirect call (OFI-054).
Value          em_field_owned(EmberRt *ctx, Value v, int index);

static inline int em_tag(Value v) {
    return AS_STRUCT(v)->tag;
}

// Closures / function values (refcounted heap, like enums). em_closure builds an ObjClosure
// (a lifted function index + captured values, each retained); rt_call_closure invokes one,
// splicing [captures…, args…] and dispatching through `invoke` — the generated em_invoke that
// maps a function index to the concrete em_fn_<k>. drop_value already releases an ObjClosure.
Value          em_closure(EmberRt *ctx, int fn_index, int capture_count, ...);
Value          rt_call_closure(EmberRt *ctx, Value clo, int argc, const Value *args,
                               Value (*invoke)(EmberRt *, int, Value *));

// The value-struct <-> boxed bridge (for interface receivers and erased generics over a
// struct type). A FLAT value struct (no nested inline-struct fields) is a contiguous Value[]
// in C; em_box_struct packs it into a heap ObjStruct, em_unbox_struct reads it back.
Value          em_box_struct(EmberRt *ctx, int sid, const Value *fields, int n);
void           em_unbox_struct(EmberRt *ctx, int sid, Value boxed, Value *out, int n);

// A non-all-scalar struct (one with a heap field) is BOXED like the VM, not a value-type C
// struct: em_struct constructs it (moves fields in), em_set_field overwrites a field (dropping
// the old boxed value). Field reads use em_enum_field; drop_value releases it.
Value          em_struct(EmberRt *ctx, int sid, int n, ...);
void           em_set_field(EmberRt *ctx, Value structval, int idx, Value newval);
// Build-then-place construction of a boxed struct with a nested inline-struct field (OFI-054 A2):
// em_struct_empty allocates; em_struct_put_field MOVES a scalar/heap field in; em_struct_put_inline
// copies a boxed nested struct's packed bytes into the inline slot (reclaiming the source shell).
Value          em_struct_empty(EmberRt *ctx, int sid);
void           em_struct_put_field(EmberRt *ctx, Value structval, int idx, Value val);
void           em_struct_put_inline(EmberRt *ctx, Value structval, int idx, Value boxed_field);

// ---- Native concurrency (M4) — spawn / nursery / channels on real threads ----------
// Only emitted for programs that use concurrency, which forces the parallel build
// (-DEMBER_PARALLEL -lpthread); a serial native binary never reaches any of this. Mirrors the
// VM's threaded runtime: each spawned task runs on its own OS thread with a PRIVATE thread-local
// context (lock-free alloc), channels are pthread mutex + dual-condvar queues, and a per-nursery
// deadlock detector aborts a fully-blocked group. The deferred-channel reclaim + cross-thread
// free (Obj.home) machinery already in this runtime makes shared values safe.
#if EMBER_PARALLEL
#define EM_MAX_GROUP_FIBERS 256

// A nursery's structured task group + deadlock detector (the VM's `Nursery`).
typedef struct {
    int             total;
    pthread_mutex_t lock;
    int             nwaiting;
    int             deadlocked;
    ObjChannel     *waits_on[EM_MAX_GROUP_FIBERS];
    int             is_send[EM_MAX_GROUP_FIBERS];
    int             active[EM_MAX_GROUP_FIBERS];
} EmNursery;

// A recorded spawn: the function to run (by table index) with its OWNED argument values. The
// runtime fills `nursery`/`slot` (the deadlock-detector identity) when it launches the task.
typedef struct {
    int        fn_index;
    Value     *args;
    int        argc;
    EmNursery *nursery;
    int        slot;
} EmTask;

// The running thread's nursery context — read by a channel send/recv to register a block with
// the deadlock detector. NULL on a thread not running under a nursery.
extern _Thread_local EmNursery *em_cur_nursery;
extern _Thread_local int        em_cur_slot;

void  em_run_nursery(EmTask *tasks, int n, void *(*worker)(void *));  // launch one thread/task, join all
void  em_merge(EmberRt *self);          // splice a finished worker's arena into the shared graveyard
void  em_free_graveyard(void);          // main's exit sweep frees the merged-in (and deferred) objects
#endif

// Channels (the impl is parallel-only — a serial native binary never creates one). recv builds
// an Option<T> (Some(v) / None on a closed+drained channel), so it carries the enum's tags.
Value em_channel_new(EmberRt *ctx, int cap);
Value em_channel_send(EmberRt *ctx, Value ch, Value v);
Value em_channel_recv(EmberRt *ctx, Value ch, int enum_id, int some_tag, int none_tag);
Value em_channel_close(Value ch);

// Bounded-generic (interface-witness) dispatch (the VM's OP_CALL_INDIRECT): given a method's
// function index read out of a witness, call it — routing a built-in key type's Hash/Eq
// witness (index >= WITNESS_NATIVE_BASE) to the native shim, and a user method to em_invoke.
Value          rt_call_indirect(EmberRt *ctx, int64_t fnidx, int argc, const Value *args,
                                Value (*invoke)(EmberRt *, int, Value *));

// Hash any built-in key Value (string by FNV-1a, scalar by mixing its payload); non-negative.
// The C equivalent of NATIVE_HASH_ANY (em_value_eq below covers NATIVE_VALUE_EQ).
static inline Value em_hash_any(Value v) {
    uint64_t h;
    if (IS_STRING(v)) {
        ObjString *s = AS_STRING(v);
        h = 1469598103934665603ULL;
        for (size_t i = 0; i < s->length; i++) {
            h ^= (unsigned char)s->chars[i];
            h *= 1099511628211ULL;
        }
    } else {
        uint64_t x = (uint64_t)AS_INT(v);
        x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33;
        h = x;
    }
    return INT_VAL((int64_t)(h & 0x7fffffffffffffffULL));
}

// Heap arrays (move types): construction, bounds-checked index get/set, append; length
// is read inline. em_struct_array builds an array of INLINE value-struct elements (each arg a
// boxed ObjStruct whose packed bytes move into the buffer); em_index/em_array_append take the
// runtime ctx so they can materialise/reclaim an inline-struct element (a value-semantics copy
// on read, a move-in on append).
Value          em_array(EmberRt *ctx, int n, int elem_kind, ...);
Value          em_struct_array(EmberRt *ctx, int n, int struct_id, ...);
Value          em_index(EmberRt *ctx, Value arr, Value idx);
void           em_set_index(EmberRt *ctx, Value arr, Value idx, Value value);
Value          em_array_append(EmberRt *ctx, Value arr, Value value);

static inline Value em_array_len(Value arr) {
    return INT_VAL((int64_t)AS_ARRAY(arr)->length);
}

// Boxed strings (refcounted, immutable). em_str builds a literal; em_to_string renders a
// value for interpolation; em_print/em_println write a value to stdout and do NOT consume it
// (the VM's print reads, never drops — a named/var argument is freed by the checker's scope
// drop, a temp by the exit sweep). Concatenation is em_add (below). Byte length is read inline.
Value          em_str(EmberRt *ctx, const char *bytes, int len);
Value          em_to_string(EmberRt *ctx, Value v, int nk);
Value          em_print(EmberRt *ctx, Value v);
Value          em_println(EmberRt *ctx, Value v);

static inline Value em_str_len(Value v) {
    return INT_VAL((int64_t)AS_STRING(v)->length);
}


// UTF-8 (code-point granularity). Stateless decode/encode of ONE code point, lenient
// (invalid/overlong/surrogate/truncated → U+FFFD, consuming one byte). Shared by the VM
// and the runtime library's string methods.
int            utf8_decode(const unsigned char *s, size_t len, uint32_t *cp);
int            utf8_encode(uint32_t cp, unsigned char *out);

// String methods (M5), mirroring the VM's OP_STR_* — each allocates a fresh result:
//   em_str_chars   → [string] of code points       (OP_STR_CHARS)
//   em_str_split   → [string] split on a separator  (OP_STR_SPLIT; empty sep → [whole])
//   em_str_bytes   → [u8] of the raw bytes          (OP_STR_BYTES)
//   em_str_char_count → code-point count            (OP_STR_CHAR_COUNT)
//   em_str_parse_int  → Option<int> (Some/None tags carried, as recv) (OP_STR_PARSE_INT)
// The receiver is BORROWED (read, not consumed); the caller's drop discipline frees it.
Value          em_str_chars(EmberRt *ctx, Value sv);
Value          em_str_split(EmberRt *ctx, Value sv, Value sepv);
Value          em_str_bytes(EmberRt *ctx, Value sv);
Value          em_str_char_count(Value sv);
Value          em_str_parse_int(EmberRt *ctx, Value sv, int enum_id, int some_tag, int none_tag);

// Array methods (M5): em_array_pop removes + returns the last element (the array is mutated
// in place; a slice view is read-only → panic); em_array_slice copies arr[lo..hi] into a
// fresh owned array (heap elements retained). Mirror OP_ARRAY_POP / OP_SLICE_COPY.
Value          em_array_pop(EmberRt *ctx, Value arr);
Value          em_array_remove_at(EmberRt *ctx, Value arr, Value iv);  // remove + return element i
Value          em_array_slice(EmberRt *ctx, Value arr, Value lov, Value hiv);

// em_slice builds a borrowed Slice<T> view (zero-copy) over arr[lo..hi] — the VM's OP_SLICE.
// On drop only the slice header is freed (the buffer/elements belong to the frozen source).
Value          em_slice(EmberRt *ctx, Value arr, Value lov, Value hiv);

// Numeric conversions (M5): em_to_float int→float, em_to_int float→int (truncating),
// em_conv narrows/widens to numeric kind `nk` (trap on out-of-range, except u64 = kind 7
// which is a lossless bit-reinterpretation; kinds 8/9 = f32/f64 float targets). Mirror
// OP_INT_TO_FLOAT / OP_FLOAT_TO_INT / OP_CONV.
Value          em_to_float(Value v);
Value          em_to_int(Value v);
Value          em_conv(Value v, int nk);

// em_clock → monotonic seconds as a float (OP_CLOCK); native has no nondet capture, so it
// reads the real clock directly. em_assert traps (stderr + exit 70) on a false condition —
// native treats contracts as release-elided, but a bare `assert` stays a hard check.
Value          em_clock(void);
Value          em_assert(Value cond, const char *msg);

// Native builtins (M5): one dispatcher over the registry ids in builtin.h (read_line, file
// I/O, math via libm, char/parse helpers, concat, args/env/exit, …) — the print/println ids
// stay special-cased in the emitter (em_print/em_println). args() reads em_argc/em_argv,
// which the generated main() sets from its argv.
extern int     em_argc;
extern char  **em_argv;
Value          em_native(EmberRt *ctx, int nid, int argc, const Value *args);

// FFI (M5): invoke `extern "c"` function registry index `idx` through cextern_call. `args`
// are the call's flattened scalar leaves (one Value per scalar/string/buffer/Ptr arg); the
// result is the scalar leaf, or — when rsid >= 0 — a boxed struct reassembled from the leaves.
Value          em_ffi(EmberRt *ctx, int idx, int rsid, int argc, const Value *args);


// Numeric kinds, the one-byte operand the checker tags onto each arithmetic node:
//   0 i64, 1 i8, 2 i16, 3 i32, 4 u8, 5 u16, 6 u32, 7 u64, 8 f32.
// EM_NK_MIN/MAX bound a signed integer result to its width (kinds 0..6); kind 7 is
// unsigned (wrap-trapped at 2^64) and kind 8 rounds the float to 32 bits. These
// mirror NK_MIN/NK_MAX in src/vm.c byte-for-byte.
static const int64_t EM_NK_MIN[7] __attribute__((unused)) = {
    INT64_MIN, -128, -32768, -2147483648LL, 0, 0, 0
};
static const int64_t EM_NK_MAX[7] __attribute__((unused)) = {
    INT64_MAX, 127, 32767, 2147483647LL, 255, 65535, 4294967295LL
};

static inline int em_nk_bits(int nk) {
    switch (nk) {
        case 1: case 4: return 8;
        case 2: case 5: return 16;
        case 3: case 6: return 32;
        default:        return 64;   // 0 (i64), 7 (u64)
    }
}

// A trapped runtime fault (overflow, /0, bad shift). The VM prints to stderr and
// unwinds with VM_RUNTIME_ERROR (driver exit 65); the compiled program, being its
// own process, prints the same line and exits non-zero. The differential test
// compares stdout, so neither emits a `=> N` line on the faulting path.
static inline void em_panic(const char *msg) {
    fprintf(stderr, "emberc: runtime error: %s\n", msg);
    exit(70);
}

// A value is truthy iff its integer payload is non-zero (bool is an int 0/1). Used
// for `if`/`loop` conditions and the short-circuit operands of `&&`/`||`.
static inline int em_truthy(Value v) {
    return AS_INT(v) != 0;
}

// +/-/* that TRAP on overflow (OFI-005). The common case (plain i64, kind 0) skips
// the width table; floats round to f32 for kind 8; kind 7 is unsigned; kinds 1..6
// range-check the signed result to their width. No string-concat branch yet (M1 has
// no heap) — that lands with strings in M2.
#define EM_DEF_ARITH(fn, builtin, op)                                          \
    static inline Value fn(Value a, Value b, int nk) {                         \
        if (IS_INT(a) && nk == 0) {                                            \
            int64_t r;                                                         \
            if (builtin(AS_INT(a), AS_INT(b), &r)) em_panic("integer overflow"); \
            return INT_VAL(r);                                                 \
        } else if (IS_FLOAT(a)) {                                              \
            double fr = AS_FLOAT(a) op AS_FLOAT(b);                            \
            if (nk == 8) fr = (float)fr;                                       \
            return FLOAT_VAL(fr);                                              \
        } else if (nk == 7) {                                                  \
            uint64_t ur;                                                       \
            if (builtin((uint64_t)AS_INT(a), (uint64_t)AS_INT(b), &ur))        \
                em_panic("integer overflow");                                 \
            return INT_VAL((int64_t)ur);                                       \
        } else {                                                              \
            int64_t r;                                                         \
            if (builtin(AS_INT(a), AS_INT(b), &r) ||                           \
                r < EM_NK_MIN[nk] || r > EM_NK_MAX[nk])                        \
                em_panic("integer overflow");                                 \
            return INT_VAL(r);                                                 \
        }                                                                     \
    }
EM_DEF_ARITH(em_sub, __builtin_sub_overflow, -)
EM_DEF_ARITH(em_mul, __builtin_mul_overflow, *)
#undef EM_DEF_ARITH

// em_add: numeric `+`, or STRING CONCATENATION when both operands are strings. Concat
// allocates a fresh result and then CONSUMES both operands (drops a reference). The emitter
// guarantees each operand is OWNED at the call: a temporary (a literal — interned and retained
// per use — or a call/concat result) owns its reference outright, and a BORROWED operand (a
// binding/field read) is retained at the site (emit_concat_operand), so this drop balances and
// the borrow's owner keeps its reference. This bounds memory (no leaked operand temporaries)
// without double-freeing a borrowed string. Numeric `+` leaves its scalar operands untouched.
static inline Value em_add(EmberRt *ctx, Value a, Value b, int nk) {
    if (IS_INT(a) && nk == 0) {
        int64_t r;
        if (__builtin_add_overflow(AS_INT(a), AS_INT(b), &r)) em_panic("integer overflow");
        return INT_VAL(r);
    } else if (IS_STRING(a) && IS_STRING(b)) {
        ObjString *sa = AS_STRING(a), *sb = AS_STRING(b);
        ObjString *r = make_string(ctx, sa->length + sb->length);
        memcpy(r->chars, sa->chars, sa->length);
        memcpy(r->chars + sa->length, sb->chars, sb->length);
        drop_value(ctx, a);
        drop_value(ctx, b);
        return OBJ_VAL(r);
    } else if (IS_FLOAT(a)) {
        double fr = AS_FLOAT(a) + AS_FLOAT(b);
        if (nk == 8) fr = (float)fr;
        return FLOAT_VAL(fr);
    } else if (nk == 7) {
        uint64_t ur;
        if (__builtin_add_overflow((uint64_t)AS_INT(a), (uint64_t)AS_INT(b), &ur))
            em_panic("integer overflow");
        return INT_VAL((int64_t)ur);
    } else {
        int64_t r;
        if (__builtin_add_overflow(AS_INT(a), AS_INT(b), &r) ||
            r < EM_NK_MIN[nk] || r > EM_NK_MAX[nk])
            em_panic("integer overflow");
        return INT_VAL(r);
    }
}

// +/-/* that WRAP modulo 2^width instead of trapping (OFI-041): the explicit
// wrapping_* builtins for hashes/PRNGs/checksums. Done in uint64_t, then truncated
// to the kind's width and re-sign-extended for the signed kinds.
#define EM_DEF_WRAP(fn, op)                                                    \
    static inline Value fn(Value a, Value b, int nk) {                         \
        uint64_t ur = (uint64_t)AS_INT(a) op (uint64_t)AS_INT(b);             \
        int64_t r;                                                            \
        switch (nk) {                                                         \
            case 1: r = (int8_t)(ur & 0xFFu);        break;                   \
            case 2: r = (int16_t)(ur & 0xFFFFu);     break;                   \
            case 3: r = (int32_t)(ur & 0xFFFFFFFFu); break;                   \
            case 4: r = (int64_t)(ur & 0xFFu);       break;                   \
            case 5: r = (int64_t)(ur & 0xFFFFu);     break;                   \
            case 6: r = (int64_t)(ur & 0xFFFFFFFFu); break;                   \
            default: r = (int64_t)ur;                break;                   \
        }                                                                     \
        return INT_VAL(r);                                                    \
    }
EM_DEF_WRAP(em_wrap_add, +)
EM_DEF_WRAP(em_wrap_sub, -)
EM_DEF_WRAP(em_wrap_mul, *)
#undef EM_DEF_WRAP

static inline Value em_div(Value a, Value b, int nk) {
    if (IS_FLOAT(a)) {
        double fr = AS_FLOAT(a) / AS_FLOAT(b);
        if (nk == 8) fr = (float)fr;
        return FLOAT_VAL(fr);
    }
    if (nk == 7) {
        uint64_t x = (uint64_t)AS_INT(a), y = (uint64_t)AS_INT(b);
        if (y == 0) em_panic("division by zero");
        return INT_VAL((int64_t)(x / y));
    }
    int64_t x = AS_INT(a), y = AS_INT(b);
    if (y == 0) em_panic("division by zero");
    // x==INT64_MIN && y==-1 is tested first (|| short-circuits) so x/y, which would
    // be UB there, is never evaluated; a narrow result can also leave its width.
    if ((x == INT64_MIN && y == -1) || x / y < EM_NK_MIN[nk] || x / y > EM_NK_MAX[nk])
        em_panic("integer overflow");
    return INT_VAL(x / y);
}

static inline Value em_mod(Value a, Value b, int nk) {
    int64_t x = AS_INT(a), y = AS_INT(b);
    if (y == 0) em_panic("modulo by zero");
    int64_t r;
    if (nk == 7) r = (int64_t)((uint64_t)x % (uint64_t)y);
    else         r = (x == INT64_MIN && y == -1) ? 0 : x % y;   // INT64_MIN % -1 is UB in C
    return INT_VAL(r);
}

static inline Value em_neg(Value a, int nk) {
    if (IS_FLOAT(a)) {
        double fr = -AS_FLOAT(a);
        if (nk == 8) fr = (float)fr;
        return FLOAT_VAL(fr);
    }
    if (nk == 7) {                       // -u64 is valid only for 0
        if (AS_INT(a) != 0) em_panic("integer overflow");
        return INT_VAL(0);
    }
    int64_t x = AS_INT(a);
    if (x == INT64_MIN || -x < EM_NK_MIN[nk] || -x > EM_NK_MAX[nk])
        em_panic("integer overflow");
    return INT_VAL(-x);
}

static inline Value em_not(Value a) {
    return INT_VAL(AS_INT(a) == 0 ? 1 : 0);
}

static inline Value em_bitand(Value a, Value b) { return INT_VAL(AS_INT(a) & AS_INT(b)); }
static inline Value em_bitor (Value a, Value b) { return INT_VAL(AS_INT(a) | AS_INT(b)); }
static inline Value em_bitxor(Value a, Value b) { return INT_VAL(AS_INT(a) ^ AS_INT(b)); }

static inline Value em_bitnot(Value a, int nk) {
    int64_t x = AS_INT(a), r;
    if (nk >= 4 && nk <= 6) r = (int64_t)((~(uint64_t)x) & (uint64_t)EM_NK_MAX[nk]);
    else                    r = ~x;
    return INT_VAL(r);
}

static inline Value em_shl(Value a, Value nbv, int nk) {
    int64_t nb = AS_INT(nbv), x = AS_INT(a);
    int bits = em_nk_bits(nk);
    if (nb < 0 || nb >= bits) em_panic("shift amount out of range");
    uint64_t mask = (bits == 64) ? ~0ull : (((uint64_t)1 << bits) - 1);
    uint64_t ur = ((uint64_t)x << nb) & mask;
    if (nk <= 3 && bits < 64 && ((ur >> (bits - 1)) & 1)) ur |= ~mask;   // re-sign-extend
    return INT_VAL((int64_t)ur);
}

static inline Value em_shr(Value a, Value nbv, int nk) {
    int64_t nb = AS_INT(nbv), x = AS_INT(a);
    int bits = em_nk_bits(nk);
    if (nb < 0 || nb >= bits) em_panic("shift amount out of range");
    int64_t r;
    if (nk <= 3) {
        r = x >> nb;                                                   // arithmetic (signed)
    } else {
        uint64_t mask = (bits == 64) ? ~0ull : (((uint64_t)1 << bits) - 1);
        r = (int64_t)(((uint64_t)x & mask) >> nb);                     // logical (unsigned)
    }
    return INT_VAL(r);
}

// Equality (the VM's OP_EQ): strings compare by content, floats as doubles, everything
// else as int64 bits. A borrow, so operands are not consumed here.
static inline int em_value_eq(Value a, Value b) {
    if (IS_STRING(a) && IS_STRING(b)) {
        ObjString *sa = AS_STRING(a), *sb = AS_STRING(b);
        return sa->length == sb->length && memcmp(sa->chars, sb->chars, sa->length) == 0;
    }
    if (IS_FLOAT(a)) {
        return AS_FLOAT(a) == AS_FLOAT(b);
    }
    return AS_INT(a) == AS_INT(b);
}

static inline Value em_eq(Value a, Value b)  { return INT_VAL(em_value_eq(a, b) ? 1 : 0); }
static inline Value em_neq(Value a, Value b) { return INT_VAL(em_value_eq(a, b) ? 0 : 1); }

// The `==` / `!=` OPERATORS consume their operands (like em_add): the emitter retains a
// borrowed operand at the site (emit_concat_operand), so dropping here frees a temporary
// (a concat result, a literal's per-use retain) without leaking and without double-freeing a
// borrow. (em_eq/em_neq above stay non-consuming for the Hash/Eq witness shim, which borrows.)
static inline Value em_eq_op(EmberRt *ctx, Value a, Value b) {
    int r = em_value_eq(a, b);
    drop_value(ctx, a);
    drop_value(ctx, b);
    return INT_VAL(r ? 1 : 0);
}
static inline Value em_neq_op(EmberRt *ctx, Value a, Value b) {
    int r = em_value_eq(a, b);
    drop_value(ctx, a);
    drop_value(ctx, b);
    return INT_VAL(r ? 0 : 1);
}

// Ordering: floats compare as doubles, kind 7 as unsigned u64, otherwise signed.
#define EM_DEF_CMP(fn, cop)                                                    \
    static inline Value fn(Value a, Value b, int nk) {                         \
        int res;                                                              \
        if (IS_FLOAT(a))      res = (AS_FLOAT(a) cop AS_FLOAT(b));            \
        else if (nk == 7)     res = ((uint64_t)AS_INT(a) cop (uint64_t)AS_INT(b)); \
        else                  res = (AS_INT(a) cop AS_INT(b));                \
        return INT_VAL(res ? 1 : 0);                                          \
    }
EM_DEF_CMP(em_lt, <)
EM_DEF_CMP(em_le, <=)
EM_DEF_CMP(em_gt, >)
EM_DEF_CMP(em_ge, >=)
#undef EM_DEF_CMP

// ---- Packed marshalling (shared with the VM; M2a Stage A) ------------------
// The edge between the erased uniform Value and a PACKED scalar in a struct field
// or array element. A packed scalar is stored at its natural width; AEK_BOXED is a
// 16/24-byte Value stored as-is. These are the single source of truth for box/unbox
// — the VM (src/vm.c) and generated C both use them, so a struct read can't drift
// between the two backends. Pure (no runtime context), hence header-only inline.

// Bytes per packed element/field of an ArrayElemKind (sizeof(Value) when boxed).
static inline uint8_t elem_size_for(uint8_t kind) {
    switch (kind) {
        case AEK_I8: case AEK_U8: case AEK_BOOL: return 1;
        case AEK_I16: case AEK_U16:              return 2;
        case AEK_I32: case AEK_U32: case AEK_F32: return 4;
        case AEK_I64: case AEK_U64: case AEK_F64: return 8;
        default:                                 return sizeof(Value);   // boxed
    }
}

// value_box reads a packed scalar/Value of `kind` at `p` into a uniform Value;
// value_unbox writes one (truncating an integer to width, rounding f32).
static inline Value value_box(const unsigned char *p, int kind) {
    switch (kind) {
        case AEK_I8:   { int8_t   v; memcpy(&v, p, 1); return INT_VAL(v); }
        case AEK_U8:   { uint8_t  v; memcpy(&v, p, 1); return INT_VAL(v); }
        case AEK_BOOL: { uint8_t  v; memcpy(&v, p, 1); return INT_VAL(v ? 1 : 0); }
        case AEK_I16:  { int16_t  v; memcpy(&v, p, 2); return INT_VAL(v); }
        case AEK_U16:  { uint16_t v; memcpy(&v, p, 2); return INT_VAL(v); }
        case AEK_I32:  { int32_t  v; memcpy(&v, p, 4); return INT_VAL(v); }
        case AEK_U32:  { uint32_t v; memcpy(&v, p, 4); return INT_VAL(v); }
        case AEK_I64:  { int64_t  v; memcpy(&v, p, 8); return INT_VAL(v); }
        case AEK_U64:  { uint64_t v; memcpy(&v, p, 8); return INT_VAL((int64_t)v); }
        case AEK_F32:  { float    v; memcpy(&v, p, 4); return FLOAT_VAL((double)v); }
        case AEK_F64:  { double   v; memcpy(&v, p, 8); return FLOAT_VAL(v); }
        default:       { Value v; memcpy(&v, p, sizeof(Value)); return v; }  // boxed
    }
}

static inline void value_unbox(unsigned char *p, int kind, Value v) {
    switch (kind) {
        case AEK_I8: case AEK_U8: case AEK_BOOL:
            { uint8_t  x = (uint8_t)AS_INT(v);  memcpy(p, &x, 1); break; }
        case AEK_I16: case AEK_U16:
            { uint16_t x = (uint16_t)AS_INT(v); memcpy(p, &x, 2); break; }
        case AEK_I32: case AEK_U32:
            { uint32_t x = (uint32_t)AS_INT(v); memcpy(p, &x, 4); break; }
        case AEK_I64: case AEK_U64:
            { int64_t  x = AS_INT(v);           memcpy(p, &x, 8); break; }
        case AEK_F32:
            { float    x = (float)AS_FLOAT(v);  memcpy(p, &x, 4); break; }
        case AEK_F64:
            { double   x = AS_FLOAT(v);         memcpy(p, &x, 8); break; }
        default:   memcpy(p, &v, sizeof(Value)); break;   // boxed
    }
}

// Read/write element `i` of a packed array at the element edge.
static inline Value array_box(const ObjArray *a, size_t i) {
    return value_box((const unsigned char *)a->data + i * a->elem_size, a->elem_kind);
}

static inline void array_unbox(ObjArray *a, size_t i, Value v) {
    value_unbox((unsigned char *)a->data + i * a->elem_size, a->elem_kind, v);
}

#endif // EMBER_RT_H
