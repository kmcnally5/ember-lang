#ifndef EMBER_AST_H
#define EMBER_AST_H

#include "token.h"
#include <stddef.h>

// Intrinsic array-method codes (Expr.as.get.array_op). SINGLE SOURCE: the checker assigns one of
// these, and codegen + the native cgen_c backend dispatch on them — so the value must mean the same
// thing in all three. Named here (not a bare 1/2/3/4 in each file) so they can't drift apart when a
// new array method is added (the "same magic number in 4 places" trap).
enum {
    ARR_OP_NONE        = 0,
    ARR_OP_APPEND      = 1,
    ARR_OP_REMOVE_LAST = 2,
    ARR_OP_LEN         = 3,
    ARR_OP_SLICE       = 4,
    ARR_OP_REMOVE_AT   = 5    // arr.remove_at(i) — remove + return element i, shifting the tail down
};

// The Ember abstract syntax tree.
//
// Nodes come in five families — Type, Expr, Stmt, Pattern, Decl — each a tagged
// union (a `kind` discriminant plus a `union as`). Every node and every child
// array is allocated from the parse arena, so the whole tree is freed at once
// and child pointers never need individual ownership tracking.
//
// `line`/`col` are kept on the major nodes for future diagnostics; the AST
// printer deliberately omits them so golden tests stay stable across edits to a
// test program's surrounding whitespace.

// OwnQual is the ownership qualifier on a parameter, written before the binding
// (e.g. `mut self`, `move items: [string]`). Per MANIFESTO §5b the common case
// is OWN_NONE (an immutable borrow); `mut` and `move` are the explicit,
// self-describing exceptions. It is a property of the parameter, not the type.
typedef enum {
    OWN_NONE,
    OWN_MUT,
    OWN_MOVE
} OwnQual;

// ---------------------------------------------------------------- Types ----

typedef enum {
    TYPE_NAME,      // int, Point, Self
    TYPE_GENERIC,   // Result<Config, string>, Option<T>
    TYPE_ARRAY,     // [T]
    TYPE_FN         // fn(T, …) -> R   — a function value's type
} TypeKind;

typedef struct Type Type;

struct Type {
    TypeKind kind;
    int      line;
    int      col;
    union {
        struct {
            const char *qualifier;   // module alias for `mod.Type`, else NULL
            const char *name;
        } name;
        struct {
            const char *qualifier;   // module alias for `mod.Type<…>`, else NULL
            const char *name;
            Type      **args;
            size_t      arg_count;
        } generic;
        struct {
            Type *elem;
        } array;
        struct {
            Type **params;       // parameter types, in order
            size_t param_count;
            Type  *ret;          // return type, or NULL for a unit-returning function
        } fn;
    } as;
};

// ----------------------------------------------------------- Expressions ----

typedef enum {
    EXPR_INT,
    EXPR_FLOAT,
    EXPR_STRING,
    EXPR_BOOL,
    EXPR_IDENT,
    EXPR_UNARY,      // !x, -x
    EXPR_BINARY,     // a + b, a == b, a && b
    EXPR_CALL,       // callee(args)
    EXPR_GET,        // object.field
    EXPR_INDEX,      // object[index]
    EXPR_ARRAY,      // [a, b, c]
    EXPR_STRUCT_LIT, // Name { field: value }  /  Name<T> { ... }
    EXPR_TRY,        // expr?   (error propagation)
    EXPR_FN_VALUE,   // a named function used as a value (checker rewrites EXPR_IDENT)
    EXPR_LAMBDA,     // |params| expr   or   |params| { ... }
    EXPR_RANGE       // a..b   (exclusive integer range; valid only as a `for` iterator)
} ExprKind;

#define EMBER_MAX_CAPTURES 32   // captured variables per lambda
#define EMBER_MAX_LAMBDAS  512  // lifted lambda functions per program (decl slack)

typedef struct Expr Expr;

// A witness: a concrete type's method fn-indices for one bound interface, in the
// interface's method order. Passed to bounded generic code so it can dispatch an
// interface method on an erased type parameter (dictionary passing).
typedef struct {
    const int *fns;
    int        count;
} Witness;
typedef struct Stmt Stmt;

// A brace-delimited sequence of statements. (Defined here so a lambda expression,
// which carries a body block, can embed one.)
typedef struct {
    Stmt **stmts;
    size_t count;
} Block;

// A function/method/lambda parameter. The receiver `self` is a parameter with
// is_self = 1 (and an optional mut/move qualifier); ordinary parameters carry a
// name and type (a lambda parameter's type may be NULL = inferred).
typedef struct {
    OwnQual     qual;
    int         is_self;
    const char *name;    // NULL when is_self
    Type       *type;    // NULL when is_self or an inferred lambda parameter
    int         release_at_exit;  // checker-set: a refcounted param the callee owns
                                  // a reference to and releases when the call returns
    int         inline_struct_id; // checker-set (value-types 3b.4): a plain all-scalar
                                  // struct param of a non-generic free function is stored
                                  // MULTI-SLOT (its N field slots), -1 otherwise
} Param;

// One `field: value` initialiser inside a struct literal.
typedef struct {
    const char *name;
    Expr       *value;
} StructLitField;

// One piece of a (possibly interpolated) string literal. A literal run carries
// its decoded bytes (`text`/`len`, expr == NULL); an interpolation hole carries
// the parsed expression of `{ … }` (expr != NULL). A plain `"abc"` is one part.
typedef struct {
    Expr       *expr;
    const char *text;
    size_t      len;
    int         render_kind;   // numeric kind of an interpolation hole, so codegen
                               // emits OP_TO_STRING with the right (e.g. u64) render
    int         string_temp;   // 1 if the hole is a fresh OWNED-temp string (a call/concat
                               // result, incl. a desugared `.show()`): codegen skips the
                               // retaining OP_TO_STRING since the value already owns a
                               // reference the fold's OP_CONCAT consumes (else it leaks).
} StrPart;

struct Expr {
    ExprKind kind;
    int      line;
    int      col;
    int      moves_local;   // checker-set on an EXPR_IDENT whose read moves a struct
                            // binding out: codegen nils the slot so a later scope
                            // drop is a no-op (the receiver now owns the value)
    int      suffix_type;   // EXPR_INT: the SemType implied by a width suffix
                            // (e.g. `255u8`), or 0 for an unsuffixed literal
    int      num_kind;      // checker-set numeric kind (0..6) for an arithmetic
                            // node, so codegen emits width-aware overflow opcodes
    int      variant_enum_id;  // checker-set when this node CONSTRUCTS an enum variant (a bare
    int      variant_tag;      // zero-field EXPR_IDENT, or a data-carrying EXPR_CALL): the resolved
                               // enum id + tag, so codegen builds the variant the CHECKER chose
                               // rather than re-resolving by (no-longer-globally-unique) name. Both
                               // -1 when the node does not construct a variant (OFI-073).
    // Dynamic-dispatch upcast: when this value is supplied where an interface type is
    // expected (a `let x: Iface`, an arg, a return, an array element, a struct field),
    // the checker records the implementing struct's vtable here and codegen boxes the
    // value into an interface value {receiver, vtable}. NULL witness = no coercion.
    const int *coerce_witness;        // impl method fn-indices in interface order (the vtable)
    int        coerce_witness_count;
    int        coerce_iface;          // interface id (meaningful only when coerce_witness != NULL)
    union {
        long long   int_lit;     // EXPR_INT
        double      float_lit;   // EXPR_FLOAT
        struct {                 // EXPR_STRING — decoded parts (literal runs + holes)
            StrPart *parts;
            size_t   part_count;
        } str;
        int         bool_lit;    // EXPR_BOOL — 0 or 1
        const char *ident;       // EXPR_IDENT
        struct {
            TokenType op;
            Expr     *operand;
        } unary;
        struct {
            TokenType op;
            Expr     *left;
            Expr     *right;
            int       str_concat;  // checker-set: a string `+` (emit the consuming OP_CONCAT, not OP_ADD)
        } binary;
        struct {
            Expr  *callee;
            Expr **args;
            size_t arg_count;
            // NAMED arguments (OFI-140): for `Circle(radius: 2.0)` enum-variant construction, one entry
            // per arg — the field name, or NULL for a positional arg. The whole pointer is NULL when no
            // argument was named (the common case). The checker validates + reorders into declared field
            // order (named construction is only legal for an enum variant; a function call rejects it).
            const char **arg_names;
            // Bounded generic call: one witness per (type parameter, bound), in the
            // order the callee expects them as hidden leading arguments (param0's
            // bounds, then param1's, …). Each witness is the concrete type's method
            // fn-indices for that bound interface. NULL/0 when the call needs none.
            const Witness *witnesses;
            int            witness_total;
            // Direct function call (free or module-qualified `mod.foo`): the
            // resolved function-table index, set by the checker so codegen needn't
            // re-resolve across modules. -1 for method/builtin/variant calls.
            int         resolved_fn;
            // Monomorphization key: the concrete type arguments inferred for a
            // generic call, in terms of the *enclosing* function's type parameters
            // (so the monomorphizer substitutes the caller's instance through
            // them). `mono_arg_count == 0` for a non-generic call. Set by the checker.
            int         mono_args[8];   // SemType values (8 == MAX_TYPE_ARGS)
            int         mono_arg_count;
            // Set by the checker when the callee is a function *value* (a local of
            // function type, or a lambda) rather than a named function/method: codegen
            // evaluates the callee to a closure and dispatches with OP_CALL_CLOSURE.
            int         closure_call;
            // Set by the checker when the FIRST value pushed for the call — arg0 of a
            // direct call, or the receiver of a method call — is a fresh owned struct
            // temporary passed by borrow. The callee can't release it (a struct has no
            // refcount), so the caller drops it after the call (OP_DROP_UNDER) — else it
            // leaks (OFI-027). It's the first-pushed value, so it lands directly under
            // the call result, exactly where OP_DROP_UNDER reclaims it.
            int         drop_first;
            // Direct calls: a bitmask of which arguments are fresh owned struct
            // temporaries passed by borrow (so the caller must drop them — OFI-027).
            // Generalises drop_first to any argument position / multiple temps: codegen
            // evaluates the marked temps first (keeping copies below the arg region),
            // builds the args (re-fetching temps with OP_PICK), then OP_DROP_UNDER×N.
            int         drop_mask;
            // Value-types 3b.4: per-argument struct id when the matching parameter is a
            // plain all-scalar struct passed MULTI-SLOT (codegen pushes its N field slots
            // instead of a boxed value). -1 for an ordinary boxed arg; the whole pointer
            // is NULL when no argument is multi-slot. Arena-allocated, length arg_count.
            const int  *arg_inline_struct;
            // Value-types 3b.4b: struct id if the callee RETURNS an all-scalar struct
            // MULTI-SLOT (the call leaves N field slots), -1 for a boxed/scalar result.
            int         ret_struct_id;
            // When the result is multi-slot, whether codegen BOXES it right after the call
            // (1, the default — keeps the result a single value for ordinary consumers) or
            // leaves the N slots raw (0 — set by a consumer that takes them directly: a
            // `let` binding a multi-slot struct, or a `return` from a multi-slot function).
            int         box_result;
            // FFI (§5h): registry index of the foreign (C) function this call targets, set by
            // the checker for a call to an `extern "c"` function; codegen emits OP_CALL_C. -1
            // for an ordinary Ember call.
            int         cextern_index;
            // FFI structs-by-value (3b.6): the Ember struct id the C function RETURNS, so the VM
            // reassembles a struct from the wrapper's result leaves; -1 for a scalar return.
            int         cextern_ret_sid;
            int         newtype_ctor;   // OFI-149: this call is a newtype construction (codegen passthrough)
            Expr       *refinement;     // OFI-150: a refined newtype's `where` predicate to check here, or NULL
        } call;
        struct {
            Expr       *object;
            const char *name;
            int         name_line;      // 1-based source position of the field NAME (the token
            int         name_col;       // after the `.`), distinct from the node's object-start
                                        // line/col — lets tooling key on `.field` itself
            int         field_index;    // resolved by the checker; -1 until then
            int         bound_method;   // interface method slot for witness dispatch
                                        // (a.compare(b) on a bounded T); -1 if static
            int         bound_witness;  // bound dispatch: the hidden witness LOCAL slot (free fn),
                                        // or the self FIELD index when bound_via_self (struct method)
            int         bound_via_self; // 1 if the bound's witness is read from a self field
                                        // (instance-storage on a bounded generic struct)
            int         dyn_method;     // interface method slot for DYNAMIC dispatch on an
                                        // interface-typed receiver (d.area()); -1 if not dynamic.
                                        // codegen reads the vtable from the value (OP_CALL_DYN)
            int         array_op;       // intrinsic array method (ARR_OP_* above), set by the checker:
                                        // none/append/remove_last/len/slice/remove_at
            int         string_op;      // intrinsic string method, set by the checker:
                                        // 0 none, 1 len, 2 chars, 3 split, 4 parse_int
            int         clone_op;       // intrinsic `.clone()` deep copy, set by the checker:
                                        // 0 none, 1 array receiver, 2 value-struct receiver (OFI-082)
            int         drop_object;    // checker-set: the object is a fresh owned struct
                                        // temporary (a call/construction result), so after
                                        // reading the field the receiver must be dropped —
                                        // else it leaks (OFI-027). 0 = a borrow, keep it.
            int         inline_field;   // checker-set (value-types 3b.5): this reads a nested
                                        // struct field stored INLINE — the read materialises a
                                        // value COPY, so a nested assignment must write it back.
            int         inline_struct_id; // checker-set: the nested inline-struct field's struct
                                        // id (the native backend materialises a value COPY into an
                                        // em_s); -1 otherwise. (inline_field stays a bool for VM
                                        // nested write-back; this carries the sid for the cgen.)
        } get;
        struct {
            Expr *object;
            Expr *index;
            int   inline_struct_id;  // checker-set: if `arr[i]` reads an all-scalar struct stored
                                     // INLINE, its struct type id (the read materialises a value
                                     // COPY — codegen unboxes into an em_s); -1 otherwise.
        } index;
        struct {
            Expr **elems;
            size_t count;
            int    elem_struct_id;  // checker-set: if the element is an all-scalar
                                    // struct stored inline, its struct type id (codegen
                                    // emits OP_NEW_STRUCT_ARRAY); -1 for a boxed/scalar
                                    // element (the usual OP_NEW_ARRAY).
        } array;
        struct {
            Type           *type;        // the named (possibly generic) type
            StructLitField *fields;
            size_t          field_count;
            int             resolved_struct;  // checker-set struct-type id (-1 until then)
            // Value-types 3b.4c: struct id if this construction may be built MULTI-SLOT
            // (an all-scalar struct — its N field values stay on the stack, no box), -1
            // otherwise. `box_result` (default 1) is cleared by a consumer that takes the
            // slots directly (a `let` binding, a `return` from a multi-slot function).
            int             inline_sid;
            int             box_result;
            // Instance-storage of bound witnesses: for a bounded generic struct
            // (Map<K: Hash+Eq, V>) the checker builds the concrete key type's witnesses
            // here and codegen appends them as hidden trailing fields at construction.
            const Witness  *witnesses;
            int             witness_total;
        } struct_lit;
        struct {
            Expr *operand;
            int   success_variant;   // checker-resolved: Ok/Some variant index (-1 until then)
        } try_;
        int fn_value;   // EXPR_FN_VALUE — the callee's function-table index
        struct {
            Expr *lo;               // inclusive lower bound
            Expr *hi;               // exclusive upper bound
        } range;
        struct {
            Param *params;          // lambda parameters (types may be NULL = inferred)
            size_t param_count;
            Block  body;            // expression body is wrapped as a single `return`
            // Filled by the checker once the lambda is lifted to a real function:
            int    lifted_fn_index; // its slot in the function table
            int    capture_count;   // captured enclosing locals, pushed at the site
            int    capture_slots[EMBER_MAX_CAPTURES];
        } lambda;
    } as;
};

// -------------------------------------------------------------- Patterns ----

// A match-case pattern: an optional qualifier (`Shape.` in the full form), a
// variant name, and zero or more positional field bindings.
typedef struct {
    const char  *type_name;     // NULL in the short form `case Circle(r)`
    const char  *variant;
    int          enum_id;       // checker-set: the scrutinee enum's id + this variant's tag, so
    int          variant_index; // codegen dispatches on the CHECKER's resolution, not a by-name
                                // lookup (which is no longer globally unique — OFI-073). -1 until set.
    const char **bindings;
    size_t       binding_count;
    int          binding_struct[16];  // checker-set per binding: an all-scalar value-struct payload's
                                      // struct id (the native backend unboxes it into an em_s); -1
                                      // for a scalar/boxed/non-flat binding (max 16 payload fields).
    int          wildcard;      // `case _` — matches every otherwise-unhandled variant
    int          line;
    int          col;
} Pattern;

// ------------------------------------------------------------ Statements ----

// One arm of a match.
typedef struct {
    Pattern pattern;
    Block   body;
} MatchCase;

typedef enum {
    STMT_LET,        // let/var name [: type] = value
    STMT_RETURN,     // return [value]
    STMT_EXPR,       // an expression used for effect
    STMT_ASSIGN,     // target = value
    STMT_IF,         // if cond { } [else ...]
    STMT_FOR,        // for name in iter { }
    STMT_LOOP,       // loop { }
    STMT_BREAK,
    STMT_CONTINUE,
    STMT_MATCH,      // match value { case ... }
    STMT_SPAWN,      // spawn call
    STMT_NURSERY,    // nursery { }
    STMT_BLOCK       // a bare { } block
} StmtKind;

struct Stmt {
    StmtKind kind;
    int      line;
    int      col;
    union {
        struct {
            int         is_var;   // 0 = let (immutable), 1 = var (mutable)
            const char *name;
            Type       *type;     // NULL when inferred
            Expr       *value;
            int         drop_at_scope_end;  // checker-set: owns a struct never moved
                                            // out ⇒ codegen frees it at scope exit
            int         inline_struct_id;   // checker-set (value-types 3b): an immutable
                                            // all-scalar struct binding stored MULTI-SLOT
                                            // (its fields exploded on the stack), this is
                                            // the struct type id; -1 = boxed (the usual).
            int         scalar_kind;        // checker-set (OFI-123): the binding's numeric
                                            // width kind (int_kind: 0 i64 … 9 f64) when it is
                                            // a sized scalar, so the NATIVE backend stores it
                                            // at width (uint8_t/…/float) not a 16-byte Value;
                                            // -1 for any non-numeric binding.
        } let;
        struct {
            Expr *value;          // NULL for a bare `return`
        } ret;
        struct {
            Expr *expr;
            int   release_temp;   // checker-set: the discarded result is a fresh
                                  // refcounted value to release (not just pop)
        } expr;
        struct {
            Expr *target;
            Expr *value;
        } assign;
        struct {
            Expr *cond;
            Block then_blk;
            Stmt *else_branch;    // NULL, or a STMT_BLOCK, or a STMT_IF (else-if)
        } if_;
        struct {
            const char *var;        // element variable (or the index, for `for i in range`)
            const char *index_var;  // NULL for `for x in …`; the index in `for (i, x) in array`
            Expr       *iter;
            Block       body;
        } for_;
        struct {
            Block body;
        } loop;
        struct {
            Expr      *value;
            MatchCase *cases;
            size_t     case_count;
            int        subject_drop;   // checker-set: the scrutinee is a fresh
                                       // refcounted temporary to release at match end
        } match;
        struct {
            Expr *call;
        } spawn;
        struct {
            Block body;
        } nursery;
        struct {
            Block body;
        } block;
    } as;
};

// ----------------------------------------------------------- Declarations ----

// A generic type parameter: `T`, `T: Ord` (an interface bound), `T: Copy` (the
// copyable marker — MANIFESTO §5f), or several via `+` (`T: Hash + Eq + Copy`).
#define MAX_BOUNDS 4
typedef struct {
    const char *name;
    const char *bounds[MAX_BOUNDS];   // interface bounds (Copy excluded), in source order
    int         bound_count;          // number of interface bounds
    int         is_copy;              // 1 if `Copy` is among the bounds (the param is copyable)
} GenericParam;


// A struct field or, reused, an enum variant's payload field.
typedef struct {
    const char *name;
    Type       *type;
    const char *doc;     // `///` doc comment, cleaned, or NULL (struct fields only)
    int         line;    // 1-based source position of the field name, for go-to-definition
    int         col;
} Field;

// One enum variant, with zero or more payload fields.
typedef struct {
    const char *name;
    Field      *fields;
    size_t      field_count;
    const char *doc;     // `///` doc comment, cleaned, or NULL
} Variant;

// A function declaration, shared by free functions, struct methods, and
// interface method signatures. Interface signatures set has_body = 0.
typedef struct {
    const char   *name;
    GenericParam *generics;
    size_t        generic_count;
    Param        *params;
    size_t        param_count;
    Type         *return_type;   // NULL = unit
    int           ret_struct_id; // checker-set (value-types 3b.4b): struct id if this
                                 // function RETURNS an all-scalar struct MULTI-SLOT, else -1
    // Contracts (MANIFESTO §5e). Each is a bool expression: a `requires` clause is a
    // precondition checked on entry, an `ensures` clause a postcondition checked
    // before every return (with `result` bound to the return value). Debug builds
    // check them; release elides. count 0 when the function has no contract.
    Expr        **requires_clauses;
    size_t        requires_count;
    Expr        **ensures_clauses;
    size_t        ensures_count;
    int           has_body;
    Block         body;
    int           line;
    int           col;
    const char   *src_path;  // OFI-111a: defining module's path for a LIFTED LAMBDA (which lands
                             // outside every ModuleSet range, so module_of_decl can't map it); NULL
                             // for a normal fn/method (codegen maps those via module_of_decl).
    const char   *doc;     // `///` doc comment, cleaned, or NULL
} FnDecl;

typedef enum {
    DECL_FN,
    DECL_STRUCT,
    DECL_ENUM,
    DECL_INTERFACE,
    DECL_IMPORT,
    DECL_LET,        // top-level (global) let/var binding
    DECL_EXTERN,     // extern "c" { fn … } — foreign (C) function signatures (§5h)
    DECL_TYPE        // type UserId = int — a distinct nominal type over a base (OFI-149)
} DeclKind;

typedef struct Decl Decl;

struct Decl {
    DeclKind kind;
    int      line;
    int      col;
    const char *doc;     // `///` doc comment, cleaned, or NULL (top-level decls)
    union {
        FnDecl fn;
        struct {
            const char   *name;
            GenericParam *generics;
            size_t        generic_count;
            const char  **implements;     // interfaces this struct declares it satisfies
            size_t        implements_count;
            Field        *fields;
            size_t        field_count;
            FnDecl       *methods;
            size_t        method_count;
            int           is_rc;          // `rc struct`: a shared, deeply-immutable, refcounted struct
            int           is_resource;    // `resource struct`: a uniquely-owned struct with a `drop` (OFI-122)
        } struct_;
        struct {
            const char   *name;
            GenericParam *generics;
            size_t        generic_count;
            const char  **implements;
            size_t        implements_count;
            Variant      *variants;
            size_t        variant_count;
        } enum_;
        struct {
            const char   *name;
            GenericParam *generics;
            size_t        generic_count;
            FnDecl       *methods;       // signatures only (has_body = 0)
            size_t        method_count;
        } interface;
        struct {
            const char *path;     // the import string (raw inner text)
            const char *alias;    // name after `as`
        } import;
        struct {
            int         is_var;
            const char *name;
            Type       *type;
            Expr       *value;
        } let;
        struct {
            const char *abi;        // the ABI string, e.g. "c"
            FnDecl     *fns;        // foreign function signatures (has_body = 0)
            size_t      fn_count;
        } extern_;
        struct {
            const char *name;       // the newtype's name (e.g. UserId) — OFI-149
            Type       *base;       // the underlying base type (int, float, bool, …)
            Expr       *refinement; // OFI-150: the `where` predicate (over `self`), or NULL
        } type_;
    } as;
};

// A whole compilation unit: the ordered top-level declarations of one file.
typedef struct {
    Decl **decls;
    size_t count;
} Program;

// Prints a stable, indented textual rendering of the tree to stdout. Used by the
// `--emit=ast` driver mode and the parser golden tests. Source positions are
// intentionally omitted so the output is robust to whitespace edits.
void ast_print(const Program *program);

#endif // EMBER_AST_H
