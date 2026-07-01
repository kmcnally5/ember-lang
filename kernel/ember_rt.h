#ifndef EMBER_RT_FREESTANDING_H
#define EMBER_RT_FREESTANDING_H
//
// Freestanding shadow of include/ember_rt.h for the bare-metal target (OFI-167 / kernel milestone 1).
//
// The real runtime header pulls in <stdio.h>/<stdlib.h>/<pthread.h> and a large object runtime; a
// kernel has none of that. This minimal header provides ONLY what emberc's `--emit=c` output
// references in the HEAP-FREE subset: the uniform 16-byte tagged `Value`, the `EmberRt` context the
// generated `main`/`em_invoke` touch, and the handful of `em_*` runtime entry points (implemented in
// rt.c). It is selected over the real header by compiling the emitted C with `-Ikernel`.
//
// Only the freestanding C headers are used (<stdint.h>/<stddef.h> are provided even under
// `-ffreestanding -nostdlib`). No heap, no OS, no libc.
//
#include <stdint.h>
#include <stddef.h>

typedef struct Obj Obj;

// A runtime value: a tagged union of an inline 64-bit int (bool = 0/1), a double, or an object
// pointer. Identical layout to include/value.h so the emitted C's macros behave the same.
typedef enum { VAL_INT, VAL_FLOAT, VAL_OBJ } ValueType;

typedef struct {
    ValueType type;
    union {
        int64_t integer;
        double  floating;
        Obj    *obj;
    } as;
} Value;

#define INT_VAL(i)    ((Value){ VAL_INT,   { .integer  = (int64_t)(i) } })
#define FLOAT_VAL(f)  ((Value){ VAL_FLOAT, { .floating = (double)(f) } })
#define OBJ_VAL(o)    ((Value){ VAL_OBJ,   { .obj = (Obj *)(o) } })
#define IS_INT(v)     ((v).type == VAL_INT)
#define IS_FLOAT(v)   ((v).type == VAL_FLOAT)
#define IS_OBJ(v)     ((v).type == VAL_OBJ)
#define AS_INT(v)     ((v).as.integer)
#define AS_FLOAT(v)   ((v).as.floating)
#define AS_OBJ(v)     ((v).as.obj)
#define OBJ_RETAIN(o) ((void)((o)->refcount++))

// The heap-free subset never allocates, so no Obj is ever constructed — but the emitted `main`'s
// result-echo references IS_STRING / AS_CSTRING, so the types must exist to compile.
typedef enum { OBJ_STRING } ObjType;
struct Obj { ObjType type; int refcount; };
typedef struct { Obj obj; size_t length; char chars[]; } ObjString;
#define IS_STRING(v)  (IS_OBJ(v) && AS_OBJ(v)->type == OBJ_STRING)
#define AS_CSTRING(v) (((ObjString *)AS_OBJ(v))->chars)

// The runtime context the generated code threads through arithmetic and the em_invoke trampoline.
// Only the three fields the emitted `main` sets are kept.
typedef struct EmberRt {
    void   *structs;
    int     struct_count;
    Value (*invoke)(struct EmberRt *ctx, int fn_index, Value *slots);
} EmberRt;

extern int    em_argc;
extern char **em_argv;

// The em_* entry points the heap-free subset references (implemented in rt.c).
Value em_add(EmberRt *ctx, Value a, Value b, int kind);   // integer add (width via `kind`)
Value em_eq_op(EmberRt *ctx, Value a, Value b);           // equality -> 0/1 bool Value
int   em_truthy(Value v);                                 // bool/int truthiness
void  em_panic(const char *msg);                          // kernel panic: print + hang
void  rt_free_objects(EmberRt *ctx);                      // no heap -> no-op
int   printf(const char *fmt, ...);                       // no-op result-echo stub

#endif // EMBER_RT_FREESTANDING_H
