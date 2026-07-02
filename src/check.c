#include "check.h"
#include "token.h"
#include "builtin.h"
#include "diag.h"
#include "cextern.h"
#include "semindex.h"
#include "typefmt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// A semantic type. Encoded as an int so existing == comparisons keep working
// and struct types slot in with no churn: negative values are the primitives,
// and any value >= 0 is a struct-type id (index into the checker's struct table).
typedef int SemType;
#define TY_ERROR (-1)
#define TY_INT   (-2)   // the default integer; an alias for i64
#define TY_BOOL  (-3)
#define TY_SELF  (-4)   // placeholder in an interface signature for the impl type
#define TY_FLOAT (-5)
#define TY_STRING (-6)
#define TY_UNIT  (-7)   // result of a statement-only call (e.g. print); not a value
// Explicit-width integers. `int` == `i64` == TY_INT. All seven fit a signed
// int64 at runtime (the erased value model has no width tag), so they store,
// compare, and print correctly as signed; u64/f32 await a non-erased layout.
#define TY_I8    (-8)
#define TY_I16   (-9)
#define TY_I32   (-10)
#define TY_U8    (-11)
#define TY_U16   (-12)
#define TY_U32   (-13)
#define TY_U64   (-14)   // unsigned 64-bit; its bits live in the int64 slot, so its
                         // arithmetic/compare/display are unsigned (numeric kind 7)
#define TY_F32   (-15)   // 32-bit float; stored as double, rounded after each op
#define TY_INFER (-16)   // a lambda whose return type is inferred from its body
#define TY_PTR   (-17)   // FFI (§5h): an opaque C pointer/handle (e.g. FILE*). Round-trips to
                         // and from `extern "c"` calls; its bits live in the int64 slot (the
                         // erased value model), and it is never dereferenced from Ember.

// The non-negative range is partitioned into bands (no program approaches a
// million of anything, so the split is safe and keeps existing id comparisons
// intact). Each band's value carries the relevant index:
//   [0, ENUM_BASE)            struct type      id        = t
//   [ENUM_BASE, PARAM_BASE)   enum type        id        = t - ENUM_BASE
//   [PARAM_BASE, GENERIC_BASE) type parameter  index     = t - PARAM_BASE
//   [GENERIC_BASE, ...)       generic instance intern ix = t - GENERIC_BASE
#define ENUM_BASE    1000000
#define PARAM_BASE   2000000
#define GENERIC_BASE 3000000
#define ARRAY_BASE   4000000   //   [ARRAY_BASE, CHANNEL_BASE) array type; elem table
#define CHANNEL_BASE 5000000   //   [CHANNEL_BASE, FN_BASE)    channel type; elem table
#define FN_BASE      6000000   //   [FN_BASE, IFACE_BASE)      function type; fntype table
#define IFACE_BASE   7000000   //   [IFACE_BASE, SLICE_BASE)    interface value type; id = t - IFACE_BASE
#define SLICE_BASE   8000000   //   [SLICE_BASE, ...)          Slice<T> view; shares the array elem table
#define NEWTYPE_BASE 9000000   //   [NEWTYPE_BASE, ...)        newtype (OFI-149); id = t - NEWTYPE_BASE; base in c->newtypes[id]

static int is_struct_type(SemType t) {
    return t >= 0 && t < ENUM_BASE;
}

// is_slice_type / intern_slice / slice_elem — a Slice<T> is a borrowed, read-only view over an
// array (slices §). It reuses the array element table: a slice's index into c->arrays equals the
// array type's, so Slice<T> and [T] share one elem entry. Slices may appear only as a parameter
// type or an inferred local (escape is forbidden — see the return/field/element checks).
static int is_slice_type(SemType t) {
    return t >= SLICE_BASE && t < NEWTYPE_BASE;
}

static int is_enum_type(SemType t) {
    return t >= ENUM_BASE && t < PARAM_BASE;
}

static int enum_id_of(SemType t) {
    return t - ENUM_BASE;
}

static int is_type_param(SemType t) {
    return t >= PARAM_BASE && t < GENERIC_BASE;
}

static int is_generic_inst(SemType t) {
    return t >= GENERIC_BASE && t < ARRAY_BASE;
}

static int is_array_type(SemType t) {
    return t >= ARRAY_BASE && t < CHANNEL_BASE;
}

static int is_channel_type(SemType t) {
    return t >= CHANNEL_BASE && t < FN_BASE;
}

static int is_fn_type(SemType t) {
    return t >= FN_BASE && t < IFACE_BASE;
}

// An interface used as a value type (dynamic dispatch): the value is a boxed pair
// {receiver, vtable}. The id indexes c->interfaces[].
static int is_interface_type(SemType t) {
    return t >= IFACE_BASE && t < SLICE_BASE;
}

static int interface_id_of(SemType t) {
    return t - IFACE_BASE;
}

// is_integer_type / int_kind / int_fits cover the explicit-width integers. The
// "numeric kind" is the byte codegen emits on each arithmetic op so the VM knows
// the overflow bounds; its ordering matches the VM's bounds table:
//   0 = i64 (int), 1 = i8, 2 = i16, 3 = i32, 4 = u8, 5 = u16, 6 = u32
// is_newtype reports whether `t` is a user newtype (`type UserId = int`, OFI-149) — nominally
// distinct, but with the runtime representation of its base. newtype_id_of indexes c->newtypes.
static int is_newtype(SemType t) {
    return t >= NEWTYPE_BASE && t < NEWTYPE_BASE + 1000000;
}

static int newtype_id_of(SemType t) {
    return t - NEWTYPE_BASE;
}

static int is_integer_type(SemType t) {
    return t == TY_INT || t == TY_I8 || t == TY_I16 || t == TY_I32 ||
           t == TY_U8  || t == TY_U16 || t == TY_U32 || t == TY_U64;
}

// is_float_type covers f64 (the default `float`) and f32. is_numeric_type is any
// number. The "numeric kind" byte threaded to the VM (arithmetic, ordering
// compares, display) selects the right signed/unsigned/rounded behaviour:
//   0 i64, 1 i8, 2 i16, 3 i32, 4 u8, 5 u16, 6 u32, 7 u64, 8 f32, 9 f64
static int is_float_type(SemType t) {
    return t == TY_FLOAT || t == TY_F32;
}

static int is_numeric_type(SemType t) {
    return is_integer_type(t) || is_float_type(t);
}

static int int_kind(SemType t) {
    switch (t) {
        case TY_I8:  return 1;
        case TY_I16: return 2;
        case TY_I32: return 3;
        case TY_U8:  return 4;
        case TY_U16: return 5;
        case TY_U32: return 6;
        case TY_U64: return 7;
        case TY_F32: return 8;
        case TY_FLOAT: return 9;
        default:     return 0;   // TY_INT / i64
    }
}

// array_elem_kind maps an element type to its packed-array storage kind. The
// values match ArrayElemKind in value.h: 0 boxed, 1..4 i8/i16/i32/i64, 5..8
// u8/u16/u32/u64, 9 f32, 10 f64, 11 bool. A non-scalar element (struct, string,
// enum, nested array, channel) is boxed (a uniform Value[]).
static int array_elem_kind(SemType t) {
    switch (t) {
        case TY_I8:    return 1;
        case TY_I16:   return 2;
        case TY_I32:   return 3;
        case TY_INT:   return 4;
        case TY_U8:    return 5;
        case TY_U16:   return 6;
        case TY_U32:   return 7;
        case TY_U64:   return 8;
        case TY_F32:   return 9;
        case TY_FLOAT: return 10;
        case TY_BOOL:  return 11;
        default:       return 0;   // boxed
    }
}

// int_fits reports whether an integer LITERAL'S magnitude fits a target type. `v` is the parser's
// non-negative magnitude held in the int_lit slot (a literal carries no sign — `-n` is unary minus on
// a non-negative literal). The one exception is a magnitude in (i64-max, u64-max]: it lands with the
// sign bit set (v < 0), which marks it "u64-only" — representable by no type but `u64` (OFI-123).
static int int_fits(long long v, SemType t) {
    if (v < 0) {
        return t == TY_U64;   // magnitude overflowed the i64 sign bit → fits only u64
    }
    switch (t) {
        case TY_I8:  return v <= 127;
        case TY_I16: return v <= 32767;
        case TY_I32: return v <= 2147483647LL;
        case TY_U8:  return v <= 255;
        case TY_U16: return v <= 65535;
        case TY_U32: return v <= 4294967295LL;
        case TY_U64: return 1;        // any non-negative magnitude ≤ 2⁶⁴−1 (parser-bounded) is a valid u64
        default:     return 1;        // i64 (int): any non-negative magnitude ≤ i64-max fits
    }
}

// numeric_typename maps a bare type name used as a conversion call (`u8(x)`,
// `i32(x)`, `int(x)`, `f32(x)`, `f64(x)`) to its target type, or TY_ERROR if
// `name` is not a numeric type. An integer target wants an integer source; a
// float target wants a float source (int<->float still uses to_int/to_float).
static SemType numeric_typename(const char *name) {
    if (strcmp(name, "i8") == 0)  return TY_I8;
    if (strcmp(name, "i16") == 0) return TY_I16;
    if (strcmp(name, "i32") == 0) return TY_I32;
    if (strcmp(name, "i64") == 0) return TY_INT;
    if (strcmp(name, "int") == 0) return TY_INT;
    if (strcmp(name, "u8") == 0)  return TY_U8;
    if (strcmp(name, "u16") == 0) return TY_U16;
    if (strcmp(name, "u32") == 0) return TY_U32;
    if (strcmp(name, "u64") == 0) return TY_U64;
    if (strcmp(name, "f32") == 0) return TY_F32;
    if (strcmp(name, "f64") == 0) return TY_FLOAT;
    return TY_ERROR;
}

// suffix_to_type maps a parser width-suffix code (see suffix_code in the parser)
// to its integer type. i64 is the canonical `int`.
static SemType suffix_to_type(int code) {
    switch (code) {
        case 1: return TY_I8;
        case 2: return TY_I16;
        case 3: return TY_I32;
        case 4: return TY_INT;   // i64
        case 5: return TY_U8;
        case 6: return TY_U16;
        case 7: return TY_U32;
        case 8: return TY_U64;
        default: return TY_ERROR;
    }
}

// resolve_self maps the TY_SELF placeholder to a concrete struct id (the type a
// method belongs to / a conformance is being checked against). Outside a method
// — no owning struct — `Self` is meaningless, so it becomes TY_ERROR.
static SemType resolve_self(SemType t, SemType self_type) {
    if (t == TY_SELF) {
        return self_type >= 0 ? self_type : TY_ERROR;
    }
    return t;
}

// A declared local: its name, mutability (`var` vs `let`), value type, and the
// scope depth it was declared at (0 = function body, deeper inside blocks). The
// depth distinguishes same-scope redeclaration (an error) from shadowing an
// outer scope (allowed).
typedef struct {
    const char *name;
    int         is_var;
    SemType     type;
    int         depth;
    int         owned;   // owns its value (local / move-param) vs borrows it
    int         moved;   // its value has been moved out (use is an error)
    int         move_line; // where the move happened (0 = not directly moved here),
    int         move_col;  // so a use-after-move can point a "moved here" note at it
    // Linearity (OFI-049 leak half). A `Ptr` is a LINEAR FFI handle: move-only (affine, the
    // double-close half) AND must-consume (it has no Ember destructor, so leaving scope without
    // being closed/returned leaks). `consumed` is the AND-merge dual of `moved`'s OR-merge: it is 1
    // only when the binding has been moved out on EVERY path reaching this point (vs `moved` = on
    // SOME path). `leaked` is a monotonic latch so one un-closed handle is reported once, not at
    // every enclosing scope exit. `open_line/col` point a note at where the handle was opened.
    int         consumed;
    int         leaked;
    int         open_line;
    int         open_col;
    Stmt       *decl;    // the `let` that declared this (NULL for params etc.);
                         // its drop_at_scope_end is set when the local expires
    int         multislot_sid; // value-types 3b: struct id if this binding is stored
                         // MULTI-SLOT (a let-inline or plain-param all-scalar struct), else -1
    int         def_line; // 1-based source position where this binding was declared,
    int         def_col;  // for the semantic index's go-to-definition (0 = unknown)
    int         is_param; // 1 if a function parameter, 0 if a `let`/`var` binding
    int         frozen;   // a live Slice<T> borrows this array, so it is read-only for the rest
                          // of its scope: no append/assign/move while frozen (slices §)
    int         frozen_line; // where the freezing slice was taken (for the error note)
    int         frozen_col;
} Local;

#define MAX_PARAMS  32
#define MAX_FNS     256
#define MAX_STRUCTS 256
#define MAX_METHODS 32
// Cap on check_expr recursion. A flat operator chain (`1+1+…`) parses iteratively but builds
// a deep left-leaning AST, and the recursive checker overflows the C stack walking it (~800
// deep here). 400 is far beyond any realistic expression nesting yet safely below the limit;
// a check error halts the pipeline before codegen, so this also shields the codegen recursion.
#define MAX_CHECK_DEPTH 400

// A struct type's checked layout: its name, its fields (name + type) in declared
// order, and its methods. Field access resolves a name to its index here.
typedef struct {
    const char *name;
    SemType     type;
    int         def_line;   // 1-based source position of the field's declaration, for the
    int         def_col;    // semantic index's go-to-definition (0 = unknown)
} FieldInfo;

// A method signature. `params`/`param_count` are the *explicit* parameters
// (excluding the implicit `self`). `fn_index` is the method's slot in the
// compiled function table — codegen enumerates functions in the same order, so
// a method call can target it directly.
typedef struct {
    const char *name;
    SemType     params[MAX_PARAMS];
    int         quals[MAX_PARAMS];   // each explicit param's qualifier (OWN_NONE/MUT/MOVE):
                                     // a fresh temp passed to a `move` param is consumed by
                                     // the callee, so it must NOT be caller-dropped (OFI-027).
    int         param_count;
    SemType     ret;
    int         fn_index;
    int         self_qual;   // the `self` parameter's qualifier (OWN_NONE/MUT/MOVE):
                             // a `move self` method consumes the receiver, so a fresh
                             // temp receiver must NOT be caller-dropped (OFI-027).
    const FnDecl *decl;      // the method's AST declaration — its source position and (via the
                             // shared formatter) its signature, for the LSP semantic index
} MethodInfo;

#define MAX_TYPE_ARGS  8
#define MAX_IMPLEMENTS 8

typedef struct {
    const char *name;
    const char *generics[MAX_TYPE_ARGS];   // type-parameter names (e.g. T, A, B)
    int         generic_count;
    int         bounds[MAX_TYPE_ARGS][MAX_BOUNDS]; // interface ids bounding each type param
    int         bound_count[MAX_TYPE_ARGS];        // number of bounds on each type param
    int         is_copy[MAX_TYPE_ARGS];            // 1 if a type param has the `Copy` bound
    int         witness_count;              // total hidden witness fields = sum of bound_count[]
    FieldInfo  *fields;                     // dynamic (no cap); field types may be TY_PARAM(i)
    int         fields_cap;                 // allocated capacity of `fields`
    int         field_count;                // DECLARED fields (hidden witnesses are layout-only)
    MethodInfo *methods;                    // dynamic (no cap), like fields — a widget kit grows many
    int         methods_cap;                // allocated capacity of `methods`
    int         method_count;
    int         implements[MAX_IMPLEMENTS]; // interface ids this struct implements
    int         implements_count;
    int         module;                     // owning module index (for name scoping)
    int         is_rc;                      // `rc struct`: a shared, deeply-immutable refcounted type
    int         is_resource;                // `resource struct`: a uniquely-owned, drop-bearing type (OFI-122)
    int         drop_fn;                    // the `drop` method's fn-table index (resource only), else -1
    int         def_line;                   // the struct's source position, for LSP go-to-def
    int         def_col;
} StructInfo;

// An interned generic instantiation, e.g. Box<int> or Option<string>. Field /
// variant types resolve by substituting the base's type parameters with `args`.
// Instances are interned so the same instantiation always shares one SemType id.
typedef struct {
    int     base;                  // struct id, or enum id when is_enum
    int     is_enum;
    SemType args[MAX_TYPE_ARGS];
    int     arg_count;
} GenericInst;

// An interface's required method signature. Explicit params (excluding self) and
// the return type may contain TY_SELF, resolved to the implementing struct when
// conformance is checked.
typedef struct {
    const char *name;
    SemType     params[MAX_PARAMS];
    int         param_count;
    SemType     ret;
} MethodSig;

typedef struct {
    const char *name;
    MethodSig   methods[MAX_METHODS];
    int         method_count;
} InterfaceInfo;


// An enum variant: its name, payload field types (in order), and its position.
typedef struct {
    const char *name;
    SemType     fields[MAX_PARAMS];
    const char *field_names[MAX_PARAMS];   // the declared payload field names — for NAMED construction
                                           // `Circle(radius: 2.0)` (OFI-140); positional builds ignore them
    int         field_count;
    int         enum_id;         // which enum (index in c->enums)
    int         variant_index;   // position within that enum
} VariantInfo;

typedef struct {
    const char *name;
    const char *generics[MAX_TYPE_ARGS];   // type-parameter names
    int         generic_count;
    VariantInfo *variants;                  // dynamic; variant field types may be TY_PARAM(i)
    int         variants_cap;               // allocated capacity of `variants`
    int         variant_count;
    int         module;                     // owning module index (for name scoping)
    int         def_line;                   // the enum's source position, for LSP go-to-def
    int         def_col;
} EnumInfo;

// A newtype: a distinct nominal type over a base (`type UserId = int`, OFI-149). Zero runtime
// cost — a value of this type IS its base value; the SemType is NEWTYPE_BASE + its index here.
typedef struct {
    const char *name;
    SemType     base;             // the erased base type (TY_INT, TY_FLOAT, …)
    Expr       *refinement;       // OFI-150: the `where` predicate (over `self`), or NULL
    int         refinement_checked; // OFI-150: predicate type-checked once (lazily, at first construction)
    int         refinement_in_progress; // OFI-150: this type's predicate is mid-check — a construction
                                        // of it inside its own predicate is a non-terminating cycle
    int         module;
    int         def_line;
    int         def_col;
} NewtypeInfo;

// A collected function signature, gathered in pass 1 so that calls (including
// forward and recursive ones) can be type-checked in pass 2.
typedef struct {
    const char *name;
    SemType     params[MAX_PARAMS];   // may contain TY_PARAM(i) when generic
    OwnQual     quals[MAX_PARAMS];    // ownership qualifier per parameter
    int         param_count;
    SemType     ret;
    int         generic_count;        // number of type parameters (0 = non-generic)
    int         bounds[MAX_TYPE_ARGS][MAX_BOUNDS]; // interface ids bounding each type param
    int         bound_count[MAX_TYPE_ARGS];        // number of bounds on each type param
    int         is_copy[MAX_TYPE_ARGS];// 1 if each type param has the `Copy` bound
    int         module;               // owning module index (for name scoping)
    int         fn_index;             // slot in the compiled function table
    int         cextern_index;        // FFI (§5h): C-registry index if this is an `extern "c"`
                                      // function (no bytecode slot); -1 for an ordinary function
    int         direct_extern;        // OFI-167: an `extern "c"` fn NOT in the hosted registry — the
                                      // native backend emits a direct call to `name`; the VM has no
                                      // binding (native-only). 0 for a registry extern or Ember fn.
    const FnDecl *decl;               // the function's AST declaration — its source position and
                                      // (via the shared formatter) its signature, for the LSP index
} FnSig;

// A function-type descriptor: the type of a function value (a named function used
// as a value, or a lambda). Interned in the checker's fntypes table; the SemType is
// FN_BASE + its index, so two structurally identical `fn(int)->int` types compare ==.
typedef struct {
    SemType params[MAX_PARAMS];
    int     param_count;
    SemType ret;
} FnType;

typedef struct {
    const char *src;
    int         had_error;
    int         expr_depth;       // current check_expr recursion depth (stack-overflow guard)
    Local      *locals;       // dynamic, grown on demand (no per-function cap — OFI-007/047/056)
    int         locals_cap;   // allocated capacity of `locals`
    int         local_count;
    SemType     current_return;   // declared return type of the function in scope
    int         current_ret_struct_id;  // value-types 3b.4b: struct id if the function in
                                  // scope returns an all-scalar struct MULTI-SLOT, else -1
    int         scope_depth;      // 0 = function body; >0 = inside a nested block
    int         allow_slice;      // 1 only while resolving a parameter or let annotation: a
                                  // Slice<T> may appear there but nowhere else (return/field/
                                  // element) — escape is forbidden by default-deny (slices §)
    int         loop_depth;       // >0 = inside a loop (break/continue legal)
    // Linearity across loops (OFI-049). `loop_local_base` is the `local_count` at the innermost
    // loop body's entry, so a `break`/`continue` scans exactly the body-local `Ptr` handles
    // ([base, local_count)) that won't survive the loop exit. `loop_break_consumed` is the
    // loop-EXIT AND-merge accumulator: for an infinite `loop` (whose only exits are `break`s), an
    // OUTER handle is consumed-after-the-loop iff consumed on every `break` path — so each `break`
    // ANDs the live `consumed[]` (outer slots) into it. NULL inside a `while`/`for` body (their
    // normal-false exit dominates, so a break-consume can't be credited). All three are saved/
    // restored around each loop, so nesting needs no fixed-depth array (no silent cap).
    int         loop_local_base;
    int        *loop_break_consumed;
    int         loop_break_seen;
    // OFI-074: the loop BACK-EDGE moved-accumulator. The "value moved inside a loop body" guard must
    // fire only if a move can actually reach the NEXT iteration — i.e. a back-edge (a `continue`, or a
    // reachable fall-through off the body's end). A move on a path that instead `break`s/`return`s out
    // never recurs. So each back-edge ORs the live `moved[]` (outer slots) in here, and the guard
    // checks THIS, not the body-end state (which can be a stale move on an already-exited path). NULL
    // outside a loop; saved/restored per loop so nesting needs no fixed-depth array.
    int        *loop_backedge_moved;
    // OFI-049: 1 when the statement being checked is statically UNREACHABLE — it follows a construct
    // that always diverges (a `return`, or an `if`/`match` whose every branch returns/breaks). The
    // leak scans skip such code: reporting "this Ptr leaks" on a dead trailing `return 0` is a false
    // positive. Set after a diverging statement in each statement sequence; saved/restored per scope.
    int         unreachable;
    int         any_rc;           // 1 if the program declares any `rc struct` — gates the rc-specific
                                  // mutation guards so non-rc code (the whole existing corpus) is
                                  // entirely unaffected (no extra path-walks, no duplicate diagnostics)
    int         nursery_depth;    // >0 = inside a nursery (spawn legal)
    const ModuleSet *modules;     // module boundaries + import aliases
    int         current_module;   // module index of the declaration being checked
    FnSig      *fns;              // signatures of all top-level functions (dynamic, no cap)
    int         fns_cap;         // allocated capacity of `fns`
    int         fn_count;
    // Top-level `let` constants (MANIFESTO §5e / OFI-023). Each is a named, immutable,
    // compile-time constant: a use is rewritten to its literal value at check time, so
    // there is no runtime global storage. `value` is the literal initializer.
    struct {
        const char *name;
        int         module;
        SemType     type;
        Expr       *value;
        int         def_line;   // the `let` constant's source position, for LSP go-to-def
        int         def_col;
    }           globals[MAX_FNS];
    int         global_count;
    StructInfo *structs;          // dynamic; grown only in pass 1a (struct-name registration), so the
    int         structs_cap;      // many cached `&c->structs[id]` in later passes never see a realloc
    int         struct_count;
    InterfaceInfo interfaces[MAX_STRUCTS];
    int           interface_count;
    EnumInfo    enums[MAX_STRUCTS];
    int         enum_count;
    NewtypeInfo newtypes[MAX_STRUCTS];   // OFI-149: nominal newtypes (parallel to enums)
    int         newtype_count;
    GenericInst ginsts[MAX_STRUCTS];
    int         ginst_count;
    // Monomorphized concrete struct instances (Step 2.5): each concrete generic
    // struct used in a construction (e.g. Box<int>) gets its own struct type id
    // (appended after the declared structs) and a packed descriptor.
    int         sinst_of[MAX_STRUCTS];     // ginst index → appended struct id, or -1
    int         sinst_ginst[MAX_STRUCTS];  // appended index → its ginst index
    int         sinst_count;
    SemType     arrays[MAX_STRUCTS];   // element type per array-type id
    int         array_count;
    SemType     channels[MAX_STRUCTS]; // element type per channel-type id
    int         channel_count;
    FnType      fntypes[MAX_STRUCTS];  // descriptor (param types + ret) per fn-type id
    int         fntype_count;
    const char **tparams;          // type-parameter names in scope (NULL if none)
    int          tparam_count;
    int          self_struct;      // struct id when checking a method body (-1 in a free fn):
                                   // a bounded type param's witness then lives in a self field
    // OFI-122 (resource drop): while checking a `resource struct`'s `drop` body, the carve-out that
    // lets it CLOSE its own `Ptr` fields + the must-close-every-handle leak scan are active. A handle
    // field is closed (consumed) only at the TOP LEVEL of drop (scope_depth 0), so the consumed mask
    // is monotonic — no control-flow merge needed (conditional close is rejected for now).
    int          in_resource_drop; // 1 while checking a resource drop body, else 0
    int          drop_self_struct; // the resource struct id whose drop is being checked, else -1
    int          drop_self_slot;   // the `self` local slot in that drop body, else -1
    int          drop_self_consumed;  // bitmask of self's Ptr fields already closed (compact ptr-bit)
    int          drop_self_ptr_mask;  // target: every one of self's Ptr fields must be closed at exit
    int          tparam_bounds[MAX_TYPE_ARGS][MAX_BOUNDS];  // interface ids per type param
    int          tparam_bound_count[MAX_TYPE_ARGS];         // number of bounds per type param
    int          tparam_is_copy[MAX_TYPE_ARGS]; // 1 if the param has the `Copy` bound
    SemType      expected;         // expected type of the expression in scope, for
                                   // variant-construction inference (TY_ERROR = none)
    // Lambda lifting: each lambda becomes a synthetic top-level function appended
    // to the program after body checking (so mono + codegen handle it like any
    // function). `base_fn_count` is the function-table index the first lambda takes.
    Arena       *arena;
    Program     *program;
    int          base_fn_count;
    Decl        *lambda_decls[EMBER_MAX_LAMBDAS];
    int          lambda_count;
    SemType      inferred_return;  // while current_return == TY_INFER: the body's type
    SemanticIndex *index;          // LSP semantic index to fill, or NULL in batch builds
} Checker;

// is_move_type reports whether values of `t` are *moved* (vs copied) on transfer.
// Only mutable heap aggregates — structs and generic struct instances — move;
// scalars copy, and immutable heap values (strings, enums, generic enums) are
// freely shareable, so they copy too.
// is_copy_param reports whether type parameter `t` was declared `T: Copy` in the
// callable currently being checked — a copyable type (alias freely, return by copy)
// rather than the move default.
static int is_copy_param(Checker *c, SemType t) {
    if (!is_type_param(t)) {
        return 0;
    }
    int i = t - PARAM_BASE;
    return i >= 0 && i < c->tparam_count && c->tparam_is_copy[i];
}






static int is_move_type(Checker *c, SemType t) {
    if (is_struct_type(t) && c->structs[t].is_rc) {
        return 0;   // R1: an `rc struct` is a shared, refcounted shareable — NOT a unique-owner
                    // move type. It takes the incref/alias path in consume(), like a string/enum.
    }
    if (is_struct_type(t) || is_array_type(t)) {
        return 1;   // structs and arrays are mutable, uniquely-owned aggregates
    }
    if (is_interface_type(t)) {
        return 1;   // an interface value uniquely owns its boxed struct receiver
    }
    if (is_generic_inst(t)) {
        return !c->ginsts[t - GENERIC_BASE].is_enum;
    }
    if (is_type_param(t)) {
        // A type parameter is a MOVE type by default, so a generic body is ownership-
        // checked soundly: a `T` value cannot be silently aliased or returned from a
        // borrow (that let a struct double-free at runtime — OFI-009). A `T: Copy`
        // parameter (MANIFESTO §5f) is exempt — it copies freely, like a scalar.
        return is_copy_param(c, t) ? 0 : 1;
    }
    if (t == TY_PTR) {
        // An opaque C handle (FILE*, …) is move-only (OFI-049): the move checker then tracks it
        // like a unique resource, so closing it (a `move` consume — fclose(move f: Ptr)) marks the
        // binding moved and any reuse is a use-after-move compile error (no double-close). It is NOT
        // a refcounted shareable and has NO Ember-side destructor — see the TY_PTR carve-outs in
        // is_owning_temp, drop_locals, and the param release, which keep it from being freed.
        return 1;
    }
    return 0;
}






// is_refcounted reports whether values of `t` are shared, immutable heap values
// reclaimed by reference counting (vs structs and arrays, which are uniquely
// owned and freed directly). Strings and enums — generic (`Option<int>`) or not —
// qualify: several bindings may name the same heap object, so each holds a counted
// reference. Channels likewise: a channel is a shareable handle that may be named
// by the creating scope AND passed to several spawned tasks at once, so each owner
// holds a counted reference and the last drop reclaims it (the buffer + its OS
// primitives). Scalars and arrays do not.
// newtype_base returns the base (erased) type of a newtype `t` (OFI-149).
static SemType newtype_base(Checker *c, SemType t) {
    return c->newtypes[newtype_id_of(t)].base;
}

static int is_refcounted(Checker *c, SemType t) {
    if (is_newtype(t)) {   // OFI-149: a newtype is refcounted iff its base is (a string base => yes)
        return is_refcounted(c, newtype_base(c, t));
    }
    if (t == TY_STRING || is_enum_type(t) || is_fn_type(t) || is_channel_type(t)) {
        return 1;   // closures + channels are heap objects, shared by reference count
    }
    if (is_struct_type(t) && c->structs[t].is_rc) {
        return 1;   // R1: an `rc struct` is the fifth shared-immutable shareable, reference-counted
    }
    return is_generic_inst(t) && c->ginsts[t - GENERIC_BASE].is_enum;
}


// type_is_rc reports whether `t` is an `rc struct` — a shared, deeply-immutable, refcounted struct.
// Used by the mutation gates (a write THROUGH an rc value is illegal) and the layout predicates.
static int type_is_rc(Checker *c, SemType t) {
    if (is_struct_type(t)) {
        return c->structs[t].is_rc;
    }
    if (is_generic_inst(t)) {
        // Defensive: R7 currently bans a generic `rc struct`, so a generic instance's base is
        // never rc today — but keep the predicate correct should generic rc ever land.
        const GenericInst *g = &c->ginsts[t - GENERIC_BASE];
        return !g->is_enum && g->base >= 0 && g->base < c->struct_count && c->structs[g->base].is_rc;
    }
    return 0;
}





// intern_array returns the array type `[elem]`, reusing an existing entry so the
// same element type always yields the same array-type id.
static int is_resource_type(Checker *c, SemType t);   // OFI-122 fwd (defined near ptr_storage_error)
static SemType intern_array(Checker *c, SemType elem) {
    if (elem == TY_PTR) {
        return TY_ERROR;   // OFI-049: a Ptr is a linear FFI handle, never a stored array/slice element.
    }                      // Defensive floor — the annotation/inference sites emit the precise message.
    if (is_resource_type(c, elem)) {
        return TY_ERROR;   // OFI-122: a `resource` is uniquely owned (clone = double-drop); never an
    }                      // array/slice element in Phase 1. Defensive floor; sites emit the message.
    for (int i = 0; i < c->array_count; i++) {
        if (c->arrays[i] == elem) {
            return (SemType)(ARRAY_BASE + i);
        }
    }
    if (c->array_count >= MAX_STRUCTS) {
        return TY_ERROR;
    }
    c->arrays[c->array_count] = elem;
    return (SemType)(ARRAY_BASE + c->array_count++);
}





static SemType array_elem(Checker *c, SemType arr) {
    return c->arrays[arr - ARRAY_BASE];
}


// A Slice<T> shares the array element table: it interns the same entry as [T] and is named with
// the SLICE_BASE offset, so slice_elem and array_elem read the same slot.
static SemType intern_slice(Checker *c, SemType elem) {
    SemType arr = intern_array(c, elem);
    if (arr == TY_ERROR) {
        return TY_ERROR;
    }
    return (SemType)(SLICE_BASE + (arr - ARRAY_BASE));
}


static SemType slice_elem(Checker *c, SemType sl) {
    return c->arrays[sl - SLICE_BASE];
}





// intern_channel / channel_elem mirror the array ones for the built-in
// `Channel<T>` type. Channels are refcounted shareable handles (a counted reference
// per owner, see is_refcounted) — not move types — so the same channel may be passed
// to several spawned tasks and is reclaimed when the last owner drops it.
static SemType intern_channel(Checker *c, SemType elem) {
    if (elem == TY_PTR) {
        return TY_ERROR;   // OFI-049: a Ptr is linear — it cannot ride a (shareable) channel.
    }
    if (is_resource_type(c, elem)) {
        return TY_ERROR;   // OFI-122: a `resource` is uniquely owned; it cannot ride a shareable channel.
    }
    for (int i = 0; i < c->channel_count; i++) {
        if (c->channels[i] == elem) {
            return (SemType)(CHANNEL_BASE + i);
        }
    }
    if (c->channel_count >= MAX_STRUCTS) {
        return TY_ERROR;
    }
    c->channels[c->channel_count] = elem;
    return (SemType)(CHANNEL_BASE + c->channel_count++);
}





static SemType channel_elem(Checker *c, SemType ch) {
    return c->channels[ch - CHANNEL_BASE];
}






// intern_fn_type returns the function type `fn(params) -> ret`, reusing an existing
// entry so two structurally identical function types share one id and compare ==.
static SemType intern_fn_type(Checker *c, const SemType *params, int param_count,
                              SemType ret) {
    if (param_count > MAX_PARAMS) {
        param_count = MAX_PARAMS;
    }
    for (int i = 0; i < c->fntype_count; i++) {
        FnType *f = &c->fntypes[i];
        if (f->param_count != param_count || f->ret != ret) {
            continue;
        }
        int same = 1;
        for (int k = 0; k < param_count; k++) {
            if (f->params[k] != params[k]) {
                same = 0;
                break;
            }
        }
        if (same) {
            return (SemType)(FN_BASE + i);
        }
    }
    if (c->fntype_count >= MAX_STRUCTS) {
        return TY_ERROR;
    }
    FnType *f = &c->fntypes[c->fntype_count];
    f->param_count = param_count;
    f->ret         = ret;
    for (int k = 0; k < param_count; k++) {
        f->params[k] = params[k];
    }
    return (SemType)(FN_BASE + c->fntype_count++);
}






static FnType *fn_type_of(Checker *c, SemType t) {
    return &c->fntypes[t - FN_BASE];
}




// render_type writes a SemType's surface form ("int", "[string]", "Point",
// "Box<int>", "fn(int) -> bool") into `buf`, using the checker's type tables to
// name structs, enums, and generic instances. It is the checker-side counterpart
// of the parser-level `type_str`/`fmt_type` formatters; here the names come from
// resolved type ids, not AST annotations, so it can describe an *inferred* type
// the source never spelled out. Only the semantic index (LSP hover) uses it, so
// it favours clarity over completeness — an unprintable corner renders as "?".
static void render_type(Checker *c, SemType t, char *buf, size_t cap) {
    if (cap == 0) {
        return;
    }
    const char *prim = NULL;
    switch (t) {
        case TY_ERROR:  prim = "?";      break;
        case TY_INT:    prim = "int";    break;
        case TY_BOOL:   prim = "bool";   break;
        case TY_FLOAT:  prim = "float";  break;
        case TY_STRING: prim = "string"; break;
        case TY_UNIT:   prim = "()";     break;
        case TY_SELF:   prim = "Self";   break;
        case TY_I8:  prim = "i8";  break;
        case TY_I16: prim = "i16"; break;
        case TY_I32: prim = "i32"; break;
        case TY_U8:  prim = "u8";  break;
        case TY_U16: prim = "u16"; break;
        case TY_U32: prim = "u32"; break;
        case TY_U64: prim = "u64"; break;
        case TY_F32: prim = "f32"; break;
        case TY_PTR: prim = "Ptr"; break;
        default: break;
    }
    if (prim != NULL) {
        snprintf(buf, cap, "%s", prim);
        return;
    }
    if (is_struct_type(t) && t < c->struct_count) {
        snprintf(buf, cap, "%s", c->structs[t].name);
        return;
    }
    if (is_enum_type(t)) {
        int id = enum_id_of(t);
        if (id >= 0 && id < c->enum_count) {
            snprintf(buf, cap, "%s", c->enums[id].name);
            return;
        }
    }
    if (is_array_type(t)) {
        char elem[96];
        render_type(c, c->arrays[t - ARRAY_BASE], elem, sizeof elem);
        snprintf(buf, cap, "[%s]", elem);
        return;
    }
    if (is_channel_type(t)) {
        char elem[96];
        render_type(c, c->channels[t - CHANNEL_BASE], elem, sizeof elem);
        snprintf(buf, cap, "channel<%s>", elem);
        return;
    }
    if (is_generic_inst(t)) {
        GenericInst *gi = &c->ginsts[t - GENERIC_BASE];
        const char *base = gi->is_enum
                               ? (gi->base < c->enum_count ? c->enums[gi->base].name : "?")
                               : (gi->base < c->struct_count ? c->structs[gi->base].name : "?");
        size_t o = (size_t)snprintf(buf, cap, "%s<", base);
        for (int i = 0; i < gi->arg_count && o < cap; i++) {
            char arg[96];
            render_type(c, gi->args[i], arg, sizeof arg);
            o += (size_t)snprintf(buf + o, o < cap ? cap - o : 0,
                                  "%s%s", i ? ", " : "", arg);
        }
        if (o < cap) {
            snprintf(buf + o, cap - o, ">");
        }
        return;
    }
    if (is_fn_type(t)) {
        FnType *f = fn_type_of(c, t);
        size_t o = (size_t)snprintf(buf, cap, "fn(");
        for (int i = 0; i < f->param_count && o < cap; i++) {
            char p[96];
            render_type(c, f->params[i], p, sizeof p);
            o += (size_t)snprintf(buf + o, o < cap ? cap - o : 0,
                                  "%s%s", i ? ", " : "", p);
        }
        char ret[96];
        render_type(c, f->ret, ret, sizeof ret);
        snprintf(buf + o, o < cap ? cap - o : 0, ") -> %s", ret);
        return;
    }
    if (is_type_param(t)) {
        int idx = t - PARAM_BASE;
        if (c->tparams != NULL && idx < c->tparam_count) {
            snprintf(buf, cap, "%s", c->tparams[idx]);
            return;
        }
    }
    if (is_interface_type(t)) {
        int id = interface_id_of(t);
        if (id >= 0 && id < c->interface_count) {
            snprintf(buf, cap, "%s", c->interfaces[id].name);
            return;
        }
    }
    snprintf(buf, cap, "?");
}




// sem_record_local logs an identifier occurrence that resolved to a local or
// parameter into the semantic index (no-op when no index is being built). The
// span is the identifier's own extent; the detail is the binding the LSP shows on
// hover, and def_line/def_col point at where it was introduced.
static void sem_record_local(Checker *c, Expr *e, int slot) {
    if (c->index == NULL || e->kind != EXPR_IDENT) {
        return;
    }
    Local *l = &c->locals[slot];
    char type[160];
    render_type(c, l->type, type, sizeof type);
    char detail[256];
    if (l->is_param) {
        snprintf(detail, sizeof detail, "%s: %s", e->as.ident, type);
    } else {
        snprintf(detail, sizeof detail, "%s %s: %s",
                 l->is_var ? "var" : "let", e->as.ident, type);
    }
    SemEntry se   = SEM_ENTRY_INIT;
    se.line       = e->line;
    se.col        = e->col;
    se.end_col    = e->col + (int)strlen(e->as.ident);
    se.kind       = l->is_param ? SK_PARAM : SK_LOCAL;
    se.type       = type;
    se.detail     = detail;
    se.def_line   = l->def_line;
    se.def_col    = l->def_col;
    se.ref_file   = c->modules != NULL ? (char *)c->modules->modules[c->current_module].path : NULL;
    semindex_add_entry(c->index, &se);
}




// sem_record_field logs a field access (`object.field`) into the semantic index, keyed at the
// FIELD name's own position (not the object's), so hovering `.field` shows the field's resolved
// type and go-to-definition jumps to `def_line`/`def_col` — where the field was declared in its
// struct.
static void sem_record_field(Checker *c, Expr *e, SemType ft, int def_line, int def_col,
                             const char *container, int byte_offset, int byte_size) {
    if (c->index == NULL || e->kind != EXPR_GET || e->as.get.name_line == 0) {
        return;
    }
    char type[160];
    render_type(c, ft, type, sizeof type);
    char detail[256];
    snprintf(detail, sizeof detail, "%s: %s", e->as.get.name, type);
    SemEntry se     = SEM_ENTRY_INIT;
    se.line         = e->as.get.name_line;
    se.col          = e->as.get.name_col;
    se.end_col      = e->as.get.name_col + (int)strlen(e->as.get.name);
    se.kind         = SK_FIELD;
    se.type         = type;
    se.detail       = detail;
    se.container    = (char *)container;   // owning struct, e.g. "Point" (copied in by add_entry)
    se.byte_offset  = byte_offset;
    se.byte_size    = byte_size;
    se.def_line     = def_line;
    se.def_col      = def_col;
    se.ref_file     = c->modules != NULL ? (char *)c->modules->modules[c->current_module].path : NULL;
    semindex_add_entry(c->index, &se);
}




// A bounded string sink for the shared formatter (typefmt.h): typefmt_fn writes a method's
// signature into a fixed buffer so the checker can store it in the index (which outlives the AST
// arena). Overflow is silently truncated — a hover label, not data.
typedef struct {
    char  *buf;
    size_t cap;
    size_t len;
} StrSink;

static void strsink_put(void *ctx, const char *s) {
    StrSink *ss = (StrSink *)ctx;
    size_t   n  = strlen(s);
    if (ss->len + n < ss->cap) {
        memcpy(ss->buf + ss->len, s, n);
        ss->len += n;
        ss->buf[ss->len] = '\0';
    }
}




// sem_record_method logs a method call (`object.method(...)`) into the semantic index, keyed at the
// METHOD name's position on the call's `EXPR_GET` callee, so hovering it shows the method signature
// and go-to-definition jumps to the method (when it lives in the same file). The signature is
// rendered through the one shared formatter so it matches a free function's hover.
static void sem_record_method(Checker *c, const Expr *callee, const MethodInfo *mi,
                              const char *container, int same_file) {
    if (c->index == NULL || callee->kind != EXPR_GET || callee->as.get.name_line == 0 ||
        mi->decl == NULL) {
        return;
    }
    char    sig[256];
    sig[0] = '\0';
    StrSink ss   = { sig, sizeof sig, 0 };
    TypeSink sink = { strsink_put, &ss };
    typefmt_fn(&sink, mi->decl);
    SemEntry se   = SEM_ENTRY_INIT;
    se.line       = callee->as.get.name_line;
    se.col        = callee->as.get.name_col;
    se.end_col    = callee->as.get.name_col + (int)strlen(callee->as.get.name);
    se.kind       = SK_METHOD;
    se.detail     = sig;
    se.container  = (char *)container;  // owning struct, e.g. "Point" (copied in by add_entry)
    se.doc        = (char *)mi->decl->doc;
    se.def_line   = same_file ? mi->decl->line : 0;
    se.def_col    = same_file ? mi->decl->col  : 0;
    se.ref_file   = c->modules != NULL ? (char *)c->modules->modules[c->current_module].path : NULL;
    semindex_add_entry(c->index, &se);
}




// sem_record_at is the low-level recorder shared by the A2/A3 reference recorders below: it
// logs an identifier occurrence at (line, col) spanning `name`, with the given kind and the
// optional descriptive strings (all copied in by semindex_add_entry, so transient buffers are
// fine). A NULL index, line==0, or name==NULL is a no-op.
static void sem_record_at(Checker *c, int line, int col, const char *name, SemKind kind,
                          const char *detail, const char *container, const char *doc,
                          const char *value, const char *def_file, int def_line, int def_col) {
    if (c->index == NULL || line == 0 || name == NULL) {
        return;
    }
    SemEntry se   = SEM_ENTRY_INIT;
    se.line       = line;
    se.col        = col;
    se.end_col    = col + (int)strlen(name);
    se.kind       = kind;
    se.detail     = (char *)detail;
    se.container  = (char *)container;
    se.doc        = (char *)doc;
    se.value      = (char *)value;
    se.def_file   = (char *)def_file;
    se.def_line   = def_line;
    se.def_col    = def_col;
    // The file this occurrence lives in — lets the LSP attribute cross-module references to their
    // own file (project-wide find-references / rename). It is the module currently being checked.
    se.ref_file   = c->modules != NULL ? (char *)c->modules->modules[c->current_module].path : NULL;
    semindex_add_entry(c->index, &se);
}




// sem_record_intrinsic logs a BUILT-IN array/string method call (`a.append(x)`, `s.chars()`, …)
// into the semantic index, keyed at the method name's position on the call's `EXPR_GET` callee.
// These intrinsics are special-cased in the checker rather than resolved through a struct's method
// table, so without this they leave no index entry and hover finds nothing (OFI-038). The one-line
// signature is rendered from the receiver / parameter / return SemTypes through the same
// `render_type` the rest of the index uses, so the card matches a real method's surface syntax:
// `pname == NULL` means no parameter, `ret == TY_UNIT` means no `-> ` clause. There is no def site
// (the method is native), so go-to-definition is intentionally a no-op. A no-op in batch mode.
static void sem_record_intrinsic(Checker *c, const Expr *callee, SemType recv_t,
                                 const char *pname, SemType param_t, SemType ret,
                                 const char *doc) {
    if (c->index == NULL || callee->kind != EXPR_GET || callee->as.get.name_line == 0) {
        return;
    }
    char   recv[128], sig[224];
    render_type(c, recv_t, recv, sizeof recv);
    size_t o = (size_t)snprintf(sig, sizeof sig, "fn %s(", callee->as.get.name);
    if (pname != NULL) {
        char pt[96];
        render_type(c, param_t, pt, sizeof pt);
        o += (size_t)snprintf(sig + o, o < sizeof sig ? sizeof sig - o : 0,
                              "%s: %s", pname, pt);
    }
    o += (size_t)snprintf(sig + o, o < sizeof sig ? sizeof sig - o : 0, ")");
    if (ret != TY_UNIT) {
        char rt[96];
        render_type(c, ret, rt, sizeof rt);
        snprintf(sig + o, o < sizeof sig ? sizeof sig - o : 0, " -> %s", rt);
    }
    sem_record_at(c, callee->as.get.name_line, callee->as.get.name_col, callee->as.get.name,
                  SK_METHOD, sig, recv, doc, NULL, NULL, 0, 0);
}




// sem_record_fn logs a top-level function reference (a call's callee, or a bare function value)
// keyed at the name's position, with the function's signature (rendered through the shared
// formatter so it matches a method's hover), its `///` doc, and its declaration site. `container`
// names the owning module for a cross-module reference (NULL = same module); `def_file` likewise
// gives a cross-file definition path (NULL = same file).
static void sem_record_fn(Checker *c, int line, int col, const char *name, const FnSig *sig,
                          const char *container, const char *def_file) {
    if (c->index == NULL || sig->decl == NULL || line == 0) {
        return;
    }
    char    buf[256];
    buf[0] = '\0';
    StrSink  ss   = { buf, sizeof buf, 0 };
    TypeSink sink = { strsink_put, &ss };
    typefmt_fn(&sink, sig->decl);
    sem_record_at(c, line, col, name, SK_FUNCTION, buf, container, sig->decl->doc,
                  NULL, def_file, sig->decl->line, sig->decl->col);
}




// const_value_str renders a constant's literal initializer to a short display string ("42",
// "3.14", "true", "-1", or a quoted string) for the hover card. Returns 1 on success.
static int const_value_str(const Expr *v, char *out, size_t cap) {
    if (v == NULL) {
        return 0;
    }
    switch (v->kind) {
        case EXPR_INT:   snprintf(out, cap, "%lld", (long long)v->as.int_lit);   return 1;
        case EXPR_FLOAT: snprintf(out, cap, "%g", v->as.float_lit);              return 1;
        case EXPR_BOOL:  snprintf(out, cap, "%s", v->as.bool_lit ? "true" : "false"); return 1;
        case EXPR_UNARY:
            if (v->as.unary.op == TOK_MINUS) {
                char inner[64];
                if (const_value_str(v->as.unary.operand, inner, sizeof inner)) {
                    snprintf(out, cap, "-%s", inner);
                    return 1;
                }
            }
            return 0;
        default: return 0;   // a string or non-literal — omit the value (still shows type)
    }
}




// sem_record_const logs a reference to a top-level `let` constant (`gi` indexes c->globals)
// keyed at the name's position, with its type, evaluated value, and declaration site.
static void sem_record_const(Checker *c, int line, int col, const char *name, int gi,
                             const char *container, const char *def_file) {
    if (c->index == NULL || line == 0) {
        return;
    }
    char type[160];
    render_type(c, c->globals[gi].type, type, sizeof type);
    char detail[256];
    snprintf(detail, sizeof detail, "%s: %s", name, type);
    char value[96];
    int  has_v = const_value_str(c->globals[gi].value, value, sizeof value);
    sem_record_at(c, line, col, name, SK_CONSTANT, detail, container, NULL,
                  has_v ? value : NULL, def_file,
                  c->globals[gi].def_line, c->globals[gi].def_col);
}




// sem_record_variant logs a reference to an enum variant (`Some`, `Ok`, a user variant) keyed at
// the name's position, rendering its payload signature ("Some(value: T)") and naming its enum.
static void sem_record_variant(Checker *c, int line, int col, const VariantInfo *v) {
    if (c->index == NULL || line == 0) {
        return;
    }
    char detail[256];
    int  n = snprintf(detail, sizeof detail, "%s", v->name);
    if (v->field_count > 0) {
        n += snprintf(detail + n, sizeof detail - (size_t)n, "(");
        for (int i = 0; i < v->field_count && n < (int)sizeof detail; i++) {
            char ft[120];
            render_type(c, v->fields[i], ft, sizeof ft);
            n += snprintf(detail + n, sizeof detail - (size_t)n, "%s%s",
                          i ? ", " : "", ft);
        }
        n += snprintf(detail + n, sizeof detail - (size_t)n, ")");
    }
    const char *enum_name = c->enums[v->enum_id].name;
    sem_record_at(c, line, col, v->name, SK_VARIANT, detail, enum_name, NULL, NULL, NULL, 0, 0);
}




// sem_record_type logs a reference to a struct/enum NAME in a type annotation (`p: Point`,
// `[Shape]`, `Box<int>`) keyed at the name's position, so hovering the type shows what it is
// and go-to-definition jumps to its declaration. `t` carries the name's source span.
static void sem_record_type(Checker *c, const Type *t, int is_enum, int base,
                            const char *container, const char *def_file) {
    if (c->index == NULL || t == NULL || t->line == 0) {
        return;
    }
    const char *name = (t->kind == TYPE_GENERIC) ? t->as.generic.name : t->as.name.name;
    char detail[160];
    int  def_line, def_col;
    if (is_enum) {
        snprintf(detail, sizeof detail, "enum %s", c->enums[base].name);
        def_line = c->enums[base].def_line;
        def_col  = c->enums[base].def_col;
    } else {
        snprintf(detail, sizeof detail, "struct %s", c->structs[base].name);
        def_line = c->structs[base].def_line;
        def_col  = c->structs[base].def_col;
    }
    sem_record_at(c, t->line, t->col, name, SK_TYPE, detail, container, NULL, NULL,
                  def_file, def_line, def_col);
}




// sem_record_module logs a reference to an import alias (the `ui` in `ui.window`) as a module,
// keyed at the alias token's position, with the imported file as its definition.
static void sem_record_module(Checker *c, const Expr *alias_node, int target_mod) {
    if (c->index == NULL || alias_node == NULL || alias_node->kind != EXPR_IDENT) {
        return;
    }
    const char *path = c->modules->modules[target_mod].path;
    sem_record_at(c, alias_node->line, alias_node->col, alias_node->as.ident, SK_MODULE,
                  alias_node->as.ident, NULL, NULL, NULL, path, path != NULL ? 1 : 0, 1);
}




// diag_src is the file a diagnostic should be attributed to: the module CURRENTLY being checked, so
// an error raised while checking an imported module names that module's file (the language server
// filters diagnostics by file), not the entry point. Falls back to c->src before modules are wired.
static const char *diag_src(const Checker *c) {
    if (c->modules != NULL && c->modules->modules[c->current_module].path != NULL) {
        return c->modules->modules[c->current_module].path;
    }
    return c->src;
}


static void type_error(Checker *c, int line, int col, const char *msg) {
    diag_error(diag_src(c), line, col, msg, NULL, NULL);
    c->had_error = 1;
}


// ptr_storage_error rejects a `Ptr` used where it would be STORED inside an aggregate — an array or
// slice element, a struct/enum field, a channel element, or a generic type argument. A `Ptr` is a
// LINEAR FFI handle with no Ember destructor (OFI-049): it must live in a local and be closed on every
// path. An aggregate cannot discharge that obligation (and under generic erasure the body is checked
// once with the parameter as `PARAM_BASE+k`, so no value-site `TY_PTR` guard ever sees it), so the
// only sound rule is to forbid the type from forming. `where` names the offending position. Returns 1
// (and emits) iff `inner` is `TY_PTR`. Mirrors the defensive TY_PTR floor in intern_array/_channel/
// _generic, which keep any inference path I did not name here sound (it surfaces as a type error).
static int ptr_storage_error(Checker *c, SemType inner, int line, int col, const char *where) {
    if (inner != TY_PTR) {
        return 0;
    }
    char msg[200];
    snprintf(msg, sizeof msg,
             "a 'Ptr' is a linear FFI handle and cannot be %s", where);
    diag_error(diag_src(c), line, col, msg, NULL,
               "a 'Ptr' has no destructor — keep it in a local and close it (e.g. fclose), "
               "or pass it by 'move'; it cannot be stored in an array, field, channel, or "
               "generic container (where its close obligation would be lost)");
    c->had_error = 1;
    return 1;
}


// is_resource_type reports whether `t` is a `resource struct` (a uniquely-owned, drop-bearing type).
// Resources are never generic (R1 bans generic resource structs), so a direct struct check suffices.
static int is_resource_type(Checker *c, SemType t) {
    return is_struct_type(t) && c->structs[t].is_resource;
}


// resource_storage_error rejects a `resource` used where it would be CLONED — an array/slice/channel
// element, a generic STRUCT argument (Box<R>/Map<_,R>), or a field of a non-resource struct (OFI-122).
// A resource is uniquely owned with a `drop`; duplicating it (a shallow copy of its handle fields)
// would run drop twice → double-close. Phase 1 keeps a resource in a local, a Result/Option payload,
// a field of ANOTHER resource, or a return value; collections (pools/caches) are Phase 2. Returns 1
// (and emits) iff `inner` is a resource. `where` names the offending position.
static int resource_storage_error(Checker *c, SemType inner, int line, int col, const char *where) {
    if (!is_resource_type(c, inner)) {
        return 0;
    }
    char msg[220];
    snprintf(msg, sizeof msg,
             "a 'resource' is uniquely owned and cannot be %s", where);
    diag_error(diag_src(c), line, col, msg, NULL,
               "a 'resource' has a 'drop' that runs once per value — duplicating it would double-free; "
               "keep it in a local, a Result/Option, a field of another 'resource', or a return value "
               "(collections come in a later phase)");
    c->had_error = 1;
    return 1;
}


// recv_reads_as_copy reports whether reading expression `r` materialises a COPY disconnected from
// storage (indexing clones the element; an inline value-struct field is boxed as a copy) rather than
// the live handle. A mutating method whose receiver reads as a copy mutates the copy (OFI-072) —
// `append` is rewritten to write back, but `remove_last` is rejected here until its write-back lands
// (its result element rides on top of the moved-out array copy, which the VM codegen can only thread
// at a clean-stack statement position, not as a sub-expression — see OFI-072). Matches the backends'
// expr_reads_as_copy / cgc_reads_as_copy.
static int recv_reads_as_copy(const Expr *r) {
    if (r->kind == EXPR_INDEX) {
        return 1;
    }
    if (r->kind == EXPR_GET) {
        if (r->as.get.inline_field) {
            return 1;
        }
        return recv_reads_as_copy(r->as.get.object);
    }
    return 0;
}





// resolve_local returns the index of a declared local by name, searching
// innermost-first so a shadowing binding wins over the outer one it hides.
static int resolve_local(Checker *c, const char *name) {
    // A bare `_` is a write-only discard wildcard (OFI-095): it binds nothing readable,
    // so it is never resolvable and reading it is an undefined-identifier error. Match the
    // EXACT name "_" only — never a leading-underscore name like `_foo`, which is the
    // module-privacy marker (OFI-081) and stays an ordinary readable binding.
    if (name[0] == '_' && name[1] == '\0') {
        return -1;
    }
    for (int i = c->local_count - 1; i >= 0; i--) {
        if (strcmp(c->locals[i].name, name) == 0) {
            return i;
        }
    }
    return -1;
}





// grow_arena_vec ensures an arena-backed dynamic vector holds at least `need` elements of `elem`
// bytes. It doubles the capacity, bump-allocates the larger buffer from the arena (so the old buffer
// is reclaimed wholesale at compile end — no per-grow free), copies the `count` live elements over,
// and returns the new base; `*cap` is updated in place. This is the single growth primitive behind
// every cap-free checker table — locals, top-level functions, per-struct fields, per-enum variants —
// so none of them imposes a ceiling (the matching bytecode operands are all LEB128 OPK_IDX, which
// cannot overflow). Grows at most log2(N) times, so the wasted intermediate buffers are negligible.
static void *grow_arena_vec(Arena *arena, void *base, int count, int *cap, int need, size_t elem) {
    if (need <= *cap) {
        return base;
    }
    int ncap = *cap ? *cap * 2 : 8;
    while (ncap < need) {
        ncap *= 2;
    }
    void *grown = arena_alloc(arena, (size_t)ncap * elem);
    if (count > 0) {
        memcpy(grown, base, (size_t)count * elem);
    }
    *cap = ncap;
    return grown;
}


// ensure_locals_cap grows the dynamic locals vector (no per-function cap on local variables).
static void ensure_locals_cap(Checker *c, int need) {
    c->locals = grow_arena_vec(c->arena, c->locals, c->local_count, &c->locals_cap,
                               need, sizeof(Local));
}


// ensure_fns_cap grows the dynamic top-level-function signature vector (no cap on function count;
// the program function table + mono plan already size by the true total — build_mono_instances).
static void ensure_fns_cap(Checker *c, int need) {
    c->fns = grow_arena_vec(c->arena, c->fns, c->fn_count, &c->fns_cap, need, sizeof(FnSig));
}


// ensure_structs_cap grows the dynamic struct-type (StructInfo) vector. Struct ids span [0, ENUM_BASE)
// so the id space has no cap; the vector grows ONLY in pass 1a (struct-name registration), and every
// other `&c->structs[id]` runs after that with the base stable — no cached pointer is invalidated. The
// monomorphized generic instances do not live here (they are StructLayout entries — see build_layouts).
static void ensure_structs_cap(Checker *c, int need) {
    c->structs = grow_arena_vec(c->arena, c->structs, c->struct_count, &c->structs_cap,
                                need, sizeof(StructInfo));
}


// declare_local registers a new binding. Redeclaring a name already bound *in
// the same scope* is an error; shadowing a name from an outer scope is allowed.
static void declare_local(Checker *c, int line, int col, const char *name,
                          int is_var, SemType type, int owned) {
    // A bare `_` is a discard wildcard (OFI-095): it may be (re)bound any number of times
    // in one scope, so skip the same-scope redeclaration check for it. EXACT name "_" only
    // (never a leading-underscore name — that is the module-privacy marker, OFI-081). It is
    // still given a real slot below, so an owned value is dropped at scope exit and a
    // discarded linear `Ptr` is still flagged as opened-but-not-closed.
    int discard = (name[0] == '_' && name[1] == '\0');
    if (!discard) {
        for (int i = c->local_count - 1; i >= 0; i--) {
            if (c->locals[i].depth < c->scope_depth) {
                break;   // reached an enclosing scope — no same-scope clash
            }
            if (strcmp(c->locals[i].name, name) == 0) {
                type_error(c, line, col, "redeclaration of a variable in the same scope");
                return;
            }
        }
    }
    ensure_locals_cap(c, c->local_count + 1);
    c->locals[c->local_count] = (Local){0};   // a fresh binding owns no slice-freeze / move state
    c->locals[c->local_count].name   = name;
    c->locals[c->local_count].is_var = is_var;
    c->locals[c->local_count].type   = type;
    c->locals[c->local_count].depth  = c->scope_depth;
    c->locals[c->local_count].owned  = owned;
    c->locals[c->local_count].moved  = 0;
    c->locals[c->local_count].move_line = 0;
    c->locals[c->local_count].move_col  = 0;
    c->locals[c->local_count].decl   = NULL;
    c->locals[c->local_count].multislot_sid = -1;   // set by the caller for a multi-slot binding
    c->locals[c->local_count].def_line = line;      // semantic index: go-to-definition target
    c->locals[c->local_count].def_col  = col;
    c->locals[c->local_count].open_line = line;     // OFI-049: "opened here" note for a leaked Ptr
    c->locals[c->local_count].open_col  = col;
    c->locals[c->local_count].is_param = 0;
    c->local_count++;
}






// reserve_hidden_slot claims a stack slot for a codegen temporary that has no
// source name (a `for` loop's array/index/length). It mirrors the hidden slots
// codegen allocates so the two stay in lock-step: a lambda inside the body records
// capture slots by the checker's numbering, and codegen reads them back, so the two
// must agree. The "" name is unmatchable by resolve_local (no identifier is empty),
// so it never shadows; it owns nothing, so scope exit drops it for free.
static void reserve_hidden_slot(Checker *c) {
    ensure_locals_cap(c, c->local_count + 1);
    c->locals[c->local_count] = (Local){0};   // a fresh hidden slot owns no slice-freeze / move state
    c->locals[c->local_count].name   = "";
    c->locals[c->local_count].is_var = 0;
    c->locals[c->local_count].type   = TY_INT;
    c->locals[c->local_count].depth  = c->scope_depth;
    c->locals[c->local_count].owned  = 0;
    c->locals[c->local_count].moved  = 0;
    c->locals[c->local_count].decl   = NULL;
    c->locals[c->local_count].multislot_sid = -1;
    c->locals[c->local_count].def_line = 0;
    c->locals[c->local_count].def_col  = 0;
    c->locals[c->local_count].is_param = 0;
    c->local_count++;
}





// resolve_struct returns the struct-type id for a name in the current module
// (unqualified names are module-local), or -1 if there is none.
static int resolve_struct(Checker *c, const char *name) {
    for (int i = 0; i < c->struct_count; i++) {
        if ((c->structs[i].module == c->current_module ||
             is_global_module(c->modules, c->structs[i].module)) &&
            strcmp(c->structs[i].name, name) == 0) {
            return i;
        }
    }
    return -1;
}





// intern_generic returns the SemType for a generic instantiation (base + args),
// reusing an existing interned instance or adding a new one so the same
// instantiation always has the same id.
static SemType intern_generic(Checker *c, int base, int is_enum,
                              const SemType *args, int n) {
    for (int a = 0; a < n; a++) {
        if (args[a] == TY_PTR) {
            return TY_ERROR;   // OFI-049: a Ptr is linear — never a generic type argument (it would
        }                      // escape linearity under erasure). Sites with source context message it.
    }
    for (int i = 0; i < c->ginst_count; i++) {
        GenericInst *g = &c->ginsts[i];
        if (g->base != base || g->is_enum != is_enum || g->arg_count != n) {
            continue;
        }
        int same = 1;
        for (int a = 0; a < n; a++) {
            if (g->args[a] != args[a]) {
                same = 0;
                break;
            }
        }
        if (same) {
            return (SemType)(GENERIC_BASE + i);
        }
    }
    if (c->ginst_count >= MAX_STRUCTS) {
        return TY_ERROR;
    }
    GenericInst *g = &c->ginsts[c->ginst_count];
    g->base      = base;
    g->is_enum   = is_enum;
    g->arg_count = n;
    for (int a = 0; a < n; a++) {
        g->args[a] = args[a];
    }
    return (SemType)(GENERIC_BASE + c->ginst_count++);
}






// option_of returns the SemType for `Option<elem>`. `Option` normally comes from
// the always-in-scope prelude, but is resolved here by shape rather than identity
// so a program that declares its own `Option` (shadowing the prelude's) still
// works. `recv` returns this so a closed, drained channel can yield `None`.
// Reports an error and returns TY_ERROR if no suitable `Option<T>` is in scope.
// Matched by shape across all modules: one type parameter, a `Some` carrying one
// field, and a fieldless `None`.
static SemType option_of(Checker *c, SemType elem, int line, int col) {
    for (int i = 0; i < c->enum_count; i++) {
        EnumInfo *ei = &c->enums[i];
        if (strcmp(ei->name, "Option") != 0 || ei->generic_count != 1) {
            continue;
        }
        int some_ok = 0, none_ok = 0;
        for (int v = 0; v < ei->variant_count; v++) {
            if (strcmp(ei->variants[v].name, "Some") == 0 &&
                ei->variants[v].field_count == 1) {
                some_ok = 1;
            } else if (strcmp(ei->variants[v].name, "None") == 0 &&
                       ei->variants[v].field_count == 0) {
                none_ok = 1;
            }
        }
        if (some_ok && none_ok) {
            return intern_generic(c, i, 1, &elem, 1);
        }
    }
    type_error(c, line, col,
               "recv returns Option<T>, but no matching Option is in scope; "
               "declare `enum Option<T> { Some(value: T)  None }`");
    return TY_ERROR;
}





// subst replaces type parameters with the corresponding arguments of a generic
// instance. It recurses into nested generic instantiations (a `Box<T>` field of
// `Outer<T>` becomes `Box<int>` under `Outer<int>`), re-interning the result;
// other types pass through. Used when reading a generic value's field/variant.
static SemType subst(Checker *c, const GenericInst *inst, SemType t) {
    if (is_type_param(t)) {
        int i = t - PARAM_BASE;
        return i < inst->arg_count ? inst->args[i] : t;
    }
    if (is_generic_inst(t)) {
        // Copy first: interning below may append to c->ginsts, and we must not
        // read through a pointer into the array across that.
        GenericInst g = c->ginsts[t - GENERIC_BASE];
        SemType args[MAX_TYPE_ARGS];
        for (int k = 0; k < g.arg_count; k++) {
            args[k] = subst(c, inst, g.args[k]);
        }
        return intern_generic(c, g.base, g.is_enum, args, g.arg_count);
    }
    if (is_array_type(t)) {
        return intern_array(c, subst(c, inst, c->arrays[t - ARRAY_BASE]));
    }
    if (is_fn_type(t)) {
        FnType f = *fn_type_of(c, t);   // copy: interning may append to fntypes
        SemType params[MAX_PARAMS];
        for (int i = 0; i < f.param_count; i++) {
            params[i] = subst(c, inst, f.params[i]);
        }
        return intern_fn_type(c, params, f.param_count, subst(c, inst, f.ret));
    }
    return t;
}





// inst_is_concrete reports whether a generic instantiation has no type-parameter
// arguments left (so it can be given a packed per-instance layout). A nested
// generic argument (Box<Box<int>>) counts as concrete — that field is a pointer.
static int inst_is_concrete(const GenericInst *g) {
    for (int i = 0; i < g->arg_count; i++) {
        if (is_type_param(g->args[i])) {
            return 0;
        }
    }
    return 1;
}

// struct_instance_id returns the appended struct type id for a concrete generic
// struct instance (Box<int>), assigning a fresh one on first use. Field access
// then resolves offsets through this instance's own descriptor at run time.
static int struct_instance_id(Checker *c, SemType st) {
    int gi = (int)st - GENERIC_BASE;
    if (c->sinst_of[gi] >= 0) {
        return c->sinst_of[gi];
    }
    if (c->sinst_count >= MAX_STRUCTS) {
        return c->ginsts[gi].base;   // table full: fall back to the shared base
    }
    int id = c->struct_count + c->sinst_count;
    c->sinst_of[gi]              = id;
    c->sinst_ginst[c->sinst_count] = gi;
    c->sinst_count++;
    return id;
}


// unify matches a signature type `pat` (which may contain type parameters)
// against a concrete type `conc`, binding each parameter it meets. A bare `T`
// binds directly; a generic instance like `Box<T>` recurses into a matching
// `Box<int>`. First binding wins (later conflicts are caught when arguments are
// re-checked against the substituted signature). This is the inference engine for
// generic calls.
static void unify(Checker *c, SemType pat, SemType conc, SemType *bind,
                  int *bound, int gcount) {
    if (is_type_param(pat)) {
        int k = pat - PARAM_BASE;
        if (k < gcount && !bound[k] && conc != TY_ERROR) {
            bind[k]  = conc;
            bound[k] = 1;
        }
        return;
    }
    if (is_generic_inst(pat) && is_generic_inst(conc)) {
        GenericInst p = c->ginsts[pat - GENERIC_BASE];
        GenericInst q = c->ginsts[conc - GENERIC_BASE];
        if (p.base == q.base && p.is_enum == q.is_enum &&
            p.arg_count == q.arg_count) {
            for (int i = 0; i < p.arg_count; i++) {
                unify(c, p.args[i], q.args[i], bind, bound, gcount);
            }
        }
        return;
    }
    // An array `[T]` against `[int]` binds T to int; a function `fn(T) -> U`
    // against `fn(int) -> bool` binds each parameter and the result in turn.
    if (is_array_type(pat) && is_array_type(conc)) {
        unify(c, c->arrays[pat - ARRAY_BASE], c->arrays[conc - ARRAY_BASE],
              bind, bound, gcount);
        return;
    }
    if (is_fn_type(pat) && is_fn_type(conc)) {
        FnType *pf = fn_type_of(c, pat);
        FnType *qf = fn_type_of(c, conc);
        if (pf->param_count == qf->param_count) {
            for (int i = 0; i < pf->param_count; i++) {
                unify(c, pf->params[i], qf->params[i], bind, bound, gcount);
            }
            unify(c, pf->ret, qf->ret, bind, bound, gcount);
        }
        return;
    }
}





// resolve_enum returns the enum-type id for a name in the current module, or -1.
static int resolve_enum(Checker *c, const char *name) {
    for (int i = 0; i < c->enum_count; i++) {
        if ((c->enums[i].module == c->current_module ||
             is_global_module(c->modules, c->enums[i].module)) &&
            strcmp(c->enums[i].name, name) == 0) {
            return i;
        }
    }
    return -1;
}


// resolve_newtype returns the newtype id for a name in the current (or a global) module, or -1.
static int resolve_newtype(Checker *c, const char *name) {
    for (int i = 0; i < c->newtype_count; i++) {
        if ((c->newtypes[i].module == c->current_module ||
             is_global_module(c->modules, c->newtypes[i].module)) &&
            strcmp(c->newtypes[i].name, name) == 0) {
            return i;
        }
    }
    return -1;
}


// is_pure_expr (OFI-150): an expression with NO side effects, safe to RE-EVALUATE — a refined
// newtype's `where` predicate re-reads the constructor argument (as `self`) and the construction
// also produces it, so the two reads must yield the same value. Conservative: only obviously-pure
// forms (literals, names, field/index reads, numeric conversions, newtype constructions, and
// arithmetic/logic over those); a user/method call is impure.
static int is_pure_expr(Checker *c, const Expr *e) {
    switch (e->kind) {
        case EXPR_INT: case EXPR_FLOAT: case EXPR_BOOL: case EXPR_IDENT:
            return 1;
        case EXPR_STRING:
            for (size_t i = 0; i < e->as.str.part_count; i++) {
                if (e->as.str.parts[i].expr != NULL) {
                    return 0;   // an interpolation hole may call show()
                }
            }
            return 1;
        case EXPR_UNARY:
            return is_pure_expr(c, e->as.unary.operand);
        case EXPR_BINARY:
            return is_pure_expr(c, e->as.binary.left) && is_pure_expr(c, e->as.binary.right);
        case EXPR_GET:
            return is_pure_expr(c, e->as.get.object);
        case EXPR_INDEX:
            return is_pure_expr(c, e->as.index.object) && is_pure_expr(c, e->as.index.index);
        case EXPR_CALL:
            if (e->as.call.callee->kind == EXPR_IDENT &&
                (numeric_typename(e->as.call.callee->as.ident) != TY_ERROR ||
                 resolve_newtype(c, e->as.call.callee->as.ident) >= 0)) {
                for (size_t i = 0; i < e->as.call.arg_count; i++) {
                    if (!is_pure_expr(c, e->as.call.args[i])) {
                        return 0;
                    }
                }
                return 1;
            }
            return 0;
        default:
            return 0;
    }
}





// resolve_variant returns a variant by name among the current module's enums, or
// NULL. (Variants of imported enums are reached through their constructor — cross-
// module qualified variant construction is not yet supported.)
static VariantInfo *resolve_variant(Checker *c, const char *name) {
    for (int e = 0; e < c->enum_count; e++) {
        if (c->enums[e].module != c->current_module &&
            !is_global_module(c->modules, c->enums[e].module)) {
            continue;
        }
        for (int v = 0; v < c->enums[e].variant_count; v++) {
            if (strcmp(c->enums[e].variants[v].name, name) == 0) {
                return &c->enums[e].variants[v];
            }
        }
    }
    return NULL;
}





// enum_variant returns the named variant of a *specific* enum, or NULL — used to
// validate the qualified construction `EnumName.Variant`, where the enum is named
// explicitly rather than found by the variant's globally-unique name.
static VariantInfo *enum_variant(Checker *c, int eid, const char *name) {
    EnumInfo *ei = &c->enums[eid];
    for (int v = 0; v < ei->variant_count; v++) {
        if (strcmp(ei->variants[v].name, name) == 0) {
            return &ei->variants[v];
        }
    }
    return NULL;
}





// resolve_method returns a struct's method by name, or NULL if there is none.
static MethodInfo *resolve_method(Checker *c, int struct_id, const char *name) {
    StructInfo *si = &c->structs[struct_id];
    for (int i = 0; i < si->method_count; i++) {
        if (strcmp(si->methods[i].name, name) == 0) {
            return &si->methods[i];
        }
    }
    return NULL;
}





// annotation_type maps a type annotation to a SemType: a primitive, a
// type-parameter in scope, a (non-generic) struct/enum, or a generic
// instantiation `Name<args>`. Arrays and ill-formed types are TY_ERROR.
static int resolve_interface_id(Checker *c, const char *name);     // defined below
static int interface_object_safe(Checker *c, int iid);             // defined below
static int *build_witness(Checker *c, SemType type, int iid, int *out_count); // below
static int assignable(Checker *c, Expr *e, SemType actual, SemType expected);  // below
static int type_satisfies_bound(Checker *c, SemType t, int iid);               // below

static SemType annotation_type(Checker *c, const Type *t) {
    // A Slice<T> is legal only at the TOP of a parameter or let annotation (allow_slice set by
    // those callers). Capture that permission for this level and clear it for every nested type,
    // so `[Slice<T>]`, `Slice<T>` returns/fields, `Box<Slice<T>>`, etc. are rejected (slices §).
    int slice_ok = c->allow_slice;
    c->allow_slice = 0;
    if (t->kind == TYPE_ARRAY) {
        SemType elem = annotation_type(c, t->as.array.elem);
        if (elem == TY_ERROR || ptr_storage_error(c, elem, t->line, t->col, "an array element") ||
            resource_storage_error(c, elem, t->line, t->col, "an array element")) {
            return TY_ERROR;
        }
        return intern_array(c, elem);
    }

    if (t->kind == TYPE_FN) {
        SemType params[MAX_PARAMS];
        int n = (int)t->as.fn.param_count;
        if (n > MAX_PARAMS) {
            n = MAX_PARAMS;
        }
        for (int i = 0; i < n; i++) {
            params[i] = annotation_type(c, t->as.fn.params[i]);
            if (params[i] == TY_ERROR) {
                return TY_ERROR;
            }
        }
        SemType ret = t->as.fn.ret != NULL ? annotation_type(c, t->as.fn.ret)
                                           : TY_UNIT;
        if (ret == TY_ERROR) {
            return TY_ERROR;
        }
        return intern_fn_type(c, params, n, ret);
    }

    // Module-qualified type: `alias.Name` or `alias.Name<args>`. The base type is
    // looked up in the imported module (public only); any type arguments resolve
    // in the current module.
    const char *qual = (t->kind == TYPE_GENERIC) ? t->as.generic.qualifier
                     :                             t->as.name.qualifier;
    if (qual != NULL) {
        const char *tn = (t->kind == TYPE_GENERIC) ? t->as.generic.name
                                                   : t->as.name.name;
        const ModuleInfo *mi = &c->modules->modules[c->current_module];
        int target = -1;
        for (int i = 0; i < mi->import_count; i++) {
            if (strcmp(mi->aliases[i], qual) == 0) {
                target = mi->targets[i];
                break;
            }
        }
        if (target < 0) {
            type_error(c, t->line, t->col, "unknown module qualifier on a type");
            return TY_ERROR;
        }
        if (!is_public_name(tn)) {
            type_error(c, t->line, t->col,
                       "that type is private to its module (leading '_')");
            return TY_ERROR;
        }
        int sid = -1, eid = -1;
        for (int i = 0; i < c->struct_count; i++) {
            if (c->structs[i].module == target && strcmp(c->structs[i].name, tn) == 0) {
                sid = i;
                break;
            }
        }
        for (int i = 0; i < c->enum_count; i++) {
            if (c->enums[i].module == target && strcmp(c->enums[i].name, tn) == 0) {
                eid = i;
                break;
            }
        }
        int is_enum, base, param_count;
        if (sid >= 0) {
            base = sid; is_enum = 0; param_count = c->structs[sid].generic_count;
        } else if (eid >= 0) {
            base = eid; is_enum = 1; param_count = c->enums[eid].generic_count;
        } else {
            type_error(c, t->line, t->col,
                       "no such public type in the imported module");
            return TY_ERROR;
        }
        // LSP: cross-module hover/go-to-def on `mod.Type` (its owning module + def file).
        sem_record_type(c, t, is_enum, base, qual, c->modules->modules[target].path);
        if (t->kind == TYPE_NAME) {
            if (param_count != 0) {
                return TY_ERROR;   // a generic type named without arguments
            }
            return is_enum ? (SemType)(ENUM_BASE + base) : (SemType)base;
        }
        if ((size_t)param_count != t->as.generic.arg_count) {
            return TY_ERROR;
        }
        SemType args[MAX_TYPE_ARGS];
        int n = 0;
        for (size_t i = 0; i < t->as.generic.arg_count && n < MAX_TYPE_ARGS; i++) {
            args[n] = annotation_type(c, t->as.generic.args[i]);
            if (ptr_storage_error(c, args[n], t->line, t->col, "a generic type argument") ||
                (!is_enum &&
                 resource_storage_error(c, args[n], t->line, t->col, "a generic struct argument"))) {
                return TY_ERROR;   // OFI-049: no Option<Ptr>/…; OFI-122: no Box<R>/Map<_,R> (R is cloned)
            }
            n++;
        }
        return intern_generic(c, base, is_enum, args, n);
    }

    if (t->kind == TYPE_GENERIC) {
        // Built-in `Channel<T>` (one type argument).
        if (strcmp(t->as.generic.name, "Channel") == 0) {
            if (t->as.generic.arg_count != 1) {
                return TY_ERROR;
            }
            SemType elem = annotation_type(c, t->as.generic.args[0]);
            if (elem == TY_ERROR || ptr_storage_error(c, elem, t->line, t->col, "a channel element") ||
                resource_storage_error(c, elem, t->line, t->col, "a channel element")) {
                return TY_ERROR;
            }
            return intern_channel(c, elem);
        }
        // Built-in `Slice<T>` — a borrowed array view (slices §). Legal only at the top of a
        // parameter or let annotation; anywhere else it would let the view escape its source.
        if (strcmp(t->as.generic.name, "Slice") == 0) {
            if (t->as.generic.arg_count != 1) {
                return TY_ERROR;
            }
            if (!slice_ok) {
                type_error(c, t->line, t->col,
                           "a Slice<T> may appear only as a parameter type or a let binding — "
                           "it cannot be returned, stored in a field, or be an element (it is a "
                           "borrowed view); return an owned copy with .slice(a, b) instead");
                return TY_ERROR;
            }
            SemType elem = annotation_type(c, t->as.generic.args[0]);
            if (elem == TY_ERROR || ptr_storage_error(c, elem, t->line, t->col, "a slice element") ||
                resource_storage_error(c, elem, t->line, t->col, "a slice element")) {
                return TY_ERROR;
            }
            return intern_slice(c, elem);
        }
        // `Name<args>`: the base is a generic struct or enum with matching arity.
        int sbase = resolve_struct(c, t->as.generic.name);
        int ebase = resolve_enum(c, t->as.generic.name);
        int is_enum, base, param_count;
        if (sbase >= 0) {
            base = sbase; is_enum = 0; param_count = c->structs[sbase].generic_count;
        } else if (ebase >= 0) {
            base = ebase; is_enum = 1; param_count = c->enums[ebase].generic_count;
        } else {
            return TY_ERROR;
        }
        sem_record_type(c, t, is_enum, base, NULL, NULL);   // LSP: hover/go-to-def on the generic type name
        if ((size_t)param_count != t->as.generic.arg_count) {
            return TY_ERROR;
        }
        SemType args[MAX_TYPE_ARGS];
        int n = 0;
        for (size_t i = 0; i < t->as.generic.arg_count && n < MAX_TYPE_ARGS; i++) {
            args[n] = annotation_type(c, t->as.generic.args[i]);
            if (ptr_storage_error(c, args[n], t->line, t->col, "a generic type argument") ||
                (!is_enum &&
                 resource_storage_error(c, args[n], t->line, t->col, "a generic struct argument"))) {
                return TY_ERROR;   // OFI-049: no Option<Ptr>/…; OFI-122: no Box<R>/Map<_,R> (R is cloned)
            }
            n++;
        }
        return intern_generic(c, base, is_enum, args, n);
    }

    const char *name = t->as.name.name;
    // A type parameter in scope (within a generic declaration's body).
    for (int i = 0; i < c->tparam_count; i++) {
        if (strcmp(c->tparams[i], name) == 0) {
            return (SemType)(PARAM_BASE + i);
        }
    }
    if (strcmp(name, "int") == 0)    return TY_INT;
    if (strcmp(name, "i64") == 0)    return TY_INT;   // i64 is the canonical `int`
    if (strcmp(name, "i8") == 0)     return TY_I8;
    if (strcmp(name, "i16") == 0)    return TY_I16;
    if (strcmp(name, "i32") == 0)    return TY_I32;
    if (strcmp(name, "u8") == 0)     return TY_U8;
    if (strcmp(name, "u16") == 0)    return TY_U16;
    if (strcmp(name, "u32") == 0)    return TY_U32;
    if (strcmp(name, "u64") == 0)    return TY_U64;
    if (strcmp(name, "bool") == 0)   return TY_BOOL;
    if (strcmp(name, "float") == 0)  return TY_FLOAT;
    if (strcmp(name, "f64") == 0)    return TY_FLOAT;   // f64 is the canonical float
    if (strcmp(name, "f32") == 0)    return TY_F32;
    if (strcmp(name, "string") == 0) return TY_STRING;
    if (strcmp(name, "Ptr") == 0)    return TY_PTR;   // FFI: an opaque C handle (§5h)
    if (strcmp(name, "Self") == 0)   return TY_SELF;
    int sid = resolve_struct(c, name);
    if (sid >= 0) {
        sem_record_type(c, t, 0, sid, NULL, NULL);   // LSP: hover/go-to-def on the type name
        // A generic struct named without type arguments is ill-formed.
        return c->structs[sid].generic_count == 0 ? (SemType)sid : TY_ERROR;
    }
    int eid = resolve_enum(c, name);
    if (eid >= 0) {
        sem_record_type(c, t, 1, eid, NULL, NULL);   // LSP: hover/go-to-def on the type name
        return (SemType)(ENUM_BASE + eid);
    }
    int ntid = resolve_newtype(c, name);   // OFI-149: a newtype name resolves to its NEWTYPE_BASE id
    if (ntid >= 0) {
        return (SemType)(NEWTYPE_BASE + ntid);
    }
    // An interface used as a VALUE type (dynamic dispatch). Only object-safe
    // interfaces qualify: a method that mentions `Self` beyond the receiver can't be
    // honored once the concrete type is erased, so such interfaces are usable only as
    // a generic bound (`<T: Iface>`), never as `let x: Iface` / `[Iface]`.
    int iid = resolve_interface_id(c, name);
    if (iid >= 0) {
        if (!interface_object_safe(c, iid)) {
            type_error(c, t->line, t->col,
                       "this interface can't be used as a value type: one of its methods "
                       "uses 'Self' beyond the receiver, which dynamic dispatch can't honor. "
                       "Use it as a generic bound instead (e.g. fn f<T: Name>(x: T)).");
            return TY_ERROR;
        }
        return (SemType)(IFACE_BASE + iid);
    }
    return TY_ERROR;
}





// resolve_signature returns the index of a top-level function by name within the
// module currently being checked (unqualified names are module-local), or -1.
static int resolve_signature(Checker *c, const char *name) {
    for (int i = 0; i < c->fn_count; i++) {
        if (c->fns[i].module == c->current_module &&
            strcmp(c->fns[i].name, name) == 0) {
            return i;
        }
    }
    return -1;
}





// resolve_qualified_fn finds a *public* function `name` exported by the module
// bound to `alias` in the current module's imports, or -1 (with `*reason` set to
// 0 = no such alias, 1 = no such function, 2 = function is private).
static int resolve_qualified_fn(Checker *c, const char *alias,
                                const char *name, int *reason) {
    const ModuleInfo *mi = &c->modules->modules[c->current_module];
    int target = -1;
    for (int i = 0; i < mi->import_count; i++) {
        if (strcmp(mi->aliases[i], alias) == 0) {
            target = mi->targets[i];
            break;
        }
    }
    if (target < 0) {
        *reason = 0;
        return -1;
    }
    for (int i = 0; i < c->fn_count; i++) {
        if (c->fns[i].module == target && strcmp(c->fns[i].name, name) == 0) {
            if (!is_public_name(name)) {
                *reason = 2;
                return -1;
            }
            return i;
        }
    }
    *reason = 1;
    return -1;
}


// resolve_qualified_variant finds a variant named `name` among the PUBLIC enums of the module bound
// to `alias`, for cross-module construction `json.Obj(...)` (OFI-073 Stage 2). Returns its VariantInfo
// (whose enum_id + tag codegen reads off the node) or NULL. Variant names are unique within a module,
// so the first match is unambiguous.
static VariantInfo *resolve_qualified_variant(Checker *c, const char *alias, const char *name) {
    const ModuleInfo *mi = &c->modules->modules[c->current_module];
    int target = -1;
    for (int i = 0; i < mi->import_count; i++) {
        if (strcmp(mi->aliases[i], alias) == 0) {
            target = mi->targets[i];
            break;
        }
    }
    if (target < 0) {
        return NULL;
    }
    for (int e = 0; e < c->enum_count; e++) {
        if (c->enums[e].module != target || !is_public_name(c->enums[e].name)) {
            continue;
        }
        for (int v = 0; v < c->enums[e].variant_count; v++) {
            if (strcmp(c->enums[e].variants[v].name, name) == 0) {
                return &c->enums[e].variants[v];
            }
        }
    }
    return NULL;
}





// Operator-class predicates for binary operators.
static int is_arith_op(TokenType op) {
    switch (op) {
        case TOK_PLUS: case TOK_MINUS: case TOK_STAR:
        case TOK_SLASH: case TOK_PERCENT:
            return 1;
        default:
            return 0;
    }
}





static int is_relational_op(TokenType op) {
    switch (op) {
        case TOK_LT: case TOK_LE: case TOK_GT: case TOK_GE:
            return 1;
        default:
            return 0;
    }
}





static int is_equality_op(TokenType op) {
    return op == TOK_EQ || op == TOK_NEQ;
}




// Bitwise and/or/xor (`& | ^`) and the shifts (`<< >>`) — integer-only operators.
static int is_bitwise_op(TokenType op) {
    return op == TOK_AMP || op == TOK_PIPE || op == TOK_CARET;
}




static int is_shift_op(TokenType op) {
    return op == TOK_SHL || op == TOK_SHR;
}





static int is_logical_op(TokenType op) {
    return op == TOK_AND || op == TOK_OR;
}





static int struct_implements(Checker *c, int struct_id, int iface_id);     // below
static int method_is_interface_impl(Checker *c, int struct_id, const char *name); // below
static int resolve_interface_id(Checker *c, const char *name);             // below

// resolve_named_args handles NAMED enum-variant construction `Circle(radius: 2.0)` (OFI-140). If the
// call carries argument names (parser set `arg_names`), it must be CONSTRUCTING an enum variant — a
// bare-identifier or module-qualified callee that resolves to a variant; anything else is an error.
// On a valid variant it matches each `name: value` to the declared field by name (rejecting a misspelled
// name, a duplicate, a missing field, or a mix of positional + named), REORDERS `args` into declared
// field order, and clears `arg_names` — so every downstream consumer (infer_variant_type, both codegen
// backends) sees a plain positional construction, exactly as `Circle(2.0)`. A no-op for a positional call.
static void resolve_named_args(Checker *c, Expr *e) {
    if (e->as.call.arg_names == NULL) {
        return;   // positional fast path — the overwhelming common case
    }
    const Expr *callee = e->as.call.callee;
    VariantInfo *v = NULL;
    if (callee->kind == EXPR_IDENT) {
        v = resolve_variant(c, callee->as.ident);
    } else if (callee->kind == EXPR_GET && callee->as.get.object->kind == EXPR_IDENT) {
        // A qualified callee: an import-ALIAS `mod.Variant(...)`, or a local ENUM-NAME `Enum.Variant(...)`.
        // The positional path resolves both (the latter via resolve_enum/enum_variant, check.c ~3659), so
        // named construction must too, or `Shape.Circle(radius: 2.0)` / `Option.Some(value: 5)` over-reject.
        v = resolve_qualified_variant(c, callee->as.get.object->as.ident, callee->as.get.name);
        if (v == NULL) {
            int veid = resolve_enum(c, callee->as.get.object->as.ident);
            if (veid >= 0) {
                v = enum_variant(c, veid, callee->as.get.name);
            }
        }
    }
    if (v == NULL) {
        type_error(c, e->line, e->col,
                   "named arguments ('name: value') are only valid when constructing an enum variant; "
                   "function and method calls pass their arguments positionally");
        e->as.call.arg_names = NULL;   // proceed positionally so further checking still runs
        return;
    }
    int argc = (int)e->as.call.arg_count;
    if (argc != v->field_count) {
        type_error(c, e->line, e->col,
                   "named construction must set each of the variant's fields exactly once");
        e->as.call.arg_names = NULL;
        return;
    }
    Expr *reordered[MAX_PARAMS];
    int   seen[MAX_PARAMS];
    for (int k = 0; k < v->field_count; k++) {
        reordered[k] = NULL;
        seen[k] = 0;
    }
    for (int i = 0; i < argc; i++) {
        const char *nm = e->as.call.arg_names[i];
        if (nm == NULL) {
            type_error(c, e->line, e->col,
                       "construction cannot mix positional and named arguments — name every field, or none");
            e->as.call.arg_names = NULL;
            return;
        }
        int slot = -1;
        for (int k = 0; k < v->field_count; k++) {
            if (v->field_names[k] != NULL && strcmp(v->field_names[k], nm) == 0) {
                slot = k;
                break;
            }
        }
        if (slot < 0) {
            char buf[160];
            snprintf(buf, sizeof buf, "this variant has no field named '%s'", nm);
            type_error(c, e->line, e->col, buf);
            e->as.call.arg_names = NULL;
            return;
        }
        if (seen[slot]) {
            char buf[160];
            snprintf(buf, sizeof buf, "field '%s' is set more than once", nm);
            type_error(c, e->line, e->col, buf);
            e->as.call.arg_names = NULL;
            return;
        }
        seen[slot] = 1;
        reordered[slot] = e->as.call.args[i];
    }
    for (int k = 0; k < v->field_count; k++) {
        e->as.call.args[k] = reordered[k];   // now in declared field order
    }
    e->as.call.arg_names = NULL;             // positional from here on
}


// infer_variant_type type-checks a variant construction and returns its enum
// type. For a non-generic enum that is the enum id; for a generic enum it infers
// the type arguments — from the expected type (a `let`/`return` annotation) and
// from the constructor arguments (a field declared `T` fixes `T` to the arg's
// type) — then interns and returns the instantiation. `arg_types` holds the
// already-checked argument types (NULL when there are none).
static SemType infer_variant_type(Checker *c, int line, int col, VariantInfo *v,
                                  const SemType *arg_types, int argc,
                                  SemType expected) {
    EnumInfo *ei = &c->enums[v->enum_id];
    if (argc != v->field_count) {
        type_error(c, line, col, "wrong number of fields for this variant");
    }
    if (ei->generic_count == 0) {
        for (int i = 0; i < argc && i < v->field_count; i++) {
            if (arg_types[i] != TY_ERROR && v->fields[i] != TY_ERROR &&
                arg_types[i] != v->fields[i]) {
                type_error(c, line, col, "field value type does not match the variant");
            }
        }
        return (SemType)(ENUM_BASE + v->enum_id);
    }

    // Generic enum: infer one binding per type parameter.
    SemType bind[MAX_TYPE_ARGS];
    int     bound[MAX_TYPE_ARGS];
    for (int k = 0; k < ei->generic_count; k++) {
        bind[k]  = TY_ERROR;
        bound[k] = 0;
    }
    // The expected type (if it is this enum) supplies every argument.
    if (is_generic_inst(expected)) {
        GenericInst *ex = &c->ginsts[expected - GENERIC_BASE];
        if (ex->is_enum && ex->base == v->enum_id &&
            ex->arg_count == ei->generic_count) {
            for (int k = 0; k < ei->generic_count; k++) {
                bind[k]  = ex->args[k];
                bound[k] = 1;
            }
        }
    }
    // A field declared as a bare type parameter fixes it to the argument's type.
    for (int i = 0; i < argc && i < v->field_count; i++) {
        if (is_type_param(v->fields[i])) {
            int k = v->fields[i] - PARAM_BASE;
            if (k < ei->generic_count && !bound[k]) {
                bind[k]  = arg_types[i];
                bound[k] = 1;
            }
        }
    }
    int all_bound = 1;
    for (int k = 0; k < ei->generic_count; k++) {
        if (!bound[k]) {
            all_bound = 0;
        }
    }
    if (!all_bound) {
        type_error(c, line, col,
                   "cannot infer the type arguments here; add a type annotation");
    }
    // Check each argument against its substituted field type.
    GenericInst tmp;
    tmp.base = v->enum_id;
    tmp.is_enum = 1;
    tmp.arg_count = ei->generic_count;
    for (int k = 0; k < ei->generic_count; k++) {
        tmp.args[k] = bind[k];
    }
    for (int i = 0; i < argc && i < v->field_count; i++) {
        SemType ft = subst(c, &tmp, v->fields[i]);
        if (arg_types[i] != TY_ERROR && ft != TY_ERROR && arg_types[i] != ft) {
            type_error(c, line, col, "field value type does not match the variant");
        }
    }
    // OFI-049: constructing a generic enum at T = Ptr (e.g. `Some(f)` ⇒ Option<Ptr>) would wrap a
    // linear handle in a value whose drop can't close it — emit here (intern_generic only fails
    // silently with TY_ERROR), so a discarded Option<Ptr> can't leak `f`.
    for (int k = 0; k < ei->generic_count; k++) {
        if (ptr_storage_error(c, bind[k], line, col, "an enum payload")) {
            return TY_ERROR;
        }
    }
    return intern_generic(c, v->enum_id, 1, bind, ei->generic_count);
}





static int field_storage_size(Checker *c, SemType t);   // packed width of a field (def. below)


// is_scalar_type reports whether `t` is a primitive packed scalar (1/2/4/8 bytes, no heap).
static int is_scalar_type(SemType t) {
    return t == TY_I8  || t == TY_U8  || t == TY_BOOL ||
           t == TY_I16 || t == TY_U16 ||
           t == TY_I32 || t == TY_U32 || t == TY_F32  ||
           t == TY_INT || t == TY_U64 || t == TY_FLOAT;
}


// is_immutably_shareable reports whether a type may be a FIELD of an `rc struct` (R3, the deep-
// immutability formation whitelist). It must be a CLOSED POSITIVE whitelist: a field that can carry
// a mutable interior into a shared value (an array, a plain/mutable struct, a Ptr, a function/closure
// that could capture a mutable, a channel, an interface, or a bare type parameter) breaks the
// `shared => immutable` invariant and would re-open reference cycles, so every one of those is FALSE.
static int is_immutably_shareable(Checker *c, SemType t) {
    if (is_scalar_type(t) || t == TY_STRING) {
        return 1;
    }
    if (is_enum_type(t)) {
        return 1;   // a plain enum is itself an immutable refcounted shareable
    }
    if (is_generic_inst(t)) {
        const GenericInst *g = &c->ginsts[t - GENERIC_BASE];
        if (!g->is_enum) {
            return 0;   // a generic STRUCT instance is a mutable aggregate (generic rc is banned);
        }               // only a generic ENUM can be a shareable, and only if...
        for (int k = 0; k < g->arg_count; k++) {
            if (!is_immutably_shareable(c, g->args[k])) {
                return 0;   // ...every concrete payload arg is itself shareable (Option<int> ok,
            }               // Option<[int]> / Result<MutStruct,_> NOT — closes the generic smuggle)
        }
        return 1;
    }
    if (is_struct_type(t) && c->structs[t].is_rc) {
        return 1;   // another rc struct (it runs its own formation pass; safe under forward-ref)
    }
    return 0;       // array, plain/mutable struct, Ptr, fn/closure, channel, interface, type-param
}


// nested_inline_sid reports the struct type id if `t` is a struct that can be stored fully
// INLINE inside a parent (value-types 3b.5): every field is a scalar or itself an inline-able
// struct (recursively), with no boxed/refcounted/pointer field. Such a field is packed into the
// parent's buffer (no separate heap object) and read out as a value COPY — which dissolves the
// "can't move a value out of a field" restriction (OFI-031). All-scalar only for now (a
// refcounted sub-field would need recursive retain/release on copy, a later stage).
static int nested_inline_sid(Checker *c, SemType t) {
    if (!is_struct_type(t)) {
        return -1;
    }
    if (c->structs[t].is_rc || c->structs[t].is_resource) {
        return -1;   // an rc OR resource struct is boxed (refcounted / drop-bearing), never packed inline
    }
    StructInfo *si = &c->structs[t];
    if (si->field_count == 0) {
        return -1;
    }
    for (int f = 0; f < si->field_count; f++) {
        SemType ft = si->fields[f].type;
        if (is_scalar_type(ft)) {
            continue;
        }
        if (nested_inline_sid(c, ft) >= 0) {
            continue;
        }
        return -1;   // a boxed/refcounted field — not fully inline
    }
    return t;
}

// array_inline_struct_id reports the struct type id if `elem` is a struct an array may
// store INLINE — packed size <= 255 (the array's 1-byte stride), and every field either a
// packed scalar OR a REFCOUNTED boxed value (string/enum/closure). Indexing materialises a
// value COPY that shares those boxed sub-fields with the array via an incref, which is sound
// only for refcounted things. A UNIQUE-OWNER boxed field (a nested struct/array, or a type
// parameter) would be aliased by a shallow copy (a double free), so it disqualifies the
// struct — that needs recursive copy, a later stage. (Non-generic structs only for now.)
static int array_inline_struct_id(Checker *c, SemType elem) {
    if (!is_struct_type(elem)) {
        return -1;
    }
    if (c->structs[elem].is_rc || c->structs[elem].is_resource) {
        return -1;   // an rc/resource element is boxed (retained / drop-bearing), never inline-packed
    }
    StructInfo *si = &c->structs[elem];
    int total = 0;
    for (int f = 0; f < si->field_count; f++) {
        SemType ft = si->fields[f].type;
        if (nested_inline_sid(c, ft) >= 0) {
            return -1;   // a nested inline-struct field — arrays of these are a later stage
        }
        int sz = field_storage_size(c, ft);
        if (sz == 16 && !is_refcounted(c, ft)) {
            return -1;   // a unique-owner boxed field can't be shallow-copied
        }
        total += sz;
    }
    if (total <= 0 || total > 255) {
        return -1;
    }
    return elem;   // for a non-generic struct, the SemType is its struct id
}


// struct_all_scalar_id reports the struct type id if `t` is a struct whose every field
// is a packed scalar (no boxed/refcounted field) — the case an immutable local can store
// MULTI-SLOT on the stack (its fields exploded into N slots), with no per-field drop
// (nothing refcounted to release) so scope exit just pops N. Value-types 3b; structs with
// a boxed field, or `var` (mutable) struct locals, stay boxed for now. Non-generic only.
static int struct_all_scalar_id(Checker *c, SemType t) {
    if (!is_struct_type(t)) {
        return -1;
    }
    if (c->structs[t].is_rc || c->structs[t].is_resource) {
        return -1;   // an rc/resource struct stays boxed, never multi-slot on the stack
    }
    StructInfo *si = &c->structs[t];
    if (si->field_count == 0) {
        return -1;
    }
    for (int f = 0; f < si->field_count; f++) {
        SemType ft = si->fields[f].type;
        if (nested_inline_sid(c, ft) >= 0) {
            return -1;   // a nested struct field — the parent stays boxed for now (3b.5-A)
        }
        if (field_storage_size(c, ft) == 16) {
            return -1;   // a boxed field — not all-scalar
        }
    }
    return t;
}


// param_multislot_sid reports the struct id if a PARAMETER of type `ptype` with ownership
// qualifier `qual`, on a function with `generic_count` type parameters, is stored MULTI-SLOT
// (value-types 3b.4): its N field slots are passed on the stack instead of a boxed value.
// Only a PLAIN (borrow) all-scalar struct parameter of a NON-generic function qualifies —
// a `mut` param must keep mutating the caller's value through a shared box, a `move` param
// nils the caller's binding, and a generic function (and its monomorphized clones) keeps
// every parameter boxed so its call sites need no per-instance convention. The same
// predicate decides the callee prologue, the call-site arg emission, and the fn-value guard,
// so every call path agrees on the convention.
static int param_multislot_sid(Checker *c, SemType ptype, int qual, int generic_count) {
    if (generic_count != 0 || qual != OWN_NONE) {
        return -1;
    }
    return nested_inline_sid(c, ptype);   // multi-slot: flat OR nested all-scalar (3b.5-B)
}


// ret_multislot_sid reports the struct id if a function returning `rtype`, with
// `generic_count` type parameters, returns it MULTI-SLOT (value-types 3b.4b): its N field
// slots are moved into the caller's frame instead of a boxed value. Only an all-scalar
// struct returned from a NON-generic function qualifies (a generic function and its
// monomorphized clones keep boxed returns so call sites need no per-instance convention).
static int ret_multislot_sid(Checker *c, SemType rtype, int generic_count) {
    if (generic_count != 0) {
        return -1;
    }
    return nested_inline_sid(c, rtype);   // multi-slot: flat OR nested all-scalar (3b.5-B)
}


// is_multislot_local reports whether `e` reads a binding stored MULTI-SLOT (value-types 3b):
// a let-inline or plain-parameter all-scalar struct, flagged at declaration. Reading such a
// binding as a whole value COPIES it (codegen boxes its field slots into a fresh struct) — so
// it does not move the source (it stays usable) and the result is a fresh owned temporary.
static int is_multislot_local(Checker *c, Expr *e) {
    if (e->kind != EXPR_IDENT) {
        return 0;
    }
    int slot = resolve_local(c, e->as.ident);
    if (slot < 0) {
        return 0;
    }
    return c->locals[slot].multislot_sid >= 0;
}


// consume records that a value in an *owning* position (a `let`/`var` initialiser,
// an assignment RHS, a struct/variant field, a `move` argument, a return) is taken.
// For a move type read from a bare binding, that binding is marked moved (a later
// use is then an error); moving a value *out of a field* is a partial move, which
// is not supported. Copy types and fresh temporaries are unaffected. Returns
// whether the consumed value is owned, so the receiving binding inherits it. Call
// drop_self_ptr_field_bit returns the compact ptr-bit (0,1,2,…) if `e` reads a `Ptr` FIELD of the
// drop's own `self` (only meaningful inside a resource drop), else -1. The bit indexes self's Ptr
// fields in declaration order — its position in the drop_self_consumed / drop_self_ptr_mask masks.
static int drop_self_ptr_field_bit(Checker *c, Expr *e) {
    if (!c->in_resource_drop || c->drop_self_slot < 0 || e->kind != EXPR_GET) {
        return -1;
    }
    Expr *obj = e->as.get.object;
    if (obj->kind != EXPR_IDENT || resolve_local(c, obj->as.ident) != c->drop_self_slot) {
        return -1;
    }
    StructInfo *si = &c->structs[c->drop_self_struct];
    int bit = 0;
    for (int f = 0; f < si->field_count; f++) {
        if (si->fields[f].type != TY_PTR) {
            continue;
        }
        if (strcmp(si->fields[f].name, e->as.get.name) == 0) {
            return bit < 31 ? bit : -1;
        }
        bit++;
    }
    return -1;   // not a Ptr field of self
}


// it *after* type-checking the expression (so reads are seen while still live).
static int consume(Checker *c, Expr *e, SemType t, int line, int col) {
    if (is_refcounted(c, t) || is_type_param(t)) {
        // Strings, arrays, and enums are shared and reference-counted. Reading an
        // *existing* owner — a binding, a struct field, or an array element — into
        // a new owning slot aliases the same heap object, so codegen must bump its
        // refcount (moves_local == 2 ⇒ OP_INCREF). A fresh temporary (a literal,
        // a concatenation, a call result, or a variant construction like `Some(5)`
        // / bare `None`) already carries the single reference the new owner adopts,
        // so it is left alone — hence the EXPR_IDENT must resolve to a *local*, not
        // a zero-field variant constructor.
        //
        // A *type parameter* is included: under erasure the value may turn out to
        // be refcounted at run time, and an owning store (OP_SET_INDEX releases the
        // old element; an array adopts an appended value) must then carry its own
        // reference or the count underflows and a live value is freed (the sort-
        // shift crash). OP_INCREF is a runtime no-op for scalars, so for an int
        // instantiation the mark costs one dead opcode; for a string one it is the
        // missing +1. Over-retaining an erased temporary leaks rather than crashes
        // — the same sound convention erased generics already follow (OFI-009).
        // A whole-value read of an OWNED type-parameter local is a MOVE, not a
        // share: a struct T cannot be double-owned (aliasing it double-freed it at
        // run time — OFI-009), and a refcounted T's single reference transfers
        // soundly. A BORROWED T (a plain param) and field/element reads (GET/INDEX)
        // instead incref-share (a runtime no-op for a non-refcounted T): you cannot
        // move out of a borrow, and the accumulator pattern `var acc = init` over a
        // borrowed `U` relies on it. (A borrowed *struct*-T copied into an owner, and
        // a struct-T field extracted, are the remaining erased gaps — they need the
        // `T: Copy` bound / monomorphization to resolve; tracked under OFI-009.)
        if (is_type_param(t) && !is_copy_param(c, t) && e->kind == EXPR_IDENT) {
            int slot = resolve_local(c, e->as.ident);
            if (slot >= 0 && c->locals[slot].owned) {
                c->locals[slot].moved     = 1;
                c->locals[slot].move_line = e->line;
                c->locals[slot].move_col  = e->col;
                e->moves_local = 1;
                return 1;
            }
        }
        if ((e->kind == EXPR_IDENT && resolve_local(c, e->as.ident) >= 0) ||
            e->kind == EXPR_GET || e->kind == EXPR_INDEX) {
            e->moves_local = 2;
        }
        return 1;
    }
    if (!is_move_type(c, t)) {
        return 1;                       // other Copy values are freely owned
    }
    if (e->kind == EXPR_IDENT) {
        int slot = resolve_local(c, e->as.ident);
        if (slot >= 0) {
            // OFI-122 R4: inside a `resource` drop, `self` may not be moved or copied as a WHOLE —
            // handing its handle fields to a new owner whose drop re-closes them is a double free.
            // Close its fields in place; the runtime reclaims `self` after drop returns.
            if (c->in_resource_drop && slot == c->drop_self_slot) {
                type_error(c, line, col,
                           "cannot move or copy 'self' inside 'drop'; close its handle fields and let "
                           "the runtime reclaim 'self' (moving it would re-run drop)");
                return 0;
            }
            // A multi-slot struct local read as a value is COPIED (boxed from its slots),
            // not moved — the source stays valid, the copy is a fresh owned temporary.
            if (is_multislot_local(c, e)) {
                return 1;
            }
            if (c->locals[slot].frozen) {   // a live slice borrows it (slices §)
                type_error(c, line, col,
                           "cannot move an array while it is borrowed by a slice "
                           "(the view would dangle)");
            }
            // A BORROWED value-struct binding read into a new owner is NOT a move: the
            // source still owns the struct, so the new owner must take an independent
            // CLONE or both reclaim it at drop (OFI-064). The canonical case is a `match`
            // case binding (`case Some(v) { dst = v }`) — it borrows the matched enum's
            // payload, which the enum still drops — and a by-borrow value-struct param.
            // Value semantics: own_into_slot deep-copies a unique-owner aggregate
            // (moves_local == 2 ⇒ OP_INCREF / native own_into_slot, a no-op for scalars).
            // The borrow stays live (it can be read again), so don't mark it moved.
            if (!c->locals[slot].owned) {
                // OFI-049: a BORROWED `Ptr` may not be closed or transferred — you don't own the
                // handle, so closing it strands the owner with a stale pointer (double-close / UAF),
                // and `let g = f` must not mint a fresh OWNED obligation on a borrow. Returning 0
                // (not owned) stops the launder; every consuming position routes through here, so
                // this one placement covers move-arg / let / assign / return / field / send. Also
                // catches `mut f: Ptr` (mut is owned == 0). The general clone-on-bind-out (OFI-064)
                // path below is for value-structs only.
                if (t == TY_PTR) {
                    type_error(c, line, col,
                               "cannot close or transfer a borrowed 'Ptr'; take it by 'move' to gain "
                               "ownership (declare the parameter 'move f: Ptr', not 'f' or 'mut f')");
                    return 0;
                }
                if (is_resource_type(c, t)) {
                    // OFI-122 R2: a BORROWED resource (a `match` case binding, a borrowed param) may not
                    // be moved/copied into an owner — the clone-on-bind path would shallow-copy its handle
                    // fields, giving two owners that each run `drop` (double-close). Read its fields in
                    // place, or own it where it is constructed.
                    type_error(c, line, col,
                               "cannot move or copy a 'resource' out of a borrow (a 'match' binding or a "
                               "borrowed parameter) — it would duplicate the owned handle and double-free; "
                               "read its fields in place, or own it where it is created");
                    return 0;
                }
                e->moves_local = 2;
                return 1;
            }
            // An OWNED local: this read transfers ownership away from the binding. Mark it
            // moved and tell codegen to nil the slot after reading it, so the scope-exit
            // drop for this binding becomes a no-op on the paths where the move happened.
            c->locals[slot].moved = 1;
            c->locals[slot].consumed = 1;   // OFI-049: the must-consume (AND-merge) dual of `moved`
            c->locals[slot].move_line = e->line;   // for a "moved here" diagnostic note
            c->locals[slot].move_col  = e->col;
            e->moves_local = 1;
            return 1;
        }
        return 1;                       // a bare variant constructor, etc.
    }
    if (e->kind == EXPR_GET) {
        if (t == TY_PTR) {
            // OFI-122 R6/R5p1: a linear `Ptr` field. The ONE place it may be CLOSED (consumed) is the
            // resource's own `drop`, at the TOP LEVEL of the body (so the consumed mask is monotonic —
            // no control-flow merge). Inside a nested block of drop, or anywhere else, a `Ptr` field is
            // borrow-only — closing it elsewhere (or twice) would double-close the live handle.
            int fbit = drop_self_ptr_field_bit(c, e);
            if (fbit >= 0 && c->scope_depth == 0) {
                if (c->drop_self_consumed & (1 << fbit)) {
                    type_error(c, line, col,
                               "this 'resource' handle field was already closed on this path");
                    return 0;
                }
                c->drop_self_consumed |= (1 << fbit);
                return 1;   // legal: the drop closes its own resource handle exactly once
            }
            if (fbit >= 0) {
                type_error(c, line, col,
                           "close a 'resource' handle field at the TOP LEVEL of 'drop' (conditional "
                           "close is not supported yet); close it unconditionally");
                return 0;
            }
            type_error(c, line, col,
                       "cannot close or move a 'Ptr' field out of a struct (it is borrow-only); only "
                       "a 'resource' struct's own 'drop' may close its handle fields");
            return 0;
        }
        // An INLINE nested struct field is a value type: reading it out materialises a fresh
        // COPY of its packed bytes, so binding it out is fine (OFI-031). A BOXED struct field
        // is a unique-owner pointer, so moving it out is a partial move — still rejected.
        if (nested_inline_sid(c, t) >= 0) {
            return 1;   // a fresh owned copy of the nested struct
        }
        type_error(c, line, col,
                   "cannot move a value out of a field (partial moves are not "
                   "supported); pass it by borrow or restructure");
        return 1;
    }
    if (e->kind == EXPR_INDEX) {
        // An INLINE struct array element is a value type: indexing materialises a fresh
        // COPY, so binding it out is fine — it owns its own bytes (no aliasing). For a
        // BOXED struct array, the element is the array's unique-owner object, so moving
        // it out would create a second owner (a double free) — still rejected.
        if (array_inline_struct_id(c, t) >= 0) {
            return 1;   // a fresh owned copy
        }
        type_error(c, line, col,
                   "cannot move a struct out of an array element (it would alias the "
                   "array's value); read its fields in place instead");
        return 1;
    }
    return 1;                           // a fresh temporary (literal/call/construction)
}






// is_owning_temp reports whether `e` produces a *fresh* owned value — a literal,
// concatenation, construction (`Some(x)`, `[…]`, `P{…}`, bare `None`), or call result
// (including `recv`). Such a value owns the thing it yields, so if it is discarded (an
// expression statement, or a `match` scrutinee that ends) it must be reclaimed, not
// just popped off the stack. This covers BOTH refcounted values (string/enum/closure —
// reclaimed by releasing a reference) AND unique-owner move-types (struct/array —
// reclaimed by a direct free); `OP_RELEASE` runs `drop_value`, which does the right
// thing for each. A place-read (a local, a field, an element) is excluded — it borrows
// a value an existing owner still holds; and a bare local has its own scope-exit drop.
// (Before this, an owned STRUCT temporary discarded at a statement leaked — OFI-027.)
static int is_owning_temp(Checker *c, Expr *e, SemType t) {
    // A Ptr is move-tracked (OFI-049) but is a raw C handle Ember never frees, so it is NEVER an
    // owning temp the caller must drop — without this, a fresh handle temp (`fclose(fopen(...))`)
    // would be drop-masked into a dead OP_DROP_UNDER (drop_value no-ops on it, but it is spurious).
    if (t == TY_PTR) {
        return 0;
    }
    // Indexing an INLINE struct array materialises a fresh owned COPY — an owning temp
    // that must be reclaimed after transient use (OFI-027), unlike a borrowing place-read.
    if (e->kind == EXPR_INDEX && array_inline_struct_id(c, t) >= 0) {
        return 1;
    }
    // Reading an INLINE nested struct field out materialises a fresh owned COPY (value-types
    // 3b.5) — reclaim it after transient use (`mk().a.x`), like an inline array element.
    if (e->kind == EXPR_GET && nested_inline_sid(c, t) >= 0) {
        return 1;
    }
    if (e->kind == EXPR_GET || e->kind == EXPR_INDEX) {
        return 0;
    }
    // A multi-slot struct local read as a value boxes into a fresh owned temp (3b) —
    // reclaim it after transient use, unlike an ordinary borrowing local read.
    if (is_multislot_local(c, e)) {
        return 1;
    }
    if (e->kind == EXPR_IDENT && resolve_local(c, e->as.ident) >= 0) {
        return 0;
    }
    return is_refcounted(c, t) || is_move_type(c, t);
}





static SemType check_lambda(Checker *c, Expr *e, SemType expected);
static SemType check_expr(Checker *c, Expr *e);
static void report_unconsumed_ptrs(Checker *c, int from, int line, int col);   // OFI-049 leak scan


// ---- Show: string-interpolation rendering (OFI-139) ----

// show_renders reports whether a value of type `t` provides the Show contract — a
// `fn show(self) -> string` (a plain borrow `self`, no explicit params). Detection is
// STRUCTURAL (the method's presence is the opt-in, like Go's Stringer), so a struct need
// not `implements Show` to be interpolated. For an interface VALUE it is the interface's
// own `show` slot (dynamic dispatch reads it from the vtable). On a match it reports the
// dispatch target: `*dyn_slot` >= 0 for an interface value (else -1), or `*fn_index` >= 0
// for a concrete/generic struct method (else -1).
static int show_renders(Checker *c, SemType t, int *dyn_slot, int *fn_index) {
    *dyn_slot  = -1;
    *fn_index  = -1;
    if (is_interface_type(t)) {
        InterfaceInfo *ii = &c->interfaces[interface_id_of(t)];
        for (int m = 0; m < ii->method_count; m++) {
            MethodSig *ms = &ii->methods[m];
            if (strcmp(ms->name, "show") == 0 &&
                ms->param_count == 0 && ms->ret == TY_STRING) {
                *dyn_slot = m;
                return 1;
            }
        }
        return 0;
    }
    int base = -1;
    if (is_struct_type(t)) {
        base = t;
    } else if (is_generic_inst(t) && !c->ginsts[t - GENERIC_BASE].is_enum) {
        base = c->ginsts[t - GENERIC_BASE].base;
    }
    if (base < 0) {
        return 0;
    }
    MethodInfo *mi = resolve_method(c, base, "show");
    if (mi == NULL || mi->param_count != 0 || mi->ret != TY_STRING ||
        mi->self_qual != OWN_NONE) {
        return 0;
    }
    *fn_index = mi->fn_index;
    return 1;
}


// synth_show_call wraps an already-checked interpolation receiver `recv` (of type
// `recv_ty`, which show_renders has accepted) into a synthesized `recv.show()` method
// call, so the hole flows through the ordinary method-call codegen on BOTH backends and
// renders as the resulting string. Every node field is set explicitly — arena nodes are
// not zeroed, and a stray `variant_enum_id`/`resolved_fn` would misroute codegen.
static Expr *synth_show_call(Checker *c, Expr *recv, SemType recv_ty,
                             int dyn_slot, int fn_index) {
    Expr *get = arena_alloc(c->arena, sizeof(Expr));
    get->kind                 = EXPR_GET;
    get->line                 = recv->line;
    get->col                  = recv->col;
    get->moves_local          = 0;
    get->suffix_type          = 0;
    get->num_kind             = 0;
    get->variant_enum_id      = -1;
    get->variant_tag          = -1;
    get->coerce_witness       = NULL;
    get->coerce_witness_count = 0;
    get->coerce_iface         = 0;
    get->as.get.object        = recv;
    get->as.get.name          = "show";
    get->as.get.name_line     = recv->line;
    get->as.get.name_col      = recv->col;
    get->as.get.field_index   = fn_index;   // -1 for the interface (dyn) path
    get->as.get.bound_method  = -1;
    get->as.get.bound_witness = 0;
    get->as.get.bound_via_self = 0;
    get->as.get.dyn_method    = dyn_slot;   // -1 for the concrete-struct path
    get->as.get.array_op      = ARR_OP_NONE;
    get->as.get.string_op     = 0;
    get->as.get.clone_op      = 0;
    get->as.get.drop_object   = 0;
    get->as.get.inline_field  = 0;
    get->as.get.inline_struct_id = -1;

    Expr *call = arena_alloc(c->arena, sizeof(Expr));
    call->kind                 = EXPR_CALL;
    call->line                 = recv->line;
    call->col                  = recv->col;
    call->moves_local          = 0;
    call->suffix_type          = 0;
    call->num_kind             = 0;
    call->variant_enum_id      = -1;
    call->variant_tag          = -1;
    call->coerce_witness       = NULL;
    call->coerce_witness_count = 0;
    call->coerce_iface         = 0;
    call->as.call.callee       = get;
    call->as.call.args         = NULL;
    call->as.call.arg_count    = 0;
    call->as.call.arg_names    = NULL;   // not named construction (OFI-140); arena nodes aren't zeroed
    call->as.call.witnesses    = NULL;
    call->as.call.witness_total = 0;
    call->as.call.resolved_fn  = -1;
    call->as.call.mono_arg_count = 0;
    call->as.call.closure_call = 0;
    // A fresh owned struct temporary receiver (`"{make_circle()}"`) is borrowed by show()
    // and must be caller-dropped (OFI-027), exactly as the normal method path sets it. An
    // interface value is dispatched dynamically (self borrowed, never dropped here).
    call->as.call.drop_first   = (dyn_slot < 0) && is_owning_temp(c, recv, recv_ty);
    call->as.call.drop_mask    = 0;
    call->as.call.arg_inline_struct = NULL;
    call->as.call.ret_struct_id = -1;   // show() returns a string, never multi-slot
    call->as.call.box_result   = 0;
    call->as.call.cextern_index = -1;
    call->as.call.cextern_ret_sid = -1;
    call->as.call.extern_direct = 0;   // OFI-167: show() is an Ember call, never a direct extern
    call->as.call.extern_cname  = NULL;
    return call;
}


// ---- Top-level constants (OFI-023) ----

// is_const_literal reports whether `e` is a literal usable as a top-level constant:
// an int/float/bool/string literal, or unary minus on a numeric literal.
static int is_const_literal(const Expr *e) {
    if (e->kind == EXPR_INT || e->kind == EXPR_FLOAT ||
        e->kind == EXPR_BOOL || e->kind == EXPR_STRING) {
        return 1;
    }
    if (e->kind == EXPR_UNARY && e->as.unary.op == TOK_MINUS) {
        const Expr *o = e->as.unary.operand;
        return o->kind == EXPR_INT || o->kind == EXPR_FLOAT;
    }
    return 0;
}






// collect_global records a top-level `let NAME = <literal>` as a named constant of
// the current module. Only `let` (immutable) literals are constants; a `var` or a
// non-literal initializer is rejected (the general runtime-global is future work).
static void collect_global(Checker *c, const Decl *d) {
    if (d->as.let.is_var) {
        type_error(c, d->line, d->col,
                   "a top-level 'var' is not supported; a module-level binding must "
                   "be an immutable 'let' constant");
        return;
    }
    if (d->as.let.value == NULL || !is_const_literal(d->as.let.value)) {
        type_error(c, d->line, d->col,
                   "a top-level constant must be a literal value (int, float, bool, "
                   "or string)");
        return;
    }
    if (c->global_count >= MAX_FNS) {
        type_error(c, d->line, d->col, "too many top-level constants");
        return;
    }
    // A declared annotation becomes the EXPECTED type so a literal adopts it (`let Z: u8 = 5` makes `5`
    // a u8, `let F: f32 = 1.5` an f32) — then the value must match it. Mirrors the function-local
    // STMT_LET path (this top-level path used to skip the annotation check entirely, OFI-147).
    SemType at = d->as.let.type != NULL ? annotation_type(c, d->as.let.type) : TY_ERROR;
    SemType saved = c->expected;
    c->expected = at;
    SemType t = check_expr(c, d->as.let.value);
    c->expected = saved;
    if (d->as.let.type != NULL) {
        if (at == TY_ERROR) {
            type_error(c, d->line, d->col, "unknown or unsupported type in binding annotation");
        } else if (t != TY_ERROR && !assignable(c, d->as.let.value, t, at)) {
            type_error(c, d->line, d->col, "binding annotation does not match the value's type");
        } else {
            t = at;   // the declared type wins
        }
    }
    if (d->as.let.name[0] == '_' && d->as.let.name[1] == '\0') {
        // A module-scope DISCARD: `let _ = <literal>` checks the value (for errors) but binds no name,
        // exactly like a function-local `_` (OFI-098). So `_` never resolves to a usable global.
        return;
    }
    int g = c->global_count++;
    c->globals[g].name     = d->as.let.name;
    c->globals[g].module   = c->current_module;
    c->globals[g].type     = t;
    c->globals[g].value    = d->as.let.value;
    c->globals[g].def_line = d->line;
    c->globals[g].def_col  = d->col;
}






// resolve_global finds a constant `name` in the current module, or -1.
static int resolve_global(Checker *c, const char *name) {
    for (int i = 0; i < c->global_count; i++) {
        if (c->globals[i].module == c->current_module &&
            strcmp(c->globals[i].name, name) == 0) {
            return i;
        }
    }
    return -1;
}






// resolve_qualified_const finds a *public* constant `name` exported by the module
// bound to `alias` in the current module's imports, or -1 (with *reason set as in
// resolve_qualified_fn: 0 = no such alias, 1 = no such constant, 2 = it is private).
static int resolve_qualified_const(Checker *c, const char *alias,
                                   const char *name, int *reason) {
    const ModuleInfo *mi = &c->modules->modules[c->current_module];
    int target = -1;
    for (int i = 0; i < mi->import_count; i++) {
        if (strcmp(mi->aliases[i], alias) == 0) {
            target = mi->targets[i];
            break;
        }
    }
    if (target < 0) {
        *reason = 0;
        return -1;
    }
    for (int i = 0; i < c->global_count; i++) {
        if (c->globals[i].module == target &&
            strcmp(c->globals[i].name, name) == 0) {
            if (!is_public_name(name)) {
                *reason = 2;
                return -1;
            }
            return i;
        }
    }
    *reason = 1;
    return -1;
}






// substitute_const rewrites a use-site expression `e` into a copy of constant `gi`'s
// literal value (compile-time substitution — no runtime global storage), preserving
// `e`'s source position, and returns the constant's type.
static SemType substitute_const(Checker *c, Expr *e, int gi) {
    Expr   *v   = c->globals[gi].value;
    SemType t   = c->globals[gi].type;
    int     ln  = e->line;
    int     col = e->col;
    *e      = *v;          // become the literal (shares read-only sub-nodes)
    e->line = ln;
    e->col  = col;
    return t;
}


// check_fn_call type-checks a call to a resolved top-level function — reached
// either directly (`foo(args)`) or module-qualified (`mod.foo(args)`); both paths
// share every rule here: argument checking with parameter-guided expectation,
// borrow-conflict and consume analysis, and for a generic callee the full
// type-argument inference (unification over arrays/functions, deferred lambda
// arguments in a second phase, bounded-parameter witnesses) plus the recorded
// monomorphization key. The caller has already set e->as.call.resolved_fn.
static SemType check_fn_call(Checker *c, Expr *e, FnSig *sig, SemType expected) {
    int argc = (int)e->as.call.arg_count;
    if (argc != sig->param_count) {
        type_error(c, e->line, e->col, "wrong number of arguments to function");
    }
    // Each argument is checked with its *parameter's* type as the expected
    // type, so a literal/empty-array/None argument infers (e.g. a bare
    // literal adopts a sized-int parameter's width). Generic parameters are
    // type variables, so they guide nothing — leave the expected type clear.
    SemType at[MAX_PARAMS];
    int deferred[MAX_PARAMS];
    for (int i = 0; i < argc && i < MAX_PARAMS; i++) {
        deferred[i] = 0;
        // A lambda argument to a *generic* call is deferred: its parameter
        // and result types depend on type arguments inferred from the other
        // arguments, so it is checked in a second phase once those are known.
        if (sig->generic_count != 0 &&
            e->as.call.args[i]->kind == EXPR_LAMBDA) {
            at[i]       = TY_ERROR;
            deferred[i] = 1;
            continue;
        }
        if (sig->generic_count == 0 && i < sig->param_count) {
            c->expected = sig->params[i];
        }
        at[i] = check_expr(c, e->as.call.args[i]);
    }
    for (int i = MAX_PARAMS; i < argc; i++) {
        check_expr(c, e->as.call.args[i]);
    }
    int np = argc < sig->param_count ? argc : sig->param_count;
    if (np > MAX_PARAMS) {
        np = MAX_PARAMS;
    }
    // Borrow conflict: a value passed to a `mut`/`move` parameter may not
    // be aliased by another argument in the same call (mutable XOR shared).
    for (int i = 0; i < np; i++) {
        Expr *ai = e->as.call.args[i];
        if (ai->kind != EXPR_IDENT) {
            continue;
        }
        for (int j = i + 1; j < np; j++) {
            Expr *aj = e->as.call.args[j];
            if (aj->kind == EXPR_IDENT &&
                strcmp(ai->as.ident, aj->as.ident) == 0 &&
                (sig->quals[i] != OWN_NONE || sig->quals[j] != OWN_NONE)) {
                type_error(c, e->line, e->col,
                           "the same value is passed to a 'mut'/'move' "
                           "parameter and aliased by another argument");
            }
        }
    }
    // A `mut` parameter is a MUTABLE BORROW: the callee may write through it and, for a
    // reference-like value (an array, or a boxed `var` struct), the caller observes the
    // change. So the argument must be a mutable place — exactly as an assignment target is
    // — never an immutable `let` binding, or the callee could mutate a value the caller
    // froze with `let` (a soundness hole: `let a = [1,2,3]; fill(mut a)` would write a[0]).
    // A non-place argument (literal, constructor, call result) is a throwaway temporary and
    // is fine. `move` is exempt: it consumes the binding, so the caller observes nothing
    // after the call.
    for (int i = 0; i < np; i++) {
        if (sig->quals[i] != OWN_MUT) {
            continue;
        }
        Expr *root = e->as.call.args[i];
        while (root->kind == EXPR_GET || root->kind == EXPR_INDEX) {
            root = root->kind == EXPR_GET ? root->as.get.object
                                          : root->as.index.object;
        }
        if (root->kind == EXPR_IDENT) {
            int slot = resolve_local(c, root->as.ident);
            if (slot >= 0 && !c->locals[slot].is_var) {
                type_error(c, e->line, e->col,
                           "cannot pass an immutable binding to a 'mut' parameter; "
                           "declare it 'var' (or pass by 'move' to transfer ownership)");
            }
        }
    }
    // A foreign (C) call BORROWS its heap arguments for the call's duration (§5h pointers):
    // a `string`/buffer/`Ptr` is never consumed or moved — the wrapper only reads through it,
    // and Ember keeps ownership. So skip the consume below; the only thing the caller must do
    // is release a fresh OWNING TEMP afterward (e.g. the literals in `fopen("f","r")`), which
    // the drop_mask path handles exactly like an owned struct temp.
    int is_extern = sig->cextern_index >= 0 || sig->direct_extern;   // OFI-167: direct externs borrow too
    // `move` arguments are consumed (their binding is moved out); a refcounted argument is also
    // consumed, since the callee owns a reference to it and releases it on return — consuming an
    // aliased argument increfs it, while a fresh temporary is simply adopted.
    for (int i = 0; i < np; i++) {
        if (sig->quals[i] == OWN_MOVE) {
            // A `move` arg is ALWAYS consumed, extern or not. For an extern `move Ptr` this is how
            // an FFI handle is closed/transferred (fclose(move f: Ptr), OFI-049): the binding is
            // moved out, so any later use of it is a use-after-move error (no double-close).
            consume(c, e->as.call.args[i], at[i], e->line, e->col);
        } else if (!is_extern && is_refcounted(c, sig->params[i])) {
            // A non-extern refcounted arg is consumed IFF the PARAMETER owns it — a concrete
            // refcounted param (string/enum/channel/closure/rc) the callee releases on return
            // (release_at_exit). A generic BORROW param (`x: T`) does NOT release its arg — under
            // erasure is_refcounted(T) is false — and a body that stores it takes its OWN reference
            // (the store's moves_local == 2 ⇒ own_into_slot). So consuming a refcounted arg here for
            // such a param would OVER-RETAIN: one leaked reference per call — fatal for a long-running
            // UI whose render loop hammers Map<string,_> get/set every frame (the param-leak bug). The
            // borrow's owner stays the CALLER. Gate on the param, not the arg's concrete type. (An
            // extern call only borrows its non-`move` heap args, §5h, so they are not consumed here.)
            consume(c, e->as.call.args[i], at[i], e->line, e->col);
        }
    }
    // Each fresh owned temporary passed by borrow (not consumed above) must be dropped by the
    // caller or it leaks (OFI-027). Mark them in a bitmask; codegen keeps copies below the arg
    // region and OP_DROP_UNDERs them after the call. Any position, any number — generalises the
    // arg0/receiver `drop_first` fast path. For an extern call this also covers refcounted/move
    // temps (string/array), since the foreign callee adopts nothing. A refcounted TEMP passed to a
    // generic BORROW param is now caller-dropped too (it was not consumed above — gated on the
    // param), so the temp's reference is reclaimed without the callee owning it.
    e->as.call.drop_mask = 0;
    for (int i = 0; i < np && i < 31; i++) {
        // A multi-slot struct arg is passed as its field slots (copied or unboxed in
        // place), not as a boxed value, so the caller never drops it — skip it here.
        if (param_multislot_sid(c, sig->params[i], sig->quals[i],
                                sig->generic_count) >= 0) {
            continue;
        }
        int owning_temp = is_owning_temp(c, e->as.call.args[i], at[i]);
        int marked = is_extern
                       ? owning_temp
                       : (sig->quals[i] != OWN_MOVE && !is_refcounted(c, sig->params[i]) && owning_temp);
        if (marked) {
            e->as.call.drop_mask |= (1 << i);
        }
    }
    // Value-types 3b.4: record, per argument, the struct id of a plain all-scalar struct
    // parameter passed MULTI-SLOT, so codegen pushes its N field slots instead of boxing.
    // Allocated only when at least one argument is multi-slot; NULL means all args boxed.
    e->as.call.arg_inline_struct = NULL;
    int any_ms = 0;
    for (int i = 0; i < np; i++) {
        if (param_multislot_sid(c, sig->params[i], sig->quals[i],
                                sig->generic_count) >= 0) {
            any_ms = 1;
            break;
        }
    }
    if (any_ms && argc > 0) {
        int *am = arena_alloc(c->arena, sizeof(int) * (size_t)argc);
        for (int i = 0; i < argc; i++) {
            am[i] = (i < np) ? param_multislot_sid(c, sig->params[i], sig->quals[i],
                                                   sig->generic_count)
                             : -1;
            // If a multi-slot-parameter argument is itself a construction or a multi-slot-
            // returning call, have it deliver its N field slots directly (no box→unbox round
            // trip): gen_arg consumes a box_result==0 producer in place (value-types 3b.4c).
            if (am[i] >= 0) {
                Expr *a = e->as.call.args[i];
                if (a->kind == EXPR_STRUCT_LIT && a->as.struct_lit.inline_sid >= 0) {
                    a->as.struct_lit.box_result = 0;
                } else if (a->kind == EXPR_CALL && a->as.call.ret_struct_id >= 0 &&
                           a->as.call.drop_first == 0 && a->as.call.drop_mask == 0) {
                    a->as.call.box_result = 0;
                }
            }
        }
        e->as.call.arg_inline_struct = am;
    }
    // Value-types 3b.4b: does this direct call return an all-scalar struct MULTI-SLOT?
    // (the callee leaves N field slots). -1 for a boxed/scalar result or a generic call.
    e->as.call.ret_struct_id = ret_multislot_sid(c, sig->ret, sig->generic_count);
    if (sig->generic_count == 0) {
        for (int i = 0; i < np; i++) {
            if (at[i] != TY_ERROR && sig->params[i] != TY_ERROR &&
                !assignable(c, e->as.call.args[i], at[i], sig->params[i])) {
                type_error(c, e->line, e->col,
                           "argument type does not match the parameter");
            }
        }
        return sig->ret;
    }
    // Generic call: infer each type parameter from the expected (return)
    // type and from bare type-parameter arguments, then check the rest.
    SemType bind[MAX_TYPE_ARGS];
    int     bound[MAX_TYPE_ARGS];
    for (int k = 0; k < sig->generic_count; k++) {
        bind[k]  = TY_ERROR;
        bound[k] = 0;
    }
    if (expected != TY_ERROR) {
        unify(c, sig->ret, expected, bind, bound, sig->generic_count);
    }
    for (int i = 0; i < np; i++) {
        if (!deferred[i]) {
            unify(c, sig->params[i], at[i], bind, bound, sig->generic_count);
        }
    }
    GenericInst tmp;
    tmp.base = 0;
    tmp.is_enum = 0;
    tmp.arg_count = sig->generic_count;
    for (int k = 0; k < sig->generic_count; k++) {
        // A parameter still unbound after phase 1 maps to *itself*, so a
        // deferred lambda's substituted type keeps it as an open parameter
        // (e.g. `fn(int) -> U`) that the lambda's body then pins.
        tmp.args[k] = bound[k] ? bind[k] : (SemType)(PARAM_BASE + k);
    }
    // Phase 2: now that the other arguments have pinned the type parameters,
    // check each deferred lambda against the substituted parameter type (its
    // parameter types are concrete; an unbound result is inferred from the
    // body), then bind any still-open parameters from the lambda's own type.
    for (int i = 0; i < np; i++) {
        if (!deferred[i]) {
            continue;
        }
        c->expected = subst(c, &tmp, sig->params[i]);
        at[i] = check_expr(c, e->as.call.args[i]);
        unify(c, sig->params[i], at[i], bind, bound, sig->generic_count);
        if (is_refcounted(c, at[i])) {
            consume(c, e->as.call.args[i], at[i], e->line, e->col);
        }
    }
    for (int k = 0; k < sig->generic_count; k++) {
        tmp.args[k] = bind[k];   // refresh with whatever the lambdas bound
    }
    int all_bound = 1;
    for (int k = 0; k < sig->generic_count; k++) {
        if (!bound[k]) {
            all_bound = 0;
        }
    }
    if (!all_bound) {
        type_error(c, e->line, e->col,
                   "cannot infer the type arguments for this call; "
                   "add a type annotation");
    }
    // Record the monomorphization key: the inferred type arguments, in
    // terms of the enclosing function's type parameters (the monomorphizer
    // substitutes the caller's instance through them).
    e->as.call.mono_arg_count = sig->generic_count;
    for (int k = 0; k < sig->generic_count; k++) {
        e->as.call.mono_args[k] = (int)bind[k];
    }
    for (int i = 0; i < np; i++) {
        SemType pt = subst(c, &tmp, sig->params[i]);
        if (at[i] != TY_ERROR && pt != TY_ERROR && at[i] != pt) {
            type_error(c, e->line, e->col,
                       "argument type does not match the parameter");
        }
    }
    // Bounded type parameters: each bound needs a witness (the concrete type's method
    // fn-indices for that interface). Build one per (param, bound), in the order the
    // callee receives them as hidden leading arguments — param0's bounds, then param1's.
    int wtotal = 0;
    for (int k = 0; k < sig->generic_count; k++) {
        wtotal += sig->bound_count[k];
    }
    Witness *ws = NULL;
    if (wtotal > 0) {
        ws = malloc(sizeof(Witness) * (size_t)wtotal);
        if (ws == NULL) {
            fprintf(stderr, "emberc: out of memory building witnesses\n");
            exit(70);
        }
    }
    int wi = 0;
    for (int k = 0; k < sig->generic_count; k++) {
        // Copy bound: the type argument must be copyable. Structs and arrays are
        // unique-owner move types that can't be freely aliased — binding one to a
        // `Copy` parameter would reintroduce the double-free (OFI-009). Scalars,
        // strings, enums, and closures are Copy.
        if (sig->is_copy[k] && bound[k] && bind[k] != TY_ERROR &&
            is_move_type(c, bind[k])) {
            type_error(c, e->line, e->col,
                       "type argument is not Copy — only scalars, strings, enums, and "
                       "closures satisfy a 'Copy' bound (not a struct or array)");
        }
        // OFI-049: a Ptr bound to a generic parameter would flow into an erased body the move/leak
        // checker can't see (it checks the body once with the param as `PARAM_BASE+k`, never re-run at
        // T = Ptr) — so the handle could be sunk or aliased un-tracked. Forbid it for EVERY parameter
        // (the Copy check above only fires for `T: Copy`). The defensive intern_* nets back this up.
        if (bound[k] && bind[k] == TY_PTR) {
            ptr_storage_error(c, bind[k], e->line, e->col, "a generic type argument");
        }
        // OFI-122: a `resource` flows into an erased generic body the move/clone checker can't re-check
        // at T = R, so it could be cloned or sunk un-tracked (double free) — e.g. `fn f<T>(x){ [x] }`
        // would build `[R]` at T = R. Forbid a resource as a generic-fn argument for EVERY parameter
        // (Phase 1: use a resource concretely, not through generics). Enum construction is a separate
        // path (it allows a resource payload — Result<R>/Option<R> — so this never blocks `Ok(db)`).
        if (is_resource_type(c, bind[k])) {
            type_error(c, e->line, e->col,
                       "a 'resource' cannot be a generic type argument — under erasure the body is "
                       "checked once and could clone or leak it (double free); use it concretely");
        }
        SemType arg = bind[k];
        for (int b = 0; b < sig->bound_count[k]; b++) {
            int iid = sig->bounds[k][b];
            ws[wi].fns = NULL;
            ws[wi].count = 0;
            if (!bound[k] || arg == TY_ERROR) {
                wi++;
                continue;
            }
            if (!type_satisfies_bound(c, arg, iid)) {
                type_error(c, e->line, e->col,
                           "type argument does not satisfy the generic bound");
                wi++;
                continue;
            }
            ws[wi].fns = build_witness(c, arg, iid, &ws[wi].count);
            wi++;
        }
    }
    e->as.call.witnesses     = ws;
    e->as.call.witness_total = wtotal;
    return subst(c, &tmp, sig->ret);
}


static SemType check_expr_inner(Checker *c, Expr *e);

// check_expr is a thin recursion-depth guard around check_expr_inner: a pathologically deep
// AST (a long operator chain, or deeply nested calls) would otherwise overflow the C stack
// (SIGSEGV) instead of producing a diagnostic. The depth is decremented on every path out.
static SemType check_expr(Checker *c, Expr *e) {
    if (++c->expr_depth > MAX_CHECK_DEPTH) {
        type_error(c, e->line, e->col, "expression nests too deeply to type-check");
        c->expr_depth--;
        return TY_ERROR;
    }
    SemType t = check_expr_inner(c, e);
    c->expr_depth--;
    return t;
}

static SemType check_expr_inner(Checker *c, Expr *e) {
    // The expected type applies only to this expression; sub-expressions checked
    // below must not inherit it, so capture and clear it up front.
    SemType expected = c->expected;
    c->expected = TY_ERROR;

    switch (e->kind) {
        case EXPR_INT: {
            // A width suffix forces the type; otherwise an integer expected type
            // (from an annotation or parameter) is taken; otherwise it is `int`.
            // The value must fit the chosen type's range.
            SemType t = TY_INT;
            if (e->suffix_type != 0) {
                t = suffix_to_type(e->suffix_type);
            } else if (is_integer_type(expected)) {
                t = expected;
            }
            if (!int_fits(e->as.int_lit, t)) {
                if (e->as.int_lit < 0 && t != TY_U64) {
                    // A magnitude in (i64-max, u64-max] reached here in a non-u64 context.
                    type_error(c, e->line, e->col,
                               "this integer literal exceeds the i64 range; only 'u64' can hold it "
                               "(annotate the binding 'u64', or add the 'u64' suffix)");
                } else {
                    type_error(c, e->line, e->col,
                               "integer literal is out of range for its type");
                }
            }
            return t;
        }

        case EXPR_BOOL:
            return TY_BOOL;

        case EXPR_UNARY: {
            SemType t = check_expr(c, e->as.unary.operand);
            if (e->as.unary.op == TOK_MINUS && is_numeric_type(t)) {
                e->num_kind = int_kind(t);   // width-aware negation (overflow trap)
                return t;
            }
            if (e->as.unary.op == TOK_BANG && t == TY_BOOL) {
                return TY_BOOL;
            }
            if (e->as.unary.op == TOK_TILDE && is_integer_type(t)) {
                e->num_kind = int_kind(t);   // width-aware: unsigned narrow types mask
                return t;
            }
            type_error(c, e->line, e->col,
                       "unary '-' needs a number, '~' needs an integer, '!' needs a bool");
            return TY_ERROR;
        }

        case EXPR_BINARY: {
            SemType l = check_expr(c, e->as.binary.left);
            SemType r = check_expr(c, e->as.binary.right);
            TokenType op = e->as.binary.op;
            e->as.binary.str_concat = 0;   // default (arena nodes aren't zeroed); set only for a string `+`

            // A bare integer literal adopts the other operand's width, so `x + 1`
            // and `1 + x` work when `x` is a sized int. Only a direct, unsuffixed
            // literal is promoted (and range-checked); deeper mixes need a suffix.
            Expr *le = e->as.binary.left;
            Expr *re = e->as.binary.right;
            if (is_integer_type(l) && r == TY_INT &&
                re->kind == EXPR_INT && re->suffix_type == 0) {
                if (!int_fits(re->as.int_lit, l)) {
                    type_error(c, e->line, e->col,
                               "integer literal is out of range for its type");
                }
                r = l;
            } else if (is_integer_type(r) && l == TY_INT &&
                       le->kind == EXPR_INT && le->suffix_type == 0) {
                if (!int_fits(le->as.int_lit, r)) {
                    type_error(c, e->line, e->col,
                               "integer literal is out of range for its type");
                }
                l = r;
            } else if (l == TY_F32 && r == TY_FLOAT && re->kind == EXPR_FLOAT) {
                r = l;   // an f32 operand pulls a bare float literal to f32
            } else if (r == TY_F32 && l == TY_FLOAT && le->kind == EXPR_FLOAT) {
                l = r;
            }

            // No coercion: integer operands must share the *same* width.
            if (op == TOK_PERCENT) {
                if (is_integer_type(l) && l == r) {
                    e->num_kind = int_kind(l);
                    return l;
                }
                type_error(c, e->line, e->col,
                           "'%' requires two integer operands of the same type");
                return TY_ERROR;
            }
            if (op == TOK_PLUS && l == TY_STRING && r == TY_STRING) {
                // String concatenation. Emit the CONSUMING OP_CONCAT (num_kind 8 marks it for codegen),
                // mirroring the interpolation fix (OFI-059): a plain OP_ADD does not release its operands,
                // so a multi-operand chain `a + b + c` ((a+b)+c) leaks the intermediate `a+b` — one heap
                // string per chain, per word in a wrap loop, per frame (the long-running-UI leak). Consume
                // both operands: a BORROWED operand is incref'd (moves_local==2) so OP_CONCAT's release
                // nets to zero (its owner keeps its reference); an OWNED temporary (a nested concat / call
                // result) gets no incref, so OP_CONCAT frees it. Sound either way.
                consume(c, e->as.binary.left, TY_STRING, e->line, e->col);
                consume(c, e->as.binary.right, TY_STRING, e->line, e->col);
                e->as.binary.str_concat = 1;
                return TY_STRING;   // string concatenation
            }
            if (is_arith_op(op)) {   // + - * /
                if (is_numeric_type(l) && l == r) {
                    e->num_kind = int_kind(l);   // width-aware overflow / f32 rounding
                    return l;
                }
                if (is_newtype(l) || is_newtype(r)) {   // OFI-149: arithmetic needs an explicit unwrap
                    type_error(c, e->line, e->col,
                               "arithmetic on a newtype requires unwrapping to its base first "
                               "(e.g. `int(x)`), then re-wrapping the result");
                    return TY_ERROR;
                }
                type_error(c, e->line, e->col,
                           "arithmetic operands must be the same numeric type "
                           "(or both string for '+')");
                return TY_ERROR;
            }
            if (is_relational_op(op)) {
                SemType lb = is_newtype(l) ? newtype_base(c, l) : l;   // OFI-149: compare via the base
                if (is_numeric_type(lb) && l == r) {
                    e->num_kind = int_kind(lb);   // u64 compares unsigned
                    return TY_BOOL;
                }
                type_error(c, e->line, e->col,
                           "comparison operands must be the same numeric type");
                return TY_ERROR;
            }
            if (is_equality_op(op)) {
                // No coercion: the two sides must be the same comparable type. A newtype compares
                // via its base (OFI-149), same-newtype only (l == r) — never against the raw base.
                SemType lb = is_newtype(l) ? newtype_base(c, l) : l;
                if (l == r &&
                    (is_integer_type(lb) || lb == TY_BOOL || lb == TY_FLOAT ||
                     lb == TY_STRING)) {
                    return TY_BOOL;
                }
                type_error(c, e->line, e->col,
                           "'==' / '!=' operands must be the same scalar/string type");
                return TY_ERROR;
            }
            if (is_logical_op(op)) {
                if (l == TY_BOOL && r == TY_BOOL) {
                    return TY_BOOL;
                }
                type_error(c, e->line, e->col,
                           "'&&' / '||' operands must both be bool");
                return TY_ERROR;
            }
            if (is_bitwise_op(op)) {
                // `& | ^` are integer-only and width-preserving; both operands must
                // be the same integer type (bools use `&&`/`||`). The result keeps the
                // operand width — the bit pattern of two in-width values stays in width.
                if (is_integer_type(l) && l == r) {
                    e->num_kind = int_kind(l);
                    return l;
                }
                type_error(c, e->line, e->col,
                           "bitwise '& | ^' require two integer operands of the same type");
                return TY_ERROR;
            }
            if (is_shift_op(op)) {
                // `<< >>` shift the LEFT operand by a count; the result has the left
                // operand's type. The count is any integer (it need not match the
                // value's width), so unlike arithmetic we do NOT require l == r. The
                // value is truncated to its width (a bit op), and the shift amount is
                // range-checked to [0, width) at run time.
                if (is_integer_type(l) && is_integer_type(r)) {
                    e->num_kind = int_kind(l);
                    return l;
                }
                type_error(c, e->line, e->col,
                           "shift '<< >>' require integer operands "
                           "(value and shift amount)");
                return TY_ERROR;
            }
            type_error(c, e->line, e->col, "unsupported binary operator");
            return TY_ERROR;
        }

        case EXPR_IDENT: {
            int slot = resolve_local(c, e->as.ident);
            if (slot >= 0) {
                if (c->locals[slot].moved) {
                    // Teacher-grade diagnostic (MANIFESTO §3.1): name the value, point
                    // a note at where it was moved, and explain the fix in the user's
                    // terms — not "ownership theory". This is the #1 LLM error class.
                    char msg[160];
                    snprintf(msg, sizeof msg,
                             "use of '%s' after it was moved", e->as.ident);
                    diag_error(diag_src(c), e->line, e->col, msg, NULL,
                               "a move transfers ownership; pass it without `move` to "
                               "borrow it instead, or make a copy before the move");
                    if (c->locals[slot].move_line > 0) {
                        diag_note(diag_src(c), c->locals[slot].move_line,
                                  c->locals[slot].move_col, "value moved here");
                    }
                    c->had_error = 1;
                }
                sem_record_local(c, e, slot);   // LSP: hover/go-to-def for this local/param
                return c->locals[slot].type;
            }
            // A bare name may be a zero-field enum variant (constructs a value).
            VariantInfo *v = resolve_variant(c, e->as.ident);
            if (v != NULL) {
                if (v->field_count != 0) {
                    type_error(c, e->line, e->col,
                               "this variant carries fields — call it with arguments");
                    return TY_ERROR;
                }
                sem_record_variant(c, e->line, e->col, v);   // LSP: hover on `None`/zero-field variant
                e->variant_enum_id = v->enum_id;             // codegen builds THIS variant, not a by-name lookup
                e->variant_tag     = v->variant_index;
                return infer_variant_type(c, e->line, e->col, v, NULL, 0, expected);
            }
            // A bare top-level function name in value position is a function value,
            // of type fn(params) -> ret. (A *call* never reaches here — its callee
            // is resolved directly in EXPR_CALL.) Generic functions can't yet be
            // taken as values: their type parameters would be unbound.
            int fi = resolve_signature(c, e->as.ident);
            if (fi >= 0) {
                FnSig *sig = &c->fns[fi];
                // A foreign (extern "c") function has NO bytecode slot (fn_index == -1) — whether a
                // hosted-registry extern (dispatched by index) or a native direct-extern (OFI-167) —
                // so it cannot be closed over or called indirectly. Taking one as a value would emit
                // a closure over function index -1 (OP_MAKE_CLOSURE / em_closure(-1)), which the VM
                // then indexes out of bounds → a crash. Reject it, like `spawn` of an extern (OFI-168).
                if (sig->cextern_index >= 0 || sig->direct_extern) {
                    type_error(c, e->line, e->col,
                               "a foreign (extern \"c\") function cannot be used as a function value; "
                               "call it directly");
                    return TY_ERROR;
                }
                if (sig->generic_count != 0) {
                    type_error(c, e->line, e->col,
                               "a generic function cannot yet be used as a value");
                    return TY_ERROR;
                }
                // A function with a MULTI-SLOT (plain all-scalar struct) parameter OR return
                // uses a by-slot calling convention only the direct/spawn call paths emit; a
                // closure call would pass/expect it boxed and corrupt the frame. Until the
                // closure path learns the convention, taking such a function as a value is an
                // error rather than latent corruption (value-types 3b.4).
                int ms_sig = ret_multislot_sid(c, sig->ret, sig->generic_count) >= 0;
                for (int p = 0; p < sig->param_count && !ms_sig; p++) {
                    if (param_multislot_sid(c, sig->params[p], sig->quals[p],
                                            sig->generic_count) >= 0) {
                        ms_sig = 1;
                    }
                }
                if (ms_sig) {
                    type_error(c, e->line, e->col,
                               "a function with a struct value parameter or return cannot yet "
                               "be used as a function value");
                    return TY_ERROR;
                }
                SemType ft = intern_fn_type(c, sig->params, sig->param_count,
                                            sig->ret);
                // LSP: hover/go-to-def on a bare function-value reference (record before the
                // node is rewritten below, while `ident` still names it).
                sem_record_fn(c, e->line, e->col, e->as.ident, sig, NULL, NULL);
                // Rewrite to a function-value node carrying the exact table index, so
                // codegen need not re-resolve the name (function names aren't unique
                // across modules). Safe: `ident` is no longer needed past this point.
                e->kind = EXPR_FN_VALUE;
                e->as.fn_value = sig->fn_index;
                return ft;
            }
            // A top-level constant (OFI-023): rewrite the use to its literal value.
            int gi = resolve_global(c, e->as.ident);
            if (gi >= 0) {
                sem_record_const(c, e->line, e->col, e->as.ident, gi, NULL, NULL);
                return substitute_const(c, e, gi);
            }
            type_error(c, e->line, e->col, "undefined variable");
            return TY_ERROR;
        }

        case EXPR_CALL: {
            Expr *callee = e->as.call.callee;
            // NAMED enum-variant construction `Circle(radius: 2.0)` → validate + reorder into declared
            // field order (then it is positional from here, like `Circle(2.0)`); a non-variant call with
            // named args errors here (OFI-140). A no-op when no argument was named (the common case).
            resolve_named_args(c, e);
            int argc = (int)e->as.call.arg_count;

            // A call through a function *value*: the callee evaluates to a function
            // type — a local/parameter (`f(x)`), or a compound expression such as a
            // call result (`pick(true)(9)`). A bare function NAME or a method is not
            // this; those keep their direct paths below. (A fn-typed struct field —
            // an EXPR_GET callee — is left to the method path for now.)
            SemType callee_fn = TY_ERROR;
            if (callee->kind == EXPR_IDENT) {
                int fslot = resolve_local(c, callee->as.ident);
                if (fslot >= 0 && is_fn_type(c->locals[fslot].type)) {
                    callee_fn = c->locals[fslot].type;
                }
            } else if (callee->kind != EXPR_GET) {
                SemType ct = check_expr(c, callee);
                if (is_fn_type(ct)) {
                    callee_fn = ct;
                } else {
                    if (ct != TY_ERROR) {
                        type_error(c, e->line, e->col,
                                   "this expression is not callable");
                    }
                    for (int i = 0; i < argc; i++) {
                        check_expr(c, e->as.call.args[i]);
                    }
                    return TY_ERROR;
                }
            }
            if (is_fn_type(callee_fn)) {
                FnType *ft = fn_type_of(c, callee_fn);
                e->as.call.closure_call = 1;
                SemType ret = ft->ret;
                int pc = ft->param_count;
                if (argc != pc) {
                    type_error(c, e->line, e->col,
                               "wrong number of arguments to this function value");
                }
                int n = argc < pc ? argc : pc;
                for (int i = 0; i < argc; i++) {
                    SemType saved = c->expected;
                    if (i < n) {
                        c->expected = ft->params[i];
                    }
                    SemType at = check_expr(c, e->as.call.args[i]);
                    c->expected = saved;
                    if (i < n && at != TY_ERROR && ft->params[i] != TY_ERROR &&
                        at != ft->params[i]) {
                        type_error(c, e->line, e->col,
                                   "argument type does not match the function "
                                   "value's parameter");
                    }
                    // No consume here: OP_CALL_CLOSURE retains heap arguments at
                    // run time (the call site may sit inside an erased generic body
                    // where the static type is a bare `T`), and the callee's
                    // concrete parameters release them. Consuming here too would
                    // double-retain at concrete call sites.
                }
                return ret;
            }

            // Method call: `object.method(args)`. The receiver is the implicit
            // self argument; explicit args follow. A generic receiver (Box<int>)
            // supplies `recv`, whose args substitute the method's signature.
            // Module-qualified function call: `alias.foo(args)`, where `alias` is
            // an import (not a local value). Resolves to a public function in the
            // imported module.
            if (callee->kind == EXPR_GET &&
                callee->as.get.object->kind == EXPR_IDENT &&
                resolve_local(c, callee->as.get.object->as.ident) < 0) {
                int reason = 0;
                int qidx = resolve_qualified_fn(c, callee->as.get.object->as.ident,
                                                callee->as.get.name, &reason);
                if (qidx >= 0) {
                    // A qualified call follows every rule a direct call does —
                    // including full generic inference — via the shared helper.
                    FnSig *sig = &c->fns[qidx];
                    e->as.call.resolved_fn = sig->fn_index;
                    // LSP: cross-module hover/go-to-def on `ui.window` — the function (with its
                    // owning module + the imported file as its def site) and the alias itself.
                    sem_record_fn(c, callee->as.get.name_line, callee->as.get.name_col,
                                  callee->as.get.name, sig, callee->as.get.object->as.ident,
                                  c->modules->modules[sig->module].path);
                    sem_record_module(c, callee->as.get.object, sig->module);
                    return check_fn_call(c, e, sig, expected);
                }
                // Cross-module qualified variant construction `json.Obj([...])`: the alias is an
                // import whose `.name` is a variant of one of its public enums. Codegen builds it
                // from the threaded enum id + tag set here, so no desugar is needed (OFI-073 Stage 2).
                VariantInfo *qvar = resolve_qualified_variant(c, callee->as.get.object->as.ident,
                                                              callee->as.get.name);
                if (qvar != NULL) {
                    sem_record_variant(c, callee->as.get.name_line, callee->as.get.name_col, qvar);
                    e->variant_enum_id = qvar->enum_id;
                    e->variant_tag     = qvar->variant_index;
                    int qargc = (int)e->as.call.arg_count;
                    // Zero-init: the fill loop sets at[0..n-1] (n = min(qargc, MAX_PARAMS)) and only
                    // those are read, so this is safe — but gcc -O2 can't prove the bound matches n
                    // and warns (-Wmaybe-uninitialized, a false positive). Init makes it provable.
                    SemType at[MAX_PARAMS] = {0};
                    for (int i = 0; i < qargc && i < MAX_PARAMS; i++) {
                        at[i] = check_expr(c, e->as.call.args[i]);
                    }
                    for (int i = MAX_PARAMS; i < qargc; i++) {
                        check_expr(c, e->as.call.args[i]);
                    }
                    int n = qargc < MAX_PARAMS ? qargc : MAX_PARAMS;
                    SemType vt = infer_variant_type(c, e->line, e->col, qvar, at, n, expected);
                    for (int i = 0; i < qargc; i++) {
                        consume(c, e->as.call.args[i], i < n ? at[i] : TY_ERROR, e->line, e->col);
                    }
                    return vt;
                }
                if (reason != 0) {   // alias matched an import, but the function did not
                    type_error(c, e->line, e->col, reason == 2 ?
                               "that function is private to its module (leading '_')"
                               : "no such public function in the imported module");
                    for (size_t i = 0; i < e->as.call.arg_count; i++) {
                        check_expr(c, e->as.call.args[i]);
                    }
                    return TY_ERROR;
                }
                // Qualified enum-variant construction: `Option.Some(7)`. The object
                // names an enum in scope, so `.name` must be one of its variants.
                // Desugar to the bare variant — names are globally unique — so the
                // bare-variant path below (and codegen) handle it as `Some(7)`.
                int veid = resolve_enum(c, callee->as.get.object->as.ident);
                if (veid >= 0) {
                    VariantInfo *qv = enum_variant(c, veid, callee->as.get.name);
                    if (qv == NULL) {
                        type_error(c, e->line, e->col, "no such variant on this enum");
                        for (int i = 0; i < argc; i++) {
                            check_expr(c, e->as.call.args[i]);
                        }
                        return TY_ERROR;
                    }
                    (void)qv;
                    // Desugar to the bare variant, repositioning the callee onto the variant
                    // NAME so the bare-variant path below records the LSP hover at `Some`, not
                    // at the `Option` qualifier.
                    const char *vname = callee->as.get.name;
                    callee->line     = callee->as.get.name_line;
                    callee->col      = callee->as.get.name_col;
                    callee->kind     = EXPR_IDENT;
                    callee->as.ident = vname;
                }
                // reason == 0: not an import alias — fall through to a method call
                // (or, after the desugar above, the bare-variant construction path).
            }

            if (callee->kind == EXPR_GET) {
                SemType ot = check_expr(c, callee->as.get.object);

                // Intrinsic array methods: a.append(x) / a.remove_last() / a.len().
                // append and remove_last mutate, so the receiver must be rooted at a
                // mutable place (a `var` binding or a `mut`/`move` parameter).
                if (is_array_type(ot) || is_slice_type(ot)) {
                    int is_slice = is_slice_type(ot);
                    SemType elem = is_slice ? slice_elem(c, ot) : array_elem(c, ot);
                    const char *m = callee->as.get.name;
                    int mutates = (strcmp(m, "append") == 0 ||
                                   strcmp(m, "remove_last") == 0 ||
                                   strcmp(m, "remove_at") == 0);
                    if (mutates && is_slice) {
                        type_error(c, e->line, e->col,
                                   "a slice is a read-only view; mutate the underlying array, "
                                   "or copy with .slice(a, b)");
                    }
                    if (mutates && !is_slice) {
                        Expr *root = callee->as.get.object;
                        while (root->kind == EXPR_INDEX || root->kind == EXPR_GET) {
                            root = root->kind == EXPR_INDEX ? root->as.index.object
                                                            : root->as.get.object;
                        }
                        if (root->kind == EXPR_IDENT) {
                            int slot = resolve_local(c, root->as.ident);
                            if (slot >= 0 && !c->locals[slot].is_var) {
                                type_error(c, e->line, e->col,
                                           "cannot mutate an array through an immutable "
                                           "binding; declare it 'var' or take 'mut'");
                            }
                            if (slot >= 0 && c->locals[slot].frozen) {
                                type_error(c, e->line, e->col,
                                           "cannot mutate an array while it is borrowed by a "
                                           "slice (the view would dangle)");
                            }
                        }
                    }
                    if (strcmp(m, "append") == 0) {
                        callee->as.get.array_op = ARR_OP_APPEND;
                        if (argc != 1) {
                            type_error(c, e->line, e->col,
                                       "append takes one argument (the element)");
                        }
                        c->expected = elem;   // a literal arg adopts the element width
                        SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                               : TY_ERROR;
                        if (at != TY_ERROR && at != elem) {
                            type_error(c, e->line, e->col,
                                       "appended value's type does not match the array");
                        }
                        if (argc >= 1) {
                            consume(c, e->as.call.args[0], at, e->line, e->col);
                        }
                        sem_record_intrinsic(c, callee, ot, "value", elem, TY_UNIT,
                            "Appends a value to the end of the array, growing it by one "
                            "(mutates the receiver).");   // LSP: hover on `.append`
                        return TY_UNIT;
                    }
                    if (strcmp(m, "remove_at") == 0) {
                        callee->as.get.array_op = ARR_OP_REMOVE_AT;
                        if (argc != 1) {
                            type_error(c, e->line, e->col,
                                       "remove_at takes one argument (the index)");
                        }
                        c->expected = TY_INT;
                        SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                               : TY_ERROR;
                        if (at != TY_ERROR && at != TY_INT) {
                            type_error(c, e->line, e->col,
                                       "remove_at's index must be 'int'");
                        }
                        if (recv_reads_as_copy(callee->as.get.object)) {
                            // Same restriction as remove_last: a receiver read as a copy (an index /
                            // value-struct field) would shrink the copy and not persist (OFI-072). The
                            // in-place write-back needs a clean statement position the VM can't yet
                            // thread. Workaround: bind the array to a var, remove_at, assign it back.
                            type_error(c, e->line, e->col,
                                "remove_at on an array reached through an index isn't supported yet "
                                "(OFI-072): bind the array to a variable, remove_at from that, then "
                                "assign it back.");
                        }
                        sem_record_intrinsic(c, callee, ot, "index", TY_INT, elem,
                            "Removes the element at the given index and returns it, shifting the "
                            "later elements down (mutates the receiver).");   // LSP: hover on `.remove_at`
                        return elem;   // hands back the removed element
                    }
                    if (strcmp(m, "remove_last") == 0) {
                        callee->as.get.array_op = ARR_OP_REMOVE_LAST;
                        if (argc != 0) {
                            type_error(c, e->line, e->col,
                                       "remove_last takes no arguments");
                        }
                        if (recv_reads_as_copy(callee->as.get.object)) {
                            // The receiver reads a copy (an index / value-struct field), so
                            // remove_last would shrink the copy and not persist (OFI-072). The
                            // write-back is implemented for `append`; remove_last's result rides on
                            // top of the moved-out array, which the VM codegen can only thread at a
                            // clean statement position — reject it rather than risk it. Workaround:
                            // bind the array to a variable, remove_last from that, assign it back.
                            type_error(c, e->line, e->col,
                                "remove_last on an array reached through an index isn't supported "
                                "yet (OFI-072): bind the array to a variable, remove_last from that, "
                                "then assign it back.");
                        }
                        sem_record_intrinsic(c, callee, ot, NULL, TY_ERROR, elem,
                            "Removes the last element and returns it (mutates the "
                            "receiver).");   // LSP: hover on `.remove_last`
                        return elem;   // hands back the removed element
                    }
                    if (strcmp(m, "len") == 0) {
                        callee->as.get.array_op = ARR_OP_LEN;
                        if (argc != 0) {
                            type_error(c, e->line, e->col, "len takes no arguments");
                        }
                        sem_record_intrinsic(c, callee, ot, NULL, TY_ERROR, TY_INT,
                            is_slice ? "Returns the number of elements in the slice."
                                     : "Returns the number of elements in the array.");
                        return TY_INT;
                    }
                    if (strcmp(m, "slice") == 0) {
                        // A COPYING slice: a fresh OWNED [T] holding a copy of [lo, hi). Unlike the
                        // zero-copy view `a[lo..hi]`, this can be returned/stored (slices §). Not
                        // allowed when the element is itself an array (a shallow copy would alias
                        // a move-type element — deferred).
                        callee->as.get.array_op = ARR_OP_SLICE;
                        if (argc != 2) {
                            type_error(c, e->line, e->col,
                                       "slice takes two arguments (lo, hi)");
                        }
                        SemType a0 = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                        SemType a1 = argc >= 2 ? check_expr(c, e->as.call.args[1]) : TY_ERROR;
                        if ((a0 != TY_INT && a0 != TY_ERROR) ||
                            (a1 != TY_INT && a1 != TY_ERROR)) {
                            type_error(c, e->line, e->col, "slice bounds must be 'int'");
                        }
                        if (is_array_type(elem)) {
                            type_error(c, e->line, e->col,
                                       "copying .slice() of a nested-array element is not "
                                       "supported yet; slice the inner arrays instead");
                        }
                        SemType ret = intern_array(c, elem);   // an owned [T] copy
                        sem_record_intrinsic(c, callee, ot, "lo", TY_INT, ret,
                            "Returns a new OWNED array copy of the elements in [lo, hi).");
                        return ret;
                    }
                    if (strcmp(m, "clone") == 0) {
                        // A DEEP COPY: a fresh OWNED [T] independent of the receiver, elements
                        // cloned recursively (OFI-082). The receiver is READ, not consumed, so
                        // `arr[i].clone()` is legal where the bare move-out `dst.append(arr[i])`
                        // is rejected — clone makes the copy explicit (manifesto: costs visible).
                        if (is_slice) {
                            type_error(c, e->line, e->col,
                                       "a slice is a read-only view; copy it with "
                                       ".slice(0, len), not .clone()");
                            return TY_ERROR;
                        }
                        callee->as.get.clone_op = 1;
                        if (argc != 0) {
                            type_error(c, e->line, e->col, "clone takes no arguments");
                        }
                        sem_record_intrinsic(c, callee, ot, NULL, TY_ERROR, ot,
                            "Returns an independent DEEP COPY of the array (elements cloned "
                            "recursively); mutating the copy never affects the original.");
                        return ot;   // an owned, independent [T]
                    }
                    type_error(c, e->line, e->col,
                               is_slice
                                 ? "no such slice method (expected len or slice)"
                                 : "no such array method (expected append, remove_last, "
                                   "remove_at, len, slice, or clone)");
                    return TY_ERROR;
                }

                // Intrinsic string methods. Strings are immutable UTF-8, so these read and
                // return new values. `chars`/`char_count`/`char_code` work at Unicode CODE-POINT
                // granularity; `len`/`bytes` work at the byte (storage / FFI) level.
                if (ot == TY_STRING) {
                    const char *m = callee->as.get.name;
                    if (strcmp(m, "len") == 0) {
                        callee->as.get.string_op = 1;
                        if (argc != 0) {
                            type_error(c, e->line, e->col, "len takes no arguments");
                        }
                        sem_record_intrinsic(c, callee, TY_STRING, NULL, TY_ERROR, TY_INT,
                            "Returns the length of the string in BYTES (O(1)). For the number "
                            "of Unicode code points, use char_count().");   // LSP: hover
                        return TY_INT;
                    }
                    if (strcmp(m, "chars") == 0) {
                        callee->as.get.string_op = 2;
                        if (argc != 0) {
                            type_error(c, e->line, e->col, "chars takes no arguments");
                        }
                        SemType ret = intern_array(c, TY_STRING);   // [string], one per code point
                        sem_record_intrinsic(c, callee, TY_STRING, NULL, TY_ERROR, ret,
                            "Decodes the UTF-8 string into its Unicode code points, one string "
                            "per code point.");   // LSP: hover
                        return ret;
                    }
                    if (strcmp(m, "char_count") == 0) {
                        callee->as.get.string_op = 5;
                        if (argc != 0) {
                            type_error(c, e->line, e->col, "char_count takes no arguments");
                        }
                        sem_record_intrinsic(c, callee, TY_STRING, NULL, TY_ERROR, TY_INT,
                            "Returns the number of Unicode code points (O(n)). For the byte "
                            "length, use len().");   // LSP: hover
                        return TY_INT;
                    }
                    if (strcmp(m, "bytes") == 0) {
                        callee->as.get.string_op = 6;
                        if (argc != 0) {
                            type_error(c, e->line, e->col, "bytes takes no arguments");
                        }
                        SemType ret = intern_array(c, TY_U8);   // [u8], the raw UTF-8 bytes
                        sem_record_intrinsic(c, callee, TY_STRING, NULL, TY_ERROR, ret,
                            "Returns the raw UTF-8 bytes as a [u8] (e.g. to pass to C).");   // LSP
                        return ret;
                    }
                    if (strcmp(m, "split") == 0) {
                        callee->as.get.string_op = 3;
                        if (argc != 1) {
                            type_error(c, e->line, e->col,
                                       "split takes one argument (the separator)");
                        }
                        SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                               : TY_ERROR;
                        if (at != TY_ERROR && at != TY_STRING) {
                            type_error(c, e->line, e->col,
                                       "split's separator must be a string");
                        }
                        SemType ret = intern_array(c, TY_STRING);
                        sem_record_intrinsic(c, callee, TY_STRING, "sep", TY_STRING, ret,
                            "Splits the string on every occurrence of the separator, "
                            "returning the pieces.");   // LSP: hover
                        return ret;
                    }
                    if (strcmp(m, "parse_int") == 0) {
                        callee->as.get.string_op = 4;
                        if (argc != 0) {
                            type_error(c, e->line, e->col,
                                       "parse_int takes no arguments");
                        }
                        SemType ret = option_of(c, TY_INT, e->line, e->col);  // Some(n)/None
                        sem_record_intrinsic(c, callee, TY_STRING, NULL, TY_ERROR, ret,
                            "Parses the whole string as an integer, returning Some(n) on "
                            "success or None.");   // LSP: hover
                        return ret;
                    }
                    type_error(c, e->line, e->col,
                               "no such string method (expected len, char_count, chars, "
                               "bytes, split, or parse_int)");
                    return TY_ERROR;
                }

                // Bound-method call: the receiver is a bounded type parameter
                // (`a: T` where `T: Ord`), so `a.compare(b)` dispatches through the
                // bound interface. `Self` in the interface method resolves to T.
                if (is_type_param(ot)) {
                    int pidx = ot - PARAM_BASE;
                    int nb = pidx < c->tparam_count ? c->tparam_bound_count[pidx] : 0;
                    if (nb == 0) {
                        type_error(c, e->line, e->col,
                                   "cannot call a method on an unbounded type "
                                   "parameter");
                        for (int i = 0; i < argc; i++) {
                            check_expr(c, e->as.call.args[i]);
                        }
                        return TY_ERROR;
                    }
                    // The witnesses for this param sit after those of earlier params;
                    // its bound `b` is the (wbase + b)-th witness. In a free function that
                    // is a hidden local slot; in a method it is a self FIELD, appended
                    // after the struct's declared fields (instance-storage).
                    int wbase = 0;
                    for (int j = 0; j < pidx; j++) {
                        wbase += c->tparam_bound_count[j];
                    }
                    int via_self = (c->self_struct >= 0);
                    int field_base = via_self ? c->structs[c->self_struct].field_count : 0;
                    // Search each bound interface for the method (T: Hash + Eq).
                    InterfaceInfo *ii = NULL;
                    MethodSig *ms = NULL;
                    for (int b = 0; b < nb && ms == NULL; b++) {
                        InterfaceInfo *cand = &c->interfaces[c->tparam_bounds[pidx][b]];
                        for (int m = 0; m < cand->method_count; m++) {
                            if (strcmp(cand->methods[m].name, callee->as.get.name) == 0) {
                                ii = cand;
                                ms = &cand->methods[m];
                                callee->as.get.bound_method   = m;
                                callee->as.get.bound_via_self = via_self;
                                callee->as.get.bound_witness  =
                                    via_self ? field_base + wbase + b : wbase + b;
                                break;
                            }
                        }
                    }
                    (void)ii;
                    if (ms == NULL) {
                        type_error(c, e->line, e->col,
                                   "no such method on any of the type parameter's bounds");
                        for (int i = 0; i < argc; i++) {
                            check_expr(c, e->as.call.args[i]);
                        }
                        return TY_ERROR;
                    }
                    if (argc != ms->param_count) {
                        type_error(c, e->line, e->col,
                                   "wrong number of arguments to method");
                    }
                    for (int i = 0; i < argc; i++) {
                        SemType at = check_expr(c, e->as.call.args[i]);
                        if (i < ms->param_count && at != TY_ERROR) {
                            SemType pt = resolve_self(ms->params[i], ot);
                            if (pt != TY_ERROR && at != pt) {
                                type_error(c, e->line, e->col,
                                           "argument type does not match the parameter");
                            }
                        }
                        if (is_refcounted(c, at)) {
                            consume(c, e->as.call.args[i], at, e->line, e->col);
                        }
                    }
                    return resolve_self(ms->ret, ot);
                }

                // Dynamic dispatch: the receiver is an interface VALUE (`d: Drawable`),
                // so `d.area()` looks up the method in the interface and dispatches
                // through the value's vtable at run time. Object safety (checked at the
                // type's use site) guarantees no `Self` appears beyond the receiver.
                if (is_interface_type(ot)) {
                    InterfaceInfo *ii = &c->interfaces[interface_id_of(ot)];
                    MethodSig *ms = NULL;
                    for (int m = 0; m < ii->method_count; m++) {
                        if (strcmp(ii->methods[m].name, callee->as.get.name) == 0) {
                            ms = &ii->methods[m];
                            callee->as.get.dyn_method = m;   // vtable slot
                            break;
                        }
                    }
                    if (ms == NULL) {
                        type_error(c, e->line, e->col, "no such method on this interface");
                        for (int i = 0; i < argc; i++) {
                            check_expr(c, e->as.call.args[i]);
                        }
                        return TY_ERROR;
                    }
                    if (argc != ms->param_count) {
                        type_error(c, e->line, e->col,
                                   "wrong number of arguments to method");
                    }
                    for (int i = 0; i < argc; i++) {
                        SemType at = check_expr(c, e->as.call.args[i]);
                        if (i < ms->param_count && at != TY_ERROR &&
                            !assignable(c, e->as.call.args[i], at, ms->params[i])) {
                            type_error(c, e->line, e->col,
                                       "argument type does not match the parameter");
                        }
                        if (is_refcounted(c, at)) {
                            consume(c, e->as.call.args[i], at, e->line, e->col);
                        }
                    }
                    return ms->ret;
                }

                int base = -1;
                const GenericInst *recv = NULL;
                if (is_struct_type(ot)) {
                    base = ot;
                } else if (is_generic_inst(ot) &&
                           !c->ginsts[ot - GENERIC_BASE].is_enum) {
                    recv = &c->ginsts[ot - GENERIC_BASE];
                    base = recv->base;
                }
                MethodInfo *mi = base >= 0
                    ? resolve_method(c, base, callee->as.get.name) : NULL;
                if (base < 0) {
                    if (ot != TY_ERROR) {
                        type_error(c, e->line, e->col,
                                   "method call requires a struct value");
                    }
                } else if (mi == NULL && strcmp(callee->as.get.name, "clone") == 0 &&
                           type_is_rc(c, ot)) {
                    // `.clone()` on an `rc struct` is meaningless: the value is immutable and shared,
                    // so there is nothing a private copy buys (you can't mutate it), and a deep copy
                    // would defeat the sharing. Binding it (`let b = a`) already gives another owner.
                    type_error(c, e->line, e->col,
                               "an 'rc struct' is immutable and shared; bind it ('let b = a') to "
                               "gain another owner — '.clone()' (an independent, mutable copy) is "
                               "not meaningful for an rc value");
                    return ot;
                } else if (mi == NULL && strcmp(callee->as.get.name, "clone") == 0) {
                    // Built-in `.clone()` deep copy on a value-struct (incl. a generic struct
                    // such as Map<K,V> / Set<K>), available when the struct has no user method
                    // named `clone` (a user method wins). The receiver is READ, not consumed —
                    // an independent owned copy with heap fields cloned recursively (OFI-082).
                    callee->as.get.clone_op = 2;
                    if (argc != 0) {
                        type_error(c, e->line, e->col, "clone takes no arguments");
                    }
                    sem_record_intrinsic(c, callee, ot, NULL, TY_ERROR, ot,
                        "Returns an independent DEEP COPY of the struct (heap fields cloned "
                        "recursively); mutating the copy never affects the original.");
                    return ot;   // an owned, independent copy of the struct
                } else if (mi == NULL) {
                    type_error(c, e->line, e->col, "no such method on this struct");
                } else {
                    // Point codegen at the method's function-table slot.
                    callee->as.get.field_index = mi->fn_index;
                    // LSP: hover + go-to-def on the method name (def jumps only when the method
                    // is declared in the file being edited — see the field-access guard).
                    sem_record_method(c, callee, mi, c->structs[base].name,
                                      c->structs[base].module == c->current_module);
                    // A `mut self` method is a MUTABLE BORROW of the receiver: it may write through
                    // self and, for a reference-like value (an array / boxed-field struct), the caller
                    // observes the change — so the receiver must be a mutable place, exactly as an
                    // explicit `mut` argument is (OFI-048). An immutable `let` binding would be frozen
                    // by the language yet silently mutated (or, for a value-copied scalar struct, the
                    // write would hit a throwaway copy and be lost). A non-place receiver (a literal,
                    // constructor, or call result like `mk().scale(2)`) is a throwaway temporary and is
                    // fine. `move self` is exempt: it consumes the receiver, so the caller observes
                    // nothing after the call. Mirrors the explicit-`mut`-parameter place check above.
                    if (mi->self_qual == OWN_MUT) {
                        Expr *root = callee->as.get.object;
                        while (root->kind == EXPR_GET || root->kind == EXPR_INDEX) {
                            root = root->kind == EXPR_GET ? root->as.get.object
                                                          : root->as.index.object;
                        }
                        if (root->kind == EXPR_IDENT) {
                            int slot = resolve_local(c, root->as.ident);
                            if (slot >= 0 && !c->locals[slot].is_var) {
                                type_error(c, e->line, e->col,
                                           "cannot call a 'mut self' method on an immutable "
                                           "binding; declare it 'var' (or take 'mut')");
                            }
                        }
                    }
                    // Monomorphization key for a method on a generic struct: the
                    // receiver's concrete type arguments (the method instance is
                    // selected by the struct's type, not by call type-args).
                    if (recv != NULL) {
                        e->as.call.mono_arg_count = recv->arg_count;
                        for (int k = 0; k < recv->arg_count && k < MAX_TYPE_ARGS;
                             k++) {
                            e->as.call.mono_args[k] = (int)recv->args[k];
                        }
                    }
                    if (argc != mi->param_count) {
                        type_error(c, e->line, e->col,
                                   "wrong number of arguments to method");
                    }
                }
                // A method on a NON-generic struct (recv == NULL) takes/returns all-scalar
                // structs MULTI-SLOT, exactly like a free function (value-types 3b.4d).
                // Generic-struct methods (recv != NULL) keep boxed params/return.
                int method_multislot =
                    (recv == NULL && mi != NULL &&
                     !method_is_interface_impl(c, base, callee->as.get.name));
                e->as.call.drop_mask = 0;
                for (int i = 0; i < argc; i++) {
                    SemType at = check_expr(c, e->as.call.args[i]);
                    if (mi != NULL && i < mi->param_count && at != TY_ERROR) {
                        SemType pt = recv != NULL ? subst(c, recv, mi->params[i])
                                                  : mi->params[i];
                        if (pt != TY_ERROR && at != pt) {
                            type_error(c, e->line, e->col,
                                       "argument type does not match the parameter");
                        }
                    }
                    int ms_i = (method_multislot && i < mi->param_count)
                                   ? param_multislot_sid(c, mi->params[i], mi->quals[i], 0)
                                   : -1;
                    // A refcounted argument is consumed IFF the PARAMETER owns it — a concrete
                    // refcounted method param the callee releases on return. A generic BORROW param
                    // (`key: K`) does NOT: the method is compiled once over the erased K (is_refcounted
                    // (K) is false ⇒ no release_at_exit), and a store inside takes its OWN reference
                    // (moves_local == 2). So gate on the UNSUBSTITUTED param type, not the substituted
                    // arg — else a method like Map<string,_>.set/get leaks one key reference per call
                    // (the long-running-UI leak; a render loop hammering it bleeds GB over a session).
                    // A refcounted temp then falls through to the caller-drop branch below.
                    int param_owns = (mi != NULL && i < mi->param_count)
                                         ? is_refcounted(c, mi->params[i])
                                         : is_refcounted(c, at);
                    if (param_owns) {
                        consume(c, e->as.call.args[i], at, e->line, e->col);
                    } else if (ms_i >= 0) {
                        // A multi-slot arg is pushed as field slots (copied/unboxed in
                        // place), never caller-dropped; let a construction / multi-slot call
                        // deliver its slots directly (no box round-trip).
                        Expr *a = e->as.call.args[i];
                        if (a->kind == EXPR_STRUCT_LIT && a->as.struct_lit.inline_sid >= 0) {
                            a->as.struct_lit.box_result = 0;
                        } else if (a->kind == EXPR_CALL && a->as.call.ret_struct_id >= 0 &&
                                   a->as.call.drop_first == 0 && a->as.call.drop_mask == 0) {
                            a->as.call.box_result = 0;
                        }
                    } else if (mi != NULL && i < mi->param_count && i < 31 &&
                               mi->quals[i] != OWN_MOVE &&
                               is_owning_temp(c, e->as.call.args[i], at)) {
                        // A fresh owned struct temp passed by borrow to a method: the
                        // caller drops it after the call (OFI-027), like a free call.
                        e->as.call.drop_mask |= (1 << i);
                    }
                }
                if (mi == NULL) {
                    return TY_ERROR;
                }
                // Per-arg multi-slot struct ids + a multi-slot return (3b.4d), so codegen
                // pushes/binds field slots instead of boxing — mirrors the free-call path.
                if (method_multislot) {
                    int any_ms = 0;
                    for (int i = 0; i < argc && i < mi->param_count; i++) {
                        if (param_multislot_sid(c, mi->params[i], mi->quals[i], 0) >= 0) {
                            any_ms = 1;
                            break;
                        }
                    }
                    if (any_ms && argc > 0) {
                        int *am = arena_alloc(c->arena, sizeof(int) * (size_t)argc);
                        for (int i = 0; i < argc; i++) {
                            am[i] = (i < mi->param_count)
                                        ? param_multislot_sid(c, mi->params[i],
                                                              mi->quals[i], 0)
                                        : -1;
                        }
                        e->as.call.arg_inline_struct = am;
                    }
                    e->as.call.ret_struct_id = ret_multislot_sid(c, mi->ret, 0);
                }
                // A `move self` method CONSUMES the receiver (it takes ownership): mark it moved, so it
                // can't be used after the call and its scope-exit auto-drop becomes a no-op (codegen nils
                // the slot). Without this a `move self` call left the receiver live → use-after-move +
                // double-drop — latent for value structs, CRITICAL for a `resource` whose drop runs user
                // cleanup (the OFI-145 / R5-HOLE-B fix; prerequisite for OFI-122 resource structs).
                if (mi->self_qual == OWN_MOVE) {
                    consume(c, callee->as.get.object, ot, e->line, e->col);
                }
                // A fresh owned struct temporary as the receiver, borrowed by the method
                // (self is not `move`), must be dropped after the call or it leaks
                // (OFI-027). The receiver is pushed first, so OP_DROP_UNDER reclaims it.
                e->as.call.drop_first = (mi->self_qual != OWN_MOVE &&
                                         is_owning_temp(c, callee->as.get.object, ot));
                return recv != NULL ? subst(c, recv, mi->ret) : mi->ret;
            }

            // Built-in (native) calls. Each native has a fixed signature.
            if (callee->kind == EXPR_IDENT &&
                native_id_for_name(callee->as.ident) >= 0) {
                int nid = native_id_for_name(callee->as.ident);
                e->as.call.drop_mask = 0;   // default (arena nodes aren't zeroed); set per-native below
                                            // for the string-taking builtins so codegen drops temp args
                if (nid == NATIVE_PRINT || nid == NATIVE_PRINTLN) {
                    // print(x) / println(x): one printable argument, returns unit.
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "print/println take exactly one argument");
                    }
                    e->as.call.drop_mask = 0;
                    for (int i = 0; i < argc; i++) {
                        SemType at = check_expr(c, e->as.call.args[i]);
                        if (i == 0 && at != TY_ERROR && !is_numeric_type(at) &&
                            at != TY_STRING) {
                            type_error(c, e->line, e->col,
                                       "print/println accept a number or a string");
                        }
                        if (i == 0) {
                            e->num_kind = int_kind(at);   // codegen routes u64 unsigned
                        }
                        // a fresh owning-temp string arg (`print(a + b)`) is caller-dropped after the
                        // native pops it (it adopts nothing), else it leaks one per call.
                        if (i < 31 && e->num_kind != 7 && is_owning_temp(c, e->as.call.args[i], at)) {
                            e->as.call.drop_mask |= (1 << i);
                        }
                    }
                    return TY_UNIT;
                }
                if (nid == NATIVE_READ_LINE) {
                    if (argc != 0) {
                        type_error(c, e->line, e->col,
                                   "read_line takes no arguments");
                    }
                    return TY_STRING;
                }
                if (nid == NATIVE_READ_FILE) {
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "read_file takes one argument (the file path)");
                    }
                    SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                           : TY_ERROR;
                    if (at != TY_ERROR && at != TY_STRING) {
                        type_error(c, e->line, e->col,
                                   "read_file's path must be a string");
                    }
                    e->as.call.drop_mask =
                        (argc >= 1 && is_owning_temp(c, e->as.call.args[0], at)) ? 1 : 0;
                    return TY_STRING;
                }
                if (nid == NATIVE_WRITE_FILE) {
                    if (argc != 2) {
                        type_error(c, e->line, e->col,
                                   "write_file takes two arguments (path, text)");
                    }
                    e->as.call.drop_mask = 0;
                    for (int i = 0; i < argc; i++) {
                        SemType at = check_expr(c, e->as.call.args[i]);
                        if (at != TY_ERROR && at != TY_STRING) {
                            type_error(c, e->line, e->col,
                                       "write_file's arguments must be strings");
                        }
                        if (i < 31 && is_owning_temp(c, e->as.call.args[i], at)) {
                            e->as.call.drop_mask |= (1 << i);
                        }
                    }
                    return TY_UNIT;
                }
                // Math: float -> float (one arg), pow (two floats), random (none).
                if (nid == NATIVE_SQRT || nid == NATIVE_ABS || nid == NATIVE_FLOOR ||
                    nid == NATIVE_CEIL || nid == NATIVE_ROUND) {
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "this math function takes one float argument");
                    }
                    SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                           : TY_ERROR;
                    if (at != TY_ERROR && at != TY_FLOAT) {
                        type_error(c, e->line, e->col,
                                   "this math function requires a float");
                    }
                    return TY_FLOAT;
                }
                if (nid == NATIVE_POW) {
                    if (argc != 2) {
                        type_error(c, e->line, e->col,
                                   "pow takes two floats (base, exponent)");
                    }
                    for (int i = 0; i < argc; i++) {
                        SemType at = check_expr(c, e->as.call.args[i]);
                        if (at != TY_ERROR && at != TY_FLOAT) {
                            type_error(c, e->line, e->col, "pow requires floats");
                        }
                    }
                    return TY_FLOAT;
                }
                if (nid == NATIVE_RANDOM) {
                    if (argc != 0) {
                        type_error(c, e->line, e->col,
                                   "random takes no arguments");
                    }
                    return TY_FLOAT;
                }
                // char_code(string)->int, from_char_code(int)->string,
                // parse_float(string)->float.
                if (nid == NATIVE_CHAR_CODE || nid == NATIVE_PARSE_FLOAT) {
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "this built-in takes one string argument");
                    }
                    SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                           : TY_ERROR;
                    if (at != TY_ERROR && at != TY_STRING) {
                        type_error(c, e->line, e->col,
                                   "this built-in requires a string");
                    }
                    return nid == NATIVE_CHAR_CODE ? TY_INT : TY_FLOAT;
                }
                if (nid == NATIVE_HASH) {
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "hash takes one string argument");
                    }
                    SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                           : TY_ERROR;
                    if (at != TY_ERROR && at != TY_STRING) {
                        type_error(c, e->line, e->col, "hash requires a string");
                    }
                    return TY_INT;
                }
                if (nid == NATIVE_CONCAT) {
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "concat takes one [string] argument");
                    }
                    SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                           : TY_ERROR;
                    if (at != TY_ERROR && at != intern_array(c, TY_STRING)) {
                        type_error(c, e->line, e->col,
                                   "concat requires a [string] (an array of strings)");
                    }
                    return TY_STRING;
                }
                if (nid == NATIVE_FROM_CHAR_CODE) {
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "from_char_code takes one int argument");
                    }
                    SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                           : TY_ERROR;
                    if (at != TY_ERROR && at != TY_INT) {
                        type_error(c, e->line, e->col,
                                   "from_char_code requires an int");
                    }
                    return TY_STRING;
                }
                if (nid == NATIVE_BYTE_SLICE) {
                    if (argc != 3) {
                        type_error(c, e->line, e->col,
                                   "byte_slice takes three arguments (string, start, end)");
                    }
                    SemType s0 = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                    if (s0 != TY_ERROR && s0 != TY_STRING) {
                        type_error(c, e->line, e->col,
                                   "byte_slice's first argument must be a string");
                    }
                    SemType s1 = argc >= 2 ? check_expr(c, e->as.call.args[1]) : TY_ERROR;
                    if (s1 != TY_ERROR && s1 != TY_INT) {
                        type_error(c, e->line, e->col, "byte_slice's start must be an int");
                    }
                    SemType s2 = argc >= 3 ? check_expr(c, e->as.call.args[2]) : TY_ERROR;
                    if (s2 != TY_ERROR && s2 != TY_INT) {
                        type_error(c, e->line, e->col, "byte_slice's end must be an int");
                    }
                    return TY_STRING;
                }
                if (nid == NATIVE_FROM_BYTES) {
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "from_bytes takes one argument (a [u8])");
                    }
                    SemType a0 = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                    // Lenient about the element width (an int literal adapts to u8); only a concretely
                    // non-array argument is an error, mirroring byte_slice's argument checks.
                    if (a0 != TY_ERROR && !is_array_type(a0)) {
                        type_error(c, e->line, e->col,
                                   "from_bytes requires a [u8] (an array of bytes)");
                    }
                    return TY_STRING;
                }
                if (nid == NATIVE_ARGS) {
                    if (argc != 0) {
                        type_error(c, e->line, e->col, "args takes no arguments");
                    }
                    return intern_array(c, TY_STRING);   // [string]
                }
                if (nid == NATIVE_ENV) {
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "env takes one argument (the variable name)");
                    }
                    SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                           : TY_ERROR;
                    if (at != TY_ERROR && at != TY_STRING) {
                        type_error(c, e->line, e->col, "env's name must be a string");
                    }
                    return TY_STRING;
                }
                if (nid == NATIVE_EXIT) {
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "exit takes one argument (the exit code)");
                    }
                    SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                           : TY_ERROR;
                    if (at != TY_ERROR && at != TY_INT) {
                        type_error(c, e->line, e->col, "exit's code must be an int");
                    }
                    return TY_UNIT;
                }
                // Graphics primitives (MANIFESTO §5g): each has a fixed signature. These are
                // validated in EVERY build (the signatures are raylib-free type data), so the LSP
                // gives correct diagnostics on graphics programs even from the dependency-free build;
                // only running them needs `make graphics`. `want` lists the expected argument types.
                {
                    static const SemType sig_open[] = { TY_INT, TY_INT, TY_STRING };
                    static const SemType sig_rect[] = { TY_INT, TY_INT, TY_INT, TY_INT, TY_INT };
                    static const SemType sig_text[] = { TY_STRING, TY_INT, TY_INT, TY_INT, TY_INT };
                    static const SemType sig_measure[] = { TY_STRING, TY_INT };
                    static const SemType sig_int1[] = { TY_INT };
                    static const SemType sig_bool1[] = { TY_BOOL };
                    static const SemType sig_str1[] = { TY_STRING };
                    static const SemType sig_str2[] = { TY_STRING, TY_STRING };
                    static const SemType sig_int6[] = { TY_INT, TY_INT, TY_INT, TY_INT, TY_INT, TY_INT };
                    static const SemType sig_int7[] = { TY_INT, TY_INT, TY_INT, TY_INT, TY_INT, TY_INT, TY_INT };
                    static const SemType sig_int8[] = { TY_INT, TY_INT, TY_INT, TY_INT, TY_INT, TY_INT, TY_INT, TY_INT };
                    int            g_argc = -1;
                    const SemType *want   = NULL;
                    SemType        ret    = TY_UNIT;
                    if      (nid == NATIVE_GFX_WINDOW_OPEN)  { g_argc = 3; want = sig_open; }
                    else if (nid == NATIVE_GFX_WINDOW_CLOSE) { g_argc = 0; }
                    else if (nid == NATIVE_GFX_SHOULD_CLOSE) { g_argc = 0; ret = TY_BOOL; }
                    else if (nid == NATIVE_GFX_FRAME_BEGIN)  { g_argc = 1; want = sig_int1; }
                    else if (nid == NATIVE_GFX_FRAME_END)    { g_argc = 0; }
                    else if (nid == NATIVE_GFX_DRAW_RECT)    { g_argc = 5; want = sig_rect; }
                    else if (nid == NATIVE_GFX_DRAW_TEXT)    { g_argc = 5; want = sig_text; }
                    else if (nid == NATIVE_GFX_KEY_DOWN)     { g_argc = 1; want = sig_int1; ret = TY_BOOL; }
                    else if (nid == NATIVE_GFX_MOUSE_X)      { g_argc = 0; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_MOUSE_Y)      { g_argc = 0; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_MOUSE_DOWN)   { g_argc = 0; ret = TY_BOOL; }
                    else if (nid == NATIVE_GFX_MOUSE_RDOWN)  { g_argc = 0; ret = TY_BOOL; }
                    else if (nid == NATIVE_GFX_MEASURE_TEXT) { g_argc = 2; want = sig_measure; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_TEXT_LINE_H)  { g_argc = 1; want = sig_int1; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_CHAR_PRESSED) { g_argc = 0; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_KEY_PRESSED)  { g_argc = 1; want = sig_int1; ret = TY_BOOL; }
                    else if (nid == NATIVE_GFX_KEY_REPEAT)   { g_argc = 1; want = sig_int1; ret = TY_BOOL; }
                    else if (nid == NATIVE_GFX_LOAD_FONT)    { g_argc = 1; want = sig_str1; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_SET_FONT)     { g_argc = 1; want = sig_int1; }
                    else if (nid == NATIVE_GFX_SET_CURSOR)   { g_argc = 1; want = sig_int1; }
                    else if (nid == NATIVE_GFX_CLIPBOARD_SET){ g_argc = 1; want = sig_str1; }
                    else if (nid == NATIVE_GFX_CLIPBOARD_GET){ g_argc = 0; ret = TY_STRING; }
                    else if (nid == NATIVE_GFX_DROPPED_FILES){ g_argc = 0; ret = TY_STRING; }
                    else if (nid == NATIVE_GFX_SCREEN_W)     { g_argc = 0; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_SCREEN_H)     { g_argc = 0; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_SET_LAYER)    { g_argc = 1; want = sig_int1; }
                    else if (nid == NATIVE_GFX_CLIP_PUSH)    { g_argc = 4; want = sig_rect; }
                    else if (nid == NATIVE_GFX_CLIP_POP)     { g_argc = 0; }
                    else if (nid == NATIVE_GFX_TAPE_OPEN)    { g_argc = 1; want = sig_str1; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_TAPE_CLOSE)   { g_argc = 0; }
                    else if (nid == NATIVE_GFX_TAPE_MARK)    { g_argc = 2; want = sig_str2; }
                    else if (nid == NATIVE_GFX_FILL_ROUND)   { g_argc = 7; want = sig_int7; }
                    else if (nid == NATIVE_GFX_STROKE_ROUND) { g_argc = 8; want = sig_int8; }
                    else if (nid == NATIVE_GFX_FILL_GRAD)    { g_argc = 8; want = sig_int8; }
                    else if (nid == NATIVE_GFX_SHADOW)       { g_argc = 6; want = sig_int6; }
                    else if (nid == NATIVE_GFX_FILL_CIRCLE)  { g_argc = 5; want = sig_rect; }
                    else if (nid == NATIVE_GFX_MOUSE_WHEEL)  { g_argc = 0; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_FRAME_CAPTURE){ g_argc = 1; want = sig_str1; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_SET_EVENT_WAIT){ g_argc = 1; want = sig_bool1; }
                    else if (nid == NATIVE_GFX_HAD_INPUT)    { g_argc = 0; ret = TY_BOOL; }
                    else if (nid == NATIVE_GFX_MEASURE_MISSES){ g_argc = 0; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_FRAME_STEPS)  { g_argc = 0; ret = TY_INT; }
                    else if (nid == NATIVE_GFX_SET_ALPHA)    { g_argc = 1; want = sig_int1; }
                    if (g_argc >= 0) {
                        if (argc != g_argc) {
                            type_error(c, e->line, e->col,
                                       "wrong number of arguments to a graphics primitive");
                        }
                        // A fresh owning-temp object arg (a string `draw_text(a + b, …)` /
                        // `measure_text(arr[i], …)`) must be dropped by the caller — the native pops
                        // its args without releasing them — or it leaks one per call (per widget, per
                        // frame: the long-running-UI residual). Mark them; codegen drops them after the
                        // call. Scalar args (most gfx primitives) are never owning temps, so mask == 0.
                        e->as.call.drop_mask = 0;
                        for (int i = 0; i < argc; i++) {
                            SemType at = check_expr(c, e->as.call.args[i]);
                            if (want != NULL && i < g_argc && at != TY_ERROR && at != want[i]) {
                                type_error(c, e->line, e->col,
                                           "wrong argument type to a graphics primitive");
                            }
                            if (i < 31 && is_owning_temp(c, e->as.call.args[i], at)) {
                                e->as.call.drop_mask |= (1 << i);
                            }
                        }
                        return ret;
                    }
                }
            }

            // Built-in `len(array)` — an intrinsic returning the element count.
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "len") == 0) {
                if (argc != 1) {
                    type_error(c, e->line, e->col, "len takes exactly one argument");
                }
                for (int i = 0; i < argc; i++) {
                    SemType at = check_expr(c, e->as.call.args[i]);
                    if (i == 0 && at != TY_ERROR && !is_array_type(at)) {
                        type_error(c, e->line, e->col, "len requires an array");
                    }
                }
                return TY_INT;
            }

            // Built-in numeric conversions `to_float(int)` / `to_int(float)`.
            // Ember performs no implicit int/float coercion, so a program crossing
            // the two converts explicitly. `to_int` truncates toward zero.
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "to_float") == 0) {
                if (argc != 1) {
                    type_error(c, e->line, e->col, "to_float takes exactly one argument");
                }
                SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                if (at != TY_ERROR && at != TY_INT) {
                    type_error(c, e->line, e->col, "to_float requires an int");
                }
                return TY_FLOAT;
            }
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "to_int") == 0) {
                if (argc != 1) {
                    type_error(c, e->line, e->col, "to_int takes exactly one argument");
                }
                SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                if (at != TY_ERROR && !is_float_type(at)) {
                    type_error(c, e->line, e->col, "to_int requires a float");
                }
                return TY_INT;
            }

            // Built-in WRAPPING arithmetic (OFI-041): `wrapping_add`/`wrapping_sub`/
            // `wrapping_mul(a, b)` compute modulo 2^width instead of trapping on
            // overflow, for hashes/PRNGs/checksums. Integer-only; both operands share
            // one width and the result keeps it. Trapping `+ - *` stays the default —
            // wrapping is named explicitly so it is never reached for by accident (§5b).
            if (callee->kind == EXPR_IDENT &&
                (strcmp(callee->as.ident, "wrapping_add") == 0 ||
                 strcmp(callee->as.ident, "wrapping_sub") == 0 ||
                 strcmp(callee->as.ident, "wrapping_mul") == 0)) {
                SemType want = c->expected;
                if (argc != 2) {
                    type_error(c, e->line, e->col,
                               "a wrapping operation takes exactly two arguments");
                }
                c->expected = want;
                SemType a0 = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                if (a0 != TY_ERROR && !is_integer_type(a0)) {
                    type_error(c, e->line, e->col,
                               "wrapping arithmetic requires integer operands");
                    a0 = TY_INT;
                }
                if (argc >= 2) {
                    c->expected = a0;   // a bare-literal second operand adopts the first's width
                    SemType a1 = check_expr(c, e->as.call.args[1]);
                    if (a0 != TY_ERROR && a1 != TY_ERROR && a0 != a1) {
                        type_error(c, e->line, e->col,
                                   "wrapping arithmetic operands must be the same integer type");
                    }
                }
                SemType rt = (a0 == TY_ERROR) ? TY_INT : a0;
                e->num_kind = int_kind(rt);
                return rt;
            }

            // Numeric width conversion written as a type-name call: `u8(x)`,
            // `i32(x)`, `int(x)`. The source must be an integer; the value is
            // range-checked to the target width at run time (a trap if it does
            // not fit). int<->float still uses to_int/to_float.
            if (callee->kind == EXPR_IDENT) {
                SemType target = numeric_typename(callee->as.ident);
                if (target != TY_ERROR) {
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "a width conversion takes exactly one argument");
                    }
                    SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0])
                                           : TY_ERROR;
                    int want_float = is_float_type(target);
                    SemType at_repr = is_newtype(at) ? newtype_base(c, at) : at;   // OFI-149: unwrap a newtype
                    if (at != TY_ERROR &&
                        ((want_float && !is_float_type(at_repr)) ||
                         (!want_float && !is_integer_type(at_repr)))) {
                        type_error(c, e->line, e->col,
                                   want_float
                                       ? "a float width conversion's argument must "
                                         "be a float (use to_float for int -> float)"
                                       : "an integer width conversion's argument must "
                                         "be an integer (use to_int/to_float to cross "
                                         "int and float)");
                    }
                    e->num_kind = int_kind(target);   // codegen: target kind
                    return target;
                }
            }

            // Newtype construction: `UserId(x)` wraps a base value in a distinct nominal type
            // (OFI-149). The argument must match the newtype's base; the result IS the base value
            // at runtime (codegen passthrough), so construction is zero-cost.
            if (callee->kind == EXPR_IDENT) {
                int ntid = resolve_newtype(c, callee->as.ident);
                if (ntid >= 0) {
                    SemType base = c->newtypes[ntid].base;
                    if (argc != 1) {
                        type_error(c, e->line, e->col,
                                   "a newtype constructor takes exactly one argument");
                    }
                    SemType saved_exp = c->expected;
                    c->expected = base;   // a literal arg adopts the base width (Small(200), Big(...))
                    SemType at = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                    c->expected = saved_exp;
                    if (at != TY_ERROR && !assignable(c, e->as.call.args[0], at, base)) {
                        type_error(c, e->line, e->col,
                                   "a newtype constructor's argument must have the newtype's base type");
                    }
                    // OFI-149: construction is codegen-passthrough (the value IS the base value).
                    // For a refcounted base (a string newtype) the argument is therefore aliased
                    // straight into the new owner, so it must be consumed/retained exactly as a
                    // plain copy would be — else an existing-owner source (`Email(s)`) underflows
                    // its refcount and double-frees. A fresh temporary arg (literal/call) is left
                    // alone by consume(), so no double-retain.
                    if (at != TY_ERROR) {
                        consume(c, e->as.call.args[0], base, e->line, e->col);
                    }
                    e->as.call.newtype_ctor = 1;
                    // OFI-150: a refined newtype (`type Percent = int where P`) checks P at
                    // construction. Type-check the predicate ONCE (lazily, in full body-checking
                    // context so it may call predicate fns), binding `self` to the base; codegen
                    // then emits the check per construction site (debug-checked, release-elided).
                    {
                        NewtypeInfo *ni = &c->newtypes[ntid];
                        if (ni->refinement != NULL && ni->refinement_in_progress) {
                            // OFI-150: this type is being CONSTRUCTED inside its OWN `where`
                            // predicate — checking it would require checking it, a
                            // non-terminating cycle (and an infinite codegen recursion / crash
                            // if left to emit). Reject it and leave this call's refinement NULL
                            // so codegen emits no check.
                            type_error(c, e->line, e->col,
                                       "a newtype's 'where' predicate cannot construct its own type "
                                       "(the refinement would never terminate)");
                            return (SemType)(NEWTYPE_BASE + ntid);
                        }
                        if (ni->refinement != NULL) {
                            if (argc >= 1 && !is_pure_expr(c, e->as.call.args[0])) {
                                type_error(c, e->line, e->col,
                                           "a refined newtype's constructor argument must be a simple "
                                           "expression (a literal, variable, field, conversion, or "
                                           "arithmetic) so the predicate checks the value that is "
                                           "stored — bind a computed value to a `let` first");
                            }
                            if (!ni->refinement_checked) {
                                ni->refinement_checked = 1;
                                ni->refinement_in_progress = 1;
                                // OFI-150: the predicate is over `self` ONLY. Check it in an
                                // ISOLATED local scope — HIDE the ambient locals by zeroing
                                // local_count for the duration (notably a method receiver also
                                // named `self`, which would otherwise make declare_local report a
                                // bogus "redeclaration" and bind the predicate's `self` to the
                                // receiver). This makes the one-time check independent of WHERE
                                // the type is first constructed. The ambient locals are restored
                                // verbatim afterward (they were never modified — local_count is
                                // an index, the entries above it survive).
                                int saved = c->local_count;
                                // Preserve the entry declare_local will overwrite at index 0
                                // (e.g. the ambient receiver `self`), then restore it verbatim.
                                Local saved_slot0 = (saved > 0) ? c->locals[0] : (Local){0};
                                c->local_count = 0;
                                declare_local(c, e->line, e->col, "self", 0, base, 0);
                                SemType pt = check_expr(c, ni->refinement);
                                c->local_count = saved;
                                if (saved > 0) {
                                    c->locals[0] = saved_slot0;
                                }
                                ni->refinement_in_progress = 0;
                                if (pt != TY_BOOL && pt != TY_ERROR) {
                                    type_error(c, e->line, e->col,
                                               "a newtype's 'where' predicate must be a bool expression over 'self'");
                                }
                            }
                            e->as.call.refinement = ni->refinement;
                        }
                    }
                    return (SemType)(NEWTYPE_BASE + ntid);
                }
            }

            // Built-in `clock()` — a monotonic clock in seconds (a float), for
            // timing. Takes no arguments; successive calls never decrease.
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "clock") == 0) {
                if (argc != 0) {
                    type_error(c, e->line, e->col, "clock takes no arguments");
                    for (int i = 0; i < argc; i++) {
                        check_expr(c, e->as.call.args[i]);
                    }
                }
                return TY_FLOAT;
            }

            // Built-in `channel(N)` — a buffered channel; its element type comes
            // from the expected type (`let c: Channel<T> = channel(N)`).
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "channel") == 0) {
                if (argc != 1) {
                    type_error(c, e->line, e->col, "channel takes one argument (the buffer size)");
                }
                for (int i = 0; i < argc; i++) {
                    SemType at = check_expr(c, e->as.call.args[i]);
                    if (i == 0 && at != TY_ERROR && at != TY_INT) {
                        type_error(c, e->line, e->col, "channel's buffer size must be an int");
                    }
                }
                if (is_channel_type(expected)) {
                    return expected;
                }
                type_error(c, e->line, e->col,
                           "cannot infer the channel's element type; annotate it "
                           "(e.g. let c: Channel<int> = channel(N))");
                return TY_ERROR;
            }

            // Built-in `send(channel, value)` — value is moved into the channel.
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "send") == 0) {
                if (argc != 2) {
                    type_error(c, e->line, e->col, "send takes a channel and a value");
                }
                SemType ct = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                SemType vt = argc >= 2 ? check_expr(c, e->as.call.args[1]) : TY_ERROR;
                if (ct != TY_ERROR && !is_channel_type(ct)) {
                    type_error(c, e->line, e->col, "send's first argument must be a channel");
                } else if (argc >= 2 && ct != TY_ERROR && vt != TY_ERROR &&
                           vt != channel_elem(c, ct)) {
                    type_error(c, e->line, e->col,
                               "sent value's type does not match the channel");
                }
                if (argc >= 2) {
                    consume(c, e->as.call.args[1], vt, e->line, e->col);   // moved in
                }
                return TY_UNIT;
            }

            // Built-in `recv(channel)` — yields the next value (blocking).
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "recv") == 0) {
                if (argc != 1) {
                    type_error(c, e->line, e->col, "recv takes one argument (a channel)");
                }
                SemType ct = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                if (ct != TY_ERROR && !is_channel_type(ct)) {
                    type_error(c, e->line, e->col, "recv's argument must be a channel");
                    return TY_ERROR;
                }
                // recv yields Option<elem>: Some(v) while values flow, None once
                // the channel is closed and drained. Absence is a value here, not
                // a control-flow signal — so the worker loop is an ordinary match.
                return ct == TY_ERROR ? TY_ERROR
                                      : option_of(c, channel_elem(c, ct),
                                                  e->line, e->col);
            }
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "try_recv") == 0) {
                if (argc != 1) {
                    type_error(c, e->line, e->col, "try_recv takes one argument (a channel)");
                }
                SemType ct = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                if (ct != TY_ERROR && !is_channel_type(ct)) {
                    type_error(c, e->line, e->col, "try_recv's argument must be a channel");
                    return TY_ERROR;
                }
                // try_recv is the NON-BLOCKING poll: Some(v) if a value is queued right now, None
                // if the channel is currently empty (open OR closed). It never blocks/yields, so an
                // event loop (a GUI frame, a server tick) can check a channel without stalling.
                return ct == TY_ERROR ? TY_ERROR
                                      : option_of(c, channel_elem(c, ct),
                                                  e->line, e->col);
            }
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "close") == 0) {
                if (argc != 1) {
                    type_error(c, e->line, e->col, "close takes one argument (a channel)");
                }
                SemType ct = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                if (ct != TY_ERROR && !is_channel_type(ct)) {
                    type_error(c, e->line, e->col, "close's argument must be a channel");
                    return TY_ERROR;
                }
                return TY_UNIT;   // close runs for effect; it has no value
            }

            // `assert(cond [, "message"])` — an in-language assertion (verification loop, §5j).
            // It lowers to the contract-check machinery, so a failure is a structured tape event
            // (contract_violation), not a bare crash, and is release-elided like a contract. The
            // optional message must be a string LITERAL (it becomes a compile-time constant).
            if (callee->kind == EXPR_IDENT && strcmp(callee->as.ident, "assert") == 0) {
                if (argc < 1 || argc > 2) {
                    type_error(c, e->line, e->col,
                               "assert takes a bool condition and an optional message literal");
                }
                SemType ct = argc >= 1 ? check_expr(c, e->as.call.args[0]) : TY_ERROR;
                if (ct != TY_ERROR && ct != TY_BOOL) {
                    type_error(c, e->line, e->col, "assert's condition must be a bool");
                }
                if (argc >= 2) {
                    SemType mt = check_expr(c, e->as.call.args[1]);
                    if (mt != TY_ERROR && e->as.call.args[1]->kind != EXPR_STRING) {
                        type_error(c, e->line, e->col,
                                   "assert's message must be a string literal");
                    }
                }
                return TY_UNIT;
            }

            // Data-carrying variant construction: `Circle(2.0)`, `Some(5)`.
            if (callee->kind == EXPR_IDENT) {
                VariantInfo *v = resolve_variant(c, callee->as.ident);
                if (v != NULL) {
                    sem_record_variant(c, callee->line, callee->col, v);   // LSP: hover on `Some(…)`
                    e->variant_enum_id = v->enum_id;          // codegen builds THIS variant, not a by-name lookup
                    e->variant_tag     = v->variant_index;
                    // check_expr already cleared c->expected, so the arguments are
                    // checked without the construction's expected type.
                    // Zero-init: as above — at[0..n-1] are the only entries read; gcc -O2's
                    // -Wmaybe-uninitialized can't see that and false-positives without the init.
                    SemType at[MAX_PARAMS] = {0};
                    for (int i = 0; i < argc && i < MAX_PARAMS; i++) {
                        at[i] = check_expr(c, e->as.call.args[i]);
                    }
                    for (int i = MAX_PARAMS; i < argc; i++) {
                        check_expr(c, e->as.call.args[i]);   // report errors in extras
                    }
                    int n = argc < MAX_PARAMS ? argc : MAX_PARAMS;
                    SemType vt = infer_variant_type(c, e->line, e->col, v, at, n,
                                                    expected);
                    // The variant takes ownership of each payload argument.
                    for (int i = 0; i < argc; i++) {
                        consume(c, e->as.call.args[i],
                                i < n ? at[i] : TY_ERROR, e->line, e->col);
                    }
                    return vt;
                }
            }

            if (callee->kind != EXPR_IDENT) {
                type_error(c, e->line, e->col,
                           "can only call a named function or method");
                for (int i = 0; i < argc; i++) {
                    check_expr(c, e->as.call.args[i]);
                }
                return TY_ERROR;
            }
            int idx = resolve_signature(c, callee->as.ident);
            if (idx < 0) {
                type_error(c, e->line, e->col, "call to an undefined function");
                for (size_t i = 0; i < e->as.call.arg_count; i++) {
                    check_expr(c, e->as.call.args[i]);
                }
                return TY_ERROR;
            }
            FnSig *sig = &c->fns[idx];
            e->as.call.resolved_fn = sig->fn_index;   // codegen targets this directly
            e->as.call.cextern_index = sig->cextern_index;  // >=0 ⇒ a foreign C call → OP_CALL_C
            e->as.call.extern_direct = sig->direct_extern;  // OFI-167: native direct-extern → direct C call
            e->as.call.extern_cname  = sig->direct_extern ? sig->name : NULL;
            // LSP: hover/go-to-def on the called function's name.
            sem_record_fn(c, callee->line, callee->col, callee->as.ident, sig, NULL, NULL);
            SemType rt = check_fn_call(c, e, sig, expected);
            if (sig->cextern_index >= 0) {
                // An extern call delivers a BOXED result (the VM reassembles a struct return from
                // the wrapper's leaves), so it does NOT use the multi-slot-return convention —
                // clear ret_struct_id and record the return struct id separately (3b.6).
                e->as.call.cextern_ret_sid = nested_inline_sid(c, rt);
                e->as.call.ret_struct_id   = -1;
            }
            return rt;
        }

        case EXPR_GET: {
            // Qualified zero-field enum-variant construction: `Option.None`. When the
            // object names an enum in scope (not a local), `.name` is a variant, not a
            // field — desugar to the bare variant (globally unique) and construct it.
            if (e->as.get.object->kind == EXPR_IDENT &&
                resolve_local(c, e->as.get.object->as.ident) < 0) {
                int geid = resolve_enum(c, e->as.get.object->as.ident);
                if (geid >= 0) {
                    VariantInfo *gv = enum_variant(c, geid, e->as.get.name);
                    if (gv == NULL) {
                        type_error(c, e->line, e->col, "no such variant on this enum");
                        return TY_ERROR;
                    }
                    if (gv->field_count != 0) {
                        type_error(c, e->line, e->col,
                                   "this variant carries fields — call it with arguments");
                        return TY_ERROR;
                    }
                    // LSP: hover on the variant name in `Option.None` (record at the `.name`
                    // position before the node is rewritten to a bare ident below).
                    sem_record_variant(c, e->as.get.name_line, e->as.get.name_col, gv);
                    const char *vname = e->as.get.name;
                    e->kind = EXPR_IDENT;
                    e->as.ident = vname;
                    return infer_variant_type(c, e->line, e->col, gv, NULL, 0, expected);
                }
                // Qualified constant `mod.NAME` (OFI-023): if the object names an
                // import alias and `.name` is an exported constant, substitute it.
                int qreason = 0;
                int qgi = resolve_qualified_const(c, e->as.get.object->as.ident,
                                                  e->as.get.name, &qreason);
                if (qgi >= 0) {
                    // LSP: cross-module hover/go-to-def on `draw.RED` (its value + owning module
                    // + def site) and the alias itself.
                    sem_record_const(c, e->as.get.name_line, e->as.get.name_col, e->as.get.name,
                                     qgi, e->as.get.object->as.ident,
                                     c->modules->modules[c->globals[qgi].module].path);
                    sem_record_module(c, e->as.get.object, c->globals[qgi].module);
                    return substitute_const(c, e, qgi);
                }
                if (qreason == 2) {
                    type_error(c, e->line, e->col,
                               "that constant is private to its module");
                    return TY_ERROR;
                }
            }
            SemType ot = check_expr(c, e->as.get.object);
            int base;
            const GenericInst *inst = NULL;   // non-NULL ⇒ substitute field types
            if (is_struct_type(ot)) {
                base = ot;
            } else if (is_generic_inst(ot)) {
                inst = &c->ginsts[ot - GENERIC_BASE];
                base = inst->base;
            } else {
                if (ot != TY_ERROR) {
                    type_error(c, e->line, e->col,
                               "field access requires a struct value");
                }
                return TY_ERROR;
            }
            StructInfo *si = &c->structs[base];
            for (int i = 0; i < si->field_count; i++) {
                if (strcmp(si->fields[i].name, e->as.get.name) == 0) {
                    e->as.get.field_index = i;   // annotate for codegen
                    // If the object is a fresh owned struct temporary (a call or
                    // construction result, not a borrowed place), reading its field
                    // must drop the receiver afterward, or it leaks (OFI-027).
                    e->as.get.drop_object = is_owning_temp(c, e->as.get.object, ot);
                    SemType ft = si->fields[i].type;
                    SemType rt = inst != NULL ? subst(c, inst, ft) : ft;
                    // A nested struct field stored INLINE: reading it materialises a value
                    // COPY (value-types 3b.5), so a nested assignment must write back (codegen).
                    // The bool drives VM write-back; the sid lets the native backend unbox the
                    // materialised copy into an em_s (OFI-054).
                    e->as.get.inline_field = nested_inline_sid(c, rt) >= 0;
                    e->as.get.inline_struct_id = nested_inline_sid(c, rt);
                    // Offer go-to-def only when the struct is declared in the same file as the
                    // access (the LSP reports the def in the current document); a field of an
                    // imported struct still gets hover, but no — possibly wrong-file — jump.
                    int same_file = (si->module == c->current_module);
                    // Field byte layout (the clangd-style hover extra): offset is the packed
                    // sum of the preceding fields' widths, size is this field's width. Exact
                    // for a non-generic struct; an approximation for a generic instance (the
                    // preceding fields use their unsubstituted widths) — a hover hint, not data.
                    int foff = 0;
                    for (int f = 0; f < i; f++) {
                        foff += field_storage_size(c, si->fields[f].type);
                    }
                    sem_record_field(c, e, rt,    // LSP: hover + go-to-def on `.field`
                                     same_file ? si->fields[i].def_line : 0,
                                     same_file ? si->fields[i].def_col  : 0,
                                     si->name, foff, field_storage_size(c, rt));
                    return rt;
                }
            }
            type_error(c, e->line, e->col, "no such field on this struct");
            return TY_ERROR;
        }

        case EXPR_STRUCT_LIT: {
            SemType st = annotation_type(c, e->as.struct_lit.type);
            int base;
            const GenericInst *inst = NULL;
            if (is_struct_type(st)) {
                base = st;
            } else if (is_generic_inst(st)) {
                inst = &c->ginsts[st - GENERIC_BASE];
                base = inst->base;
            } else {
                type_error(c, e->line, e->col, "unknown struct type in construction");
                for (size_t i = 0; i < e->as.struct_lit.field_count; i++) {
                    check_expr(c, e->as.struct_lit.fields[i].value);
                }
                return TY_ERROR;
            }
            StructInfo *si = &c->structs[base];
            // A concrete generic struct (Box<int>) is constructed as its own
            // monomorphized type id (its packed layout); otherwise use the base.
            e->as.struct_lit.resolved_struct =
                (inst != NULL && inst_is_concrete(inst)) ? struct_instance_id(c, st)
                                                         : base;
            // A non-generic all-scalar struct may be constructed MULTI-SLOT — its field
            // values stay on the stack, no box (value-types 3b.4c). A consumer that takes
            // the slots directly clears box_result below; otherwise codegen boxes as before.
            // A bounded generic struct carries boxed witness fields, so it is never multi-slot.
            e->as.struct_lit.inline_sid =
                si->witness_count > 0 ? -1 : struct_all_scalar_id(c, st);
            // Instance-storage: build the concrete key type's Hash/Eq witnesses, in
            // (param, bound) field order, and verify each type argument satisfies its
            // bound here (the construction site, where the type arguments are concrete).
            if (si->witness_count > 0) {
                Witness *ws = malloc(sizeof(Witness) * (size_t)si->witness_count);
                if (ws == NULL) {
                    fprintf(stderr, "emberc: out of memory building struct witnesses\n");
                    exit(70);
                }
                int wi = 0;
                for (int g = 0; g < si->generic_count; g++) {
                    SemType arg = (inst != NULL && g < inst->arg_count)
                                      ? inst->args[g] : TY_ERROR;
                    // A `Copy`-bounded param (e.g. a Map key) must be a copyable type:
                    // scalars/strings/enums copy freely, but a struct/array is a unique
                    // move type — storing/rehashing it would double-free (OFI-009). This
                    // turns an unsound struct key into a clear compile error.
                    if (si->is_copy[g] && arg != TY_ERROR && is_move_type(c, arg)) {
                        type_error(c, e->line, e->col,
                                   "a type argument is not Copy — a Map key (or other "
                                   "Copy-bounded parameter) must be a scalar, string, or "
                                   "enum, not a struct or array");
                    }
                    for (int b = 0; b < si->bound_count[g]; b++) {
                        int iid = si->bounds[g][b];
                        ws[wi].fns   = NULL;
                        ws[wi].count = 0;
                        if (arg == TY_ERROR || !type_satisfies_bound(c, arg, iid)) {
                            type_error(c, e->line, e->col,
                                       "a type argument does not satisfy the struct's "
                                       "generic bound (it must implement Hash / Eq)");
                        } else {
                            ws[wi].fns = build_witness(c, arg, iid, &ws[wi].count);
                        }
                        wi++;
                    }
                }
                e->as.struct_lit.witnesses     = ws;
                e->as.struct_lit.witness_total = si->witness_count;
            }
            // Every provided field must name a declared field, with a matching
            // type (the declared type substituted for this instantiation).
            for (size_t i = 0; i < e->as.struct_lit.field_count; i++) {
                StructLitField *lit = &e->as.struct_lit.fields[i];
                int found = -1;
                for (int j = 0; j < si->field_count; j++) {
                    if (strcmp(si->fields[j].name, lit->name) == 0) {
                        found = j;
                        break;
                    }
                }
                // The declared field type is the expected type for its value, so a
                // value that infers outside-in (an empty `[]`, a `None`) resolves
                // from the field. Find the field before checking the value.
                SemType ft = TY_ERROR;
                if (found >= 0) {
                    ft = si->fields[found].type;
                    if (inst != NULL) {
                        ft = subst(c, inst, ft);
                    }
                }
                SemType saved = c->expected;
                c->expected = ft;
                SemType vt = check_expr(c, lit->value);
                c->expected = saved;
                if (found < 0) {
                    type_error(c, e->line, e->col, "no such field on this struct");
                } else if (vt != TY_ERROR && ft != TY_ERROR &&
                           !assignable(c, lit->value, vt, ft)) {
                    type_error(c, e->line, e->col,
                               "field value type does not match the declared field");
                }
                consume(c, lit->value, vt, e->line, e->col);  // the field takes ownership
            }
            // Every declared field must be provided exactly once.
            for (int j = 0; j < si->field_count; j++) {
                int seen = 0;
                for (size_t i = 0; i < e->as.struct_lit.field_count; i++) {
                    if (strcmp(e->as.struct_lit.fields[i].name, si->fields[j].name) == 0) {
                        seen++;
                    }
                }
                if (seen != 1) {
                    type_error(c, e->line, e->col,
                               "every struct field must be set exactly once");
                }
            }
            return st;
        }

        case EXPR_FLOAT:
            // A float literal becomes f32 only when the context expects it
            // (`let x: f32 = 1.5`); otherwise it is the default f64.
            return expected == TY_F32 ? TY_F32 : TY_FLOAT;

        case EXPR_STRING: {
            // A string literal is a sequence of literal runs and interpolation
            // holes; each hole's value must be printable (int/float/string).
            for (size_t i = 0; i < e->as.str.part_count; i++) {
                StrPart *part = &e->as.str.parts[i];
                if (part->expr == NULL) {
                    continue;
                }
                SemType pt = check_expr(c, part->expr);
                // OFI-149: a newtype renders as its base (`"{userId}"` shows the int, `"{email}"`
                // the string), so the directly-printable test + render kind use the base type.
                SemType prt = is_newtype(pt) ? newtype_base(c, pt) : pt;
                if (prt != TY_ERROR && prt != TY_BOOL && !is_numeric_type(prt) && prt != TY_STRING) {
                    // A value type that provides Show (`fn show(self) -> string`) renders by
                    // desugaring the hole to `value.show()` (OFI-139): the wrapped call is an
                    // ordinary string-typed hole from here on, so codegen + ownership on BOTH
                    // backends are unchanged. Otherwise the value is not directly printable.
                    int dyn_slot, fn_index;
                    if (show_renders(c, prt, &dyn_slot, &fn_index)) {
                        part->expr = synth_show_call(c, part->expr, prt, dyn_slot, fn_index);
                        prt = TY_STRING;
                        pt  = TY_STRING;
                    } else {
                        type_error(c, e->line, e->col,
                                   "this value can't be interpolated directly: give its type a "
                                   "'fn show(self) -> string' method (the Show interface), or "
                                   "interpolate a field or method that yields a number, a string, "
                                   "or a bool");
                    }
                }
                // u64 holes render unsigned; a bool renders true/false (kind 10, set only here so
                // int_kind stays purely numeric for arithmetic/compare num_kind). A desugared Show
                // hole is now TY_STRING → kind 0 (the string-identity render path).
                part->render_kind = (prt == TY_BOOL) ? 10 : int_kind(prt);
                // A fresh OWNED-temp string hole (a call/concat result, incl. a desugared `.show()`)
                // already owns a reference the fold's OP_CONCAT consumes — codegen must NOT also
                // emit the retaining OP_TO_STRING, or that reference leaks (every Show interpolation
                // would otherwise leak one string). A borrowed string (a local/field) still retains.
                part->string_temp = (prt == TY_STRING) && is_owning_temp(c, part->expr, pt);
            }
            return TY_STRING;
        }

        case EXPR_RANGE:
            // A range is only meaningful as a `for` iterator, which handles it
            // directly (STMT_FOR never calls check_expr on the range node). Reaching
            // here means it was used as an ordinary value.
            check_expr(c, e->as.range.lo);
            check_expr(c, e->as.range.hi);
            type_error(c, e->line, e->col,
                       "a range 'a..b' is only valid as a 'for' loop iterator");
            return TY_ERROR;

        case EXPR_LAMBDA:
            return check_lambda(c, e, expected);

        case EXPR_FN_VALUE: {
            // A function name already rewritten to a value node. Not normally
            // re-checked, but recompute its type defensively if revisited.
            for (int i = 0; i < c->fn_count; i++) {
                if (c->fns[i].fn_index == e->as.fn_value) {
                    return intern_fn_type(c, c->fns[i].params,
                                          c->fns[i].param_count, c->fns[i].ret);
                }
            }
            return TY_ERROR;
        }

        case EXPR_TRY: {
            // `expr?`: unwrap an Ok/Some payload, or return the Err/None early.
            SemType ot = check_expr(c, e->as.try_.operand);
            if (ot == TY_ERROR) {
                return TY_ERROR;
            }
            if (!is_generic_inst(ot) || !c->ginsts[ot - GENERIC_BASE].is_enum) {
                type_error(c, e->line, e->col,
                           "'?' requires a Result or Option value");
                return TY_ERROR;
            }
            // OFI-049: `?` is a hidden early `return` on the Err/None path — it abandons every
            // in-scope owned `Ptr`. Scan here (after the operand is checked, so evaluation order is
            // honoured for a nested `a()? + b()?`). A `Result<Ptr,_>` can't exist (Ptr is barred as a
            // generic arg), so the unwrapped value is never itself a leaking handle.
            report_unconsumed_ptrs(c, 0, e->line, e->col);
            GenericInst *gi = &c->ginsts[ot - GENERIC_BASE];
            EnumInfo *ei = &c->enums[gi->base];
            const char *succ_name;
            int is_result;
            if (strcmp(ei->name, "Result") == 0) {
                succ_name = "Ok"; is_result = 1;
            } else if (strcmp(ei->name, "Option") == 0) {
                succ_name = "Some"; is_result = 0;
            } else {
                type_error(c, e->line, e->col,
                           "'?' requires a Result or Option value");
                return TY_ERROR;
            }
            VariantInfo *succ = NULL;
            for (int v = 0; v < ei->variant_count; v++) {
                if (strcmp(ei->variants[v].name, succ_name) == 0) {
                    succ = &ei->variants[v];
                    break;
                }
            }
            if (succ == NULL || succ->field_count != 1) {
                type_error(c, e->line, e->col,
                           "malformed Result/Option: the success variant must carry "
                           "one field");
                return TY_ERROR;
            }
            e->as.try_.success_variant = succ->variant_index;   // annotate codegen
            // The enclosing function must return the same kind (and, for Result,
            // the same error type), so the propagated Err/None type-checks.
            int ok_ret = 0;
            if (is_generic_inst(c->current_return)) {
                GenericInst *rg = &c->ginsts[c->current_return - GENERIC_BASE];
                if (rg->is_enum && rg->base == gi->base) {
                    ok_ret = is_result ? (rg->arg_count == 2 && gi->arg_count == 2 &&
                                          rg->args[1] == gi->args[1])
                                       : 1;
                }
            }
            if (!ok_ret) {
                type_error(c, e->line, e->col,
                           is_result
                               ? "'?' here needs the function to return a Result with "
                                 "the same error type"
                               : "'?' here needs the function to return an Option");
            }
            return subst(c, gi, succ->fields[0]);   // the unwrapped payload type
        }

        case EXPR_ARRAY: {
            // `[a, b, c]` — a homogeneous array literal. An empty `[]` takes its
            // element type from the expected type.
            size_t n = e->as.array.count;
            if (n == 0) {
                if (is_array_type(expected)) {
                    SemType ee = array_elem(c, expected);
                    e->num_kind = array_elem_kind(ee);
                    e->as.array.elem_struct_id = array_inline_struct_id(c, ee);
                    return expected;
                }
                type_error(c, e->line, e->col,
                           "cannot infer the element type of an empty array; "
                           "add a type annotation");
                return TY_ERROR;
            }
            // A `[i32]`-typed context guides each element (so literal elements
            // adopt the annotated width, like `let xs: [u8] = [1, 2, 3]`).
            SemType exp_elem = is_array_type(expected) ? array_elem(c, expected)
                                                       : TY_ERROR;
            // An `[Iface]`-typed array holds interface values: each element may be a
            // DIFFERENT concrete struct, each upcast to the interface (the heterogeneous-
            // collection use case). So elements are checked by `assignable` to the
            // interface, not against each other, and the element type is the interface.
            int iface_elems = is_interface_type(exp_elem);
            SemType elem = TY_ERROR;
            for (size_t i = 0; i < n; i++) {
                c->expected = exp_elem;
                SemType et = check_expr(c, e->as.array.elems[i]);
                if (iface_elems) {
                    if (et != TY_ERROR &&
                        !assignable(c, e->as.array.elems[i], et, exp_elem)) {
                        type_error(c, e->line, e->col,
                                   "array element does not implement the interface "
                                   "element type");
                    }
                } else if (i == 0) {
                    elem = et;
                } else if (et != TY_ERROR && elem != TY_ERROR && et != elem) {
                    type_error(c, e->line, e->col,
                               "array elements must all have the same type");
                }
            }
            if (iface_elems) {
                elem = exp_elem;   // the array's element type is the interface
            }
            if (ptr_storage_error(c, elem, e->line, e->col, "an array element") ||
                resource_storage_error(c, elem, e->line, e->col, "an array element")) {
                return TY_ERROR;   // OFI-049: no [Ptr] literal — caught before consuming the handles
            }
            for (size_t i = 0; i < n; i++) {   // the array takes ownership of each
                consume(c, e->as.array.elems[i], elem, e->line, e->col);
            }
            e->num_kind = array_elem_kind(elem);   // packed storage kind for codegen
            e->as.array.elem_struct_id = array_inline_struct_id(c, elem);
            return elem == TY_ERROR ? TY_ERROR : intern_array(c, elem);
        }

        case EXPR_INDEX: {
            SemType at = check_expr(c, e->as.index.object);
            // arr[lo..hi] — a SLICE: a borrowed, read-only Slice<T> view (slices §). The source
            // must be a NAMED array/slice local or param (so the view borrows something with a
            // stable lifetime, and we can freeze it); the view itself can't escape (slices may
            // not be returned, stored in a field, or be an array element — see those checks).
            if (e->as.index.index->kind == EXPR_RANGE) {
                Expr *r = e->as.index.index;
                SemType lo = check_expr(c, r->as.range.lo);
                SemType hi = check_expr(c, r->as.range.hi);
                if ((lo != TY_INT && lo != TY_ERROR) ||
                    (hi != TY_INT && hi != TY_ERROR)) {
                    type_error(c, e->line, e->col, "slice bounds must be 'int'");
                }
                SemType elem;
                if (is_array_type(at))      { elem = array_elem(c, at); }
                else if (is_slice_type(at)) { elem = slice_elem(c, at); }   // slice of a slice
                else {
                    if (at != TY_ERROR) {
                        type_error(c, e->line, e->col,
                                   "slicing requires an array or slice");
                    }
                    return TY_ERROR;
                }
                if (e->as.index.object->kind != EXPR_IDENT) {
                    type_error(c, e->line, e->col,
                               "can only slice a named array or slice (not a temporary), so the "
                               "view cannot outlive what it borrows");
                    return TY_ERROR;
                }
                int li = resolve_local(c, e->as.index.object->as.ident);
                if (li >= 0 && !c->locals[li].frozen) {
                    c->locals[li].frozen      = 1;   // freeze the source for the rest of its scope
                    c->locals[li].frozen_line = e->line;
                    c->locals[li].frozen_col  = e->col;
                }
                return intern_slice(c, elem);
            }
            SemType it = check_expr(c, e->as.index.index);
            if (it != TY_INT && it != TY_ERROR) {
                type_error(c, e->line, e->col, "an array index must be an int");
            }
            if (is_array_type(at)) {
                SemType elem = array_elem(c, at);
                // An inline (all-scalar) struct element materialises a value COPY on read; record
                // its struct id so the native backend unboxes the copy into an em_s (OFI-054).
                e->as.index.inline_struct_id = array_inline_struct_id(c, elem);
                return elem;
            }
            if (is_slice_type(at)) {
                SemType elem = slice_elem(c, at);   // reading an element of a view
                e->as.index.inline_struct_id = array_inline_struct_id(c, elem);
                return elem;
            }
            if (at != TY_ERROR) {
                type_error(c, e->line, e->col, "indexing requires an array");
            }
            return TY_ERROR;
        }
    }
    return TY_ERROR;
}





static void check_stmt(Checker *c, Stmt *s);

// Move-state snapshots for control flow. A binding is "moved on a path" if any
// branch moves it, so after a conditional we OR the branches' moved flags (a
// value moved on *some* path is unusable afterward — sound, and precise enough
// that moving the same value in different branches is fine).
static void snapshot_moved(Checker *c, int *buf) {
    for (int i = 0; i < c->local_count; i++) {
        buf[i] = c->locals[i].moved;
    }
}





static void restore_moved(Checker *c, const int *buf) {
    for (int i = 0; i < c->local_count; i++) {
        c->locals[i].moved = buf[i];
    }
}





static void merge_moved(Checker *c, const int *other) {
    for (int i = 0; i < c->local_count; i++) {
        if (other[i]) {
            c->locals[i].moved = 1;
        }
    }
}


// Linearity (OFI-049): the `consumed` flag is the AND-merge DUAL of `moved`'s OR-merge — it answers
// "has this binding been moved out on EVERY path reaching here?" (`moved` answers "on SOME path?").
// These three mirror snapshot/restore/merge_moved one-for-one and are maintained side by side at every
// control-flow join, so the must-consume analysis can't drift from the affine one (the project's
// mirror-drift discipline). The merge is an INTERSECTION: at a join, a value is consumed only if both
// reaching branches consumed it. The identity for AND is all-ones (a binding consumed on no branch
// stays 0; a join reached by no branch keeps the all-ones a caller seeds).
static void snapshot_consumed(Checker *c, int *buf) {
    for (int i = 0; i < c->local_count; i++) {
        buf[i] = c->locals[i].consumed;
    }
}


static void restore_consumed(Checker *c, const int *buf) {
    for (int i = 0; i < c->local_count; i++) {
        c->locals[i].consumed = buf[i];
    }
}


static void merge_consumed(Checker *c, const int *other) {
    for (int i = 0; i < c->local_count; i++) {
        if (!other[i]) {
            c->locals[i].consumed = 0;   // AND: un-consumed on the other path ⇒ not consumed at join
        }
    }
}


// report_ptr_leak emits the leak diagnostic for one owned, un-consumed `Ptr` binding and latches
// `leaked` so the same handle is reported once, not at every enclosing scope exit it survives.
static void report_ptr_leak(Checker *c, int slot, int line, int col) {
    Local *l = &c->locals[slot];
    char msg[200];
    if (l->name != NULL && l->name[0] != '\0') {
        snprintf(msg, sizeof msg,
                 "'%s' is a 'Ptr' opened but not closed on this path", l->name);
    } else {
        snprintf(msg, sizeof msg, "a 'Ptr' is opened but not closed on this path");
    }
    diag_error(diag_src(c), line, col, msg, NULL,
               "a 'Ptr' is a linear FFI handle with no destructor — close it on every path "
               "(e.g. fclose(it)) or return it to transfer ownership to the caller");
    if (l->open_line > 0 && (l->open_line != line || l->open_col != col)) {
        diag_note(diag_src(c), l->open_line, l->open_col, "opened here");   // skip if the primary IS the open site
    }
    c->had_error = 1;
    l->leaked = 1;
}


// report_unconsumed_ptrs flags every owned `Ptr` local in [from, local_count) that is not consumed on
// the current path — a leak at a scope EXIT. It is the shared engine for must-consume, called at every
// point control leaves a scope without consuming the handle: a `return` (from = 0, all in-scope), a
// `break`/`continue` (from = the loop-body base), a `?` early-return, and (folded into drop_locals) a
// block/match-arm/function-body fall-through. Deliberately INDEPENDENT of `l->decl` so it also covers
// `move f: Ptr` params (whose decl is NULL). `line`/`col` locate the exit for the primary message.
static void report_unconsumed_ptrs(Checker *c, int from, int line, int col) {
    if (c->unreachable) {
        return;   // a leak on a statically-dead path is a false positive (e.g. a trailing return)
    }
    for (int i = from; i < c->local_count; i++) {
        Local *l = &c->locals[i];
        if (l->owned && l->type == TY_PTR && !l->consumed && !l->leaked) {
            report_ptr_leak(c, i, line, col);
        }
    }
}


// report_unconsumed_drop_fields (OFI-122 R6): at an exit from a `resource` drop body, EVERY `Ptr`
// field of `self` must have been closed (consumed). Report a leak for any that wasn't, naming the
// field, then latch them so the same leak isn't re-reported at another exit. So a no-op
// `fn drop(self){}` fails to compile (it leaks the handle), and a drop that closes its field passes.
static void report_unconsumed_drop_fields(Checker *c, int line, int col) {
    if (!c->in_resource_drop || c->unreachable) {
        return;
    }
    int missing = c->drop_self_ptr_mask & ~c->drop_self_consumed;
    if (missing == 0) {
        return;
    }
    StructInfo *si = &c->structs[c->drop_self_struct];
    int bit = 0;
    for (int f = 0; f < si->field_count; f++) {
        if (si->fields[f].type != TY_PTR) {
            continue;
        }
        if (bit < 31 && (missing & (1 << bit))) {
            char msg[240];
            snprintf(msg, sizeof msg,
                     "this 'resource' drop does not close its handle field '%s' on every path; close "
                     "it (call a function that takes the 'Ptr' by 'move') unconditionally in 'drop'",
                     si->fields[f].name);
            type_error(c, line, col, msg);
        }
        bit++;
    }
    c->drop_self_consumed |= missing;   // latch: don't re-report at another exit of the same drop
}






// block_diverges / stmt_diverges report whether control definitely cannot fall
// off the end of a block / statement — it always exits via `return`, `break`, or
// `continue`. A diverging branch never reaches the code after an `if`, so its
// move-state must not poison the join (a value moved only on a returning path is
// still live afterward). These must err toward *false*: claiming divergence when a
// path can in fact fall through would skip real moves and mask a use-after-move,
// so only the certain cases are reported (loops/matches are conservatively
// treated as falling through, and only the last statement of a block is examined).
static int block_diverges(const Block *b);

static int stmt_diverges(const Stmt *s) {
    switch (s->kind) {
        case STMT_RETURN:
        case STMT_BREAK:
        case STMT_CONTINUE:
            return 1;
        case STMT_BLOCK:
            return block_diverges(&s->as.block.body);
        case STMT_IF:   // diverges only if there is an `else` and both arms do
            return s->as.if_.else_branch != NULL &&
                   block_diverges(&s->as.if_.then_blk) &&
                   stmt_diverges(s->as.if_.else_branch);
        default:
            return 0;
    }
}

static int block_diverges(const Block *b) {
    return b->count > 0 && stmt_diverges(b->stmts[b->count - 1]);
}





// drop_locals records, for each binding in [from, local_count) about to leave
// scope, whether codegen should free it at scope exit. A binding that owns a
// *struct* gets a drop: the value is unique (the move checker forbids aliasing
// and partial moves) so freeing it is sound. Borrows and shareable values are
// left alone. Note this fires even for bindings that *were* moved on some path —
// codegen nils a slot when its value is moved out (see Expr.moves_local), so the
// drop is a runtime no-op exactly on those paths. This makes a conditionally
// moved struct reclaim correctly: freed where it is still owned, skipped where it
// was handed off. The bit is written onto the declaring `let` for codegen.
static void drop_locals(Checker *c, int from) {
    for (int i = from; i < c->local_count; i++) {
        Local *l = &c->locals[i];
        // OFI-049 leak half: an owned `Ptr` reaching its scope end un-consumed on the fall-through
        // path leaks (it has no destructor to close it). This covers a block / match-arm / loop-body /
        // function-body closing brace; `leaked` keeps a handle already reported at an earlier divergent
        // exit (return/break) from being flagged twice. Decl-independent so the function-end
        // drop_locals(c, 0) also covers `move f: Ptr` params (decl == NULL).
        if (!c->unreachable && l->owned && l->type == TY_PTR && !l->consumed && !l->leaked) {
            report_ptr_leak(c, i, l->open_line, l->open_col);
        }
        if (l->decl != NULL) {
            // A binding that owns a struct (freed) or a refcounted shareable
            // (string/array/enum — refcount dropped) is released at scope exit.
            // A slice local is dropped too — drop_value frees just its header (the
            // borrowed buffer stays with the source). Borrows and channels are not.
            l->decl->as.let.drop_at_scope_end =
                l->owned && l->type != TY_PTR &&
                (is_move_type(c, l->type) || is_refcounted(c, l->type) ||
                 is_slice_type(l->type));   // a Ptr is move-tracked but has NO destructor (OFI-049)
        }
    }
}






// check_block checks a nested block one scope level deeper, then drops any
// bindings it declared (they go out of scope at the closing brace).
static void check_block(Checker *c, Block *b) {
    c->scope_depth++;
    int saved_count = c->local_count;
    int saved_unreach = c->unreachable;   // OFI-049: a diverging stmt makes the rest of THIS block dead
    for (size_t i = 0; i < b->count; i++) {
        check_stmt(c, b->stmts[i]);
        if (stmt_diverges(b->stmts[i])) {
            c->unreachable = 1;
        }
    }
    drop_locals(c, saved_count);          // sees `unreachable` (skips the leak scan on a dead block end)
    c->unreachable = saved_unreach;
    c->local_count = saved_count;
    c->scope_depth--;
}





static void check_stmt(Checker *c, Stmt *s) {
    switch (s->kind) {
        case STMT_LET: {
            // A type annotation becomes the expected type, so a generic variant
            // construction (`Some(5)`, `None`) can infer its type arguments.
            c->allow_slice = 1;   // a let may be annotated `: Slice<T>` (a local view)
            SemType at = s->as.let.type != NULL
                             ? annotation_type(c, s->as.let.type) : TY_ERROR;
            SemType saved = c->expected;
            c->expected = at;
            // Check the initialiser before the name is in scope, so `let a = a`
            // refers to an outer/undeclared `a`, never itself.
            SemType vt = check_expr(c, s->as.let.value);
            c->expected = saved;
            if (vt == TY_UNIT) {
                type_error(c, s->line, s->col,
                           "cannot bind a call that returns no value");
            }
            if (s->as.let.type != NULL) {
                if (at == TY_ERROR) {
                    type_error(c, s->line, s->col,
                               "unknown or unsupported type in binding annotation");
                } else if (vt != TY_ERROR && !assignable(c, s->as.let.value, vt, at)) {
                    type_error(c, s->line, s->col,
                               "binding annotation does not match the value's type");
                }
            }
            // An interface-typed binding holds a boxed {receiver, vtable} value that owns
            // its struct receiver; the binding's type is the interface, not the struct.
            int coerced_iface = (s->as.let.value->coerce_witness != NULL);
            // The initialiser is consumed; for `let q = p` (move type) this moves
            // p, and the new binding inherits whether the value is owned. For an interface
            // upcast the struct receiver is moved into the box (consume by its struct type).
            int owned = consume(c, s->as.let.value, vt, s->line, s->col);
            if (coerced_iface) {
                vt    = annotation_type(c, s->as.let.type);   // the interface type
                owned = 1;                                    // the box owns its receiver
            }
            // A sized numeric binding records its width kind so the NATIVE backend stores it at
            // width (OFI-123); non-numeric (incl. bool) stay -1 → a uniform Value. The VM ignores it.
            s->as.let.scalar_kind = is_numeric_type(vt) ? int_kind(vt) : -1;
            // An immutable all-scalar struct binding is stored MULTI-SLOT (its fields
            // exploded on the stack), not as a boxed object (value-types 3b). `var`
            // (mutable) and boxed-field structs stay boxed for now.
            if (!s->as.let.is_var) {
                s->as.let.inline_struct_id = nested_inline_sid(c, vt);   // flat OR nested (3b.5-B)
                // If the initialiser is a call that returns a struct MULTI-SLOT and this
                // binding stores it multi-slot, take the N slots DIRECTLY — tell codegen not
                // to box the result, so there is no box→unbox round-trip (value-types 3b.4b).
                Expr *rv = s->as.let.value;
                // A call delivers its result raw (no box) only when it has no caller-managed
                // drop temps — those use OP_DROP_UNDER after the call, which assumes a 1-slot
                // result; a multi-slot result would be corrupted, so it stays boxed there.
                if (s->as.let.inline_struct_id >= 0 && rv->kind == EXPR_CALL &&
                    rv->as.call.ret_struct_id >= 0 &&
                    rv->as.call.drop_first == 0 && rv->as.call.drop_mask == 0) {
                    rv->as.call.box_result = 0;
                } else if (s->as.let.inline_struct_id >= 0 &&
                           rv->kind == EXPR_STRUCT_LIT &&
                           rv->as.struct_lit.inline_sid >= 0) {
                    rv->as.struct_lit.box_result = 0;   // construct straight into the binding
                }
            }
            declare_local(c, s->line, s->col, s->as.let.name,
                          s->as.let.is_var, vt, owned);
            // Remember which `let` owns this local, so when it goes out of scope we
            // can mark whether it still owns a struct to free (see drop_locals).
            if (c->local_count > 0) {
                c->locals[c->local_count - 1].decl = s;
                c->locals[c->local_count - 1].multislot_sid =
                    s->as.let.is_var ? -1 : s->as.let.inline_struct_id;
            }
            break;
        }

        case STMT_ASSIGN: {
            // The target's type is determined first and supplied as the expected
            // type when checking the value, so a literal right-hand side adopts the
            // target's width (`x = 5` into a u8, `a[i] = 200` into a [u8]).
            Expr *target = s->as.assign.target;
            if (target->kind == EXPR_IDENT) {
                int slot = resolve_local(c, target->as.ident);
                SemType tt = slot >= 0 ? c->locals[slot].type : TY_ERROR;
                c->expected = tt;
                SemType vt = check_expr(c, s->as.assign.value);
                if (slot < 0) {
                    type_error(c, s->line, s->col, "assignment to undefined variable");
                } else if (!c->locals[slot].is_var) {
                    type_error(c, s->line, s->col,
                               "cannot assign to an immutable 'let' binding; "
                               "declare it with 'var'");
                } else if (is_slice_type(tt)) {
                    type_error(c, s->line, s->col,
                               "a slice binding cannot be reassigned (a borrowed view is fixed "
                               "to its source); take a fresh slice into a new 'let'");
                } else if (c->locals[slot].frozen) {
                    type_error(c, s->line, s->col,
                               "cannot reassign an array while it is borrowed by a slice "
                               "(the view would dangle)");
                } else if (vt != TY_ERROR && tt != vt) {
                    type_error(c, s->line, s->col,
                               "assigned value's type does not match the variable");
                }
                // OFI-049: reassigning a `var f: Ptr` that still holds an UN-consumed handle drops it
                // on the floor (no destructor) — a leak. Report against the old handle's open site,
                // then (below) track the freshly-assigned handle from here. Closed-then-reassigned
                // (`fclose(f); f = fopen()`) is fine: consumed == 1, so no leak.
                if (slot >= 0 && tt == TY_PTR && c->locals[slot].owned &&
                    !c->locals[slot].consumed && !c->locals[slot].leaked) {
                    char m[200];
                    snprintf(m, sizeof m,
                             "reassigning '%s' leaks the 'Ptr' handle it still holds",
                             target->as.ident);
                    diag_error(diag_src(c), s->line, s->col, m, NULL,
                               "close the current handle first (e.g. fclose) — a 'Ptr' has no "
                               "destructor, so an overwritten handle is lost");
                    if (c->locals[slot].open_line > 0) {
                        diag_note(diag_src(c), c->locals[slot].open_line, c->locals[slot].open_col,
                                  "the leaked handle was opened here");
                    }
                    c->had_error = 1;
                }
                // The value moves into the target; the target is now live again
                // (a fresh value), even if it had been moved out earlier.
                consume(c, s->as.assign.value, vt, s->line, s->col);
                if (slot >= 0) {
                    c->locals[slot].moved = 0;
                    if (tt == TY_PTR) {   // a fresh handle: a new un-consumed obligation, opened here
                        c->locals[slot].consumed  = 0;
                        c->locals[slot].leaked    = 0;
                        c->locals[slot].open_line = s->line;
                        c->locals[slot].open_col  = s->col;
                    }
                }
            } else if (target->kind == EXPR_GET) {
                // Field mutation `p.x = v`. The field type comes from checking the
                // target (which also annotates field_index for codegen); the root
                // of the access path must be a mutable place (`var` / `mut` / `move`).
                SemType ft = check_expr(c, target);
                // R4: a write must not pass THROUGH an `rc` value. The root-only is_var check
                // below is insufficient — a `var`, non-rc container holding an rc field would
                // otherwise let `w.r.x = v` mutate a deeply-immutable shared interior (the
                // laundering hole the adversarial design found). Re-resolve EACH intermediate
                // object's type and reject if any is rc. Gated on any_rc so non-rc code is untouched.
                if (c->any_rc) {
                    for (Expr *step = target;
                         step->kind == EXPR_GET || step->kind == EXPR_INDEX; ) {
                        Expr *obj = step->kind == EXPR_GET ? step->as.get.object
                                                           : step->as.index.object;
                        if (type_is_rc(c, check_expr(c, obj))) {
                            type_error(c, s->line, s->col,
                                       "cannot assign through a field or element of an 'rc' value; "
                                       "an rc struct is deeply immutable and shared");
                            break;
                        }
                        step = obj;
                    }
                }
                // Walk the access path to its root through BOTH field (`o.f`) and element
                // (`a[i]`) steps, so `arr[i].field = v` and `a[i].b.c = v` are rooted just like
                // `a[i] = v` is (OFI-061). The root must be a mutable, non-borrowed place.
                Expr *root = target;
                while (root->kind == EXPR_GET || root->kind == EXPR_INDEX) {
                    root = root->kind == EXPR_GET ? root->as.get.object
                                                  : root->as.index.object;
                }
                if (root->kind != EXPR_IDENT) {
                    type_error(c, s->line, s->col,
                               "a field assignment must be rooted at a variable");
                } else {
                    int slot = resolve_local(c, root->as.ident);
                    if (slot >= 0 && !c->locals[slot].is_var) {
                        type_error(c, s->line, s->col,
                                   "cannot mutate a field through an immutable "
                                   "binding; declare it 'var' or take 'mut'");
                    }
                    if (slot >= 0 && c->locals[slot].frozen) {
                        type_error(c, s->line, s->col,
                                   "cannot mutate an element's field while the array is borrowed "
                                   "by a slice (the view would dangle)");
                    }
                }
                c->expected = ft;
                SemType vt = check_expr(c, s->as.assign.value);
                if (ft != TY_ERROR && vt != TY_ERROR && ft != vt) {
                    type_error(c, s->line, s->col,
                               "assigned value's type does not match the field");
                }
                consume(c, s->as.assign.value, vt, s->line, s->col);  // moves into the field
            } else if (target->kind == EXPR_INDEX) {
                // Element mutation `a[i] = v`. `check_expr` on the target yields the
                // element type and validates that the receiver is an array indexed
                // by an int. As with a field, the access path must be rooted at a
                // mutable place (a `var` binding or a `mut`/`move` parameter).
                SemType et = check_expr(c, target);
                // R4: reject a write that passes THROUGH an rc value (e.g. `rcArrayElem.f = v`,
                // or any path with an rc step before the final element). Assigning an element of
                // `[RcT]` itself is fine — the array is the mutable owner and consume() increfs the
                // new rc / releases the old — so only INTERIOR rc objects are rejected here.
                if (c->any_rc) {
                    for (Expr *step = target;
                         step->kind == EXPR_GET || step->kind == EXPR_INDEX; ) {
                        Expr *obj = step->kind == EXPR_GET ? step->as.get.object
                                                           : step->as.index.object;
                        if (type_is_rc(c, check_expr(c, obj))) {
                            type_error(c, s->line, s->col,
                                       "cannot assign through a field or element of an 'rc' value; "
                                       "an rc struct is deeply immutable and shared");
                            break;
                        }
                        step = obj;
                    }
                }
                Expr *root = target;
                while (root->kind == EXPR_INDEX || root->kind == EXPR_GET) {
                    root = root->kind == EXPR_INDEX ? root->as.index.object
                                                    : root->as.get.object;
                }
                if (root->kind != EXPR_IDENT) {
                    type_error(c, s->line, s->col,
                               "an element assignment must be rooted at a variable");
                } else {
                    int slot = resolve_local(c, root->as.ident);
                    if (slot >= 0 && !c->locals[slot].is_var) {
                        type_error(c, s->line, s->col,
                                   "cannot mutate an element through an immutable "
                                   "binding; declare it 'var' or take 'mut'");
                    }
                    if (slot >= 0 && c->locals[slot].frozen) {
                        type_error(c, s->line, s->col,
                                   "cannot mutate an array while it is borrowed by a slice "
                                   "(the view would dangle)");
                    }
                    if (slot >= 0 && is_slice_type(c->locals[slot].type)) {
                        type_error(c, s->line, s->col,
                                   "a slice is a read-only view; assign through the underlying "
                                   "array instead");
                    }
                }
                c->expected = et;
                SemType vt = check_expr(c, s->as.assign.value);
                if (et != TY_ERROR && vt != TY_ERROR && et != vt) {
                    type_error(c, s->line, s->col,
                               "assigned value's type does not match the element");
                }
                consume(c, s->as.assign.value, vt, s->line, s->col);  // moves into the element
            } else {
                type_error(c, s->line, s->col, "invalid assignment target");
            }
            break;
        }

        case STMT_RETURN:
            if (s->as.ret.value == NULL) {
                // A bare `return` is only legal in a unit function — one with no
                // declared return type. Anywhere else it would skip the value.
                if (c->current_return != TY_UNIT) {
                    type_error(c, s->line, s->col,
                               "this function must return a value");
                }
            } else if (c->current_return == TY_UNIT) {
                type_error(c, s->line, s->col,
                           "cannot return a value from a function with no "
                           "declared return type");
                check_expr(c, s->as.ret.value);
            } else if (c->current_return == TY_INFER) {
                // A lambda whose result type is inferred from its body: record the
                // returned type (all of a lambda's returns must agree).
                SemType t = check_expr(c, s->as.ret.value);
                if (t != TY_ERROR) {
                    if (c->inferred_return == TY_ERROR) {
                        c->inferred_return = t;
                    } else if (c->inferred_return != t) {
                        type_error(c, s->line, s->col,
                                   "a lambda's returns have differing types");
                    }
                }
                consume(c, s->as.ret.value, t, s->line, s->col);
            } else {
                // The return type is the expected type, so `return Some(5)` /
                // `return None` can infer their type arguments.
                SemType saved = c->expected;
                c->expected = c->current_return;
                SemType t = check_expr(c, s->as.ret.value);
                c->expected = saved;
                if (t != TY_ERROR && c->current_return != TY_ERROR &&
                    !assignable(c, s->as.ret.value, t, c->current_return)) {
                    type_error(c, s->line, s->col,
                               "returned value's type does not match the "
                               "function's return type");
                }
                // A returned move value must be owned — returning a borrowed
                // parameter would let a reference escape the function. EXCEPT a
                // multi-slot (all-scalar struct) value is a COPY type: returning it
                // copies the value out (box-on-use), so no reference escapes — a plain
                // borrow of one may be returned by value (OFI-028).
                if (is_move_type(c, t) && s->as.ret.value->kind == EXPR_IDENT &&
                    !is_multislot_local(c, s->as.ret.value)) {
                    int slot = resolve_local(c, s->as.ret.value->as.ident);
                    if (slot >= 0 && !c->locals[slot].owned) {
                        type_error(c, s->line, s->col,
                                   "cannot return a borrowed value — it would "
                                   "escape the function; take the parameter as 'move'");
                    }
                }
                // If this function returns a struct MULTI-SLOT and the returned value is a
                // call/construction that can deliver its slots directly, tell codegen not to
                // box it — `return f()` / `return P{…}` then build straight into the return
                // (value-types 3b.4b/4c). gen_arg leaves the N slots for OP_RETURN_STRUCT.
                if (c->current_ret_struct_id >= 0) {
                    Expr *rv = s->as.ret.value;
                    if (rv->kind == EXPR_CALL && rv->as.call.ret_struct_id >= 0 &&
                        rv->as.call.drop_first == 0 && rv->as.call.drop_mask == 0) {
                        rv->as.call.box_result = 0;
                    } else if (rv->kind == EXPR_STRUCT_LIT &&
                               rv->as.struct_lit.inline_sid >= 0) {
                        rv->as.struct_lit.box_result = 0;
                    }
                }
                consume(c, s->as.ret.value, t, s->line, s->col);
            }
            // OFI-049: a `return` abandons every in-scope owned `Ptr`. Scan AFTER the consume above,
            // so a returned handle (`return f`) is already marked consumed and is not flagged — no
            // "except the returned binding" carve-out needed. Covers bare return + every value shape.
            report_unconsumed_ptrs(c, 0, s->line, s->col);
            report_unconsumed_drop_fields(c, s->line, s->col);   // OFI-122: drop must close its handles
            break;

        case STMT_IF: {
            SemType ct = check_expr(c, s->as.if_.cond);
            if (ct != TY_BOOL && ct != TY_ERROR) {
                type_error(c, s->line, s->col, "'if' condition must be a bool");
            }
            // Each branch starts from the same move-state; afterward a value is
            // moved if a branch that *reaches the join* moved it. A branch that
            // diverges (always returns/breaks/continues) never reaches the join,
            // so its moves are excluded — a value moved only on a returning path
            // is still live in the code that follows the `if` (OFI-010).
            int *pre = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            int *then_moved = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            // OFI-049: `consumed` is tracked side by side with `moved` at this join, but merged with
            // AND (intersection) where `moved` uses OR (union) — a handle is consumed-after-the-if
            // only if consumed on every reaching branch.
            int *pre_c   = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            int *then_c  = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            int *else_c  = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            snapshot_moved(c, pre);    snapshot_consumed(c, pre_c);
            check_block(c, &s->as.if_.then_blk);
            snapshot_moved(c, then_moved); snapshot_consumed(c, then_c);
            restore_moved(c, pre);     restore_consumed(c, pre_c);
            if (s->as.if_.else_branch != NULL) {
                check_stmt(c, s->as.if_.else_branch);
            }
            snapshot_consumed(c, else_c);   // live consumed-state now = the else branch's (or `pre`)
            // At this point the live move-state is the else branch's (or `pre` if
            // there is no else). Fold in the then branch per reachability.
            int then_div = block_diverges(&s->as.if_.then_blk);
            int else_div = s->as.if_.else_branch != NULL &&
                           stmt_diverges(s->as.if_.else_branch);
            if (then_div && else_div) {
                restore_moved(c, pre);        // join unreachable; nothing reaches it
                restore_consumed(c, pre_c);
            } else if (else_div) {
                restore_moved(c, then_moved); // only the then branch reaches
                restore_consumed(c, then_c);
            } else if (!then_div) {
                merge_moved(c, then_moved);   // both reach: union of their moves
                merge_consumed(c, then_c);    // both reach: intersection of their consumes
                // OFI-049 (HIGH-1): a `Ptr` closed on exactly ONE reaching branch is now wedged —
                // `moved` on that path forbids a later re-close (use-after-move), yet it leaks on the
                // other path. Report one clean leak at the join instead of leaving that trap.
                for (int i = 0; i < c->local_count; i++) {
                    Local *l = &c->locals[i];
                    if (l->owned && l->type == TY_PTR && !l->leaked && then_c[i] != else_c[i]) {
                        report_ptr_leak(c, i, s->line, s->col);
                    }
                }
            }                                 // then_div only: keep the else state (both flags)
            break;
        }

        case STMT_BLOCK:
            check_block(c, &s->as.block.body);
            break;

        case STMT_LOOP: {
            // A value moved inside a loop body would be moved again on the next
            // iteration — reject it.
            int *pre = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            snapshot_moved(c, pre);
            // OFI-049: an infinite `loop` leaves ONLY through a `break` (or a return/?, handled at
            // their own sites). So an OUTER `Ptr` is consumed after the loop iff consumed on every
            // break path. `brk` is the AND accumulator over those paths, seeded all-1 (AND identity);
            // each `break` ANDs in its live consumed-state. This is what lets the textbook
            // `loop { …; if eof { fclose(f); break } }` read loop compile (the close sits on a
            // diverging branch the if-join discards — without this merge it falsely reads as a leak).
            int base       = c->local_count;
            int saved_base = c->loop_local_base;
            int *saved_bc  = c->loop_break_consumed;
            int saved_seen = c->loop_break_seen;
            int *saved_be  = c->loop_backedge_moved;
            int *brk = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            int *bem = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            for (int i = 0; i < base; i++) {
                brk[i] = 1;
                bem[i] = 0;   // OFI-074: OR-accumulator over back-edges, seeded empty
            }
            c->loop_local_base     = base;
            c->loop_break_consumed = brk;
            c->loop_break_seen     = 0;
            c->loop_backedge_moved = bem;
            c->loop_depth++;
            check_block(c, &s->as.loop.body);
            c->loop_depth--;
            int any_break = c->loop_break_seen;
            // The body's END is itself a back-edge IFF it is reachable (the body can fall through to
            // the next iteration). If the body always diverges (every path break/return/continue),
            // the fall-through never happens — so fold the body-end moved-state in only when reachable.
            if (!block_diverges(&s->as.loop.body)) {
                for (int i = 0; i < base; i++) {
                    if (c->locals[i].moved) {
                        bem[i] = 1;
                    }
                }
            }
            c->loop_local_base     = saved_base;   // restore the enclosing loop's break context
            c->loop_break_consumed = saved_bc;
            c->loop_break_seen     = saved_seen;
            c->loop_backedge_moved = saved_be;
            // Report only moves that can REACH a back-edge (recur next iteration) — not a move on a
            // path that breaks/returns out of the loop (OFI-074). `bem` is that set.
            for (int i = 0; i < base; i++) {
                if (!pre[i] && bem[i]) {
                    type_error(c, s->line, s->col,
                               "value moved inside a loop body (it would be moved "
                               "again on the next iteration)");
                }
            }
            // Reached only if the loop can exit: an outer handle's post-loop consumed-state is the
            // AND over the break paths. (No break ⇒ the code after is unreachable, so leave it.)
            if (any_break) {
                for (int i = 0; i < base; i++) {
                    c->locals[i].consumed = brk[i];
                }
            }
            break;
        }

        case STMT_BREAK:
            if (c->loop_depth == 0) {
                type_error(c, s->line, s->col, "'break' outside of a loop");
            }
            // OFI-049: a `break` ends every body-local handle's scope (it won't survive the loop) —
            // any still open leaks. And it is an EXIT of an infinite `loop`, so AND its live
            // consumed-state (over the OUTER slots) into that loop's break accumulator.
            report_unconsumed_ptrs(c, c->loop_local_base, s->line, s->col);
            if (c->loop_break_consumed != NULL) {
                for (int i = 0; i < c->loop_local_base; i++) {
                    if (!c->locals[i].consumed) {
                        c->loop_break_consumed[i] = 0;
                    }
                }
                c->loop_break_seen = 1;
            }
            break;

        case STMT_CONTINUE:
            if (c->loop_depth == 0) {
                type_error(c, s->line, s->col, "'continue' outside of a loop");
            }
            // A `continue` ends this iteration: body-local handles leave scope and must be closed.
            // It is NOT a loop exit, so it does not feed the break accumulator. But it IS a back-edge
            // (control returns to the loop top), so a value moved on the way to it WOULD recur next
            // iteration — OR the live moved-state of the outer slots into the back-edge accumulator (OFI-074).
            report_unconsumed_ptrs(c, c->loop_local_base, s->line, s->col);
            if (c->loop_backedge_moved != NULL) {
                for (int i = 0; i < c->loop_local_base; i++) {
                    if (c->locals[i].moved) {
                        c->loop_backedge_moved[i] = 1;
                    }
                }
            }
            break;

        case STMT_MATCH: {
            SemType st = check_expr(c, s->as.match.value);
            // A scrutinee that is a fresh refcounted temporary (e.g. `match
            // recv(ch)`) owns its reference; release it when the match ends.
            s->as.match.subject_drop = is_owning_temp(c, s->as.match.value, st);
            // The subject may be a plain enum or a generic enum instantiation;
            // for the latter, `inst` supplies the args to substitute into bindings.
            int enum_id;
            const GenericInst *inst = NULL;
            if (is_enum_type(st)) {
                enum_id = enum_id_of(st);
            } else if (is_generic_inst(st) &&
                       c->ginsts[st - GENERIC_BASE].is_enum) {
                inst = &c->ginsts[st - GENERIC_BASE];
                enum_id = inst->base;
            } else {
                if (st != TY_ERROR) {
                    type_error(c, s->line, s->col, "'match' requires an enum value");
                }
                break;
            }
            EnumInfo *ei = &c->enums[enum_id];
            // Coverage bitmap, sized to this enum's variant count (no cap). arena_alloc does NOT
            // zero, so clear it explicitly (the old fixed `covered[MAX_VARIANTS] = {0}` was zeroed).
            int *covered = arena_alloc(c->arena, (size_t)(ei->variant_count + 1) * sizeof(int));
            memset(covered, 0, (size_t)(ei->variant_count + 1) * sizeof(int));
            // Each arm starts from the same move-state; afterward a value is moved
            // if any arm moved it (the OR over arms).
            int entry_count = c->local_count;
            int *pre = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            int *acc = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            snapshot_moved(c, pre);
            for (int i = 0; i < entry_count; i++) {
                acc[i] = pre[i];
            }
            // OFI-049: `consumed` folds across arms the dual way — `acc_c` is the AND (consumed on
            // EVERY reaching arm; identity all-1), `any_c` the OR (consumed on SOME reaching arm), so a
            // handle closed on some-but-not-all arms can be reported once at the join (the match's
            // dual of the if-join wedge). Each arm restores `pre_c` first (a match is exhaustive, so
            // the arms partition the paths).
            int *pre_c = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            int *acc_c = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            int *any_c = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            snapshot_consumed(c, pre_c);
            for (int i = 0; i < entry_count; i++) {
                acc_c[i] = 1;
                any_c[i] = 0;
            }
            for (size_t k = 0; k < s->as.match.case_count; k++) {
                MatchCase *mc = &s->as.match.cases[k];
                Pattern *pat = &mc->pattern;
                if (pat->wildcard) {
                    // A catch-all arm covers every variant not handled above and
                    // binds nothing. Check its body from the pre-match state.
                    for (int v = 0; v < ei->variant_count; v++) {
                        covered[v] = 1;
                    }
                    restore_moved(c, pre);
                    restore_consumed(c, pre_c);
                    c->scope_depth++;
                    int wsaved = c->local_count;
                    int wunreach = c->unreachable;
                    for (size_t i = 0; i < mc->body.count; i++) {
                        check_stmt(c, mc->body.stmts[i]);
                        if (stmt_diverges(mc->body.stmts[i])) { c->unreachable = 1; }
                    }
                    c->unreachable = wunreach;
                    if (!block_diverges(&mc->body)) {
                        for (int i = 0; i < entry_count; i++) {
                            if (c->locals[i].moved) {
                                acc[i] = 1;
                            }
                            if (c->locals[i].consumed) { any_c[i] = 1; } else { acc_c[i] = 0; }
                        }
                    }
                    drop_locals(c, wsaved);
                    c->local_count = wsaved;
                    c->scope_depth--;
                    continue;
                }
                if (pat->type_name != NULL && strcmp(pat->type_name, ei->name) != 0) {
                    type_error(c, pat->line, pat->col,
                               "pattern names a different enum than the match subject");
                }
                // Find the variant within this enum.
                int vi = -1;
                for (int v = 0; v < ei->variant_count; v++) {
                    if (strcmp(ei->variants[v].name, pat->variant) == 0) {
                        vi = v;
                        break;
                    }
                }
                if (vi < 0) {
                    type_error(c, pat->line, pat->col,
                               "this variant does not belong to the matched enum");
                    continue;
                }
                if (covered[vi]) {
                    type_error(c, pat->line, pat->col, "duplicate case for a variant");
                }
                covered[vi] = 1;
                VariantInfo *var = &ei->variants[vi];
                pat->enum_id       = var->enum_id;        // codegen dispatches on THIS variant's tag,
                pat->variant_index = var->variant_index;  // not a by-name lookup (OFI-073)
                if ((int)pat->binding_count != var->field_count) {
                    type_error(c, pat->line, pat->col,
                               "pattern binds the wrong number of fields");
                }
                // The bindings are locals scoped to this case body, typed by the
                // variant's fields.
                restore_moved(c, pre);   // this arm starts from the pre-match state
                restore_consumed(c, pre_c);
                c->scope_depth++;
                int saved = c->local_count;
                int arm_unreach = c->unreachable;
                for (size_t b = 0; b < pat->binding_count &&
                                   (int)b < var->field_count; b++) {
                    SemType bt = inst != NULL ? subst(c, inst, var->fields[b])
                                              : var->fields[b];
                    // A match binding borrows the scrutinee's payload (owned = 0),
                    // so a move-typed binding can't escape the match.
                    declare_local(c, pat->line, pat->col, pat->bindings[b], 0, bt, 0);
                    // An all-scalar value-struct payload is stored BOXED inside the enum; record
                    // its struct id so the native backend unboxes the bound copy into an em_s.
                    if ((int)b < 16) {
                        pat->binding_struct[b] = array_inline_struct_id(c, bt);
                    }
                }
                for (size_t i = 0; i < mc->body.count; i++) {
                    check_stmt(c, mc->body.stmts[i]);
                    if (stmt_diverges(mc->body.stmts[i])) { c->unreachable = 1; }
                }
                c->unreachable = arm_unreach;
                // Only an arm that reaches the join contributes its moves; an arm
                // that always returns/breaks/continues never falls through (OFI-010).
                if (!block_diverges(&mc->body)) {
                    for (int i = 0; i < entry_count; i++) {
                        if (c->locals[i].moved) {
                            acc[i] = 1;   // moved on this arm's path
                        }
                        if (c->locals[i].consumed) { any_c[i] = 1; } else { acc_c[i] = 0; }
                    }
                }
                drop_locals(c, saved);   // case-body bindings are freed at arm end
                c->local_count = saved;
                c->scope_depth--;
            }
            for (int i = 0; i < entry_count; i++) {
                c->locals[i].moved    = acc[i];
                c->locals[i].consumed = acc_c[i];   // OFI-049: consumed after the match = AND over arms
                // A `Ptr` closed on some reaching arms but not all is wedged (closed-on-some ⇒ a later
                // close is use-after-move, yet it leaks on the arms that didn't) — report once here.
                Local *l = &c->locals[i];
                if (l->owned && l->type == TY_PTR && !l->leaked && any_c[i] && !acc_c[i]) {
                    report_ptr_leak(c, i, s->line, s->col);
                }
            }
            // Exhaustiveness: every variant of the enum must be covered.
            for (int v = 0; v < ei->variant_count; v++) {
                if (!covered[v]) {
                    type_error(c, s->line, s->col,
                               "non-exhaustive match: a variant is not handled");
                }
            }
            break;
        }

        case STMT_EXPR: {
            // An expression statement runs an expression for effect, then
            // discards its result. Only calls have effects, so require one.
            if (s->as.expr.expr->kind != EXPR_CALL) {
                type_error(c, s->line, s->col,
                           "an expression statement must be a function call");
            }
            SemType et = check_expr(c, s->as.expr.expr);
            // OFI-049: a statement that yields a fresh `Ptr` and throws it away (`fopen(...)` with no
            // binding) leaks the handle — it is never named, so nothing can close it. A function can
            // only return an OWNED Ptr (the return-borrow guard), so any Ptr-typed statement result is
            // an un-closed handle. (Linearity is value-based, not just binding-based.)
            if (et == TY_PTR && !c->unreachable) {
                diag_error(diag_src(c), s->line, s->col,
                           "this 'Ptr' handle is opened but immediately discarded — it leaks", NULL,
                           "bind it to a local and close it (e.g. `let f = …` then `fclose(f)`), or "
                           "pass it by `move` to a call that takes ownership");
                c->had_error = 1;
            }
            // If the discarded result is a fresh refcounted value (e.g. a bare
            // `recv(ch)`), release it rather than just popping the stack.
            s->as.expr.release_temp = is_owning_temp(c, s->as.expr.expr, et);
            break;
        }

        case STMT_FOR: {
            // `for i in lo..hi` — an integer counter — or `for x in array`, or
            // `for (i, x) in array` — the element with its index.
            SemType elem;
            Expr *iter = s->as.for_.iter;
            int enumerate = (s->as.for_.index_var != NULL);
            int is_range  = (iter->kind == EXPR_RANGE);
            if (iter->kind == EXPR_RANGE) {
                if (enumerate) {
                    type_error(c, s->line, s->col,
                               "'for (i, x)' iterates an array; a range already "
                               "yields the index — use 'for i in lo..hi'");
                }
                SemType lo = check_expr(c, iter->as.range.lo);
                SemType hi = check_expr(c, iter->as.range.hi);
                if ((lo != TY_ERROR && lo != TY_INT) ||
                    (hi != TY_ERROR && hi != TY_INT)) {
                    type_error(c, s->line, s->col,
                               "a range's bounds must be 'int'");
                }
                elem = TY_INT;
            } else {
                SemType it = check_expr(c, iter);
                if (!is_array_type(it) && !is_slice_type(it)) {
                    if (it != TY_ERROR) {
                        type_error(c, s->line, s->col,
                                   "'for' iterates over an array, a slice, or an integer range");
                    }
                    break;
                }
                elem = is_slice_type(it) ? slice_elem(c, it) : array_elem(c, it);
            }
            // The body runs repeatedly, so moving an outer binding inside it is an
            // error (it would move again next iteration) — same rule as `loop`.
            int *pre = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            snapshot_moved(c, pre);
            c->scope_depth++;
            c->loop_depth++;
            int saved = c->local_count;
            // Declare locals in EXACTLY codegen's slot order (including its hidden
            // temporaries), so checker and codegen slot numbers agree — a lambda in
            // the body captures by the checker's slots and codegen reads them back.
            //   range:  [i = index]  [end]
            //   array:  [array]  [index | i]  [length]  [element x]
            // The loop variables are immutable; an array element borrows the array.
            if (is_range) {
                declare_local(c, s->line, s->col, s->as.for_.var, 0, TY_INT, 0);  // i
                reserve_hidden_slot(c);                                            // end
            } else {
                reserve_hidden_slot(c);                                            // array
                if (enumerate) {
                    declare_local(c, s->line, s->col, s->as.for_.index_var, 0,
                                  TY_INT, 0);                                       // i
                } else {
                    reserve_hidden_slot(c);                                        // index
                }
                reserve_hidden_slot(c);                                            // length
                declare_local(c, s->line, s->col, s->as.for_.var, 0, elem, 0);     // x
            }
            // OFI-049: a `break`/`continue` here scans body-local handles ([loop_local_base, n)). A
            // `for` ALSO exits normally (the range/array ends), and that path can't credit a
            // break-consume — so loop_break_consumed is NULL (a break doesn't feed an outer `loop`'s
            // merge). The loop variables above aren't owned handles, so the base may sit after them.
            int for_saved_base = c->loop_local_base;
            int *for_saved_bc  = c->loop_break_consumed;
            int for_saved_seen = c->loop_break_seen;
            int *for_saved_be  = c->loop_backedge_moved;
            int *for_bem = arena_alloc(c->arena, (size_t)(c->local_count + 1) * sizeof(int));
            for (int i = 0; i < c->local_count; i++) {
                for_bem[i] = 0;   // OFI-074: back-edge move-accumulator for this `for` (see STMT_LOOP)
            }
            c->loop_local_base     = c->local_count;
            c->loop_break_consumed = NULL;
            c->loop_break_seen     = 0;
            c->loop_backedge_moved = for_bem;
            int for_unreach = c->unreachable;
            for (size_t i = 0; i < s->as.for_.body.count; i++) {
                check_stmt(c, s->as.for_.body.stmts[i]);
                if (stmt_diverges(s->as.for_.body.stmts[i])) { c->unreachable = 1; }
            }
            c->unreachable = for_unreach;
            // The body-end is a back-edge iff reachable (the body can fall through and re-iterate).
            if (!block_diverges(&s->as.for_.body)) {
                for (int i = 0; i < c->loop_local_base; i++) {
                    if (c->locals[i].moved) {
                        for_bem[i] = 1;
                    }
                }
            }
            c->loop_local_base     = for_saved_base;
            c->loop_break_consumed = for_saved_bc;
            c->loop_break_seen     = for_saved_seen;
            c->loop_backedge_moved = for_saved_be;
            drop_locals(c, saved);   // body bindings are freed each iteration
            c->local_count = saved;
            c->loop_depth--;
            c->scope_depth--;
            // OFI-074: report only moves that can REACH a back-edge (recur), not a move on a path
            // that breaks/returns out of the `for`. `for_bem` is that set.
            for (int i = 0; i < c->local_count; i++) {
                if (!pre[i] && for_bem[i]) {
                    type_error(c, s->line, s->col,
                               "value moved inside a 'for' body (it would be moved "
                               "again on the next iteration)");
                }
            }
            break;
        }

        case STMT_NURSERY:
            // A structured task group. Its body is an ordinary scope; `spawn`s
            // inside it are joined when the block ends (so any data they borrow
            // from the enclosing scope outlives them — safe by construction).
            c->nursery_depth++;
            check_block(c, &s->as.nursery.body);
            c->nursery_depth--;
            break;

        case STMT_SPAWN: {
            if (c->nursery_depth == 0) {
                type_error(c, s->line, s->col,
                           "'spawn' must appear inside a 'nursery' block");
            }
            Expr *call = s->as.spawn.call;
            int sfi = -1;
            if (call->kind == EXPR_CALL) {
                Expr *callee = call->as.call.callee;
                if (callee->kind == EXPR_IDENT) {
                    sfi = resolve_signature(c, callee->as.ident);
                } else if (callee->kind == EXPR_GET &&
                           callee->as.get.object->kind == EXPR_IDENT &&
                           resolve_local(c, callee->as.get.object->as.ident) < 0) {
                    // A module-qualified target: `spawn api.worker(args)`. Resolved exactly like a
                    // qualified direct call (a public function of the imported module); check_expr
                    // below caches resolved_fn/witnesses on the node, which both backends read.
                    int reason = 0;
                    sfi = resolve_qualified_fn(c, callee->as.get.object->as.ident,
                                               callee->as.get.name, &reason);
                }
            }
            if (sfi < 0) {
                type_error(c, s->line, s->col,
                           "'spawn' requires a call to a named function");
            } else if (c->fns[sfi].cextern_index >= 0 || c->fns[sfi].direct_extern) {
                type_error(c, s->line, s->col,
                           "cannot 'spawn' a foreign (extern \"c\") function");
            }
            check_expr(c, call);   // type-check args + apply ownership (move/borrow)
            break;
        }
    }
}





static int  enter_type_params(Checker *c, const GenericParam *gp, size_t count,
                              const char **buf);
static void leave_type_params(Checker *c);


// ---- Lambda lifting: capture analysis, then synthesis into a real function ----

// A free-variable walk over a lambda body. `bound` holds the names bound *within*
// the lambda (its parameters plus inner let/for/match bindings, lexically scoped);
// any identifier that is not bound there but resolves to an enclosing local is a
// capture — a value the closure copies in by value.
typedef struct {
    Checker    *c;
    const char *bound[256];
    int         bound_count;
    const char *cap_names[EMBER_MAX_CAPTURES];
    int         cap_slots[EMBER_MAX_CAPTURES];
    SemType     cap_types[EMBER_MAX_CAPTURES];
    int         cap_count;
    int         overflow;
} FVCtx;


static void fv_expr(FVCtx *f, const Expr *e);
static void fv_block(FVCtx *f, const Block *b);


static int fv_is_bound(FVCtx *f, const char *name) {
    for (int i = 0; i < f->bound_count; i++) {
        if (strcmp(f->bound[i], name) == 0) {
            return 1;
        }
    }
    return 0;
}


static void fv_push_bound(FVCtx *f, const char *name) {
    if (name != NULL &&
        f->bound_count < (int)(sizeof(f->bound) / sizeof(f->bound[0]))) {
        f->bound[f->bound_count++] = name;
    }
}


static void fv_use(FVCtx *f, const char *name) {
    if (name == NULL || fv_is_bound(f, name)) {
        return;
    }
    int slot = resolve_local(f->c, name);
    if (slot < 0) {
        return;   // a global function/variant/builtin — not a captured local
    }
    for (int i = 0; i < f->cap_count; i++) {
        if (strcmp(f->cap_names[i], name) == 0) {
            return;   // already captured
        }
    }
    if (f->cap_count >= EMBER_MAX_CAPTURES) {
        f->overflow = 1;
        return;
    }
    f->cap_names[f->cap_count] = name;
    f->cap_slots[f->cap_count] = slot;
    f->cap_types[f->cap_count] = f->c->locals[slot].type;
    f->cap_count++;
}


static void fv_stmt(FVCtx *f, const Stmt *s) {
    switch (s->kind) {
        case STMT_LET:
            if (s->as.let.value != NULL) {
                fv_expr(f, s->as.let.value);
            }
            fv_push_bound(f, s->as.let.name);   // bound for the rest of this block
            break;
        case STMT_RETURN:
            if (s->as.ret.value != NULL) {
                fv_expr(f, s->as.ret.value);
            }
            break;
        case STMT_EXPR:
            fv_expr(f, s->as.expr.expr);
            break;
        case STMT_ASSIGN:
            fv_expr(f, s->as.assign.target);
            fv_expr(f, s->as.assign.value);
            break;
        case STMT_IF:
            fv_expr(f, s->as.if_.cond);
            fv_block(f, &s->as.if_.then_blk);
            if (s->as.if_.else_branch != NULL) {
                fv_stmt(f, s->as.if_.else_branch);
            }
            break;
        case STMT_FOR: {
            fv_expr(f, s->as.for_.iter);
            int save = f->bound_count;
            fv_push_bound(f, s->as.for_.var);
            fv_block(f, &s->as.for_.body);
            f->bound_count = save;
            break;
        }
        case STMT_LOOP:
            fv_block(f, &s->as.loop.body);
            break;
        case STMT_MATCH:
            fv_expr(f, s->as.match.value);
            for (size_t i = 0; i < s->as.match.case_count; i++) {
                const MatchCase *mc = &s->as.match.cases[i];
                int save = f->bound_count;
                for (size_t b = 0; b < mc->pattern.binding_count; b++) {
                    fv_push_bound(f, mc->pattern.bindings[b]);
                }
                fv_block(f, &mc->body);
                f->bound_count = save;
            }
            break;
        case STMT_SPAWN:
            fv_expr(f, s->as.spawn.call);
            break;
        case STMT_NURSERY:
            fv_block(f, &s->as.nursery.body);
            break;
        case STMT_BLOCK:
            fv_block(f, &s->as.block.body);
            break;
        case STMT_BREAK:
        case STMT_CONTINUE:
            break;
    }
}


static void fv_block(FVCtx *f, const Block *b) {
    int save = f->bound_count;
    for (size_t i = 0; i < b->count; i++) {
        fv_stmt(f, b->stmts[i]);
    }
    f->bound_count = save;   // block-scoped bindings expire at the closing brace
}


static void fv_expr(FVCtx *f, const Expr *e) {
    if (e == NULL) {
        return;
    }
    switch (e->kind) {
        case EXPR_IDENT:
            fv_use(f, e->as.ident);
            break;
        case EXPR_UNARY:
            fv_expr(f, e->as.unary.operand);
            break;
        case EXPR_BINARY:
            fv_expr(f, e->as.binary.left);
            fv_expr(f, e->as.binary.right);
            break;
        case EXPR_RANGE:
            fv_expr(f, e->as.range.lo);
            fv_expr(f, e->as.range.hi);
            break;
        case EXPR_CALL:
            fv_expr(f, e->as.call.callee);
            for (size_t i = 0; i < e->as.call.arg_count; i++) {
                fv_expr(f, e->as.call.args[i]);
            }
            break;
        case EXPR_GET:
            fv_expr(f, e->as.get.object);
            break;
        case EXPR_INDEX:
            fv_expr(f, e->as.index.object);
            fv_expr(f, e->as.index.index);
            break;
        case EXPR_ARRAY:
            for (size_t i = 0; i < e->as.array.count; i++) {
                fv_expr(f, e->as.array.elems[i]);
            }
            break;
        case EXPR_STRUCT_LIT:
            for (size_t i = 0; i < e->as.struct_lit.field_count; i++) {
                fv_expr(f, e->as.struct_lit.fields[i].value);
            }
            break;
        case EXPR_TRY:
            fv_expr(f, e->as.try_.operand);
            break;
        case EXPR_STRING:
            for (size_t i = 0; i < e->as.str.part_count; i++) {
                if (e->as.str.parts[i].expr != NULL) {
                    fv_expr(f, e->as.str.parts[i].expr);
                }
            }
            break;
        case EXPR_LAMBDA: {
            // A nested lambda: its params are bound; an enclosing local it uses must
            // be captured by THIS lambda too, so it can be handed down.
            int save = f->bound_count;
            for (size_t i = 0; i < e->as.lambda.param_count; i++) {
                fv_push_bound(f, e->as.lambda.params[i].name);
            }
            fv_block(f, &e->as.lambda.body);
            f->bound_count = save;
            break;
        }
        case EXPR_INT:
        case EXPR_FLOAT:
        case EXPR_BOOL:
        case EXPR_FN_VALUE:
            break;
    }
}


// check_lambda lifts a lambda to a synthetic top-level function and returns its
// `fn(params) -> ret` type. The lifted function's parameters are the captured
// variables (by value) followed by the lambda's own parameters; codegen builds the
// closure by pushing the captured locals and OP_MAKE_CLOSURE. The lambda must appear
// where a function type is expected, so its parameter and result types are known.
static SemType check_lambda(Checker *c, Expr *e, SemType expected) {
    int np = (int)e->as.lambda.param_count;
    if (np > MAX_PARAMS) {
        type_error(c, e->line, e->col, "a lambda has too many parameters");
        return TY_ERROR;
    }
    FnType *eft = is_fn_type(expected) ? fn_type_of(c, expected) : NULL;
    if (eft != NULL && eft->param_count != np) {
        eft = NULL;   // arity mismatch — fall through to the clear error below
    }
    if (eft == NULL) {
        type_error(c, e->line, e->col,
                   "a lambda needs a function-typed context (a parameter of function "
                   "type, or a `let x: fn(..) -> ..`) so its types are known");
        return TY_ERROR;
    }
    SemType ptypes[MAX_PARAMS];
    for (int i = 0; i < np; i++) {
        Param *p = &e->as.lambda.params[i];
        c->allow_slice = 1;   // a lambda parameter may be a Slice<T>
        ptypes[i] = p->type != NULL ? annotation_type(c, p->type) : eft->params[i];
    }
    SemType ret = eft->ret;

    // Capture analysis over the body, against the current (enclosing) scope.
    FVCtx f;
    f.c = c;
    f.bound_count = 0;
    f.cap_count = 0;
    f.overflow = 0;
    for (int i = 0; i < np; i++) {
        fv_push_bound(&f, e->as.lambda.params[i].name);
    }
    fv_block(&f, &e->as.lambda.body);
    if (f.overflow) {
        type_error(c, e->line, e->col, "a lambda captures too many variables");
        return TY_ERROR;
    }
    // Captures are by value: scalars copy, refcounted values (strings, enums,
    // function values) share via their refcount. A unique owner (struct/array)
    // can do neither — the closure's copy would alias the caller's and both would
    // free it. Until captures can deep-copy, reject those with a clear error.
    for (int i = 0; i < f.cap_count; i++) {
        if (f.cap_types[i] == TY_PTR) {
            // OFI-049: a captured `Ptr` would be copied (aliased) into the closure, and the close
            // obligation would escape the scope that opened it — neither is sound for a linear handle.
            type_error(c, e->line, e->col,
                       "a lambda cannot capture a 'Ptr' handle — it is a linear FFI resource that "
                       "must be closed in the scope that owns it; pass it as a 'move' parameter");
            return TY_ERROR;
        }
        if (is_move_type(c, f.cap_types[i])) {
            type_error(c, e->line, e->col,
                       "a lambda cannot capture a struct or array yet — pass it "
                       "as a parameter instead");
            return TY_ERROR;
        }
    }
    int cc = f.cap_count;
    if (c->lambda_count >= EMBER_MAX_LAMBDAS) {
        type_error(c, e->line, e->col, "too many lambdas in one program");
        return TY_ERROR;
    }
    int fn_index = c->base_fn_count + c->lambda_count;

    // Synthesize the lifted function: params = [captures..., lambda params...].
    int total = cc + np;
    Param *lp = arena_alloc(c->arena, sizeof(Param) * (total > 0 ? total : 1));
    for (int i = 0; i < cc; i++) {
        lp[i].qual            = OWN_NONE;
        lp[i].is_self         = 0;
        lp[i].name            = f.cap_names[i];
        lp[i].type            = NULL;
        lp[i].release_at_exit = is_refcounted(c, f.cap_types[i]);
        lp[i].inline_struct_id = -1;   // a lifted-lambda param is always boxed (3b.4)
    }
    for (int i = 0; i < np; i++) {
        lp[cc + i]                 = e->as.lambda.params[i];
        lp[cc + i].qual            = OWN_NONE;
        lp[cc + i].is_self         = 0;
        lp[cc + i].release_at_exit = is_refcounted(c, ptypes[i]);
        lp[cc + i].inline_struct_id = -1;   // closures dispatch boxed — never multi-slot
    }
    Decl *ld = arena_alloc(c->arena, sizeof(Decl));
    ld->kind                = DECL_FN;
    ld->line                = e->line;
    ld->col                 = e->col;
    ld->doc                 = NULL;   // arena is not zeroed; a lifted lambda carries no
                                      // doc comment, and this decl is appended to
                                      // program->decls (read by docgen/LSP) — leaving doc
                                      // uninitialised derefs a wild pointer (OFI-026 class).
    ld->as.fn.name          = "<lambda>";
    ld->as.fn.generics      = NULL;
    ld->as.fn.generic_count = 0;
    ld->as.fn.params        = lp;
    ld->as.fn.param_count   = (size_t)total;
    ld->as.fn.return_type   = NULL;
    ld->as.fn.ret_struct_id = -1;        // closures dispatch boxed — never multi-slot return
    ld->as.fn.requires_clauses = NULL;   // lambdas carry no contracts
    ld->as.fn.requires_count   = 0;
    ld->as.fn.ensures_clauses  = NULL;
    ld->as.fn.ensures_count    = 0;
    ld->as.fn.has_body      = 1;
    ld->as.fn.body          = e->as.lambda.body;
    ld->as.fn.line          = e->line;
    ld->as.fn.col           = e->col;
    ld->as.fn.src_path      = diag_src(c);   // OFI-111a: the lambda's defining module (it lands
                                             // outside every ModuleSet range, so module_of_decl
                                             // would mis-map it to the entry file).
    c->lambda_decls[c->lambda_count++] = ld;

    e->as.lambda.lifted_fn_index = fn_index;
    e->as.lambda.capture_count   = cc;
    for (int i = 0; i < cc; i++) {
        e->as.lambda.capture_slots[i] = f.cap_slots[i];
    }

    // Check the body as the lifted function: a fresh scope of captures + params,
    // with the enclosing scope saved and restored around it (the body sees only its
    // own captures and parameters, plus globals — not the enclosing function's locals).
    int     saved_count  = c->local_count;
    Local  *saved_locals = arena_alloc(c->arena, (size_t)(saved_count + 1) * sizeof(Local));
    int     saved_scope  = c->scope_depth;
    int     saved_loop   = c->loop_depth;
    SemType saved_return = c->current_return;
    int     saved_ret_sid = c->current_ret_struct_id;
    const char **saved_tp = c->tparams;
    int     saved_tpc    = c->tparam_count;
    for (int i = 0; i < saved_count; i++) {
        saved_locals[i] = c->locals[i];
    }
    // When the expected result type is still an unbound type parameter (a lambda
    // passed to a generic HOF, e.g. `map`'s `fn(T) -> U`), infer the result from the
    // body instead of checking against it.
    int     infer_ret      = is_type_param(ret);
    SemType saved_inferred = c->inferred_return;
    c->local_count    = 0;
    c->scope_depth    = 0;
    c->loop_depth     = 0;
    c->loop_backedge_moved = NULL;   // OFI-074: no loop back-edge accumulator outside a loop
    c->unreachable    = 0;   // OFI-049: each function body starts reachable
    c->tparams        = NULL;
    c->tparam_count   = 0;
    c->current_return = infer_ret ? TY_INFER : ret;
    c->current_ret_struct_id = -1;   // a lambda returns boxed (closures dispatch boxed)
    c->inferred_return = TY_ERROR;
    for (int i = 0; i < cc; i++) {
        declare_local(c, e->line, e->col, f.cap_names[i], 0, f.cap_types[i], 0);
    }
    for (int i = 0; i < np; i++) {
        declare_local(c, e->line, e->col, e->as.lambda.params[i].name, 0,
                      ptypes[i], 0);
    }
    for (size_t i = 0; i < e->as.lambda.body.count; i++) {
        check_stmt(c, e->as.lambda.body.stmts[i]);
    }
    drop_locals(c, 0);
    if (infer_ret) {
        ret = c->inferred_return != TY_ERROR ? c->inferred_return : TY_UNIT;
    }

    c->local_count    = saved_count;
    for (int i = 0; i < saved_count; i++) {
        c->locals[i] = saved_locals[i];
    }
    c->scope_depth     = saved_scope;
    c->loop_depth      = saved_loop;
    c->current_return  = saved_return;
    c->current_ret_struct_id = saved_ret_sid;
    c->tparams         = saved_tp;
    c->tparam_count    = saved_tpc;
    c->inferred_return = saved_inferred;

    return intern_fn_type(c, ptypes, np, ret);
}


// --- Definite-return analysis (OFI-029) -------------------------------------------------
// A `-> T` function must return a value on every path. These walk the body's control flow to
// decide whether a statement/block ALWAYS leaves the function (a `return`) or never falls
// through (an infinite `loop` with no exiting `break`). A non-unit function whose body does
// not is rejected, so the codegen fall-off `return 0` becomes truly dead (no silent garbage).

static int block_returns(const Block *b);

// loop_exit_break reports whether a loop body contains a `break` that exits THIS loop — one
// not enclosed by a nested loop/for (whose break targets the inner loop). Used to tell an
// infinite, never-exiting `loop` (which diverges) from one that can fall through.
static int loop_exit_break(const Block *b);

static int stmt_exit_break(const Stmt *s) {
    switch (s->kind) {
        case STMT_BREAK:   return 1;
        case STMT_BLOCK:   return loop_exit_break(&s->as.block.body);
        case STMT_NURSERY: return loop_exit_break(&s->as.nursery.body);
        case STMT_IF:
            if (loop_exit_break(&s->as.if_.then_blk)) {
                return 1;
            }
            return s->as.if_.else_branch != NULL && stmt_exit_break(s->as.if_.else_branch);
        case STMT_MATCH:
            for (size_t i = 0; i < s->as.match.case_count; i++) {
                if (loop_exit_break(&s->as.match.cases[i].body)) {
                    return 1;
                }
            }
            return 0;
        case STMT_LOOP:
        case STMT_FOR:
            return 0;   // a break in here targets that nested loop, not ours
        default:
            return 0;
    }
}

static int loop_exit_break(const Block *b) {
    for (size_t i = 0; i < b->count; i++) {
        if (stmt_exit_break(b->stmts[i])) {
            return 1;
        }
    }
    return 0;
}

static int stmt_returns(const Stmt *s) {
    switch (s->kind) {
        case STMT_RETURN:
            return 1;
        case STMT_BLOCK:
            return block_returns(&s->as.block.body);
        case STMT_IF:
            // Both arms must return; an `if` with no `else` can fall through.
            return s->as.if_.else_branch != NULL &&
                   block_returns(&s->as.if_.then_blk) &&
                   stmt_returns(s->as.if_.else_branch);
        case STMT_MATCH:
            // Exhaustive (checker-enforced) and every arm returns.
            if (s->as.match.case_count == 0) {
                return 0;
            }
            for (size_t i = 0; i < s->as.match.case_count; i++) {
                if (!block_returns(&s->as.match.cases[i].body)) {
                    return 0;
                }
            }
            return 1;
        case STMT_LOOP:
            // An infinite loop with no exiting break never falls through — it diverges.
            return !loop_exit_break(&s->as.loop.body);
        default:
            return 0;   // let/assign/expr/for/spawn/nursery/break/continue
    }
}

static int block_returns(const Block *b) {
    // A block returns if any statement does — the rest is then unreachable.
    for (size_t i = 0; i < b->count; i++) {
        if (stmt_returns(b->stmts[i])) {
            return 1;
        }
    }
    return 0;
}


// check_callable checks a function or method body. `self_type` is the type of a
// method's implicit `self` — a struct id, or a generic instance like Box<T> for a
// method on a generic struct — or -1 for a free function (where `self` is an
// error). `tparams`/`tparam_count` are the type parameters in scope: a free
// function's own (`fn id<T>`), or the enclosing struct's (for a method).
static void check_callable(Checker *c, const FnDecl *fn, SemType self_type,
                           const char **tparams, int tparam_count) {
    c->tparams      = tparam_count > 0 ? tparams : NULL;
    c->tparam_count = tparam_count;
    // When checking a METHOD body, the type parameters in scope are the owning struct's,
    // and a bounded one's witness lives in a self field (instance-storage). Record the
    // owning struct so a `key.hash()` call knows to read the witness from `self`.
    if (is_struct_type(self_type)) {
        c->self_struct = self_type;                                   // non-generic struct method
    } else if (is_generic_inst(self_type)) {
        c->self_struct = c->ginsts[self_type - GENERIC_BASE].base;    // generic struct: base id
    } else {
        c->self_struct = -1;                                          // a free function
    }
    // Record each type parameter's bound (interface id) so a bounded `T` can have the
    // interface's methods called on it in the body — from a free function's own generics,
    // or (in a method) from the owning struct's generic bounds.
    for (int i = 0; i < tparam_count; i++) {
        c->tparam_bound_count[i] = 0;
        c->tparam_is_copy[i]     = 0;
    }
    if (self_type < 0) {
        for (size_t i = 0; i < fn->generic_count && (int)i < tparam_count; i++) {
            for (int b = 0; b < fn->generics[i].bound_count; b++) {
                int iid = resolve_interface_id(c, fn->generics[i].bounds[b]);
                if (iid >= 0) {
                    c->tparam_bounds[i][c->tparam_bound_count[i]++] = iid;
                }
            }
            c->tparam_is_copy[i] = fn->generics[i].is_copy;
        }
    } else if (c->self_struct >= 0) {
        StructInfo *si = &c->structs[c->self_struct];
        for (int i = 0; i < si->generic_count && i < tparam_count; i++) {
            for (int b = 0; b < si->bound_count[i]; b++) {
                c->tparam_bounds[i][c->tparam_bound_count[i]++] = si->bounds[i][b];
            }
        }
    }
    if (fn->return_type == NULL) {
        // No `-> T` means a unit function: it runs for effect and yields no value.
        c->current_return = TY_UNIT;
    } else {
        c->current_return = resolve_self(annotation_type(c, fn->return_type), self_type);
        if (c->current_return == TY_ERROR) {
            type_error(c, fn->line, fn->col,
                       "return type must be 'int', 'bool', a struct/enum, or a "
                       "type parameter");
        }
    }
    // A non-generic FREE function returning an all-scalar struct returns it MULTI-SLOT
    // (value-types 3b.4b): the callee moves its N field slots into the caller's frame
    // instead of a boxed object. A free function (self_type < 0) or a method on a NON-generic
    // struct (self_type is a plain struct id, not a Box<T> instance) qualifies; generic-struct
    // methods and generic functions keep boxed returns (their call sites need no per-instance
    // convention). (value-types 3b.4d — methods)
    int multislot_eligible =
        (self_type < 0) ||
        (is_struct_type(self_type) && !method_is_interface_impl(c, self_type, fn->name));
    ((FnDecl *)fn)->ret_struct_id =
        multislot_eligible ? ret_multislot_sid(c, c->current_return, (int)fn->generic_count)
                           : -1;
    c->current_ret_struct_id = fn->ret_struct_id;

    c->local_count = 0;   // each function starts with a fresh scope
    c->scope_depth = 0;
    c->loop_depth  = 0;
    c->unreachable = 0;   // OFI-100: each function body starts reachable (don't inherit a prior fn's diverging return)

    // Parameters become the function's first locals. A plain parameter is an
    // immutable borrow; `mut`/`move` make it a mutable place (its fields may be
    // mutated, and `move` also takes ownership). `mut self` follows the same rule.
    for (size_t i = 0; i < fn->param_count; i++) {
        const Param *param = &fn->params[i];
        int mutable_place = (param->qual == OWN_MUT || param->qual == OWN_MOVE);
        int owned         = (param->qual == OWN_MOVE);   // borrows unless `move`
        if (param->is_self) {
            if (self_type < 0) {
                type_error(c, fn->line, fn->col,
                           "'self' is only valid as a method's first parameter");
            } else {
                declare_local(c, fn->line, fn->col, "self", mutable_place,
                              self_type, owned);
            }
            continue;
        }
        c->allow_slice = 1;   // a method parameter may be a Slice<T>
        SemType pt = resolve_self(annotation_type(c, param->type), self_type);
        if (pt == TY_ERROR) {
            type_error(c, fn->line, fn->col,
                       "parameter types must be 'int', 'bool', a struct/enum, or "
                       "a type parameter");
        }
        // A parameter the callee *owns* is released when the function returns: a
        // refcounted one (string/array/enum) drops its reference, and a `move`
        // struct is freed. The matching transfer happens at the call site — a
        // refcounted argument is consumed (aliased → incref'd, temporary → adopted),
        // and a `move` argument nils the caller's binding. If the body moves the
        // parameter out (returns it, passes it on), its slot is nilled, so the
        // release becomes a no-op there.
        fn->params[i].release_at_exit =
            is_refcounted(c, pt) || (owned && is_move_type(c, pt) && pt != TY_PTR);
        declare_local(c, fn->line, fn->col, param->name, mutable_place, pt, owned);
        c->locals[c->local_count - 1].is_param = 1;   // semantic index: label as a parameter
        // A plain all-scalar struct EXPLICIT parameter of a free function or a non-generic
        // struct method is stored MULTI-SLOT, exactly like a multi-slot let local — its fields
        // read from slots and a whole-value read boxes on use (value-types 3b.4). Generic
        // functions/structs and mut/move params keep boxed parameters. (`self` itself stays
        // boxed for now — the receiver-push is a later brick.)
        int psid = multislot_eligible
                       ? param_multislot_sid(c, pt, param->qual, (int)fn->generic_count)
                       : -1;
        fn->params[i].inline_struct_id = psid;
        if (psid >= 0 && c->local_count > 0) {
            c->locals[c->local_count - 1].multislot_sid = psid;
        }
    }

    // Contracts (MANIFESTO §5e). A `requires` clause is a bool predicate over the
    // parameters, checked on entry; verify each types to bool with the params in
    // scope. (`ensures` needs the `result` binding — it lands in the next slice.)
    for (size_t i = 0; i < fn->requires_count; i++) {
        Expr *clause = fn->requires_clauses[i];
        SemType t = check_expr(c, clause);
        if (t != TY_BOOL && t != TY_ERROR) {
            type_error(c, clause->line, clause->col,
                       "a 'requires' clause must be a bool expression");
        }
    }
    // An `ensures` clause is a bool predicate over the parameters and `result` (the
    // return value), checked before every return. Bind `result` to the return type
    // for the duration of the check. A unit function has no value to bind.
    //
    // NOTE (OFI-026, CLOSED 2026-06-13): `ensures` on a unit-returning function IS
    // allowed — a void `mut self` mutator may state a postcondition on its own state
    // (std/ui.em's `begin(mut self) ensures self.cx == self.style.pad` relies on it).
    // Enabling it once surfaced an order-dependent corruption of cross-module call
    // resolution, but the root cause was an uninitialised `closure_call` field in
    // `new_expr` (the arena does not zero memory), NOT the contract check itself —
    // fixed, so unit `ensures` is sound. Below: bind `result` only for value returns.
    if (fn->ensures_count > 0) {
        int saved = c->local_count;
        if (c->current_return != TY_UNIT) {
            declare_local(c, fn->line, fn->col, "result", 0, c->current_return, 0);
        }
        for (size_t i = 0; i < fn->ensures_count; i++) {
            Expr *clause = fn->ensures_clauses[i];
            SemType t = check_expr(c, clause);
            if (t != TY_BOOL && t != TY_ERROR) {
                type_error(c, clause->line, clause->col,
                           "an 'ensures' clause must be a bool expression");
            }
        }
        c->local_count = saved;   // 'result' (if bound) leaves scope
    }

    // OFI-122: detect a `resource struct`'s `drop` body and arm the handle-field carve-out + leak
    // scan (after self is declared + contracts checked, before the body; cleared after it below).
    c->in_resource_drop   = 0;
    c->drop_self_struct   = -1;
    c->drop_self_slot     = -1;
    c->drop_self_consumed = 0;
    c->drop_self_ptr_mask = 0;
    if (c->self_struct >= 0 && c->structs[c->self_struct].is_resource &&
        fn->name != NULL && strcmp(fn->name, "drop") == 0) {
        c->in_resource_drop = 1;
        c->drop_self_struct = c->self_struct;
        for (int i = 0; i < c->local_count; i++) {
            if (c->locals[i].name != NULL && strcmp(c->locals[i].name, "self") == 0) {
                c->drop_self_slot = i;
                break;
            }
        }
        StructInfo *rsi = &c->structs[c->self_struct];
        int bit = 0;
        for (int f = 0; f < rsi->field_count; f++) {
            if (rsi->fields[f].type == TY_PTR) {
                if (bit < 31) { c->drop_self_ptr_mask |= (1 << bit); }
                bit++;
            }
        }
    }
    for (size_t i = 0; i < fn->body.count; i++) {
        check_stmt(c, fn->body.stmts[i]);
        if (stmt_diverges(fn->body.stmts[i])) {
            c->unreachable = 1;   // OFI-049: code after a top-level return/diverging if is dead
        }
    }
    drop_locals(c, 0);   // function-body bindings leave scope at the closing brace
    // OFI-122: on the fall-through exit of a `resource` drop, every handle field must be closed too.
    if (c->in_resource_drop) {
        report_unconsumed_drop_fields(c, fn->line, fn->col);
        c->in_resource_drop = 0;
    }
    // Definite-return (OFI-029): a `-> T` function must return on every path, else the
    // codegen fall-off would yield a silent garbage value. Unit functions may fall off.
    if (fn->has_body && c->current_return != TY_UNIT && c->current_return != TY_ERROR &&
        !block_returns(&fn->body)) {
        type_error(c, fn->line, fn->col,
                   "not every path returns a value (a function with a return type must "
                   "return on every path)");
    }
    leave_type_params(c);
}





// enter_type_params puts a callable's type-parameter *names* in scope (so `T`
// resolves to TY_PARAM while its signature/body are checked), copying them into
// the caller-owned `buf` (which must outlive the scope). Bounds are resolved
// separately (collect_signature validates them; check_callable records them).
// Returns the parameter count.
static int enter_type_params(Checker *c, const GenericParam *gp, size_t count,
                             const char **buf) {
    int n = 0;
    for (size_t i = 0; i < count && n < MAX_TYPE_ARGS; i++) {
        buf[n++] = gp[i].name;
    }
    c->tparams      = n > 0 ? buf : NULL;
    c->tparam_count = n;
    return n;
}





static void leave_type_params(Checker *c) {
    c->tparams      = NULL;
    c->tparam_count = 0;
}





// type_name_taken reports whether `name` is already registered as a struct or
// enum in `module`. Type names are module-scoped, so different modules may reuse a
// name; within one module a clash is rejected (OFI-008) instead of silently
// binding every reference to the first declaration.
static int type_name_taken(Checker *c, const char *name, int module) {
    for (int i = 0; i < c->struct_count; i++) {
        if (c->structs[i].module == module &&
            strcmp(c->structs[i].name, name) == 0) {
            return 1;
        }
    }
    for (int i = 0; i < c->enum_count; i++) {
        if (c->enums[i].module == module &&
            strcmp(c->enums[i].name, name) == 0) {
            return 1;
        }
    }
    return 0;
}






// collect_signature records a function's parameter and return types so calls to
// it (including forward and recursive calls) can be checked in pass 2. Type
// errors in the signature itself are reported later by check_fn, so this stays
// quiet and just records what it finds (TY_ERROR for anything out of slice).
static void collect_signature(Checker *c, const FnDecl *fn) {
    ensure_fns_cap(c, c->fn_count + 1);
    // Reject a free function whose name is a numeric type (OFI-066): a call `i32(x)` is parsed
    // as a width conversion before free-function resolution, so the function would be permanently
    // unreachable — silently, when the argument happens to type-check as the conversion. Surface it
    // as an error instead. (A local `let i32 = …` is fine — locals resolve before the conversion;
    // and a method `x.i32()` uses different syntax, so this only reserves FREE-function names.)
    if (numeric_typename(fn->name) != TY_ERROR) {
        type_error(c, fn->line, fn->col,
                   "a function cannot be named like a numeric type (i8/i16/i32/i64/int/"
                   "u8/u16/u32/u64/f32/f64): a call to it would parse as a width conversion "
                   "and never reach the function (OFI-066) — rename it");
    }
    if (fn->name[0] == '_' && fn->name[1] == '\0') {
        // `_` is the discard, not a name — a function named `_` could never be called (OFI-098).
        type_error(c, fn->line, fn->col,
                   "a function cannot be named '_' — it is the write-only discard, not a usable name");
    }
    // Reject a second top-level function of the same name in this module (OFI-008);
    // otherwise every call would silently bind to the first and the rest is dead.
    for (int i = 0; i < c->fn_count; i++) {
        if (c->fns[i].module == c->current_module &&
            strcmp(c->fns[i].name, fn->name) == 0) {
            type_error(c, fn->line, fn->col,
                       "a function with this name is already declared in this module");
            break;
        }
    }
    FnSig *sig = &c->fns[c->fn_count++];
    sig->decl          = fn;          // for LSP hover/go-to-def on free-function references
    // Type parameters are in scope while resolving the signature (e.g. `x: T`).
    const char *names[MAX_TYPE_ARGS];
    int gcount = enter_type_params(c, fn->generics, fn->generic_count, names);
    sig->name          = fn->name;
    sig->generic_count = gcount;
    // Resolve and validate every bound on each type parameter (T: Hash + Eq).
    for (int i = 0; i < gcount; i++) {
        sig->bound_count[i] = 0;
        sig->is_copy[i]     = fn->generics[i].is_copy;
        for (int b = 0; b < fn->generics[i].bound_count; b++) {
            int iid = resolve_interface_id(c, fn->generics[i].bounds[b]);
            if (iid < 0) {
                type_error(c, fn->line, fn->col,
                           "unknown interface in a generic bound");
            }
            sig->bounds[i][sig->bound_count[i]++] = iid;
        }
    }
    sig->param_count   = 0;
    for (size_t i = 0; i < fn->param_count && sig->param_count < MAX_PARAMS; i++) {
        const Param *p = &fn->params[i];
        sig->quals[sig->param_count]    = p->qual;
        c->allow_slice = 1;   // a function parameter may be a Slice<T>
        sig->params[sig->param_count++] =
            p->is_self ? TY_ERROR : annotation_type(c, p->type);
    }
    sig->ret = fn->return_type ? annotation_type(c, fn->return_type) : TY_UNIT;
    sig->cextern_index = -1;   // an ordinary Ember function (not a foreign C function)
    sig->direct_extern = 0;    // OFI-167: not an extern at all
    leave_type_params(c);
}


// extern_flatten appends the leaf kinds of `t` to `buf`. A scalar is one leaf ('f' float /
// 'i' int); an all-scalar struct flattens to its leaves recursively (3b.6, the C-ABI boundary
// is defined by the leaf sequence). The pointer kinds are each ONE leaf carried as the heap
// value itself, which the registry wrapper dereferences (§5h pointers): 'p' = a `string` passed
// as a borrowed `const char*`, 'b' = a packed scalar array (`[u8]`/`[i32]`/…) passed as a
// borrowed buffer (the wrapper reads its `data`+`length`), 'P' = an opaque `Ptr` handle. Returns
// 0 if `t` is none of these.
static int extern_flatten(Checker *c, SemType t, char *buf, int *n, int max) {
    if (*n >= max) {
        return 0;
    }
    if (is_scalar_type(t)) {
        buf[(*n)++] = is_float_type(t) ? 'f' : 'i';
        return 1;
    }
    if (t == TY_STRING) {                 // const char* (NUL-terminated ObjString.chars)
        buf[(*n)++] = 'p';
        return 1;
    }
    if (t == TY_PTR) {                     // opaque C handle (FILE*, void*, …)
        buf[(*n)++] = 'P';
        return 1;
    }
    if (is_array_type(t) && is_scalar_type(array_elem(c, t))) {
        // A packed scalar array stores its elements in a contiguous native buffer, so it
        // passes to C as a borrowed pointer with no marshalling. ([string]/[struct] are boxed
        // Value[] and are NOT a C buffer, so they are rejected — extern_flatten returns 0.)
        buf[(*n)++] = 'b';
        return 1;
    }
    if (nested_inline_sid(c, t) >= 0) {
        StructInfo *si = &c->structs[t];
        for (int f = 0; f < si->field_count; f++) {
            if (!extern_flatten(c, si->fields[f].type, buf, n, max)) {
                return 0;
            }
        }
        return 1;
    }
    return 0;
}


// collect_direct_extern registers an `extern "c"` function that is NOT in the hosted FFI registry
// (OFI-167). The native backend emits a DIRECT call to this C symbol (linker-resolved against a
// freestanding shim — the kernel/bare-metal path), so there is no registry index and no VM binding:
// such a program is native-only. The boundary here is deliberately narrow — every parameter and the
// return must be a scalar (i8..u64/f32/f64/bool) or an opaque `Ptr`. A `string`/buffer/struct
// crossing needs the registry's leaf marshalling (the `em_ffi` wrapper), which a direct call has
// no way to reassemble; those are rejected with a clear message rather than mis-compiled.
static void collect_direct_extern(Checker *c, const FnDecl *fn) {
    if (fn->generic_count != 0) {
        type_error(c, fn->line, fn->col, "an extern function cannot be generic");
    }
    FnSig *sig = &c->fns[c->fn_count++];
    sig->decl          = fn;   // for LSP hover/go-to-def on extern-function references
    sig->name          = fn->name;
    sig->generic_count = 0;
    sig->module        = c->current_module;
    sig->fn_index      = -1;   // no bytecode slot
    sig->cextern_index = -1;   // not in the registry
    sig->direct_extern = 1;    // native emits a direct call to sig->name
    int declared = 0;
    for (size_t p = 0; p < fn->param_count && declared < MAX_PARAMS; p++) {
        SemType pt = annotation_type(c, fn->params[p].type);
        OwnQual q  = fn->params[p].qual;
        // A direct-extern parameter is passed by value with no marshalling, so only a bare scalar
        // or a `Ptr` is allowed (a `move Ptr` handle keeps the linear consume semantics — the C
        // side takes ownership). `self`, `mut`, and any non-scalar/non-Ptr type are rejected.
        if (fn->params[p].is_self || (q == OWN_MUT) ||
            (q == OWN_MOVE && pt != TY_PTR) ||
            !(is_scalar_type(pt) || pt == TY_PTR)) {
            type_error(c, fn->line, fn->col,
                       "a direct extern parameter must be a scalar (i8..u64/f32/f64/bool) or a Ptr "
                       "handle; a string/buffer/struct argument needs a registry FFI entry");
        }
        sig->quals[declared]    = q;
        sig->params[declared++] = pt;
    }
    sig->param_count = declared;
    sig->ret = fn->return_type ? annotation_type(c, fn->return_type) : TY_UNIT;
    if (!(sig->ret == TY_UNIT || is_scalar_type(sig->ret) || sig->ret == TY_PTR)) {
        type_error(c, fn->line, fn->col,
                   "a direct extern must return a scalar, a Ptr, or nothing; a string/buffer/struct "
                   "return needs a registry FFI entry");
    }
}


// collect_extern registers the foreign (C) functions of an `extern "c"` block as call-able
// signatures (FFI, §5h). Each must name a function in the in-tree C registry and match its
// LEAF-scalar signature (scalars, or all-scalar structs flattened — 3b.6); it carries the
// registry index (cextern_index) and no bytecode slot.
static void collect_extern(Checker *c, const Decl *d) {
    if (strcmp(d->as.extern_.abi, "c") != 0) {
        type_error(c, d->line, d->col,
                   "only the \"c\" ABI is supported in an extern block");
        return;
    }
    for (size_t i = 0; i < d->as.extern_.fn_count; i++) {
        const FnDecl *fn = &d->as.extern_.fns[i];
        ensure_fns_cap(c, c->fn_count + 1);
        for (int j = 0; j < c->fn_count; j++) {
            if (c->fns[j].module == c->current_module &&
                strcmp(c->fns[j].name, fn->name) == 0) {
                type_error(c, fn->line, fn->col,
                           "a function with this name is already declared in this module");
                break;
            }
        }
        int cx = cextern_lookup(fn->name);
        if (cx < 0) {
            // OFI-167: not a hosted-registry function → a native direct-extern (the kernel/bare-metal
            // path). Register it so calls type-check; the native backend emits a direct C call.
            collect_direct_extern(c, fn);
            continue;
        }
        if (fn->generic_count != 0) {
            type_error(c, fn->line, fn->col, "an extern function cannot be generic");
        }
        const CExternSig *cs = cextern_sig(cx);
        FnSig *sig = &c->fns[c->fn_count++];
        sig->decl          = fn;   // for LSP hover/go-to-def on extern-function references
        sig->name          = fn->name;
        sig->generic_count = 0;
        sig->module        = c->current_module;
        sig->fn_index      = -1;   // no bytecode slot
        sig->cextern_index = cx;
        sig->direct_extern = 0;    // OFI-167: a registry (hosted-libc) extern, not a direct one
        // Resolve the declared signature and check it matches the C registry entry (arity +
        // scalar kinds). A scalar's "kind" is 'f' (float) or 'i' (int).
        int declared = 0;
        for (size_t p = 0; p < fn->param_count && declared < MAX_PARAMS; p++) {
            // A C call passes its arguments by value, so a qualified struct param would skip the
            // leaf-flattening the boundary needs (its arg would be passed boxed, corrupting the
            // marshalling). Two qualifiers ARE meaningful at the boundary: `mut` on a buffer ([T])
            // the C function writes in place (§5h pointers), and `move` on a `Ptr` HANDLE the C
            // function takes ownership of — fclose(move f: Ptr) consumes the handle so a use-after-
            // close (double fclose) is a compile error (OFI-049). Everything else is rejected.
            SemType pt = annotation_type(c, fn->params[p].type);
            OwnQual q  = fn->params[p].qual;
            if (fn->params[p].is_self || (q == OWN_MOVE && pt != TY_PTR) ||
                (q == OWN_MUT && !is_array_type(pt))) {
                type_error(c, fn->line, fn->col,
                           "an extern parameter must be plain, 'mut' on a buffer ([T]) the C "
                           "function writes, or 'move' on a Ptr handle it takes ownership of");
            }
            sig->quals[declared]    = q;
            sig->params[declared++] = pt;
        }
        sig->param_count = declared;
        sig->ret = fn->return_type ? annotation_type(c, fn->return_type) : TY_UNIT;
        // Flatten the declared params + return to their scalar LEAVES and compare to the C
        // registry entry. A struct param/return is allowed (it flattens to its fields) — the
        // wrapper reassembles the concrete C struct, so the C compiler owns the ABI (3b.6).
        char inb[CEXTERN_MAX_LEAVES];
        char outb[CEXTERN_MAX_LEAVES];
        int  in_n = 0, out_n = 0, ok = 1;
        for (int p = 0; ok && p < declared; p++) {
            ok = extern_flatten(c, sig->params[p], inb, &in_n, CEXTERN_MAX_LEAVES);
        }
        if (ok && sig->ret != TY_UNIT) {
            ok = extern_flatten(c, sig->ret, outb, &out_n, CEXTERN_MAX_LEAVES);
        }
        if (ok) {
            ok = (in_n == cs->in_leaves && out_n == cs->out_leaves);
        }
        for (int k = 0; ok && k < in_n; k++) {
            if (inb[k] != cs->in_kind[k]) {
                ok = 0;
            }
        }
        for (int k = 0; ok && k < out_n; k++) {
            if (outb[k] != cs->out_kind[k]) {
                ok = 0;
            }
        }
        if (!ok) {
            type_error(c, fn->line, fn->col,
                       "extern signature does not match the C function (its scalar/all-scalar-"
                       "struct arguments and return must flatten to the same leaf scalars)");
        }
    }
}





// collect_struct_fields fills a struct's field layout. Called after all struct
// names are registered, so field types may reference other structs (including
// forward references). `index` is the struct's slot in the table.
static void collect_struct_fields(Checker *c, int index, const Decl *d) {
    StructInfo *si = &c->structs[index];
    // The struct's own type parameters are in scope while resolving field types,
    // so `T` resolves to a type parameter rather than an unknown name.
    c->tparams      = si->generics;
    c->tparam_count = si->generic_count;
    si->field_count = 0;
    for (size_t i = 0; i < d->as.struct_.field_count; i++) {
        const Field *f = &d->as.struct_.fields[i];
        SemType ft = annotation_type(c, f->type);
        if (!si->is_resource && ptr_storage_error(c, ft, f->line, f->col, "a struct field")) {
            ft = TY_ERROR;   // OFI-049: a Ptr cannot be stored in a PLAIN struct (no destructor); a
                             // `resource struct` LIFTS this for its own fields — its `drop` closes them.
        } else if (!si->is_resource &&
                   resource_storage_error(c, ft, f->line, f->col, "a field of a non-'resource' struct")) {
            ft = TY_ERROR;   // OFI-122: a `resource` field is allowed ONLY inside another resource struct
                             // (else copying the plain struct would clone the resource → double drop).
        } else if (ft == TY_ERROR) {
            type_error(c, d->line, d->col,
                       "struct field types must be 'int', 'bool', 'float', "
                       "'string', a struct/enum, or a type parameter");
        } else if (si->is_rc && !is_immutably_shareable(c, ft)) {
            // R3: an `rc struct` is deeply immutable + shared, so every field must itself be
            // immutably shareable. A field that can carry a MUTABLE interior into the shared value
            // (an array, a plain struct, a Ptr, a function/closure, a channel, an interface, or a
            // bare type parameter) would defeat `shared => immutable` and re-open reference cycles.
            type_error(c, f->line, f->col,
                       "an 'rc struct' field must be immutably shareable (a scalar, string, enum, "
                       "or another 'rc struct'); an array, a plain struct, a function, a channel, "
                       "or a 'Ptr' can carry a mutable interior into a shared value");
            ft = TY_ERROR;
        }
        si->fields = grow_arena_vec(c->arena, si->fields, si->field_count, &si->fields_cap,
                                    si->field_count + 1, sizeof(FieldInfo));
        si->fields[si->field_count].name     = f->name;
        si->fields[si->field_count].type     = ft;
        si->fields[si->field_count].def_line = f->line;   // for go-to-definition
        si->fields[si->field_count].def_col  = f->col;
        si->field_count++;
    }
    c->tparams      = NULL;
    c->tparam_count = 0;
}





// struct_self_type returns the type `self` and `Self` denote for a struct: the
// plain struct id for a non-generic struct, or the self-instance `Box<T>` (the
// struct applied to its own type parameters) for a generic one.
static SemType struct_self_type(Checker *c, int struct_id) {
    StructInfo *si = &c->structs[struct_id];
    if (si->generic_count == 0) {
        return (SemType)struct_id;
    }
    SemType pargs[MAX_TYPE_ARGS];
    for (int k = 0; k < si->generic_count; k++) {
        pargs[k] = (SemType)(PARAM_BASE + k);
    }
    return intern_generic(c, struct_id, 0, pargs, si->generic_count);
}





// collect_struct_methods records a struct's method signatures and assigns each a
// function-table index from the shared enumeration counter `fi` (free functions
// and methods are numbered together, in declaration order — codegen replicates
// this exactly, so a method call can target the index directly). For a generic
// struct, the struct's type parameters are in scope and `self`/`Self` denote the
// self-instance, so method signatures may mention `T`.
static void collect_struct_methods(Checker *c, int index, const Decl *d, int *fi) {
    StructInfo *si = &c->structs[index];
    si->method_count = 0;
    SemType self_type = struct_self_type(c, index);
    c->tparams      = si->generic_count > 0 ? si->generics : NULL;
    c->tparam_count = si->generic_count;
    for (size_t m = 0; m < d->as.struct_.method_count; m++) {
        const FnDecl *fn = &d->as.struct_.methods[m];
        int my_index = (*fi)++;   // this method's slot in the function table
        si->methods = grow_arena_vec(c->arena, si->methods, si->method_count, &si->methods_cap,
                                     si->method_count + 1, sizeof(MethodInfo));
        MethodInfo *mi = &si->methods[si->method_count++];
        mi->name     = fn->name;
        mi->fn_index = my_index;
        mi->decl     = fn;       // for LSP hover/go-to-def on a method call
        mi->self_qual = (fn->param_count > 0 && fn->params[0].is_self)
                            ? fn->params[0].qual : OWN_NONE;
        if (fn->param_count == 0 || !fn->params[0].is_self) {
            type_error(c, fn->line, fn->col,
                       "a method's first parameter must be 'self'");
        }
        if (si->is_rc && (mi->self_qual == OWN_MUT || mi->self_qual == OWN_MOVE)) {
            // R6: an `rc struct` is shared + immutable, so a method may not take `mut self`
            // (it would mutate a shared value) or `move self` (consume one owner of a shared one).
            type_error(c, fn->line, fn->col,
                       "an 'rc struct' method cannot take 'mut self' or 'move self'; "
                       "an rc value is immutable and shared");
        }
        mi->param_count = 0;
        for (size_t i = 0; i < fn->param_count && mi->param_count < MAX_PARAMS; i++) {
            if (fn->params[i].is_self) {
                continue;   // self is implicit at the call site
            }
            mi->quals[mi->param_count] = fn->params[i].qual;
            c->allow_slice = 1;   // an interface-method parameter may be a Slice<T>
            mi->params[mi->param_count++] =
                resolve_self(annotation_type(c, fn->params[i].type), self_type);
        }
        // No `-> T` means a unit method: it runs for effect and yields no value.
        // This must be TY_UNIT (not TY_ERROR): the call site uses mi->ret as the
        // result type, and TY_ERROR would silently accept the call in value
        // position (and codegen a garbage slot → crash). Mirrors the free-fn path.
        mi->ret = fn->return_type
                      ? resolve_self(annotation_type(c, fn->return_type), self_type)
                      : TY_UNIT;
    }
    // `resource struct` (OFI-122): record its `drop` method — its fn-table index drives the runtime
    // drop hook — and require exactly one `fn drop(self)` taking self by value and returning nothing.
    // `drop` is reserved: a PLAIN struct may not define it (it would silently never run).
    si->drop_fn = -1;
    int drop_count = 0;
    for (int m = 0; m < si->method_count; m++) {
        if (strcmp(si->methods[m].name, "drop") != 0) {
            continue;
        }
        drop_count++;
        MethodInfo *dm = &si->methods[m];
        si->drop_fn = dm->fn_index;
        if (!si->is_resource) {
            type_error(c, dm->decl->line, dm->decl->col,
                       "'drop' is reserved for a 'resource struct'; a plain struct cannot define it");
        }
        if (dm->param_count != 0) {
            type_error(c, dm->decl->line, dm->decl->col,
                       "a 'resource' drop must be 'fn drop(self)' — no parameters beyond self");
        }
        if (dm->self_qual != OWN_NONE) {
            type_error(c, dm->decl->line, dm->decl->col,
                       "a 'resource' drop must take plain 'self' (not 'mut self' / 'move self'); it "
                       "borrows self to close its handles, and the runtime reclaims self afterward");
        }
        if (dm->ret != TY_UNIT) {
            type_error(c, dm->decl->line, dm->decl->col,
                       "a 'resource' drop must return nothing");
        }
    }
    if (si->is_resource && drop_count == 0) {
        type_error(c, d->line, d->col,
                   "a 'resource struct' must declare exactly one 'fn drop(self)' to release its resource");
    }
    if (drop_count > 1) {
        type_error(c, d->line, d->col, "a 'resource struct' may declare only one 'drop' method");
    }
    leave_type_params(c);
}





// collect_interface records an interface's required method signatures, keeping
// TY_SELF unresolved (the implementing type is not known until conformance).
static void collect_interface(Checker *c, const Decl *d) {
    if (c->interface_count >= MAX_STRUCTS) {
        type_error(c, d->line, d->col, "too many interfaces");
        return;
    }
    InterfaceInfo *ii = &c->interfaces[c->interface_count++];
    ii->name = d->as.interface.name;
    ii->method_count = 0;
    for (size_t m = 0; m < d->as.interface.method_count; m++) {
        const FnDecl *fn = &d->as.interface.methods[m];
        if (ii->method_count >= MAX_METHODS) {
            type_error(c, fn->line, fn->col, "too many methods on one interface");
            break;
        }
        MethodSig *ms = &ii->methods[ii->method_count++];
        ms->name = fn->name;
        if (fn->param_count == 0 || !fn->params[0].is_self) {
            type_error(c, fn->line, fn->col,
                       "an interface method's first parameter must be 'self'");
        }
        ms->param_count = 0;
        for (size_t i = 0; i < fn->param_count && ms->param_count < MAX_PARAMS; i++) {
            if (fn->params[i].is_self) {
                continue;
            }
            c->allow_slice = 1;   // a method-spec parameter may be a Slice<T>
            ms->params[ms->param_count++] = annotation_type(c, fn->params[i].type);
        }
        ms->ret = fn->return_type ? annotation_type(c, fn->return_type) : TY_UNIT;
    }
}





// resolve_interface returns an interface by name, or NULL.
// resolve_interface_id returns an interface's index, or -1 if there is none.
static int resolve_interface_id(Checker *c, const char *name) {
    for (int i = 0; i < c->interface_count; i++) {
        if (strcmp(c->interfaces[i].name, name) == 0) {
            return i;
        }
    }
    return -1;
}




// interface_object_safe reports whether an interface may be used as a VALUE type
// (dynamic dispatch). It is object-safe unless a method mentions `Self` outside the
// receiver — `Self` params or a `Self` return need the concrete type, which the boxed
// value has erased. (ms->params already excludes the `self` receiver.) Such interfaces
// remain usable as generic bounds, where the concrete type is known.
static int interface_object_safe(Checker *c, int iid) {
    InterfaceInfo *ii = &c->interfaces[iid];
    for (int m = 0; m < ii->method_count; m++) {
        MethodSig *ms = &ii->methods[m];
        if (ms->ret == TY_SELF) {
            return 0;
        }
        for (int i = 0; i < ms->param_count; i++) {
            if (ms->params[i] == TY_SELF) {
                return 0;
            }
        }
    }
    return 1;
}





// struct_implements reports whether a struct's `implements` list names an interface.
static int struct_implements(Checker *c, int struct_id, int iface_id) {
    StructInfo *si = &c->structs[struct_id];
    for (int i = 0; i < si->implements_count; i++) {
        if (si->implements[i] == iface_id) {
            return 1;
        }
    }
    return 0;
}




// is_hashable_builtin reports whether a built-in type auto-satisfies Hash/Eq: the
// scalar/string types whose values the VM can hash and compare natively. (Float is
// excluded — hashing/`==` on floats is a footgun.)
static int is_hashable_builtin(SemType t) {
    return is_integer_type(t) || t == TY_BOOL || t == TY_STRING;
}

// is_builtin_keyable_interface reports whether `iid` is the prelude's Hash or Eq —
// the interfaces a built-in key type satisfies natively.
static int is_builtin_keyable_interface(Checker *c, int iid) {
    if (iid < 0 || iid >= c->interface_count) {
        return 0;
    }
    const char *n = c->interfaces[iid].name;
    return strcmp(n, "Hash") == 0 || strcmp(n, "Eq") == 0;
}

// type_satisfies_bound reports whether type `t` satisfies the bound interface `iid`:
// a struct that nominally `implements` it, OR a built-in scalar/string type for the
// auto-provided Hash/Eq (native hashing/equality, no user methods needed).
// type_param_has_bound reports whether the in-scope type parameter `t` was DECLARED with the
// interface bound `iid` (OFI-045). A bounded generic body may use its own param as a type
// argument to another generic whose bound it already satisfies — `fn f<K: Hash + Eq>() -> Set<K>`
// — without any concrete `implements` lookup: K's declared bound set is the proof (a sound ⊇
// rule, the required bound being a member of the declared set). The `Copy` bound is NOT an
// interface and never appears in tparam_bounds; it is enforced separately at each construction/
// call site via is_move_type, so this function deliberately ignores it. Mirrors is_copy_param.
static int type_param_has_bound(Checker *c, SemType t, int iid) {
    if (!is_type_param(t)) {
        return 0;
    }
    int i = t - PARAM_BASE;
    if (i < 0 || i >= c->tparam_count) {
        return 0;
    }
    for (int b = 0; b < c->tparam_bound_count[i]; b++) {
        if (c->tparam_bounds[i][b] == iid) {
            return 1;
        }
    }
    return 0;
}






static int type_satisfies_bound(Checker *c, SemType t, int iid) {
    if (is_newtype(t)) {   // OFI-149: a newtype satisfies any bound its base does (Hash/Eq for Map keys)
        return type_satisfies_bound(c, newtype_base(c, t), iid);
    }
    if (is_struct_type(t) && struct_implements(c, t, iid)) {
        return 1;
    }
    // A type parameter in scope satisfies a bound it was itself declared with (OFI-045): a
    // generic constructor `fn new_set<K: Hash + Eq + Copy>() -> Set<K>` re-instantiates a bounded
    // generic over its own bounded param. (Copy is checked separately — see type_param_has_bound.)
    if (is_type_param(t) && type_param_has_bound(c, t, iid)) {
        return 1;
    }
    return is_hashable_builtin(t) && is_builtin_keyable_interface(c, iid);
}




// build_witness allocates the vtable for (type, interface): the method fn-indices in
// interface-method order. For a STRUCT they are the impl's real Ember methods; for a
// built-in scalar/string satisfying Hash/Eq there is no Ember method, so the slot holds
// a NATIVE id offset by WITNESS_NATIVE_BASE (the indirect-call opcodes detect and call
// it). Used by generic-bound dispatch (witness passed as a hidden arg), dynamic dispatch
// (witness boxed into the value), and Map's stored key witnesses. Caller owns the array.
static int *build_witness(Checker *c, SemType type, int iid, int *out_count) {
    InterfaceInfo *ii = &c->interfaces[iid];
    int n = ii->method_count > 0 ? ii->method_count : 1;
    int *w = malloc(sizeof(int) * (size_t)n);
    if (w == NULL) {
        fprintf(stderr, "emberc: out of memory building a witness\n");
        exit(70);
    }
    for (int m = 0; m < ii->method_count; m++) {
        w[m] = -1;
        const char *mname = ii->methods[m].name;
        if (is_struct_type(type)) {
            StructInfo *as = &c->structs[type];
            for (int j = 0; j < as->method_count; j++) {
                if (strcmp(as->methods[j].name, mname) == 0) {
                    w[m] = as->methods[j].fn_index;
                    break;
                }
            }
        } else {
            // Built-in key type: map the interface method to its native shim.
            if (strcmp(mname, "hash") == 0) {
                w[m] = WITNESS_NATIVE_BASE + NATIVE_HASH_ANY;
            } else if (strcmp(mname, "eq") == 0) {
                w[m] = WITNESS_NATIVE_BASE + NATIVE_VALUE_EQ;
            }
        }
    }
    *out_count = ii->method_count;
    return w;
}




// assignable reports whether a value of type `actual` may be supplied where `expected`
// is wanted, recording an interface upcast on `e` when `expected` is an object-safe
// interface that `actual` (a struct) implements. Equal types are trivially assignable.
// This is the single widening point: every site that wants "actual fits expected"
// (bindings, args, returns, array elements, struct fields) routes through it so a
// struct silently becomes an interface value exactly where one is expected.
static int assignable(Checker *c, Expr *e, SemType actual, SemType expected) {
    if (actual == expected) {
        return 1;
    }
    // OFI-149: a newtype is nominally distinct — never implicitly assignable to/from its base or
    // another newtype (same-newtype is the equal-types case above). Construct with `Name(x)`.
    if (is_newtype(actual) || is_newtype(expected)) {
        return 0;
    }
    if (is_interface_type(expected) && is_struct_type(actual) &&
        struct_implements(c, actual, interface_id_of(expected))) {
        e->coerce_iface   = interface_id_of(expected);
        e->coerce_witness = build_witness(c, actual, e->coerce_iface,
                                          &e->coerce_witness_count);
        return 1;
    }
    return 0;
}


// method_is_interface_impl reports whether method `name` on struct `struct_id` implements a
// method of an interface the struct declares — so it can be dispatched through a WITNESS
// (OP_CALL_INDIRECT) in bounded generic code, which uses the boxed calling convention. Such a
// method must keep boxed params/return; it cannot go multi-slot (value-types 3b.4d), or a
// witness call would pass a boxed value where the body reads a field slot.
static int method_is_interface_impl(Checker *c, int struct_id, const char *name) {
    if (struct_id < 0 || !is_struct_type(struct_id)) {
        return 0;
    }
    StructInfo *si = &c->structs[struct_id];
    for (int i = 0; i < si->implements_count; i++) {
        InterfaceInfo *ii = &c->interfaces[si->implements[i]];
        for (int m = 0; m < ii->method_count; m++) {
            if (strcmp(ii->methods[m].name, name) == 0) {
                return 1;
            }
        }
    }
    return 0;
}





// check_conformance verifies a struct provides every method each interface in
// its `implements` list requires, with a matching signature (the interface's
// TY_SELF resolving to this struct). This is the nominal conformance check
// (MANIFESTO §5b); dispatch stays static, so no runtime structure is produced.
static void check_conformance(Checker *c, int struct_id, const Decl *d) {
    StructInfo *si = &c->structs[struct_id];
    for (size_t k = 0; k < d->as.struct_.implements_count; k++) {
        const char *iface_name = d->as.struct_.implements[k];
        int iface_id = resolve_interface_id(c, iface_name);
        InterfaceInfo *ii = iface_id >= 0 ? &c->interfaces[iface_id] : NULL;
        if (ii == NULL) {
            type_error(c, d->line, d->col, "unknown interface in 'implements'");
            continue;
        }
        // Record the conformance so a generic bound `T: Iface` can be satisfied
        // by checking the type argument's `implements` list.
        if (si->implements_count < MAX_IMPLEMENTS) {
            si->implements[si->implements_count++] = iface_id;
        }
        for (int m = 0; m < ii->method_count; m++) {
            MethodSig *want = &ii->methods[m];
            MethodInfo *have = NULL;
            for (int j = 0; j < si->method_count; j++) {
                if (strcmp(si->methods[j].name, want->name) == 0) {
                    have = &si->methods[j];
                    break;
                }
            }
            if (have == NULL) {
                type_error(c, d->line, d->col,
                           "struct is missing a method required by an interface "
                           "it implements");
                continue;
            }
            int ok = (have->param_count == want->param_count);
            for (int p = 0; ok && p < want->param_count; p++) {
                SemType need = resolve_self(want->params[p], struct_id);
                if (need == TY_ERROR || have->params[p] == TY_ERROR) {
                    continue;
                }
                if (have->params[p] != need) {
                    ok = 0;
                }
            }
            SemType need_ret = resolve_self(want->ret, struct_id);
            if (need_ret != TY_ERROR && have->ret != TY_ERROR && have->ret != need_ret) {
                ok = 0;
            }
            if (!ok) {
                type_error(c, d->line, d->col,
                           "a method's signature does not match the interface it "
                           "implements");
            }
        }
    }
}





// collect_enum_variants fills an enum's variants (field types, positions) and
// enforces that variant names are globally unique (so bare references resolve).
static void collect_enum_variants(Checker *c, int enum_id, const Decl *d) {
    EnumInfo *ei = &c->enums[enum_id];
    // The enum's type parameters are in scope while resolving variant field types.
    c->tparams      = ei->generics;
    c->tparam_count = ei->generic_count;
    ei->variants      = NULL;   // dynamic per-enum; grown on demand (no cap on variants per enum)
    ei->variants_cap  = 0;
    ei->variant_count = 0;
    for (size_t v = 0; v < d->as.enum_.variant_count; v++) {
        const Variant *src = &d->as.enum_.variants[v];
        // Reject a variant name only where a bare reference could actually be AMBIGUOUS — i.e. when
        // both enums are visible from one resolution scope. `resolve_variant` sees the current module
        // plus global (prelude) modules, so two enums conflict iff they share a module, or either is
        // global. Same-named variants in DIFFERENT non-global modules never collide (OFI-073): a bare
        // reference in one module can't see the other's, so `std/json`'s `Str` and `std/highlight`'s
        // `Str` coexist. (`match` is already scrutinee-directed and never needed this check.)
        int new_global = is_global_module(c->modules, ei->module);
        for (int e = 0; e < c->enum_count; e++) {
            int conflicts = (c->enums[e].module == ei->module) || new_global ||
                            is_global_module(c->modules, c->enums[e].module);
            if (!conflicts) {
                continue;
            }
            for (int w = 0; w < c->enums[e].variant_count; w++) {
                if (strcmp(c->enums[e].variants[w].name, src->name) == 0) {
                    type_error(c, d->line, d->col,
                               "duplicate variant name (a variant by this name already exists in "
                               "this module or a prelude enum; variant names must be unique among "
                               "the enums visible together)");
                }
            }
        }
        ei->variants = grow_arena_vec(c->arena, ei->variants, ei->variant_count,
                                      &ei->variants_cap, ei->variant_count + 1, sizeof(VariantInfo));
        VariantInfo *vi = &ei->variants[ei->variant_count];
        vi->name          = src->name;
        vi->enum_id       = enum_id;
        vi->variant_index = ei->variant_count;
        vi->field_count   = 0;
        for (size_t f = 0; f < src->field_count && vi->field_count < MAX_PARAMS; f++) {
            SemType ft = annotation_type(c, src->fields[f].type);
            if (ptr_storage_error(c, ft, src->fields[f].line, src->fields[f].col,
                                  "an enum payload")) {
                ft = TY_ERROR;   // OFI-049: a Ptr handle cannot be an enum payload (no destructor)
            } else if (ft == TY_ERROR) {
                type_error(c, d->line, d->col,
                           "variant field types must be 'int', 'bool', 'float', "
                           "'string', a struct/enum, or a type parameter");
            }
            vi->field_names[vi->field_count] = src->fields[f].name;   // for named construction (OFI-140)
            vi->fields[vi->field_count++] = ft;
        }
        ei->variant_count++;
    }
    c->tparams      = NULL;
    c->tparam_count = 0;
}





// ------------------------------------------------ Monomorphization closure ----
// The first piece of the native-layout monomorphization pass (see the design in
// memory `ember-native-layout-build`): compute the set of concrete (function,
// type-args) instances a program actually needs. Start from every non-generic
// function/method, then follow each *generic* direct call — substituting the
// caller instance's type arguments through the call's recorded `mono_args` — to
// discover the instances it requires. This analysis runs on every compile (so
// the whole test corpus exercises it) but changes nothing; it is dumped under
// EMBER_DUMP_MONO for verification while the expand/codegen pieces are built.
// Currently follows free-function generic calls; methods on generic structs and
// generic enums are the next extension.
#define MAX_MONO_INSTS 4096

typedef struct {
    int     base_fi;                 // function-table index of the base function
    SemType args[MAX_TYPE_ARGS];     // concrete type arguments (none ⇒ arg_count 0)
    int     arg_count;
} FnInst;

// A resolved generic call: while emitting `caller` (an instance index), the call
// expression `call` targets the function instance `callee` (an instance index).
typedef struct {
    const Expr *call;
    int         caller;
    int         callee;
} MonoRes;

#define MAX_MONO_RES 16384

typedef struct {
    Checker       *c;
    const FnDecl **fn_by_fi;         // fi → its FnDecl (free fns + methods, decl order)
    int           *fi_generic;       // fi → number of type parameters
    int            fi_count;
    FnInst         insts[MAX_MONO_INSTS];
    int            final_fi[MAX_MONO_INSTS];   // each instance's compiled-table slot
    int            inst_count;
    int            cur_caller;       // instance whose body is being walked
    MonoRes        res[MAX_MONO_RES];
    int            res_count;
} MonoCtx;

// mono_add_inst interns a (base_fi, args) instance, returning its index.
static int mono_add_inst(MonoCtx *m, int base_fi, const SemType *args, int n) {
    for (int i = 0; i < m->inst_count; i++) {
        if (m->insts[i].base_fi == base_fi && m->insts[i].arg_count == n) {
            int same = 1;
            for (int k = 0; k < n; k++) {
                if (m->insts[i].args[k] != args[k]) { same = 0; break; }
            }
            if (same) {
                return i;
            }
        }
    }
    if (m->inst_count >= MAX_MONO_INSTS) {
        return -1;
    }
    int idx = m->inst_count++;
    m->insts[idx].base_fi   = base_fi;
    m->insts[idx].arg_count = n;
    for (int k = 0; k < n; k++) {
        m->insts[idx].args[k] = args[k];
    }
    return idx;
}

// mono_visit_call records the instance a generic direct call requires, under the
// substitution of the enclosing instance's type arguments.
static void mono_visit_call(MonoCtx *m, const Expr *call, const FnInst *inst) {
    if (call->as.call.mono_arg_count <= 0) {
        return;   // a non-generic call needs no new instance (callee already seeded)
    }
    // A direct call carries its target in resolved_fn; a generic method call
    // carries it as field_index on the EXPR_GET callee, keyed by the receiver's
    // struct type arguments (recorded above as mono_args).
    int base = call->as.call.resolved_fn;
    if (base < 0 && call->as.call.callee->kind == EXPR_GET) {
        base = call->as.call.callee->as.get.field_index;
    }
    if (base < 0 || base >= m->fi_count) {
        return;   // builtin / variant / unresolved call
    }
    GenericInst sub;
    sub.base = 0;
    sub.is_enum = 0;
    sub.arg_count = inst->arg_count;
    for (int k = 0; k < inst->arg_count; k++) {
        sub.args[k] = inst->args[k];
    }
    SemType cargs[MAX_TYPE_ARGS];
    int n = call->as.call.mono_arg_count;
    if (n > MAX_TYPE_ARGS) {
        n = MAX_TYPE_ARGS;
    }
    for (int j = 0; j < n; j++) {
        cargs[j] = subst(m->c, &sub, (SemType)call->as.call.mono_args[j]);
    }
    int callee = mono_add_inst(m, base, cargs, n);
    // Record that, while emitting the current caller instance, this call targets
    // the callee instance (its compiled slot is resolved once all fis are assigned).
    if (callee >= 0 && m->res_count < MAX_MONO_RES) {
        m->res[m->res_count].call   = call;
        m->res[m->res_count].caller = m->cur_caller;
        m->res[m->res_count].callee = callee;
        m->res_count++;
    }
}

static void mono_walk_block(MonoCtx *m, const Block *b, const FnInst *inst);

static void mono_walk_expr(MonoCtx *m, const Expr *e, const FnInst *inst) {
    if (e == NULL) {
        return;
    }
    switch (e->kind) {
        case EXPR_CALL:
            mono_visit_call(m, e, inst);
            mono_walk_expr(m, e->as.call.callee, inst);
            for (size_t i = 0; i < e->as.call.arg_count; i++) {
                mono_walk_expr(m, e->as.call.args[i], inst);
            }
            break;
        case EXPR_UNARY:
            mono_walk_expr(m, e->as.unary.operand, inst);
            break;
        case EXPR_BINARY:
            mono_walk_expr(m, e->as.binary.left, inst);
            mono_walk_expr(m, e->as.binary.right, inst);
            break;
        case EXPR_GET:
            mono_walk_expr(m, e->as.get.object, inst);
            break;
        case EXPR_INDEX:
            mono_walk_expr(m, e->as.index.object, inst);
            mono_walk_expr(m, e->as.index.index, inst);
            break;
        case EXPR_ARRAY:
            for (size_t i = 0; i < e->as.array.count; i++) {
                mono_walk_expr(m, e->as.array.elems[i], inst);
            }
            break;
        case EXPR_STRUCT_LIT:
            for (size_t i = 0; i < e->as.struct_lit.field_count; i++) {
                mono_walk_expr(m, e->as.struct_lit.fields[i].value, inst);
            }
            break;
        case EXPR_STRING:
            for (size_t i = 0; i < e->as.str.part_count; i++) {
                if (e->as.str.parts[i].expr != NULL) {
                    mono_walk_expr(m, e->as.str.parts[i].expr, inst);
                }
            }
            break;
        case EXPR_TRY:
            mono_walk_expr(m, e->as.try_.operand, inst);
            break;
        default:
            break;   // int/float/bool/ident carry no sub-expressions
    }
}

static void mono_walk_stmt(MonoCtx *m, const Stmt *s, const FnInst *inst) {
    if (s == NULL) {
        return;
    }
    switch (s->kind) {
        case STMT_LET:    mono_walk_expr(m, s->as.let.value, inst); break;
        case STMT_RETURN: mono_walk_expr(m, s->as.ret.value, inst); break;
        case STMT_EXPR:   mono_walk_expr(m, s->as.expr.expr, inst); break;
        case STMT_ASSIGN:
            mono_walk_expr(m, s->as.assign.target, inst);
            mono_walk_expr(m, s->as.assign.value, inst);
            break;
        case STMT_IF:
            mono_walk_expr(m, s->as.if_.cond, inst);
            mono_walk_block(m, &s->as.if_.then_blk, inst);
            mono_walk_stmt(m, s->as.if_.else_branch, inst);
            break;
        case STMT_FOR:
            mono_walk_expr(m, s->as.for_.iter, inst);
            mono_walk_block(m, &s->as.for_.body, inst);
            break;
        case STMT_LOOP:    mono_walk_block(m, &s->as.loop.body, inst); break;
        case STMT_MATCH:
            mono_walk_expr(m, s->as.match.value, inst);
            for (size_t i = 0; i < s->as.match.case_count; i++) {
                mono_walk_block(m, &s->as.match.cases[i].body, inst);
            }
            break;
        case STMT_SPAWN:   mono_walk_expr(m, s->as.spawn.call, inst); break;
        case STMT_NURSERY: mono_walk_block(m, &s->as.nursery.body, inst); break;
        case STMT_BLOCK:   mono_walk_block(m, &s->as.block.body, inst); break;
        default:           break;   // break / continue
    }
}

static void mono_walk_block(MonoCtx *m, const Block *b, const FnInst *inst) {
    for (size_t i = 0; i < b->count; i++) {
        mono_walk_stmt(m, b->stmts[i], inst);
    }
}

// build_mono_instances computes the instance closure and fills `plan` with the
// function-table layout + per-call resolutions codegen needs. Under
// EMBER_DUMP_MONO it also prints the plan.
static void build_mono_instances(Checker *c, const Program *program,
                                 MonoPlan *plan) {
    // The function table is free functions PLUS every struct method, which together
    // can exceed MAX_FNS (256) — so size these by the true total, not MAX_FNS. A
    // fixed MAX_FNS array silently dropped the functions past index 255 here, so a
    // `main` (or any callee) beyond 256 was never seeded as an instance and its
    // table slot resolved wrong — a silent miscompile, same family as OFI-007.
    int table_fns = 0;
    for (size_t i = 0; i < program->count; i++) {
        const Decl *d = program->decls[i];
        if (d->kind == DECL_FN) {
            table_fns++;
        } else if (d->kind == DECL_STRUCT) {
            table_fns += (int)d->as.struct_.method_count;
        }
    }
    const FnDecl **fn_by_fi   = malloc((size_t)(table_fns > 0 ? table_fns : 1) * sizeof(*fn_by_fi));
    int           *fi_generic = malloc((size_t)(table_fns > 0 ? table_fns : 1) * sizeof(*fi_generic));
    if (fn_by_fi == NULL || fi_generic == NULL) {
        fprintf(stderr, "emberc: out of memory enumerating functions\n");
        exit(70);
    }
    int fi = 0;
    for (size_t i = 0; i < program->count; i++) {
        const Decl *d = program->decls[i];
        if (d->kind == DECL_FN) {
            fn_by_fi[fi]   = &d->as.fn;
            fi_generic[fi] = (int)d->as.fn.generic_count;
            fi++;
        } else if (d->kind == DECL_STRUCT) {
            for (size_t mth = 0; mth < d->as.struct_.method_count; mth++) {
                fn_by_fi[fi]   = &d->as.struct_.methods[mth];
                // A method's instance args come from its struct's type parameters.
                fi_generic[fi] = (int)d->as.struct_.generic_count;
                fi++;
            }
        }
    }

    MonoCtx m;
    m.c          = c;
    m.fn_by_fi   = fn_by_fi;
    m.fi_generic = fi_generic;
    m.fi_count   = fi;
    m.inst_count = 0;
    m.res_count  = 0;

    // Seed: every non-generic function/method is always emitted.
    for (int f = 0; f < fi; f++) {
        if (fi_generic[f] == 0) {
            mono_add_inst(&m, f, NULL, 0);
        }
    }
    // Closure: process instances in order (the list grows as we discover more),
    // recording each generic call's target.
    for (int i = 0; i < m.inst_count; i++) {
        FnInst inst = m.insts[i];
        m.cur_caller = i;
        if (inst.base_fi >= 0 && inst.base_fi < fi &&
            fn_by_fi[inst.base_fi]->has_body) {
            mono_walk_block(&m, &fn_by_fi[inst.base_fi]->body, &inst);
        }
    }

    // Assign each instance its compiled-table slot. A non-generic instance keeps
    // its base fi (so non-generic functions are entirely undisturbed); a generic
    // instance is appended after the base table. This is the Step-1 "append" model.
    int appended = fi;
    for (int i = 0; i < m.inst_count; i++) {
        if (m.insts[i].arg_count == 0 && fi_generic[m.insts[i].base_fi] == 0) {
            m.final_fi[i] = m.insts[i].base_fi;
        } else {
            m.final_fi[i] = appended++;
        }
    }

    if (getenv("EMBER_DUMP_MONO") != NULL) {
        fprintf(stderr,
                "=== mono: %d instances, %d base fns, %d total slots, %d resolutions ===\n",
                m.inst_count, fi, appended, m.res_count);
        for (int i = 0; i < m.inst_count; i++) {
            fprintf(stderr, "  fi%d <- %s", m.final_fi[i],
                    fn_by_fi[m.insts[i].base_fi]->name);
            if (m.insts[i].arg_count > 0) {
                fprintf(stderr, "<");
                for (int k = 0; k < m.insts[i].arg_count; k++) {
                    fprintf(stderr, "%s%d", k ? "," : "", m.insts[i].args[k]);
                }
                fprintf(stderr, ">");
            }
            fprintf(stderr, "\n");
        }
        for (int r = 0; r < m.res_count; r++) {
            if (m.insts[m.res[r].caller].arg_count > 0 ||
                m.insts[m.res[r].callee].arg_count > 0) {
                fprintf(stderr, "    call in fi%d -> fi%d (%s)\n",
                        m.final_fi[m.res[r].caller], m.final_fi[m.res[r].callee],
                        fn_by_fi[m.insts[m.res[r].callee].base_fi]->name);
            }
        }
    }

    // Publish the plan for codegen. Base slots 0..fi-1 compile their own FnDecl
    // (a generic base slot stays emitted but is never called); an appended slot
    // compiles its instance's base FnDecl. Resolutions map a generic call (in a
    // given caller slot) to its callee slot.
    plan->total_slots   = appended;
    plan->base_fn_count = fi;
    plan->main_index    = 0;
    plan->base_of       = malloc(sizeof(int) * (appended > 0 ? appended : 1));
    plan->res           = malloc(sizeof(MonoPlanRes) *
                                 (m.res_count > 0 ? m.res_count : 1));
    if (plan->base_of == NULL || plan->res == NULL) {
        fprintf(stderr, "emberc: out of memory building the mono plan\n");
        exit(70);
    }
    for (int s = 0; s < appended; s++) {
        plan->base_of[s] = (s < fi) ? s : 0;
    }
    for (int i = 0; i < m.inst_count; i++) {
        if (m.final_fi[i] >= fi) {
            plan->base_of[m.final_fi[i]] = m.insts[i].base_fi;
        }
        if (strcmp(fn_by_fi[m.insts[i].base_fi]->name, "main") == 0 &&
            m.insts[i].arg_count == 0) {
            plan->main_index = m.final_fi[i];
        }
    }
    plan->res_count = m.res_count;
    for (int r = 0; r < m.res_count; r++) {
        plan->res[r].call        = m.res[r].call;
        plan->res[r].caller_slot = m.final_fi[m.res[r].caller];
        plan->res[r].callee_fi   = m.final_fi[m.res[r].callee];
    }
    free(fn_by_fi);
    free(fi_generic);
}


void mono_plan_free(MonoPlan *plan) {
    if (plan == NULL) {
        return;
    }
    free(plan->base_of);
    free(plan->res);
    plan->base_of = NULL;
    plan->res     = NULL;
}


// ----------------------------------------------------- Packed layout (Step 2) ----
// field_storage_size gives a field's packed width: a scalar is stored at its
// natural width; everything else (string/array/struct/enum/generic instance, and
// a generic type parameter) is a 16-byte boxed Value, runtime-tagged like today.
// This mirrors typed arrays (scalars packed, aggregates boxed) — see memory
// `ember-erased-representation`. Step 2's runtime switch consumes these layouts;
// for now build_layouts only validates the computation (EMBER_DUMP_LAYOUT).
static int field_storage_size(Checker *c, SemType t) {
    if (t == TY_I8 || t == TY_U8 || t == TY_BOOL)        return 1;
    if (t == TY_I16 || t == TY_U16)                      return 2;
    if (t == TY_I32 || t == TY_U32 || t == TY_F32)       return 4;
    if (t == TY_INT || t == TY_U64 || t == TY_FLOAT)     return 8;
    // A nested inline-able struct field is packed INLINE: its bytes embed in the parent's
    // buffer (recursive), so it costs its own packed size, not a boxed pointer (value-types 3b.5).
    if (nested_inline_sid(c, t) >= 0) {
        StructInfo *si = &c->structs[t];
        int total = 0;
        for (int f = 0; f < si->field_count; f++) {
            total += field_storage_size(c, si->fields[f].type);
        }
        return total;
    }
    return 16;   // boxed Value
}

// layout_inline_eligible: may an array store this struct's elements INLINE (packed in
// the array buffer, no per-element heap object) rather than boxed? Yes when every field
// is a packed scalar (no boxed field — a boxed sub-field is the 3a.2 case, deferred) and
// the element fits the array's 1-byte element stride (total_size <= 255). All-scalar
// structs (Pixel, Vec3, a token tag+int) qualify — the common numeric-record case.
static int layout_inline_eligible(const StructLayout *l) {
    if (l->total_size <= 0 || l->total_size > 255) {
        return 0;
    }
    for (int f = 0; f < l->field_count; f++) {
        if (l->kind[f] == AEK_BOXED) {
            return 0;
        }
    }
    return 1;
}


// layout_alloc_fields arena-allocates a StructLayout's per-field arrays, sized to `cap` (declared +
// witness fields). Arena-owned, so the StructLayout array can be freed with a plain free() while
// these are reclaimed at arena_free (after codegen has copied them into the runtime StructType).
static void layout_alloc_fields(Checker *c, StructLayout *L, int cap) {
    int n = cap > 0 ? cap : 1;
    L->offset       = arena_alloc(c->arena, (size_t)n * sizeof(int));
    L->kind         = arena_alloc(c->arena, (size_t)n * sizeof(int));
    L->field_struct = arena_alloc(c->arena, (size_t)n * sizeof(int));
}


static void build_layouts(Checker *c, StructLayout **out_layouts, int *out_count) {
    int n = c->struct_count + c->sinst_count;
    StructLayout *L = malloc(sizeof(StructLayout) * (n > 0 ? n : 1));
    if (L == NULL) {
        fprintf(stderr, "emberc: out of memory building struct layouts\n");
        exit(70);
    }
    // The declared structs, in id order.
    for (int s = 0; s < c->struct_count; s++) {
        StructInfo *si = &c->structs[s];
        int off = 0;
        L[s].field_count = si->field_count;
        L[s].base_id     = s;
        L[s].is_rc       = si->is_rc;
        L[s].is_resource = si->is_resource;
        L[s].drop_fn     = si->drop_fn;
        layout_alloc_fields(c, &L[s], si->field_count + si->witness_count);
        for (int f = 0; f < si->field_count; f++) {
            SemType ft = si->fields[f].type;
            int nsid = nested_inline_sid(c, ft);
            L[s].offset[f]       = off;
            L[s].kind[f]         = nsid >= 0 ? AEK_INLINE_STRUCT : array_elem_kind(ft);
            L[s].field_struct[f] = nsid;
            off += field_storage_size(c, ft);
        }
        // A bounded generic struct carries one hidden, boxed witness field per (param,
        // bound) after its declared fields (instance-storage: the key's Hash/Eq vtable
        // travels with the value). Construction fills them; drop releases them.
        for (int w = 0; w < si->witness_count; w++) {
            int f = L[s].field_count++;
            L[s].offset[f]       = off;
            L[s].kind[f]         = AEK_BOXED;
            L[s].field_struct[f] = -1;
            off += 16;
        }
        L[s].total_size = off;
    }
    // The appended concrete generic struct instances (Box<int>): the base struct's
    // fields with this instance's type arguments substituted in, so a type-parameter
    // field takes its concrete width (Box<u8>.value packs to 1 byte).
    for (int j = 0; j < c->sinst_count; j++) {
        const GenericInst *g = &c->ginsts[c->sinst_ginst[j]];
        StructInfo *base = &c->structs[g->base];
        int id = c->struct_count + j;
        int off = 0;
        L[id].field_count = base->field_count;
        L[id].base_id     = g->base;
        L[id].is_rc       = 0;   // a generic instance is never rc (R7 bans generic rc structs)
        L[id].is_resource = 0;   // nor resource (generic resource structs are banned, Phase 1)
        L[id].drop_fn     = -1;
        layout_alloc_fields(c, &L[id], base->field_count + base->witness_count);
        for (int f = 0; f < base->field_count; f++) {
            SemType ft = subst(c, g, base->fields[f].type);
            int nsid = nested_inline_sid(c, ft);
            L[id].offset[f]       = off;
            L[id].kind[f]         = nsid >= 0 ? AEK_INLINE_STRUCT : array_elem_kind(ft);
            L[id].field_struct[f] = nsid;
            off += field_storage_size(c, ft);
        }
        for (int w = 0; w < base->witness_count; w++) {
            int f = L[id].field_count++;
            L[id].offset[f]       = off;
            L[id].kind[f]         = AEK_BOXED;
            L[id].field_struct[f] = -1;
            off += 16;
        }
        L[id].total_size = off;
    }
    *out_layouts = L;
    *out_count   = n;

    if (getenv("EMBER_DUMP_LAYOUT") != NULL) {
        fprintf(stderr, "=== packed layouts (%d declared + %d instances) ===\n",
                c->struct_count, c->sinst_count);
        for (int s = 0; s < n; s++) {
            const char *nm = c->structs[L[s].base_id].name;
            fprintf(stderr, "  struct[%d] %s%s:", s, nm,
                    s >= c->struct_count ? " (instance)" : "");
            for (int f = 0; f < L[s].field_count; f++) {
                int sz = (f + 1 < L[s].field_count) ? L[s].offset[f + 1] - L[s].offset[f]
                                                    : L[s].total_size - L[s].offset[f];
                fprintf(stderr, " @%d(%db%s)", L[s].offset[f], sz,
                        L[s].kind[f] == 0 ? " box" : "");
            }
            fprintf(stderr, "  => %d bytes\n", L[s].total_size);
        }
    }

    // Inline-array eligibility (value-types Stage 3a.1): which struct types an array
    // could store inline. Classification only for now — validated across the whole
    // corpus before the storage switch lands (the established additive-brick pattern).
    if (getenv("EMBER_DUMP_INLINE") != NULL) {
        fprintf(stderr, "=== inline-array eligibility ===\n");
        for (int s = 0; s < n; s++) {
            fprintf(stderr, "  struct[%d] %s => %s (%d bytes)\n", s,
                    c->structs[L[s].base_id].name,
                    layout_inline_eligible(&L[s]) ? "INLINE" : "boxed",
                    L[s].total_size);
        }
    }
}


int check_program(Program *program, const ModuleSet *modules, Arena *arena,
                  const char *source_name, MonoPlan *out_plan,
                  StructLayout **out_layouts, int *out_layout_count,
                  SemanticIndex *out_index) {
    out_plan->total_slots   = 0;
    out_plan->base_fn_count = 0;
    out_plan->base_of       = NULL;
    out_plan->res           = NULL;
    out_plan->res_count     = 0;
    out_plan->main_index    = 0;
    *out_layouts            = NULL;
    *out_layout_count       = 0;
    Checker c;
    c.src            = source_name;
    c.modules        = modules;
    c.current_module = 0;
    c.had_error      = 0;
    c.expr_depth     = 0;
    c.locals         = NULL;
    c.locals_cap     = 0;
    c.local_count    = 0;
    c.fns            = NULL;
    c.fns_cap        = 0;
    c.current_return = TY_INT;
    c.scope_depth    = 0;
    c.loop_depth     = 0;
    c.loop_backedge_moved = NULL;   // OFI-074
    c.unreachable    = 0;   // OFI-100: initialise the diverging-code flag (don't read indeterminate stack)
    c.any_rc         = 0;   // set in pass 1a if any `rc struct` is declared
    c.nursery_depth  = 0;
    c.fn_count        = 0;
    c.structs         = NULL;
    c.structs_cap     = 0;
    c.struct_count    = 0;
    c.interface_count = 0;
    c.enum_count      = 0;
    c.global_count    = 0;
    c.ginst_count     = 0;
    c.sinst_count     = 0;
    for (int i = 0; i < MAX_STRUCTS; i++) {
        c.sinst_of[i] = -1;
    }
    c.array_count     = 0;
    c.channel_count   = 0;
    c.fntype_count    = 0;
    c.tparams         = NULL;
    c.tparam_count    = 0;
    c.self_struct     = -1;
    c.expected        = TY_ERROR;
    c.arena           = arena;
    c.program         = program;
    c.index           = out_index;   // NULL in batch builds; set by the LSP
    c.base_fn_count   = 0;
    c.lambda_count    = 0;
    c.inferred_return = TY_ERROR;

    // Pass 1a — register every struct *name* (assigning its id), so field types
    // and signatures in pass 1b can reference any struct, including forward ones.
    // Reject top-level declarations this slice doesn't support.
    for (size_t i = 0; i < program->count; i++) {
        const Decl *d = program->decls[i];
        c.current_module = module_of_decl(modules, (int)i);
        if (d->kind == DECL_STRUCT) {
            {
                if (type_name_taken(&c, d->as.struct_.name, c.current_module)) {
                    type_error(&c, d->line, d->col,
                               "a type with this name is already declared in this module");
                }
                if (d->as.struct_.name[0] == '_' && d->as.struct_.name[1] == '\0') {
                    type_error(&c, d->line, d->col,
                               "a struct cannot be named '_' — it is the discard, not a usable type name");
                }
                ensure_structs_cap(&c, c.struct_count + 1);
                StructInfo *si = &c.structs[c.struct_count];
                si->name             = d->as.struct_.name;
                si->fields           = NULL;   // dynamic per-struct; grown in collect_struct
                si->fields_cap       = 0;
                si->field_count      = 0;
                si->methods          = NULL;   // dynamic per-struct; grown in collect_struct_methods
                si->methods_cap      = 0;
                si->method_count     = 0;
                si->generic_count    = 0;
                si->witness_count    = 0;
                si->implements_count = 0;
                si->module           = c.current_module;
                si->is_rc            = d->as.struct_.is_rc;
                if (si->is_rc) {
                    c.any_rc = 1;   // enable the rc-specific mutation guards for this program
                }
                si->is_resource      = d->as.struct_.is_resource;
                si->drop_fn          = -1;   // set in collect_struct_methods once `drop` is found
                if (si->is_rc && si->is_resource) {
                    type_error(&c, d->line, d->col,
                               "a struct cannot be both 'rc' (shared, immutable) and 'resource' "
                               "(uniquely owned, drop-bearing) — they are opposite ownership models");
                }
                si->def_line         = d->line;
                si->def_col          = d->col;
                // R7: a GENERIC `rc struct<T>` is deferred (v1). A type-parameter field is erased
                // at the declaration, so its deep immutability can't be decided here without
                // net-new use-site bound machinery; a non-generic rc struct is the complete,
                // sound feature. Reject it rather than admit an unsound shared-mutable smuggle.
                if (si->is_rc && d->as.struct_.generic_count > 0) {
                    type_error(&c, d->line, d->col,
                               "a generic 'rc struct' is not supported yet; an 'rc struct' must "
                               "have only concrete immutably-shareable fields (scalar, string, "
                               "enum, or another rc struct)");
                }
                if (si->is_resource && d->as.struct_.generic_count > 0) {
                    type_error(&c, d->line, d->col,
                               "a generic 'resource struct' is not supported yet (Phase 1); a "
                               "'resource struct' must be non-generic");
                }
                for (size_t g = 0; g < d->as.struct_.generic_count &&
                                   si->generic_count < MAX_TYPE_ARGS; g++) {
                    // Bounds are resolved in pass 1a′′ below (after interfaces are
                    // collected); here just record the type-parameter names.
                    si->bound_count[si->generic_count] = 0;
                    si->generics[si->generic_count++]  =
                        d->as.struct_.generics[g].name;
                }
                c.struct_count++;
            }
        } else if (d->kind == DECL_ENUM) {
            if (c.enum_count >= MAX_STRUCTS) {
                type_error(&c, d->line, d->col, "too many enum types");
            } else {
                if (type_name_taken(&c, d->as.enum_.name, c.current_module)) {
                    type_error(&c, d->line, d->col,
                               "a type with this name is already declared in this module");
                }
                if (d->as.enum_.name[0] == '_' && d->as.enum_.name[1] == '\0') {
                    type_error(&c, d->line, d->col,
                               "an enum cannot be named '_' — it is the discard, not a usable type name");
                }
                EnumInfo *ei = &c.enums[c.enum_count];
                ei->name          = d->as.enum_.name;
                ei->variant_count = 0;
                ei->generic_count = 0;
                ei->module        = c.current_module;
                ei->def_line      = d->line;
                ei->def_col       = d->col;
                for (size_t g = 0; g < d->as.enum_.generic_count &&
                                   ei->generic_count < MAX_TYPE_ARGS; g++) {
                    if (d->as.enum_.generics[g].bound_count > 0) {
                        type_error(&c, d->line, d->col,
                                   "generic bounds on an enum ('<T: Ord>') are not yet "
                                   "supported (OFI-004)");
                    }
                    ei->generics[ei->generic_count++] = d->as.enum_.generics[g].name;
                }
                c.enum_count++;
            }
        } else if (d->kind == DECL_TYPE) {
            // OFI-149: register a newtype. v1 base is a scalar numeric or bool type (string and
            // other bases are a later phase); a scalar newtype is freely copyable like its base.
            if (c.newtype_count >= MAX_STRUCTS) {
                type_error(&c, d->line, d->col, "too many newtypes");
            } else if (type_name_taken(&c, d->as.type_.name, c.current_module) ||
                       resolve_newtype(&c, d->as.type_.name) >= 0) {
                type_error(&c, d->line, d->col,
                           "a type with this name is already declared in this module");
            } else {
                SemType base = annotation_type(&c, d->as.type_.base);
                if (!is_integer_type(base) && !is_float_type(base) &&
                    base != TY_BOOL && base != TY_STRING) {
                    type_error(&c, d->line, d->col,
                               "a newtype's base must be a scalar (numeric or bool) or string type");
                    base = TY_INT;
                }
                NewtypeInfo *ni = &c.newtypes[c.newtype_count++];
                ni->name     = d->as.type_.name;
                ni->base     = base;
                ni->module   = c.current_module;
                ni->def_line = d->line;
                ni->def_col  = d->col;
                // OFI-150 v1: a refinement predicate is supported on a NUMERIC or BOOL base only —
                // a refcounted (string) base would be re-read by the predicate AND produced as the
                // value, double-counting its reference. A string newtype without a predicate is fine.
                if (d->as.type_.refinement != NULL && base == TY_STRING) {
                    type_error(&c, d->line, d->col,
                               "a refinement ('where') predicate is supported on a numeric or bool "
                               "base only (a string newtype must omit the predicate for now)");
                }
                ni->refinement = (base == TY_STRING) ? NULL : d->as.type_.refinement;
                ni->refinement_checked = 0;
                ni->refinement_in_progress = 0;
            }
        } else if (d->kind == DECL_LET) {
            collect_global(&c, d);   // a top-level constant (OFI-023)
        } else if (d->kind != DECL_FN && d->kind != DECL_INTERFACE &&
                   d->kind != DECL_IMPORT && d->kind != DECL_EXTERN) {
            type_error(&c, d->line, d->col,
                       "only function, struct, enum, interface, extern, and 'let' "
                       "declarations are supported in this build slice");
        }
    }

    // Pass 1a′ — collect every interface's method signatures BEFORE any signature so
    // that a generic bound (`<K: Hash + Eq>`) on a function/method declared earlier (or
    // in another module) can resolve its bound interface. Struct/enum *names* are already
    // registered (pass 1a), which is all an interface method's types need.
    for (size_t i = 0; i < program->count; i++) {
        const Decl *d = program->decls[i];
        if (d->kind == DECL_INTERFACE) {
            c.current_module = module_of_decl(modules, (int)i);
            collect_interface(&c, d);
        }
    }

    // Pass 1a′′ — resolve the bounds on each generic STRUCT's type parameters (now that
    // interfaces exist). A bounded struct (`Map<K: Hash + Eq, V>`) carries one hidden
    // witness field per (param, bound), set at construction; `witness_count` is the total.
    {
        int s = 0;
        for (size_t i = 0; i < program->count; i++) {
            const Decl *d = program->decls[i];
            if (d->kind != DECL_STRUCT) {
                continue;
            }
            StructInfo *si = &c.structs[s++];
            c.current_module = module_of_decl(modules, (int)i);
            int wc = 0;
            for (int g = 0; g < si->generic_count &&
                            g < (int)d->as.struct_.generic_count; g++) {
                const GenericParam *gp = &d->as.struct_.generics[g];
                si->bound_count[g] = 0;
                si->is_copy[g]     = gp->is_copy;
                for (int b = 0; b < gp->bound_count; b++) {
                    int iid = resolve_interface_id(&c, gp->bounds[b]);
                    if (iid < 0) {
                        type_error(&c, d->line, d->col,
                                   "unknown interface in a struct's generic bound");
                        continue;
                    }
                    si->bounds[g][si->bound_count[g]++] = iid;
                    wc++;
                }
            }
            si->witness_count = wc;
        }
    }

    // Pass 1b — resolve struct field layouts and method signatures, and collect
    // free-function signatures. `fi` numbers the compiled function table over free
    // functions and methods together, in declaration order (codegen uses the same
    // order), so method calls can target a function-table index.
    int si = 0;
    int fi = 0;
    int ei = 0;
    for (size_t i = 0; i < program->count; i++) {
        const Decl *d = program->decls[i];
        c.current_module = module_of_decl(modules, (int)i);
        if (d->kind == DECL_STRUCT) {
            collect_struct_fields(&c, si, d);
            collect_struct_methods(&c, si, d, &fi);
            si++;
        } else if (d->kind == DECL_FN) {
            collect_signature(&c, &d->as.fn);
            c.fns[c.fn_count - 1].module   = c.current_module;
            c.fns[c.fn_count - 1].fn_index = fi;
            fi++;
        } else if (d->kind == DECL_ENUM) {
            collect_enum_variants(&c, ei, d);
            ei++;
        } else if (d->kind == DECL_EXTERN) {
            collect_extern(&c, d);   // foreign (C) functions — no bytecode slot (§5h)
        }
    }
    // `fi` now counts every declared function + method: the first lifted lambda
    // takes the next table slot, and each subsequent lambda the one after.
    c.base_fn_count = fi;

    // Pass 1c — verify nominal conformance: each struct provides the methods of
    // every interface in its `implements` list.
    si = 0;
    for (size_t i = 0; i < program->count; i++) {
        const Decl *d = program->decls[i];
        c.current_module = module_of_decl(modules, (int)i);
        if (d->kind == DECL_STRUCT) {
            check_conformance(&c, si, d);
            si++;
        }
    }

    // Pass 2 — check every function and method body.
    si = 0;
    for (size_t i = 0; i < program->count; i++) {
        const Decl *d = program->decls[i];
        c.current_module = module_of_decl(modules, (int)i);
        if (d->kind == DECL_FN) {
            const char *names[MAX_TYPE_ARGS];
            int n = 0;
            for (size_t g = 0; g < d->as.fn.generic_count && n < MAX_TYPE_ARGS; g++) {
                names[n++] = d->as.fn.generics[g].name;
            }
            check_callable(&c, &d->as.fn, -1, names, n);
        } else if (d->kind == DECL_STRUCT) {
            SemType self_type = struct_self_type(&c, si);
            for (size_t m = 0; m < d->as.struct_.method_count; m++) {
                check_callable(&c, &d->as.struct_.methods[m], self_type,
                               c.structs[si].generics, c.structs[si].generic_count);
            }
            si++;
        }
    }

    // Append every lifted lambda to the program as a DECL_FN, after the body pass so
    // it is not re-checked here (its body was checked inline at the lambda site).
    // mono and codegen number these slots right after the declared functions.
    for (int k = 0; k < c.lambda_count; k++) {
        program->decls[program->count++] = c.lambda_decls[k];
    }

    // Compute the monomorphization plan codegen consumes. Only meaningful on a
    // well-typed program.
    if (c.had_error == 0) {
        build_mono_instances(&c, program, out_plan);
        build_layouts(&c, out_layouts, out_layout_count);
    }
    return c.had_error;
}
