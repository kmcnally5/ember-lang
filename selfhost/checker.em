// selfhost/checker.em — the Ember type checker, written in Ember (Stage 3 / M3 of the self-hosting
// bootstrap, docs/design/self-hosting.md). It consumes the self-hosted parser's AST ([ps.Decl]) and
// reproduces stage-0's checker (src/check.c) — verdict first (accept valid programs, reject ill-typed
// ones), then exact diagnostic parity against `emberc --emit=bytecode` over the corpus.
//
// Mirrors stage-0's design: SemType is a plain int with million-strided bands (so type equality is `==`,
// which suits Ember — no enum `==`); a multi-pass pipeline registers all type/function NAMES, then
// signatures/fields, then checks bodies (so forward references resolve); locals are a flat array + a
// scope_depth with append/truncate. This file is built in stages — the foundation here is name
// resolution (the first concern: undefined variables); type inference, ownership, and contracts grow on
// top. Methods-in-struct (`mut self`) because native free-function `mut` struct params don't persist
// mutation (OFI-161).

import "parser" as ps


// SemType is a plain int (stage-0 check.c): equality is `==`. Kept POSITIVE (Ember top-level constants
// must be literals, and a negative is `0 - n`, an expression). Small sentinels are primitives; user types
// live in million-strided bands. TY_INFER is the lenient "type unknown to this in-progress checker" — a
// check that compares against it is SKIPPED, so an unimplemented corner never produces a false rejection.
let TY_ERROR: int = 0
let TY_INFER: int = 1
let TY_INT: int = 2          // i64 alias
let TY_FLOAT: int = 3        // f64 alias
let TY_BOOL: int = 4
let TY_STRING: int = 5
let TY_UNIT: int = 6
let TY_PTR: int = 7
let TY_SELF: int = 8
let TY_ARRAY: int = 9        // a generic array (element not yet tracked — lenient)
let TY_I8: int = 10
let TY_I16: int = 11
let TY_I32: int = 12
let TY_U8: int = 13
let TY_U16: int = 14
let TY_U32: int = 15
let TY_U64: int = 16
let TY_F32: int = 17
let STRUCT_BASE: int = 1000000
let ENUM_BASE: int = 2000000


fn is_numeric(t: int) -> bool {
    return t == TY_INT || t == TY_FLOAT || t == TY_I8 || t == TY_I16 || t == TY_I32 || t == TY_U8 || t == TY_U16 || t == TY_U32 || t == TY_U64 || t == TY_F32
}


// is_numeric_typename reports whether a name is a numeric WIDTH-conversion spelling (`u8(x)`, `i32(x)`)
// — the exact set check.c:numeric_typename recognises. Note `float`/`bool`/`string` are NOT here (only
// `f32`/`f64`/`i*`/`u*`/`int`): a call to a free function so named parses as a conversion (OFI-066).
fn is_numeric_typename(name: string) -> bool {
    return name == "i8" || name == "i16" || name == "i32" || name == "i64" || name == "int" || name == "u8" || name == "u16" || name == "u32" || name == "u64" || name == "f32" || name == "f64"
}


// scalar_class collapses a SemType to a coarse comparable class: 1 = any numeric width, 2 = string,
// 3 = bool, 0 = everything else (struct/enum/array/Ptr/unit/unmodelled — compared leniently, i.e. skipped).
fn scalar_class(t: int) -> int {
    if is_numeric(t) {
        return 1
    }
    if t == TY_STRING {
        return 2
    }
    if t == TY_BOOL {
        return 3
    }
    return 0
}


// prim_type maps a primitive type-name spelling to its SemType, or TY_ERROR if not a primitive.
fn prim_type(name: string) -> int {
    if name == "int" || name == "i64" { return TY_INT }
    if name == "float" || name == "f64" { return TY_FLOAT }
    if name == "bool" { return TY_BOOL }
    if name == "string" { return TY_STRING }
    if name == "Ptr" { return TY_PTR }
    if name == "Self" { return TY_SELF }
    if name == "i8" { return TY_I8 }
    if name == "i16" { return TY_I16 }
    if name == "i32" { return TY_I32 }
    if name == "u8" { return TY_U8 }
    if name == "u16" { return TY_U16 }
    if name == "u32" { return TY_U32 }
    if name == "u64" { return TY_U64 }
    if name == "f32" { return TY_F32 }
    return TY_ERROR
}


// BUILTINS is every global built-in callable: the core fns + numeric conversions + the graphics
// primitives (src/builtin.c native_id_for_name) + the concurrency builtins + the width-conversion type
// names used as functions (int(x), u8(x), ...). A call target matching one of these is never "undefined".
fn builtin_names() -> [string] {
    return ["print", "println", "concat", "hash", "abs", "ceil", "floor", "round", "sqrt", "pow",
        "parse_float", "char_code", "from_char_code", "byte_slice", "read_line", "read_file", "write_file",
        "random", "args", "env", "exit", "channel", "send", "recv", "close", "to_int", "to_float",
        "draw_rect", "draw_text", "fill_circle", "fill_grad", "fill_round", "stroke_round", "shadow",
        "measure_text", "measure_misses", "text_line_height", "load_font", "set_font", "set_alpha",
        "set_layer", "set_cursor", "clip_push", "clip_pop", "screen_width", "screen_height",
        "window_open", "window_close", "window_should_close", "frame_begin", "frame_end", "frame_steps",
        "frame_capture", "key_down", "key_pressed", "key_repeat", "char_pressed", "mouse_x", "mouse_y",
        "mouse_down", "mouse_wheel", "had_input", "set_event_waiting", "clipboard_get", "clipboard_set",
        "tape_open", "tape_close", "tape_mark",
        "assert", "clock", "len", "try_recv", "wrapping_add", "wrapping_sub", "wrapping_mul",
        "int", "float", "bool", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64"]
}


fn is_builtin(name: string) -> bool {
    return contains(builtin_names(), name)
}


// builtin_ret_type returns the SemType a built-in call yields, for the cases the checker relies on: the
// pure side-effecting builtins return UNIT (so binding/assigning their result is an error). Everything
// else stays TY_INFER (lenient) — a value-returning builtin is never wrongly rejected.
fn builtin_ret_type(name: string) -> int {
    if name == "print" || name == "println" || name == "exit" || name == "send" || name == "close" || name == "assert" {
        return TY_UNIT
    }
    return TY_INFER
}


struct Local {
    name: string
    depth: int
    ty: int                    // the binding's SemType (TY_INFER when not yet inferable)
    is_var: bool               // true for `var`/`mut`/`move`; false for `let` and borrowed bindings
    owned: bool                // owns its value (a local, or a `move` param) vs borrows it (a plain param)
    mvparam: bool              // a `move`-qualified parameter — movable by the qualifier regardless of type
}


fn is_integer_ty(t: int) -> bool {
    return t == TY_INT || t == TY_I8 || t == TY_I16 || t == TY_I32 || t == TY_U8 || t == TY_U16 || t == TY_U32 || t == TY_U64
}


struct Checker {
    fns: [string]              // top-level + method function names (callable)
    structs: [string]          // struct type names
    enums: [string]            // enum type names
    variants: [string]         // enum variant names (resolve_variant, module-globally-unique)
    globals: [string]          // top-level let/var names
    aliases: [string]          // import aliases
    fn_names: [string]         // top-level free-function names, parallel to fn_arity (for the arity check)
    fn_arity: [int]            // ...and their declared parameter counts (self excluded)
    fn_ret: [int]              // ...and their return SemType (TY_PTR for an `fopen`-style extern; TY_UNIT void)
    fn_pstart: [int]           // ...start index into fn_ptype for this fn's params
    fn_ptype: [int]            // every free-fn param SemType, concatenated (arg-type check)
    fn_pqual: [int]            // ...and each param's qualifier (0 none / 1 mut / 2 move), parallel to fn_ptype
    fn_ptparam: [int]          // ...if a param's type is a BARE generic type-param `T`, that param's index; else -1
    fn_extern: [bool]          // ...is this entry an `extern "c"` fn (no bytecode slot — cannot be spawned)?
    fg_name: [string]          // free-fn generic-bound table: the function name (one row per param-bound)
    fg_param: [int]            // ...the generic-parameter index within that function
    fg_bound: [string]         // ...one bound name (an interface, or "Copy") on that param
    struct_garity: [int]       // ...generic type-parameter count per struct (parallel to `structs`; 0 for a newtype)
    sg_struct: [int]           // struct generic-bound table: struct id (one row per param-bound)
    sg_param: [int]            // ...the generic-parameter index within that struct
    sg_bound: [string]         // ...one bound name (an interface, or "Copy") on that param
    simpl_struct: [int]        // struct-implements table: struct id
    simpl_iface: [string]      // ...one interface name the struct declares it `implements`
    newtypes: [string]         // newtype names (a newtype value must stay lenient, NOT resolve to a struct)
    sf_owner: [int]            // struct-field table: owning struct index (parallel to `structs`)
    sf_name: [string]          // ...field name
    sf_type: [int]             // ...field SemType (TY_INFER for any non-primitive)
    sf_tparam: [int]           // ...if the field's type is a bare generic type-param `T`, its index; else -1
                               // (lets `Box<int>{value: …}` substitute T→int and type-check the field value)
    sm_owner: [int]            // struct-method table: owning struct index
    sm_name: [string]          // ...method name
    sm_arity: [int]            // ...declared param count (self excluded)
    sm_pstart: [int]           // ...start index into sm_ptype
    sm_ptype: [int]            // every method param SemType, concatenated (method arg-type check)
    sm_mutself: [bool]         // ...does the method take `mut self` (a mutable receiver)?
    sm_moveself: [bool]        // ...does the method take `move self` (the call CONSUMES the receiver)?
    sm_ret: [int]              // ...the method's return SemType (TY_UNIT for a void method; TY_INFER if unmodelled)
    ev_enum: [int]             // enum-variant table: owning enum index (parallel to `enums`)
    ev_name: [string]          // ...variant name
    ev_arity: [int]            // ...payload field count
    ifaces: [string]           // interface names — a value of interface type stays lenient (coercion)
    im_iface: [int]            // interface-method table: owning interface index (parallel to `ifaces`)
    im_name: [string]          // ...required method name (a conforming struct must declare it)
    im_arity: [int]            // ...required param count (self excluded)
    im_ret: [int]              // ...required return SemType (TY_INFER/TY_SELF stay lenient on a conformance compare)
    tparams: [string]          // generic type-parameter names currently in scope (resolve to TY_INFER)
    current_return: int        // the enclosing function's return SemType (for the return-type check)
    self_is_var: bool          // is the enclosing method's receiver `mut self`/`move self` (mutable)?
    loop_depth: int            // enclosing loop/for nesting (break/continue must be inside one)
    nursery_depth: int         // enclosing `nursery` nesting (a `spawn` must be inside one)
    locals: [Local]
    local_moved: [bool]        // MUTABLE move state, parallel to `locals` (element-struct writeback isn't
                               // self-compilable yet — OFI-061 — so the moved flag lives in a scalar array)
    local_consumed: [bool]     // the must-consume DUAL (AND-merge): for an OWNED Ptr local, false = an open
                               // handle obligation (leaks at an exit), true = discharged; true for everything
                               // else (no obligation). OFI-049.
    loop_break_consumed: [bool]  // AND-merge of the consumed-state at each `break` in the current loop — the
    loop_saw_break: bool         // post-loop consumed-state is the merge of all break-exit paths (close-on-break).
    local_unbounded_tp: [bool]   // ...is this local a param of an UNBOUNDED generic type-param `T` (no interface
                                 // bound)? A method call on one is an error (check.c:4073); parallel to `locals`.
    scope_depth: int
    diags: [string]            // collected diagnostic messages (positions added in M3c)


    fn error(mut self, msg: string) {
        self.diags.append(msg)
    }


    // ---- scope handling: a flat locals array + a depth, with append/truncate (stage-0 check.c) --------
    // declare also enforces no-redeclaration-in-the-same-scope: a binding whose name already exists at the
    // current depth is an error (stage-0 treats a function's params and its body top level as one scope;
    // nested blocks open deeper scopes where shadowing IS allowed). `_` is the discard name, never a redecl.
    fn declare(mut self, name: string, ty: int, is_var: bool, owned: bool, mvparam: bool) {
        if name != "_" {
            var i = self.locals.len() - 1
            loop {
                if i < 0 {
                    break
                }
                if self.locals[i].depth < self.scope_depth {
                    break                            // left the current scope; deeper names already truncated
                }
                if self.locals[i].name == name {
                    self.error("redeclaration of a variable in the same scope")
                    break
                }
                i = i - 1
            }
        }
        self.locals.append(Local{ name: name, depth: self.scope_depth, ty: ty, is_var: is_var, owned: owned, mvparam: mvparam })
        self.local_moved.append(false)
        // an OWNED Ptr local is an OPEN obligation (consumed=false); everything else has none (true).
        self.local_consumed.append((owned && ty == TY_PTR) == false)
        self.local_unbounded_tp.append(false)   // set true by check_fn only for an unbounded-type-param param
    }


    // local_is_var reports whether the nearest in-scope binding `name` is mutable (`var`/`mut`/`move`).
    // A name that is not a local resolves to false — callers must gate on resolve_local first.
    fn local_is_var(self, name: string) -> bool {
        var i = self.locals.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.locals[i].name == name {
                return self.locals[i].is_var
            }
            i = i - 1
        }
        return false
    }


    fn resolve_local(self, name: string) -> bool {
        var i = self.locals.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.locals[i].name == name {
                return true
            }
            i = i - 1
        }
        return false
    }


    // local_slot returns the innermost in-scope `locals` index of `name`, or -1.
    fn local_slot(self, name: string) -> int {
        var i = self.locals.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.locals[i].name == name {
                return i
            }
            i = i - 1
        }
        return 0 - 1
    }


    // is_move_type reports whether a value of SemType `t` is MOVED (vs copied) on transfer — a uniquely-owned
    // mutable aggregate: a struct or an array (mirrors src/check.c:is_move_type). Scalars, strings, and enums
    // copy/share. (rc structs are NOT move types, but the self-host parser drops the rc flag — handled in the
    // rc regime; for now an rc struct used-after-copy is the one residual risk, watched by the gate.)
    fn is_move_type(self, t: int) -> bool {
        if t >= STRUCT_BASE && t < ENUM_BASE {
            return true
        }
        return t == TY_ARRAY || t == TY_PTR
    }


    // consume_move marks an OWNED MOVE-TYPE local as moved when it is consumed by-value into an OWNER (a
    // let/var initialiser, a return, a struct-field value, an array element, a `move` argument). A borrowed
    // param/binding (owned==false), a copy-type value, or a non-identifier expression is NOT a move.
    fn consume_move(mut self, e: ps.Expr, line: int) {
        match e {
            case EIdent(name) {
                let slot = self.local_slot(name)
                if slot >= 0 {
                    if self.locals[slot].owned == false && self.locals[slot].ty == TY_PTR {
                        // OFI-049: a BORROWED Ptr (a plain `f: Ptr` param) may not be closed or transferred —
                        // the caller still owns the handle; this would double-close / strand them.
                        self.error("cannot close or transfer a borrowed 'Ptr'; take it by 'move' to gain ownership (declare the parameter 'move f: Ptr', not 'f' or 'mut f')")
                    } else if self.locals[slot].owned && self.is_boxed_move(slot) {
                        self.local_moved[slot] = true
                        self.local_consumed[slot] = true   // a Ptr handle obligation is discharged on this path
                    }
                }
            }
            case _ {
            }
        }
    }


    // report_unconsumed_ptrs reports each OWNED Ptr local (index >= from) still OPEN (consumed==false) on the
    // current path — an opened-but-not-closed leak (OFI-049). Called at function exits (return / fall-through).
    fn report_unconsumed_ptrs(mut self, from: int) {
        var i = from
        loop {
            if i >= self.locals.len() {
                break
            }
            if self.locals[i].owned {
                if self.locals[i].ty == TY_PTR {
                    if self.local_consumed[i] == false {
                        self.error("'{self.locals[i].name}' is a 'Ptr' opened but not closed on this path")
                    }
                }
            }
            i = i + 1
        }
    }


    // merge_consumed ANDs another consumed-snapshot into the current state (a Ptr obligation is discharged
    // after a join only if discharged on EVERY reaching path).
    fn merge_consumed(mut self, other: [bool]) {
        var i = 0
        loop {
            if i >= self.local_consumed.len() {
                break
            }
            if i < other.len() {
                if other[i] == false {
                    self.local_consumed[i] = false
                }
            }
            i = i + 1
        }
    }


    // merge_into_break ANDs another consumed-snapshot into the loop's break accumulator (a Ptr is discharged
    // on the post-loop path only if discharged on EVERY break path).
    fn merge_into_break(mut self, other: [bool]) {
        var i = 0
        loop {
            if i >= self.loop_break_consumed.len() {
                break
            }
            if i < other.len() {
                if other[i] == false {
                    self.loop_break_consumed[i] = false
                }
            }
            i = i + 1
        }
    }


    // check_loop_backedge reports an OUTER local (index < loop_base) that was NOT moved before the loop but
    // IS moved at the body's end on a path that reaches the back-edge — it would be moved AGAIN next
    // iteration (OFI-074). Only runs when the body can reach the back-edge (does not always exit the loop).
    fn check_loop_backedge(mut self, pre: [bool], loop_base: int) {
        var i = 0
        loop {
            if i >= loop_base {
                break
            }
            if i < self.local_moved.len() {
                if pre[i] == false {
                    if self.local_moved[i] {
                        self.error("value moved inside a loop body (it would be moved again on the next iteration)")
                    }
                }
            }
            i = i + 1
        }
    }


    // merge_moved ORs another moved-snapshot into the current state (the OR-merge: moved on ANY path).
    fn merge_moved(mut self, other: [bool]) {
        var i = 0
        loop {
            if i >= self.local_moved.len() {
                break
            }
            if i < other.len() {
                if other[i] {
                    self.local_moved[i] = true
                }
            }
            i = i + 1
        }
    }


    // is_boxed_move reports whether local `slot` is DEFINITELY a boxed move value — an array/Ptr, or a `var`
    // (mutated ⇒ boxed) struct. A `let` struct is left lenient: an all-scalar one is MULTI-SLOT (copied, not
    // moved — check.c:2627), and without recursive all-scalar analysis we can't tell it from a boxed one, so
    // we never mark it (no false-reject; a boxed-let-struct move is simply not yet caught).
    fn is_boxed_move(self, slot: int) -> bool {
        if self.locals[slot].mvparam {
            return true                  // a `move` param is movable by the qualifier (any type, incl. generic T)
        }
        let t = self.locals[slot].ty
        if t == TY_ARRAY || t == TY_PTR {
            return true
        }
        if t >= STRUCT_BASE && t < ENUM_BASE {
            if self.locals[slot].is_var {
                return true              // a `var`/mutated struct is BOXED
            }
            return self.struct_has_string_field(t - STRUCT_BASE)   // a `let` struct is boxed iff a KNOWN
                                                                   // refcounted field; a nested-struct field
                                                                   // is TY_INFER → lenient (multi-slot copy)
        }
        return false
    }


    // struct_has_string_field reports whether struct index `sid` has a field of a KNOWN refcounted type (a
    // string) — which forces the struct BOXED (a move value). Other non-scalar fields (arrays, nested
    // structs, enums) are TY_INFER in the lenient checker, so they don't force boxing here (a recursively
    // all-scalar struct stays a multi-slot COPY — no false-reject on `nested_struct_multislot`).
    fn struct_has_string_field(self, sid: int) -> bool {
        var i = 0
        loop {
            if i >= self.sf_owner.len() {
                break
            }
            if self.sf_owner[i] == sid {
                if self.sf_type[i] == TY_STRING {
                    return true
                }
            }
            i = i + 1
        }
        return false
    }


    // local_type returns the SemType of the nearest in-scope binding `name`, or TY_INFER if `name` is not
    // a local (a function, global, variant, or the lenient unknown case — callers stay lenient on INFER).
    fn local_type(self, name: string) -> int {
        var i = self.locals.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.locals[i].name == name {
                return self.locals[i].ty
            }
            i = i - 1
        }
        return TY_INFER
    }


    // enum_has_variants reports whether enum index `eid` has any rows in the variant table (ev_enum/ev_name).
    // Option/Result (and any generic enum whose variants are deliberately unregistered) have NONE, so a bare
    // `Option`/`Result` annotation must stay TY_INFER rather than resolving to a concrete-but-empty enum id —
    // otherwise a `match` would reject every real Some/Ok/... pattern as "not belonging" to an empty table.
    fn enum_has_variants(self, eid: int) -> bool {
        var i = 0
        loop {
            if i >= self.ev_enum.len() {
                break
            }
            if self.ev_enum[i] == eid {
                return true
            }
            i = i + 1
        }
        return false
    }


    // variant_enum returns the enum SemType (ENUM_BASE+id) of a bare variant name from a USER enum, or -1
    // if `name` is not a registered user-enum variant. Prelude variants (Some/None/Ok/Err) are NOT in this
    // table (their enums are generic → stay TY_INFER), so a `match` on them stays lenient.
    fn variant_enum(self, name: string) -> int {
        var i = 0
        loop {
            if i >= self.ev_name.len() {
                break
            }
            if self.ev_name[i] == name {
                return ENUM_BASE + self.ev_enum[i]
            }
            i = i + 1
        }
        return -1
    }


    // is_known reports whether a bare value-position identifier resolves to anything: a local, the
    // pseudo-names self/result/_, a bare enum variant, a top-level function, or a global constant.
    fn is_known(self, name: string) -> bool {
        if name == "self" || name == "result" || name == "_" {
            return true
        }
        if self.resolve_local(name) {
            return true
        }
        if contains(self.variants, name) {
            return true
        }
        if contains(self.fns, name) {
            return true
        }
        if contains(self.globals, name) {
            return true
        }
        if contains(self.structs, name) {
            return true
        }
        if contains(self.enums, name) {
            return true
        }
        if contains(self.ifaces, name) {
            return true
        }
        if contains(self.aliases, name) {
            return true
        }
        return false
    }


    // ---- Pass 1: register all top-level NAMES so forward references resolve -----------------------------
    // type_exists reports whether `name` is already a declared type (a struct/newtype, an enum, or an
    // interface).
    fn type_exists(self, name: string) -> bool {
        return index_of(self.structs, name) >= 0 || index_of(self.enums, name) >= 0 || index_of(self.ifaces, name) >= 0
    }


    // is_fieldless_concrete reports whether `t` is a CONCRETE value type that cannot carry fields — a
    // primitive (int/float/bool/string/sized) or a known enum. A struct, an interface value, or an
    // unmodelled (TY_INFER) / aliased object is NOT (it stays lenient — field access may be valid).
    fn is_fieldless_concrete(self, t: int) -> bool {
        if t == TY_INT || t == TY_FLOAT || t == TY_BOOL || t == TY_STRING {
            return true
        }
        if t >= TY_I8 && t <= TY_F32 {
            return true
        }
        if t >= ENUM_BASE && t < ENUM_BASE + self.enums.len() {
            return true
        }
        return false
    }


    // is_duplicate_type reports a duplicate TYPE declaration. The prelude enums Option/Result are pre-seeded
    // but user code MAY redeclare them (a self-contained test often defines its own `enum Option<T>`), so a
    // redeclaration of a prelude name is NOT a duplicate.
    fn is_duplicate_type(self, name: string) -> bool {
        if name == "Option" || name == "Result" {
            return false
        }
        return self.type_exists(name)
    }


    fn register(mut self, decls: [ps.Decl]) {
        var i = 0
        loop {
            if i >= decls.len() {
                break
            }
            match decls[i] {
                case DFn(f) {
                    if index_of(self.fns, f.name) >= 0 {
                        self.error("a function with this name is already declared in this module")
                    }
                    // a FREE function named like a numeric width type is unreachable — a call `i32(x)` parses
                    // as a width conversion before free-fn resolution (OFI-066). (Methods use `x.i32()`: fine.)
                    if is_numeric_typename(f.name) {
                        self.error("a function cannot be named like a numeric type (a call would parse as a width conversion)")
                    }
                    self.fns.append(f.name)
                    self.fn_names.append(f.name)
                    self.fn_extern.append(false)
                    var pc = 0
                    var pp = 0
                    loop {
                        if pp >= f.params.len() {
                            break
                        }
                        if f.params[pp].is_self == false {
                            pc = pc + 1
                        }
                        pp = pp + 1
                    }
                    self.fn_arity.append(pc)
                    if f.ret.len() > 0 {
                        self.fn_ret.append(self.annotation_type(f.ret[0]))
                    } else {
                        self.fn_ret.append(TY_UNIT)
                    }
                }
                case DStruct(name, generics, impls, fields, methods) {
                    if self.is_duplicate_type(name) {
                        self.error("a type with this name is already declared in this module")
                    }
                    self.structs.append(name)
                    self.struct_garity.append(generics.len())
                }
                case DEnum(name, generics, impls, variants) {
                    if self.is_duplicate_type(name) {
                        self.error("a type with this name is already declared in this module")
                    }
                    self.enums.append(name)
                    var v = 0
                    loop {
                        if v >= variants.len() {
                            break
                        }
                        self.variants.append(variants[v].name)
                        v = v + 1
                    }
                }
                case DInterface(name, generics, methods) {
                    if self.is_duplicate_type(name) {
                        self.error("a type with this name is already declared in this module")
                    }
                    let iid = self.ifaces.len()
                    self.ifaces.append(name)         // an interface is a type NAME but not a struct id
                    var imi = 0                      // record each required method (name + arity) for conformance
                    loop {
                        if imi >= methods.len() {
                            break
                        }
                        self.im_iface.append(iid)
                        self.im_name.append(methods[imi].name)
                        var iac = 0
                        var ipp = 0
                        loop {
                            if ipp >= methods[imi].params.len() {
                                break
                            }
                            if methods[imi].params[ipp].is_self == false {
                                iac = iac + 1
                            }
                            ipp = ipp + 1
                        }
                        self.im_arity.append(iac)
                        if methods[imi].ret.len() > 0 {
                            self.im_ret.append(self.annotation_type(methods[imi].ret[0]))
                        } else {
                            self.im_ret.append(TY_UNIT)
                        }
                        imi = imi + 1
                    }
                }
                case DImport(path, alias) {
                    self.aliases.append(alias)
                }
                case DLet(is_var, name, ty, value) {
                    self.globals.append(name)
                }
                case DExtern(abi, fns) {
                    var e = 0
                    loop {
                        if e >= fns.len() {
                            break
                        }
                        self.fns.append(fns[e].name)
                        // Unify externs into the free-fn tables (an extern is a callable with a signature): the
                        // call site gets arity/arg checks AND the move-arg consume — so `fopen` types a Ptr open
                        // and `fclose(move f: Ptr)` consumes it, for free.
                        self.fn_names.append(fns[e].name)
                        self.fn_extern.append(true)
                        var ec = 0
                        var ep = 0
                        loop {
                            if ep >= fns[e].params.len() {
                                break
                            }
                            if fns[e].params[ep].is_self == false {
                                ec = ec + 1
                            }
                            ep = ep + 1
                        }
                        self.fn_arity.append(ec)
                        if fns[e].ret.len() > 0 {
                            self.fn_ret.append(self.annotation_type(fns[e].ret[0]))
                        } else {
                            self.fn_ret.append(TY_UNIT)
                        }
                        e = e + 1
                    }
                }
                case DType(name, base) {
                    if self.is_duplicate_type(name) {
                        self.error("a type with this name is already declared in this module")
                    }
                    self.structs.append(name)        // a newtype name occupies a type slot (is_known)
                    self.struct_garity.append(0)     // ...a newtype is never generic (keep parallel to structs)
                    self.fns.append(name)            // ...and a constructor: UserId(x)
                    self.newtypes.append(name)        // ...but its VALUE stays lenient (not a struct type)
                }
            }
            i = i + 1
        }
    }


    // ---- Pass 1b: resolve signatures/fields/variants into the flat type tables -------------------------
    // Runs AFTER register (all type NAMES are known), so a field/param/return annotation referencing a
    // forward-declared struct/enum resolves. annotation_type stays lenient (TY_INFER) for every
    // non-primitive, so the tables only carry concrete types where it is sound to check against them.
    fn register_types(mut self, decls: [ps.Decl]) {
        var i = 0
        loop {
            if i >= decls.len() {
                break
            }
            match decls[i] {
                case DFn(f) {
                    self.tparams = gp_names(f.generics)      // T in a param type → lenient, not a struct
                    self.fn_pstart.append(self.fn_ptype.len())
                    var p = 0
                    loop {
                        if p >= f.params.len() {
                            break
                        }
                        if f.params[p].is_self == false {
                            self.fn_ptype.append(self.param_type(f.params[p]))
                            self.fn_pqual.append(f.params[p].qual)
                            // ...and, when the param's type is a BARE generic type-param `T`, which one (so a
                            // call can bind T to the argument's type and check T's bounds at the call site).
                            self.fn_ptparam.append(tparam_index_of(f.generics, f.params[p]))
                        }
                        p = p + 1
                    }
                    // record this fn's generic-parameter bounds (one row per param-bound), keyed by name —
                    // a `Copy` bound (tracked on the GenericParam, not in `bounds`) becomes a "Copy" row.
                    var gi = 0
                    loop {
                        if gi >= f.generics.len() {
                            break
                        }
                        if f.generics[gi].is_copy {
                            self.fg_name.append(f.name)
                            self.fg_param.append(gi)
                            self.fg_bound.append("Copy")
                        }
                        var bi = 0
                        loop {
                            if bi >= f.generics[gi].bounds.len() {
                                break
                            }
                            self.fg_name.append(f.name)
                            self.fg_param.append(gi)
                            self.fg_bound.append(f.generics[gi].bounds[bi])
                            bi = bi + 1
                        }
                        gi = gi + 1
                    }
                }
                case DExtern(abi, fns) {
                    // mirror DFn: the extern param tables (types + quals), parallel to register's fn_names
                    var e = 0
                    loop {
                        if e >= fns.len() {
                            break
                        }
                        self.fn_pstart.append(self.fn_ptype.len())
                        var ep = 0
                        loop {
                            if ep >= fns[e].params.len() {
                                break
                            }
                            if fns[e].params[ep].is_self == false {
                                let pt = self.param_type(fns[e].params[ep])
                                let q = fns[e].params[ep].qual
                                self.fn_ptype.append(pt)
                                self.fn_pqual.append(q)
                                self.fn_ptparam.append(0 - 1)   // externs aren't generic (keep parallel to fn_ptype)
                                // A C call passes args BY VALUE: a qualified struct param would skip the leaf-
                                // flattening the boundary needs. Two qualifiers ARE meaningful — `mut` on a buffer
                                // ([T]) the C fn writes in place, and `move` on a `Ptr` handle it takes ownership
                                // of (fclose consumes it). Everything else is rejected (check.c:7493).
                                if (q == 2 && pt != TY_PTR) || (q == 1 && pt != TY_ARRAY) {
                                    self.error("an 'extern' parameter must be plain, 'mut' on a buffer ([T]), or 'move' on a Ptr handle")
                                }
                            }
                            ep = ep + 1
                        }
                        e = e + 1
                    }
                }
                case DStruct(name, generics, impls, fields, methods) {
                    let sid = index_of(self.structs, name)
                    self.tparams = gp_names(generics)        // the struct's own type-params shadow types
                    // Record this struct's generic-parameter bounds (one row per param-bound) and its
                    // `implements` list — consulted when a construction `Box<X>{…}` checks each type argument
                    // against the parameter's bound (a Copy bound, or an interface like Hash/Eq).
                    var gpi = 0
                    loop {
                        if gpi >= generics.len() {
                            break
                        }
                        var gbi = 0
                        loop {
                            if gbi >= generics[gpi].bounds.len() {
                                break
                            }
                            self.sg_struct.append(sid)
                            self.sg_param.append(gpi)
                            self.sg_bound.append(generics[gpi].bounds[gbi])
                            gbi = gbi + 1
                        }
                        gpi = gpi + 1
                    }
                    var sii = 0
                    loop {
                        if sii >= impls.len() {
                            break
                        }
                        self.simpl_struct.append(sid)
                        self.simpl_iface.append(impls[sii])
                        sii = sii + 1
                    }
                    // every name in `implements` must be a declared interface (or the prelude's built-in
                    // keyable interfaces Hash/Eq, which need no declaration).
                    var ii = 0
                    loop {
                        if ii >= impls.len() {
                            break
                        }
                        let iid = index_of(self.ifaces, impls[ii])
                        if iid < 0 && impls[ii] != "Hash" && impls[ii] != "Eq" {
                            self.error("unknown interface in 'implements'")
                        }
                        // CONFORMANCE: the struct must declare every method the interface requires, with a
                        // matching arity and (when both are concrete) return type — the nominal conformance
                        // check (src/check.c:check_conformance). Built-in Hash/Eq carry no required methods.
                        if iid >= 0 {
                            var mj = 0
                            loop {
                                if mj >= self.im_name.len() {
                                    break
                                }
                                if self.im_iface[mj] == iid {
                                    let di = method_decl_index(methods, self.im_name[mj])
                                    if di < 0 {
                                        self.error("struct is missing a method required by an interface it implements")
                                    } else {
                                        var sa = 0
                                        var sp = 0
                                        loop {
                                            if sp >= methods[di].params.len() {
                                                break
                                            }
                                            if methods[di].params[sp].is_self == false {
                                                sa = sa + 1
                                            }
                                            sp = sp + 1
                                        }
                                        var sret = TY_UNIT
                                        if methods[di].ret.len() > 0 {
                                            sret = self.annotation_type(methods[di].ret[0])
                                        }
                                        let iret = self.im_ret[mj]
                                        var bad = sa != self.im_arity[mj]
                                        if iret != TY_INFER && iret != TY_ERROR && iret != TY_SELF && sret != TY_INFER && sret != TY_ERROR && sret != iret {
                                            bad = true
                                        }
                                        if bad {
                                            self.error("a method's signature does not match the interface it implements")
                                        }
                                    }
                                }
                                mj = mj + 1
                            }
                        }
                        ii = ii + 1
                    }
                    // A `resource struct` (which owns a Ptr handle and frees it in `drop`) is the ONE place
                    // a Ptr field is allowed. The self-host parser drops the `resource` keyword, but only a
                    // resource struct defines a `drop` method — so that is the sound proxy for the exception.
                    var has_drop = false
                    var dmi = 0
                    loop {
                        if dmi >= methods.len() {
                            break
                        }
                        if methods[dmi].name == "drop" {
                            has_drop = true
                        }
                        dmi = dmi + 1
                    }
                    var fi = 0
                    loop {
                        if fi >= fields.len() {
                            break
                        }
                        let ft = self.annotation_type(fields[fi].ty)
                        self.sf_owner.append(sid)
                        self.sf_name.append(fields[fi].name)
                        self.sf_type.append(ft)
                        self.sf_tparam.append(ty_tparam_index(generics, fields[fi].ty))
                        if ft == TY_PTR && has_drop == false {
                            self.error("a 'Ptr' is a linear FFI handle and cannot be a struct field")
                        }
                        fi = fi + 1
                    }
                    var mi = 0
                    loop {
                        if mi >= methods.len() {
                            break
                        }
                        self.tparams = gp_names2(generics, methods[mi].generics)   // struct + method params
                        self.sm_owner.append(sid)
                        self.sm_name.append(methods[mi].name)
                        self.sm_pstart.append(self.sm_ptype.len())
                        var mself = false
                        var msmove = false
                        var ac = 0
                        var mp = 0
                        loop {
                            if mp >= methods[mi].params.len() {
                                break
                            }
                            if methods[mi].params[mp].is_self == false {
                                self.sm_ptype.append(self.param_type(methods[mi].params[mp]))
                                ac = ac + 1
                            } else if methods[mi].params[mp].qual == 1 {
                                mself = true                          // `mut self`
                            } else if methods[mi].params[mp].qual == 2 {
                                msmove = true                         // `move self` — the call consumes the receiver
                            }
                            mp = mp + 1
                        }
                        self.sm_arity.append(ac)
                        self.sm_mutself.append(mself)
                        self.sm_moveself.append(msmove)
                        if methods[mi].ret.len() > 0 {
                            self.sm_ret.append(self.annotation_type(methods[mi].ret[0]))
                        } else {
                            self.sm_ret.append(TY_UNIT)          // a method with no `-> T` returns unit
                        }
                        mi = mi + 1
                    }
                }
                case DEnum(name, generics, impls, variants) {
                    let eid = index_of(self.enums, name)
                    var v = 0
                    loop {
                        if v >= variants.len() {
                            break
                        }
                        self.ev_enum.append(eid)
                        self.ev_name.append(variants[v].name)
                        self.ev_arity.append(variants[v].fields.len())
                        v = v + 1
                    }
                }
                case _ {
                }
            }
            i = i + 1
        }
    }


    // ---- Pass 2: check every function/method body + global initialiser ---------------------------------
    fn check_all(mut self, decls: [ps.Decl]) {
        var i = 0
        loop {
            if i >= decls.len() {
                break
            }
            match decls[i] {
                case DFn(f) {
                    self.tparams = gp_names(f.generics)
                    self.check_fn(f)
                }
                case DStruct(name, generics, impls, fields, methods) {
                    var m = 0
                    loop {
                        if m >= methods.len() {
                            break
                        }
                        self.tparams = gp_names2(generics, methods[m].generics)
                        self.check_fn(methods[m])
                        m = m + 1
                    }
                }
                case DLet(is_var, name, ty, value) {
                    var empty: [string] = []
                    self.tparams = empty
                    if is_var {
                        self.error("a top-level 'var' is not supported; a module-level binding must be an immutable 'let' constant")
                    } else if is_const_literal(value.value) == false {
                        self.error("a top-level constant must be a literal value (int, float, bool, or string)")
                    }
                    let vt = self.check_expr(value.value)
                    if ty.len() > 0 {
                        let bt = self.annotation_type(ty[0])
                        if assignable(vt, bt, is_int_literal(value.value), is_float_literal(value.value)) == false {
                            self.error("binding annotation does not match the value's type")
                        }
                    }
                }
                case _ {
                }
            }
            i = i + 1
        }
    }


    // annotation_type resolves a written type annotation to a SemType. Primitives map exactly (so the
    // width-mismatch check has real types); every user/aggregate/generic type is TY_INFER for now — the
    // checker stays lenient on them, so it never false-rejects a corner it cannot yet model.
    fn annotation_type(self, ty: ps.Ty) -> int {
        match ty {
            case TyName(qual, name) {
                if qual != "" {
                    return TY_INFER                  // imported/qualified type — never modelled (no module table)
                }
                if contains(self.tparams, name) {
                    return TY_INFER                  // a generic type-parameter (shadows a same-named type)
                }
                let p = prim_type(name)
                if p != TY_ERROR {
                    if p == TY_SELF {
                        return TY_INFER              // Self stays lenient (never a concrete struct id)
                    }
                    return p
                }
                if contains(self.newtypes, name) {
                    return TY_INFER                  // a newtype VALUE is lenient (not its base, not a struct)
                }
                if contains(self.ifaces, name) {
                    return TY_INFER                  // an interface-typed value coerces from any implementor
                }
                let si = index_of(self.structs, name)
                if si >= 0 {
                    return STRUCT_BASE + si
                }
                let ei = index_of(self.enums, name)
                if ei >= 0 && self.enum_has_variants(ei) {
                    return ENUM_BASE + ei            // a concrete user enum with a real variant table
                }
                return TY_INFER                      // generic/prelude enum (Option/Result) or unknown — lenient
            }
            case TyGeneric(qual, name, args) {
                return TY_INFER
            }
            case TyArray(elem) {
                return TY_ARRAY
            }
            case TyFn(params, ret) {
                return TY_INFER
            }
        }
    }


    fn param_type(self, p: ps.Param) -> int {
        if p.ty.len() == 0 {
            return TY_INFER
        }
        return self.annotation_type(p.ty[0])
    }


    // field_row returns the index into the struct-field table for struct `si`'s field `fname`, or -1.
    fn field_row(self, si: int, fname: string) -> int {
        var i = 0
        loop {
            if i >= self.sf_owner.len() {
                break
            }
            if self.sf_owner[i] == si && self.sf_name[i] == fname {
                return i
            }
            i = i + 1
        }
        return -1
    }


    // method_row returns the index into the struct-method table for struct `si`'s method `mname`, or -1.
    fn method_row(self, si: int, mname: string) -> int {
        var i = 0
        loop {
            if i >= self.sm_owner.len() {
                break
            }
            if self.sm_owner[i] == si && self.sm_name[i] == mname {
                return i
            }
            i = i + 1
        }
        return -1
    }


    // hole_showable reports whether a value of SemType `pt` can be interpolated (`"{x}"`). Directly showable:
    // a number, bool, or string (and TY_INFER/ERROR stay lenient — incl. newtypes, which render via their
    // base, and interface values). A concrete STRUCT renders only via a `show` method (the Show contract,
    // detected structurally). An enum / array / Ptr / unit is NOT showable. Mirrors check.c:show_renders.
    fn hole_showable(self, pt: int) -> bool {
        if pt == TY_INFER || pt == TY_ERROR {
            return true
        }
        if pt == TY_BOOL || pt == TY_STRING || is_numeric(pt) {
            return true
        }
        if pt >= STRUCT_BASE && pt < ENUM_BASE {
            return self.method_row(pt - STRUCT_BASE, "show") >= 0
        }
        return false
    }


    // struct_implements reports whether struct `sid` declares it `implements` interface `iface`.
    fn struct_implements(self, sid: int, iface: string) -> bool {
        var i = 0
        loop {
            if i >= self.simpl_struct.len() {
                break
            }
            if self.simpl_struct[i] == sid && self.simpl_iface[i] == iface {
                return true
            }
            i = i + 1
        }
        return false
    }


    // type_satisfies_bound reports whether a CONCRETE type argument `t` satisfies a generic `bound` (an
    // interface name). A struct satisfies it by `implements`; an integer/bool/string satisfies the built-in
    // keyable interfaces Hash/Eq (the only bounds builtins provide). Everything unmodelled (TY_INFER —
    // type-params, newtypes, imports, generic instances) stays LENIENT (true: we can't disprove it).
    // Mirrors check.c:type_satisfies_bound. ("Copy" is handled separately — see the struct-lit check.)
    fn type_satisfies_bound(self, t: int, bound: string) -> bool {
        if t == TY_INFER || t == TY_ERROR {
            return true
        }
        if t >= STRUCT_BASE && t < ENUM_BASE {
            return self.struct_implements(t - STRUCT_BASE, bound)
        }
        if is_integer_ty(t) || t == TY_BOOL || t == TY_STRING {
            return bound == "Hash" || bound == "Eq"
        }
        return false
    }


    // check_tparam_bounds verifies that an argument bound to free function `fname`'s generic type-parameter
    // `g` (via a bare-`T` value parameter) satisfies every bound on `g`: a `Copy` bound rejects a move type
    // (struct/array), an interface bound rejects a type that doesn't satisfy it (check.c:3321/3353). An
    // unmodelled (TY_INFER) argument is lenient throughout, so only a CONCRETE bad argument is rejected.
    fn check_tparam_bounds(mut self, fname: string, g: int, argty: int) {
        var i = 0
        loop {
            if i >= self.fg_name.len() {
                break
            }
            if self.fg_name[i] == fname && self.fg_param[i] == g {
                if self.fg_bound[i] == "Copy" {
                    if self.is_move_type(argty) {
                        self.error("type argument is not Copy — only scalars, strings, and enums satisfy a 'Copy' bound (not a struct or array)")
                    }
                } else {
                    if self.type_satisfies_bound(argty, self.fg_bound[i]) == false {
                        self.error("type argument does not satisfy the generic bound")
                    }
                }
            }
            i = i + 1
        }
    }


    // check_variant_payload checks a prelude generic-enum construction against an EXPECTED annotation: for
    // `let x: Option<int> = Some(v)` / `Result<T,E> = Ok(v)/Err(v)`, the payload `v`'s type must match the
    // annotation's type argument (Some/Ok → arg 0, Err → arg 1). The type comes from the annotation (the
    // construction carries no type args), so this is a use-site substitution. A TY_INFER payload is lenient;
    // only a concrete mismatch is rejected. (User generic enums aren't covered — needs general inference.)
    fn check_variant_payload(mut self, ann: ps.Ty, value: ps.Expr) {
        match ann {
            case TyGeneric(qual, tname, targs) {
                if qual != "" {
                    return
                }
                match value {
                    case ECall(callee, cargs) {
                        match callee.value {
                            case EIdent(vn) {
                                var pidx = 0 - 1
                                if tname == "Option" && vn == "Some" {
                                    pidx = 0
                                }
                                if tname == "Result" && vn == "Ok" {
                                    pidx = 0
                                }
                                if tname == "Result" && vn == "Err" {
                                    pidx = 1
                                }
                                if pidx >= 0 && pidx < targs.len() && cargs.len() == 1 {
                                    let want = self.annotation_type(targs[pidx])
                                    let got = self.check_expr(cargs[0])
                                    if assignable(got, want, is_int_literal(cargs[0]), is_float_literal(cargs[0])) == false {
                                        self.error("the variant payload's type does not match the annotation's type argument")
                                    }
                                }
                            }
                            case _ {
                            }
                        }
                    }
                    case _ {
                    }
                }
            }
            case _ {
            }
        }
    }


    // ty_arg_types resolves a `Name<A, B, …>` annotation's type arguments to their SemTypes (empty for a
    // bare `Name`). Used to check a struct-literal's `<…>` arguments against the struct's generic bounds.
    fn ty_arg_types(self, t: ps.Ty) -> [int] {
        var out: [int] = []
        match t {
            case TyGeneric(qual, name, args) {
                var i = 0
                loop {
                    if i >= args.len() {
                        break
                    }
                    out.append(self.annotation_type(args[i]))
                    i = i + 1
                }
            }
            case _ {
            }
        }
        return out
    }


    // fn_index_of returns the parallel-array index of a top-level free function `name` (into
    // fn_arity/fn_pstart), or -1 if `name` is not one (a method, builtin, constructor, closure, unknown).
    fn fn_index_of(self, name: string) -> int {
        var i = 0
        loop {
            if i >= self.fn_names.len() {
                break
            }
            if self.fn_names[i] == name {
                return i
            }
            i = i + 1
        }
        return -1
    }


    fn check_fn(mut self, f: ps.FnDecl) {
        if f.has_body == false {
            return
        }
        var fresh: [Local] = []
        self.locals = fresh
        var freshm: [bool] = []
        self.local_moved = freshm
        var freshc: [bool] = []
        self.local_consumed = freshc
        var freshbrk: [bool] = []
        self.loop_break_consumed = freshbrk
        self.loop_saw_break = false
        var freshu: [bool] = []
        self.local_unbounded_tp = freshu
        self.scope_depth = 0
        self.self_is_var = false
        self.loop_depth = 0
        self.nursery_depth = 0
        var p = 0
        loop {
            if p >= f.params.len() {
                break
            }
            if f.params[p].is_self {
                self.self_is_var = f.params[p].qual != 0    // `mut self` / `move self` receiver is mutable
            } else {
                // a `mut`/`move` parameter is a mutable binding; a plain (borrow) parameter is not.
                self.declare(f.params[p].name, self.param_type(f.params[p]), f.params[p].qual != 0, f.params[p].qual == 2, f.params[p].qual == 2)
                // A parameter typed as an UNBOUNDED generic type-param provides no methods — mark it so a
                // method call on it is rejected (a bounded `T: Ord` keeps its interface methods, so isn't marked).
                if is_unbounded_tparam(f.generics, f.params[p]) {
                    self.local_unbounded_tp[self.locals.len() - 1] = true
                }
            }
            p = p + 1
        }
        // The enclosing return type drives both the definite-return check (below) and the return-value
        // type check (SReturn). Unit / unmodelled (TY_INFER) returns disable both — leniently.
        var ret_ty = TY_UNIT
        if f.ret.len() > 0 {
            ret_ty = self.annotation_type(f.ret[0])
        }
        self.current_return = ret_ty
        // The body top level shares the parameters' scope (depth 0) — a body `let` that re-uses a param
        // name is a same-scope redeclaration. Nested blocks (check_block) open deeper scopes.
        var i = 0
        loop {
            if i >= f.body.len() {
                break
            }
            self.check_stmt(f.body[i])
            i = i + 1
        }
        // Leak scan at the trailing fall-through exit — only when that exit is reachable (a body that always
        // returns leaves the join unreachable, and its merged consumed-state is stale, so don't scan it).
        if block_returns(f.body) == false {
            self.report_unconsumed_ptrs(0)
        }
        // Definite-return (OFI-029): a function with a concretely-known non-unit return type must return
        // on every path. The terminator analysis is an exact replica of stage-0, so this never false-rejects
        // a function stage-0 accepts. (Generic/Self/unmodelled returns are TY_INFER → skipped.)
        if ret_ty != TY_UNIT && ret_ty != TY_ERROR && ret_ty != TY_INFER {
            if block_returns(f.body) == false {
                self.error("not every path returns a value (a function with a return type must return on every path)")
            }
        }
    }


    fn check_block(mut self, body: [ps.Stmt]) {
        self.scope_depth = self.scope_depth + 1
        let saved = self.locals.len()
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.check_stmt(body[i])
            i = i + 1
        }
        self.truncate_locals(saved)
        self.scope_depth = self.scope_depth - 1
    }


    fn truncate_locals(mut self, n: int) {
        var kept: [Local] = []
        var keptm: [bool] = []
        var keptc: [bool] = []
        var keptu: [bool] = []
        var i = 0
        loop {
            if i >= n {
                break
            }
            kept.append(Local{ name: self.locals[i].name, depth: self.locals[i].depth, ty: self.locals[i].ty, is_var: self.locals[i].is_var, owned: self.locals[i].owned, mvparam: self.locals[i].mvparam })
            keptm.append(self.local_moved[i])           // a move on an OUTER local persists past an inner scope
            keptc.append(self.local_consumed[i])
            keptu.append(self.local_unbounded_tp[i])
            i = i + 1
        }
        self.locals = kept
        self.local_moved = keptm
        self.local_consumed = keptc
        self.local_unbounded_tp = keptu
    }


    // check_immutable_root emits the field/element-mutation diagnostic when an assignment `root.f = v` /
    // `root[i] = v` is rooted at an IMMUTABLE binding (a `let` local, a borrowed param, or a plain `self`).
    // A root that is not a resolvable local (a call result, a global) is left lenient — never flagged.
    fn check_immutable_root(mut self, target: ps.Expr, is_field: bool) {
        let root = assign_root_ident(target)
        if root.len() == 0 {
            return                                       // not rooted at a variable — defer (lenient)
        }
        var immut = false
        if root[0] == "self" {
            if self.self_is_var == false {
                immut = true                             // `self.f = v` in a non-`mut self` method
            }
        } else if self.resolve_local(root[0]) {
            if self.local_is_var(root[0]) == false {
                immut = true
            }
        }
        if immut {
            if is_field {
                self.error("cannot mutate a field through an immutable binding; declare it 'var' or take 'mut'")
            } else {
                self.error("cannot mutate an element through an immutable binding; declare it 'var' or take 'mut'")
            }
        }
    }


    fn check_stmt(mut self, s: ps.Stmt) {
        match s {
            case SLet(is_var, name, ty, value) {
                let vt = self.check_expr(value.value)  // initialiser checked BEFORE the binding is in scope
                self.consume_move(value.value, value.line)   // `let q = p` moves an owned move-type p
                if vt == TY_UNIT {
                    self.error("cannot bind a call that returns no value")
                }
                // OFI-049/095: discarding a Ptr-returning call via `_` is not an escape hatch — the handle
                // has no destructor, so it still leaks.
                if name == "_" && vt == TY_PTR {
                    match value.value {
                        case ECall(callee, args) {
                            self.error("this 'Ptr' handle is opened but immediately discarded — it leaks")
                        }
                        case _ {
                        }
                    }
                }
                if ty.len() > 0 {
                    let bt = self.annotation_type(ty[0])
                    if assignable(vt, bt, is_int_literal(value.value), is_float_literal(value.value)) == false {
                        self.error("binding annotation does not match the value's type")
                    }
                    self.check_variant_payload(ty[0], value.value)   // Option<int> = Some("s") → payload mismatch
                    self.declare(name, bt, is_var, true, false)     // an annotated binding carries its declared type
                } else {
                    // No annotation → the initialiser must be self-inferring. stage-0 threads an EXPECTED type
                    // down (`let c: Channel<T> = …`); without one, two forms have no inferable type: a bare
                    // `None` (Option<T> — T unknown; ALWAYS un-inferable bare, verified vs stage-0) and a
                    // `channel(N)` call (Channel<T>). channel is gated on `vt == TY_INFER` (a concrete-returning
                    // shadow would infer); None is unconditional (stage-0 rejects it for every enum).
                    match value.value {
                        case EIdent(n) {
                            if n == "None" {
                                self.error("cannot infer the type of 'None' here; add a type annotation")
                            }
                        }
                        case ECall(callee, cargs) {
                            if vt == TY_INFER {
                                match callee.value {
                                    case EIdent(cn) {
                                        if cn == "channel" {
                                            self.error("cannot infer the channel's element type; annotate it (e.g. let c: Channel<int> = channel(N))")
                                        }
                                    }
                                    case _ {
                                    }
                                }
                            }
                        }
                        case _ {
                        }
                    }
                    self.declare(name, vt, is_var, true, false)     // ...otherwise infer it from the initialiser
                }
            }
            case SReturn(value, line) {
                if value.len() > 0 {
                    let vt = self.check_expr(value[0].value)
                    if self.current_return == TY_UNIT {
                        self.error("cannot return a value from a function with no declared return type")
                    } else if self.current_return != TY_ERROR && self.current_return != TY_INFER {
                        if assignable(vt, self.current_return, is_int_literal(value[0].value), is_float_literal(value[0].value)) == false {
                            self.error("returned value's type does not match the function's return type")
                        }
                    }
                    self.consume_move(value[0].value, line)   // a returned owned handle transfers out (discharges it)
                }
                self.report_unconsumed_ptrs(0)                // every owned Ptr still open on this exit path leaks
            }
            case SExpr(expr) {
                let vt = self.check_expr(expr.value)
                // OFI-049: a Ptr-returning CALL whose result is discarded (a bare statement) leaks the handle
                // — nothing can ever close it.
                match expr.value {
                    case ECall(callee, args) {
                        if vt == TY_PTR {
                            self.error("this 'Ptr' handle is opened but immediately discarded — it leaks")
                        }
                    }
                    case _ {
                    }
                }
            }
            case SAssign(target, value) {
                let vt = self.check_expr(value.value)
                self.consume_move(value.value, value.line)   // the RHS is consumed into the target (an owner)
                match target.value {
                    case EIdent(name) {
                        // the target is a WRITE, not a use — resolve it without firing use-after-move, then
                        // REVIVE it: a reassignment gives the binding a fresh value (check.c:5871).
                        if self.is_known(name) == false {
                            self.error("undefined variable")
                        } else if self.resolve_local(name) {
                            if self.local_is_var(name) == false {
                                self.error("cannot assign to an immutable 'let' binding; declare it with 'var'")
                            }
                            if assignable(vt, self.local_type(name), is_int_literal(value.value), is_float_literal(value.value)) == false {
                                self.error("assigned value's type does not match the variable")
                            }
                            let slot = self.local_slot(name)
                            if slot >= 0 {
                                // reassigning an owned Ptr that still holds an open handle drops it (a Ptr has
                                // no destructor) — a leak. It must be closed (or moved out) before overwrite.
                                if self.locals[slot].owned && self.locals[slot].ty == TY_PTR {
                                    if self.local_consumed[slot] == false && self.local_moved[slot] == false {
                                        self.error("reassigning '{name}' drops the 'Ptr' handle it still holds — close it first")
                                    }
                                    self.local_consumed[slot] = false   // now owns the freshly-assigned handle
                                }
                                self.local_moved[slot] = false
                            }
                        }
                    }
                    case EGet(object, fname) {
                        self.check_expr(target.value)
                        self.check_immutable_root(target.value, true)
                    }
                    case EIndex(object, index) {
                        self.check_expr(target.value)
                        self.check_immutable_root(target.value, false)
                    }
                    case _ {
                        self.check_expr(target.value)
                    }
                }
            }
            case SIf(cond, then_blk, els) {
                let ct = self.check_expr(cond.value)
                if ct != TY_INFER && ct != TY_ERROR && ct != TY_BOOL {
                    self.error("'if' condition must be a bool")
                }
                // Dataflow: each branch is checked from the SAME pre-state; at the join, moved OR-merges and
                // consumed AND-merges — reachability-gated (a diverging branch doesn't reach the join).
                let pre = clone_bools(self.local_moved)
                let prec = clone_bools(self.local_consumed)
                self.check_block(then_blk)
                let then_state = clone_bools(self.local_moved)
                let then_consumed = clone_bools(self.local_consumed)
                let then_div = block_diverges(then_blk)
                self.local_moved = clone_bools(pre)              // restore: the else path starts fresh
                self.local_consumed = clone_bools(prec)
                if els.len() > 0 {
                    self.check_stmt(els[0])
                    let else_div = stmt_diverges(els[0])
                    if then_div {
                        if else_div {
                            self.local_moved = clone_bools(pre)  // both diverge: join unreachable
                            self.local_consumed = clone_bools(prec)
                        }
                        // else only: keep the else state (current)
                    } else if else_div {
                        self.local_moved = clone_bools(then_state)   // only then reaches
                        self.local_consumed = clone_bools(then_consumed)
                    } else {
                        self.merge_moved(then_state)             // both reach: moved OR, consumed AND
                        self.merge_consumed(then_consumed)
                    }
                } else {
                    if then_div == false {
                        self.local_moved = clone_bools(then_state)   // then fall-through (⊇ pre); else = pre
                        self.merge_consumed(then_consumed)           // consumed: prec AND then_consumed
                    }
                }
            }
            case SFor(vname, index_var, iter, body) {
                self.check_expr(iter.value)
                self.scope_depth = self.scope_depth + 1
                self.loop_depth = self.loop_depth + 1
                let saved = self.locals.len()
                self.declare(vname, TY_INFER, false, false, false)        // a for-loop binding is an immutable borrow
                if index_var != "" {
                    self.declare(index_var, TY_INFER, false, false, false)
                }
                let pre = clone_bools(self.local_moved)
                let prec = clone_bools(self.local_consumed)
                let outer_saw = self.loop_saw_break
                let outer_brk = clone_bools(self.loop_break_consumed)
                self.loop_saw_break = false
                self.loop_break_consumed = []
                var i = 0
                loop {
                    if i >= body.len() {
                        break
                    }
                    self.check_stmt(body[i])
                    i = i + 1
                }
                if block_exits_loop(body) == false {     // a move reaching the back-edge would recur (OFI-074)
                    self.check_loop_backedge(pre, saved)
                }
                self.local_moved = clone_bools(pre)
                // a `for` exits via the iterator running dry (≈ the pre-state, since it may run 0 times) OR a
                // `break`; the join AND-merges them, so a Ptr closed only on break still leaks on natural exit.
                self.local_consumed = clone_bools(prec)
                if self.loop_saw_break {
                    self.merge_consumed(self.loop_break_consumed)
                }
                self.loop_saw_break = outer_saw
                self.loop_break_consumed = outer_brk
                self.truncate_locals(saved)
                self.loop_depth = self.loop_depth - 1
                self.scope_depth = self.scope_depth - 1
            }
            case SLoop(body) {
                self.loop_depth = self.loop_depth + 1
                let pre = clone_bools(self.local_moved)
                let loop_base = self.locals.len()
                // save & reset the break accumulator (loops nest); collect this loop's break-exit states.
                let outer_saw = self.loop_saw_break
                let outer_brk = clone_bools(self.loop_break_consumed)
                self.loop_saw_break = false
                self.loop_break_consumed = []
                self.check_block(body)
                if block_exits_loop(body) == false {     // the body can reach the back-edge
                    self.check_loop_backedge(pre, loop_base)
                }
                self.local_moved = clone_bools(pre)      // loop-internal moves don't persist out (lenient)
                // a `loop {}` falls through only via `break`; the post-loop consumed-state is the AND of the
                // break paths (else the join is unreachable — leave the state as-is, leniently).
                if self.loop_saw_break {
                    self.local_consumed = clone_bools(self.loop_break_consumed)
                }
                self.loop_saw_break = outer_saw
                self.loop_break_consumed = outer_brk
                self.loop_depth = self.loop_depth - 1
            }
            case SBreak(line) {
                if self.loop_depth == 0 {
                    self.error("'break' outside of a loop")
                }
                // record the consumed-state on this break path — the post-loop state AND-merges every break.
                // (A named snapshot, not an inline `clone_bools(...)` arg — the self-hosted codegen doesn't yet
                // drop an inline owning-temp array passed to a method's borrow parameter. OFI-165.)
                if self.loop_saw_break {
                    let snap = clone_bools(self.local_consumed)
                    self.merge_into_break(snap)
                } else {
                    self.loop_break_consumed = clone_bools(self.local_consumed)
                    self.loop_saw_break = true
                }
            }
            case SContinue(line) {
                if self.loop_depth == 0 {
                    self.error("'continue' outside of a loop")
                }
            }
            case SMatch(value, cases) {
                let st = self.check_expr(value.value)
                // Exhaustiveness/variant checks fire ONLY when the subject is a known plain user enum.
                // A generic/imported/Option/Result subject is TY_INFER → `known` false → fully lenient.
                var known = false
                var eid = 0
                if st >= ENUM_BASE && st < ENUM_BASE + self.enums.len() {
                    known = true
                    eid = st - ENUM_BASE
                }
                // a CONCRETE non-enum subject (int/string/bool/struct/…) can't be matched; an unmodelled
                // (TY_INFER) or error subject stays lenient.
                if known == false && st != TY_INFER && st != TY_ERROR {
                    self.error("'match' requires an enum value")
                }
                var vnames: [string] = []
                var varity: [int] = []
                var covered: [bool] = []
                if known {
                    var k = 0
                    loop {
                        if k >= self.ev_name.len() {
                            break
                        }
                        if self.ev_enum[k] == eid {
                            vnames.append(self.ev_name[k])
                            varity.append(self.ev_arity[k])
                            covered.append(false)
                        }
                        k = k + 1
                    }
                }
                var has_wild = false
                // Move dataflow: each arm is checked from the SAME pre-match state; the moved-sets of the
                // REACHABLE arms are OR'd into `acc`, which becomes the post-match state.
                let pre = clone_bools(self.local_moved)
                var acc = clone_bools(self.local_moved)
                var ci = 0
                loop {
                    if ci >= cases.len() {
                        break
                    }
                    self.local_moved = clone_bools(pre)      // each arm starts fresh (no cross-poison)
                    if known {
                        if cases[ci].pattern.wildcard {
                            has_wild = true
                        } else {
                            if cases[ci].pattern.type_name != "" && cases[ci].pattern.type_name != self.enums[eid] {
                                self.error("pattern names a different enum than the match subject")
                            }
                            let vi = index_of(vnames, cases[ci].pattern.variant)
                            if vi < 0 {
                                self.error("this variant does not belong to the matched enum")
                            } else {
                                if covered[vi] {
                                    self.error("duplicate case for a variant")
                                }
                                covered[vi] = true
                                if cases[ci].pattern.bindings.len() != varity[vi] {
                                    self.error("pattern binds the wrong number of fields")
                                }
                            }
                        }
                    }
                    self.scope_depth = self.scope_depth + 1
                    let saved = self.locals.len()
                    var bi = 0
                    loop {
                        if bi >= cases[ci].pattern.bindings.len() {
                            break
                        }
                        self.declare(cases[ci].pattern.bindings[bi], TY_INFER, false, false, false)   // a match binding is a borrow
                        bi = bi + 1
                    }
                    var si = 0
                    loop {
                        if si >= cases[ci].body.len() {
                            break
                        }
                        self.check_stmt(cases[ci].body[si])
                        si = si + 1
                    }
                    self.truncate_locals(saved)
                    self.scope_depth = self.scope_depth - 1
                    if block_diverges(cases[ci].body) == false {   // a diverging arm doesn't reach the join
                        var mi = 0
                        loop {
                            if mi >= acc.len() {
                                break
                            }
                            if mi < self.local_moved.len() {
                                if self.local_moved[mi] {
                                    acc[mi] = true
                                }
                            }
                            mi = mi + 1
                        }
                    }
                    ci = ci + 1
                }
                self.local_moved = acc                       // post-match: OR of the reachable arms
                // Every variant must be covered (a wildcard covers the rest).
                if known && has_wild == false {
                    var vj = 0
                    loop {
                        if vj >= covered.len() {
                            break
                        }
                        if covered[vj] == false {
                            self.error("non-exhaustive match: a variant is not handled")
                        }
                        vj = vj + 1
                    }
                }
            }
            case SSpawn(call) {
                // a `spawn` must run under a structured-concurrency scope.
                if self.nursery_depth == 0 {
                    self.error("'spawn' is only valid inside a 'nursery'")
                }
                // a foreign (extern "c") function has no bytecode slot, so it cannot be spawned as a task.
                match call.value {
                    case ECall(callee, args) {
                        match callee.value {
                            case EIdent(name) {
                                let fi = self.fn_index_of(name)
                                if fi >= 0 && self.fn_extern[fi] {
                                    self.error("cannot 'spawn' an 'extern' function (it has no task entry point)")
                                }
                            }
                            case _ {
                            }
                        }
                    }
                    case _ {
                    }
                }
                self.check_expr(call.value)
            }
            case SNursery(body) {
                self.nursery_depth = self.nursery_depth + 1
                self.check_block(body)
                self.nursery_depth = self.nursery_depth - 1
            }
            case SBlock(body) {
                self.check_block(body)
            }
        }
    }


    // check_expr walks an expression, emitting any diagnostics, and returns its SemType. The type is a
    // best effort: anything not yet modelled (calls, fields, generics, user types) is TY_INFER, and every
    // type check is gated on its operands being concretely known — so an unmodelled corner produces no
    // diagnostic rather than a wrong one.
    fn check_expr(mut self, e: ps.Expr) -> int {
        match e {
            case EInt(v) {
                return TY_INT
            }
            case EFloat(v) {
                return TY_FLOAT
            }
            case EBool(v) {
                return TY_BOOL
            }
            case EStr(parts) {
                var i = 0
                loop {
                    if i >= parts.len() {
                        break
                    }
                    if parts[i].hole.len() == 1 {
                        let pt = self.check_expr(parts[i].hole[0])
                        // OFI-139: an interpolation hole must be directly showable (numeric / bool / string)
                        // OR provide the Show contract (`fn show(self) -> string`, a struct method). A concrete
                        // struct-without-show / enum / array / Ptr can't render. Newtypes are TY_INFER here →
                        // lenient (stage-0 renders them via their base type).
                        if self.hole_showable(pt) == false {
                            self.error("this value can't be interpolated directly: give its type a 'fn show(self) -> string' method, or interpolate a number/string/bool")
                        }
                    }
                    i = i + 1
                }
                return TY_STRING
            }
            case EIdent(name) {
                if name == "_" {
                    // `_` is a WRITE-ONLY discard wildcard (OFI-095): it binds nothing readable, so reading
                    // it in value position is an undefined-identifier error.
                    self.error("'_' is a write-only discard and cannot be read")
                    return TY_ERROR
                }
                if self.is_known(name) == false {
                    self.error("undefined variable")
                    return TY_ERROR
                }
                if self.resolve_local(name) {
                    let slot = self.local_slot(name)
                    if slot >= 0 && self.local_moved[slot] {
                        self.error("use of '{name}' after it was moved")
                    }
                    return self.local_type(name)
                }
                let ve = self.variant_enum(name)     // a bare user-enum variant carries its enum type
                if ve >= 0 {
                    return ve
                }
                return TY_INFER                      // function / global / prelude variant / struct name
            }
            case EUnary(op, operand) {
                // `!x` -> bool, `-x` -> the operand's numeric type; in both the result type IS the operand's.
                return self.check_expr(operand.value)
            }
            case EBinary(op, l, r) {
                var lt = self.check_expr(l.value)
                var rt = self.check_expr(r.value)
                let cls = ps.binop_class(op)
                if cls == 3 || cls == 4 {
                    return TY_BOOL                    // comparison / logical (operands not flagged: lenient)
                }
                if cls == 5 {
                    if is_numeric(lt) {
                        return lt                     // bitwise / shift
                    }
                    return TY_INFER
                }
                // Arithmetic (cls 1 = `+`/concat, cls 2 = `- * / %`). Mirror stage-0's literal adaptation:
                // an unsuffixed int literal adopts the other side's integer width; an f32 pulls a bare
                // float literal to f32. (The parser drops int suffixes, so every EInt is treated as
                // unsuffixed — strictly more lenient, so never a false reject.)
                if is_int_literal(l.value) && is_integer_ty(rt) {
                    lt = rt
                } else if is_int_literal(r.value) && is_integer_ty(lt) {
                    rt = lt
                } else if lt == TY_F32 && rt == TY_FLOAT && is_float_literal(r.value) {
                    rt = TY_F32
                } else if rt == TY_F32 && lt == TY_FLOAT && is_float_literal(l.value) {
                    lt = TY_F32
                }
                if cls == 1 && lt == TY_STRING && rt == TY_STRING {
                    return TY_STRING                  // string concatenation
                }
                // Flag a mismatch only when BOTH sides are concretely known (not INFER/ERROR/ARRAY).
                if lt != TY_INFER && rt != TY_INFER && lt != TY_ERROR && rt != TY_ERROR && lt != TY_ARRAY && rt != TY_ARRAY {
                    if is_numeric(lt) && lt == rt {
                        return lt
                    }
                    self.error("arithmetic operands must be the same numeric type (or both string for '+')")
                    return TY_ERROR
                }
                // One side is INFER/ERROR/ARRAY here (both-concrete-numeric already returned/errored above).
                // We have NO field/index/call type model, so we cannot know the concrete (possibly sized)
                // type the known operand really has — concretizing to the other operand's TY_INT/TY_FLOAT
                // would wrongly fail a later sized-context check (`-> u32`, `let x: f32 = ...`). Stay lenient.
                return TY_INFER
            }
            case ECall(callee, args) {
                self.check_callee(callee.value)
                var argtypes: [int] = []
                var i = 0
                loop {
                    if i >= args.len() {
                        break
                    }
                    argtypes.append(self.check_expr(args[i]))
                    i = i + 1
                }
                match callee.value {
                    case EIdent(name) {
                        // OFI-049: a Ptr cannot be an enum payload (`Some(f)`) — a handle flowing through an
                        // erased generic enum would escape linearity checking.
                        if index_of(self.variants, name) >= 0 {
                            var pa = 0
                            loop {
                                if pa >= argtypes.len() {
                                    break
                                }
                                if argtypes[pa] == TY_PTR {
                                    self.error("a 'Ptr' is a linear FFI handle and cannot be an enum payload")
                                }
                                pa = pa + 1
                            }
                        }
                        // assert(cond): the condition must be a bool (when its type is concretely known).
                        if name == "assert" && args.len() >= 1 {
                            if argtypes[0] != TY_INFER && argtypes[0] != TY_ERROR && argtypes[0] != TY_BOOL {
                                self.error("assert's condition must be a bool")
                            }
                        }
                        // D1: a bare-ident call to a top-level free function (not a local closure, builtin,
                        // method, or constructor) — arity, then argument types.
                        if self.resolve_local(name) == false && is_builtin(name) == false {
                            let fi = self.fn_index_of(name)
                            if fi >= 0 {
                                if args.len() != self.fn_arity[fi] {
                                    self.error("wrong number of arguments to function")
                                } else {
                                    var a = 0
                                    loop {
                                        if a >= args.len() {
                                            break
                                        }
                                        if assignable(argtypes[a], self.fn_ptype[self.fn_pstart[fi] + a], is_int_literal(args[a]), is_float_literal(args[a])) == false {
                                            self.error("argument type does not match the parameter")
                                        }
                                        // A `mut` parameter (qual 1, not `move`=2) requires a mutable binding.
                                        if self.fn_pqual[self.fn_pstart[fi] + a] == 1 {
                                            let aroot = assign_root_ident(args[a])
                                            if aroot.len() == 1 {
                                                if aroot[0] != "self" && self.resolve_local(aroot[0]) && self.local_is_var(aroot[0]) == false {
                                                    self.error("cannot pass an immutable binding to a 'mut' parameter; declare it 'var' (or pass by 'move' to transfer ownership)")
                                                }
                                            }
                                        }
                                        // A `move` parameter (qual 2) CONSUMES its argument — transfers ownership.
                                        if self.fn_pqual[self.fn_pstart[fi] + a] == 2 {
                                            self.consume_move(args[a], 0)
                                        }
                                        // If this parameter is a bare generic type-param `T`, the argument binds
                                        // T — so its type must satisfy T's bounds (Copy / an interface).
                                        let g = self.fn_ptparam[self.fn_pstart[fi] + a]
                                        if g >= 0 {
                                            self.check_tparam_bounds(name, g, argtypes[a])
                                        }
                                        a = a + 1
                                    }
                                }
                            }
                        }
                    }
                    case EGet(object, mname) {
                        // D2: a method call `recv.m(args)` — only when the receiver is a known plain struct;
                        // a builtin/array/string/INFER receiver (mr < 0 or non-struct) stays lenient.
                        let recv = self.check_expr(object.value)
                        // A method call on an UNBOUNDED generic type-param binding has no method to dispatch
                        // to — even `.clone()` (check.c:4073). A bounded `T: Ord` keeps its interface methods.
                        match object.value {
                            case EIdent(rname) {
                                let rslot = self.local_slot(rname)
                                if rslot >= 0 && self.local_unbounded_tp[rslot] {
                                    self.error("cannot call a method on an unbounded type parameter")
                                }
                            }
                            case _ {
                            }
                        }
                        if recv >= STRUCT_BASE && recv < ENUM_BASE {
                            let mr = self.method_row(recv - STRUCT_BASE, mname)
                            if mr < 0 && mname != "clone" {
                                self.error("no such method on this struct")   // `clone` is a built-in deep copy
                            }
                            // a `mut self` method needs a MUTABLE receiver: an immutable `let`/borrowed root
                            // can't be mutated through it.
                            if mr >= 0 && self.sm_mutself[mr] {
                                let rroot = assign_root_ident(object.value)
                                if rroot.len() == 1 {
                                    if rroot[0] != "self" && self.resolve_local(rroot[0]) && self.local_is_var(rroot[0]) == false {
                                        self.error("cannot call a 'mut self' method on an immutable binding; declare it 'var' (or take 'mut')")
                                    }
                                }
                            }
                            // a `move self` method CONSUMES the receiver — a later use is a use-after-move.
                            if mr >= 0 && self.sm_moveself[mr] {
                                self.consume_move(object.value, 0)
                            }
                            if mr >= 0 {
                                if args.len() != self.sm_arity[mr] {
                                    self.error("wrong number of arguments to method")
                                } else {
                                    var a = 0
                                    loop {
                                        if a >= args.len() {
                                            break
                                        }
                                        // The method path does not push an expected type, so a bare literal
                                        // arg is NOT width-adapted; skip it to stay strictly false-reject-free.
                                        if is_int_literal(args[a]) == false && is_float_literal(args[a]) == false {
                                            if assignable(argtypes[a], self.sm_ptype[self.sm_pstart[mr] + a], false, false) == false {
                                                self.error("argument type does not match the parameter")
                                            }
                                        }
                                        a = a + 1
                                    }
                                }
                            }
                        }
                    }
                    case _ {
                    }
                }
                // the call's RESULT TYPE — a known method's declared return, or a void builtin's unit. Most
                // calls stay TY_INFER (lenient); only a CONCRETE result drives the void-bind / assignment check.
                match callee.value {
                    case EIdent(name) {
                        if self.resolve_local(name) == false && is_builtin(name) {
                            return builtin_ret_type(name)
                        }
                        if self.resolve_local(name) == false {
                            let fi = self.fn_index_of(name)      // a free-fn / extern call: its declared return
                            if fi >= 0 {
                                return self.fn_ret[fi]
                            }
                        }
                    }
                    case EGet(object, mname) {
                        let r = self.check_expr(object.value)
                        if r >= STRUCT_BASE && r < ENUM_BASE {
                            let mr = self.method_row(r - STRUCT_BASE, mname)
                            if mr >= 0 {
                                return self.sm_ret[mr]
                            }
                        }
                    }
                    case _ {
                    }
                }
                return TY_INFER
            }
            case EGet(object, name) {
                let ot = self.check_expr(object.value)   // `name` is a field/method, not a variable
                // a CONCRETE non-struct value (a primitive or an enum) has no fields; an INFER/aliased/struct
                // object stays lenient.
                if self.is_fieldless_concrete(ot) {
                    self.error("field access requires a struct value")
                }
                return TY_INFER
            }
            case EIndex(object, index) {
                self.check_expr(object.value)
                self.check_expr(index.value)
                return TY_INFER
            }
            case EArray(elems, lines) {
                // All elements must share one type. To stay lenient (0 false-rejects) we compare only the
                // coarse SCALAR CLASS — numeric / string / bool — collapsing every numeric width into one
                // (so int↔float coercion is never flagged) and skipping non-scalar/unmodelled elements
                // (struct/enum/call → class 0). A concrete string-vs-number / bool-vs-number mix is rejected.
                var ec = 0
                var i = 0
                loop {
                    if i >= elems.len() {
                        break
                    }
                    let et = self.check_expr(elems[i])
                    let cls = scalar_class(et)
                    if cls != 0 {
                        if ec == 0 {
                            ec = cls
                        } else if cls != ec {
                            self.error("array elements must all have the same type")
                        }
                    }
                    i = i + 1
                }
                return TY_ARRAY
            }
            case EStructLit(ty, fields) {
                let name = ty_name(ty.value)
                let si = index_of(self.structs, name)
                // Stay lenient unless this is a LOCALLY-registered concrete struct: an imported/aliased
                // or generic/newtype construction resolves to no local struct → check values, emit nothing
                // (stage-0's "unknown struct type" would false-reject every imported construction).
                if si < 0 || contains(self.newtypes, name) {
                    var i = 0
                    loop {
                        if i >= fields.len() {
                            break
                        }
                        self.check_expr(fields[i].value)
                        i = i + 1
                    }
                    return TY_INFER
                }
                // The construction's explicit `<…>` type arguments (empty for a non-generic struct), resolved
                // once: drives the generic-arity check, the interface-bound check, and field substitution.
                let argtys = self.ty_arg_types(ty.value)
                let unqual = ty_qual(ty.value) == ""
                // The `<…>` type-argument count must EXACTLY equal the struct's generic-parameter count: a
                // generic `Box<T>` requires `Box<X>` (not bare `Box`), a non-generic `P` rejects `P<int>`,
                // and `Box<A,B>` is wrong. Skip a qualified (imported) type — its arity isn't known here.
                if unqual {
                    if argtys.len() != self.struct_garity[si] {
                        self.error("wrong number of type arguments for this struct")
                    }
                    // Each type argument must satisfy its parameter's INTERFACE bound (Hash/Eq/…) — checked at
                    // the construction site, where the arguments are concrete (check.c:5183). A struct arg
                    // satisfies by `implements`; a scalar/string by the built-in keyable interfaces; anything
                    // unmodelled (TY_INFER) stays lenient. (A `Copy` bound is skipped here — stage-0 only
                    // enforces it alongside a witness-bearing interface bound; no corpus target needs it.)
                    var bi = 0
                    loop {
                        if bi >= self.sg_struct.len() {
                            break
                        }
                        if self.sg_struct[bi] == si && self.sg_bound[bi] != "Copy" {
                            let g = self.sg_param[bi]
                            if g < argtys.len() {
                                if self.type_satisfies_bound(argtys[g], self.sg_bound[bi]) == false {
                                    self.error("a type argument does not satisfy the struct's generic bound (it must implement Hash / Eq)")
                                }
                            }
                        }
                        bi = bi + 1
                    }
                }
                // Each provided field must name a declared field, with an assignable value.
                var i = 0
                loop {
                    if i >= fields.len() {
                        break
                    }
                    let vt = self.check_expr(fields[i].value)
                    let row = self.field_row(si, fields[i].name)
                    if row < 0 {
                        self.error("no such field on this struct")
                    } else {
                        // A field declared as a bare type-param `T` is expected at the construction's concrete
                        // type argument (`Box<int>{value: …}` ⇒ value: int) — substitute it before the check.
                        var expected = self.sf_type[row]
                        let fg = self.sf_tparam[row]
                        if unqual && fg >= 0 && fg < argtys.len() {
                            expected = argtys[fg]
                        }
                        if assignable(vt, expected, is_int_literal(fields[i].value), is_float_literal(fields[i].value)) == false {
                            self.error("field value type does not match the declared field")
                        }
                    }
                    i = i + 1
                }
                // Every declared field of this struct must be provided exactly once (missing OR duplicate).
                var di = 0
                loop {
                    if di >= self.sf_owner.len() {
                        break
                    }
                    if self.sf_owner[di] == si {
                        var seen = 0
                        var pi = 0
                        loop {
                            if pi >= fields.len() {
                                break
                            }
                            if fields[pi].name == self.sf_name[di] {
                                seen = seen + 1
                            }
                            pi = pi + 1
                        }
                        if seen != 1 {
                            self.error("every struct field must be set exactly once")
                        }
                    }
                    di = di + 1
                }
                return STRUCT_BASE + si
            }
            case ETry(operand) {
                let ot = self.check_expr(operand.value)
                // `?` unwraps a Result/Option (both lenient TY_INFER here). A CONCRETE operand type can't be
                // one, so it is an error; an unmodelled (TY_INFER) operand stays lenient.
                if ot != TY_INFER && ot != TY_ERROR {
                    self.error("'?' requires a Result or Option value")
                } else if self.current_return != TY_INFER && self.current_return != TY_ERROR {
                    // `?` is a hidden early return of the Err/None, so the enclosing function must ITSELF
                    // return a Result/Option (which resolve to TY_INFER). A concrete return type — incl. a
                    // plain `int`/struct or an absent return type (TY_UNIT) — can't propagate (check.c:5364).
                    self.error("'?' can only be used in a function that returns a Result or Option")
                }
                return TY_INFER
            }
            case ERange(lo, hi) {
                self.check_expr(lo.value)
                self.check_expr(hi.value)
                return TY_INFER
            }
            case ELambda(params) {
                // the lambda body is not yet stored on the AST (parser drops it for ast_print); skip.
                return TY_INFER
            }
            case EError {
                return TY_ERROR
            }
        }
    }


    // check_callee resolves the target of a call. A bare-ident callee may be a function, a built-in, a
    // local closure, an enum-variant constructor, a struct/newtype constructor, or an import alias; a
    // non-ident callee (a method `obj.m`, an index, etc.) is checked as an ordinary expression.
    fn check_callee(mut self, callee: ps.Expr) {
        match callee {
            case EIdent(name) {
                if is_builtin(name) == false && self.is_known(name) == false {
                    self.error("undefined variable")
                }
            }
            case EGet(object, mname) {
                // a method-call RECEIVER (`recv.m(...)`): validate the receiver only — the method itself is
                // resolved by the ECall handler. Do NOT route through the bare-EGet field-access check (a
                // method on a string/array is not a struct field).
                self.check_expr(object.value)
            }
            case _ {
                self.check_expr(callee)
            }
        }
    }
}


// is_int_literal / is_float_literal report whether an expression is a bare numeric literal — the operands
// stage-0 lets adapt to the other side's width in arithmetic.
// method_decl_index returns the index of the method named `name` in a struct's method list, or -1.
fn method_decl_index(methods: [ps.FnDecl], name: string) -> int {
    var i = 0
    loop {
        if i >= methods.len() {
            break
        }
        if methods[i].name == name {
            return i
        }
        i = i + 1
    }
    return 0 - 1
}


// is_const_literal reports whether an expression is a compile-time constant a top-level `let` may hold: an
// int/float/bool/string literal, or a unary-minus of an int/float literal (a negative constant). Mirrors
// src/check.c:is_const_literal.
fn is_const_literal(e: ps.Expr) -> bool {
    match e {
        case EInt(v) {
            return true
        }
        case EFloat(v) {
            return true
        }
        case EBool(v) {
            return true
        }
        case EStr(parts) {
            return true
        }
        case EUnary(op, operand) {
            if ps.unop_id(op) == 1 {
                match operand.value {
                    case EInt(v) {
                        return true
                    }
                    case EFloat(v) {
                        return true
                    }
                    case _ {
                        return false
                    }
                }
            }
            return false
        }
        case _ {
            return false
        }
    }
}


fn is_int_literal(e: ps.Expr) -> bool {
    match e {
        case EInt(v) {
            return true
        }
        case _ {
            return false
        }
    }
}


fn is_float_literal(e: ps.Expr) -> bool {
    match e {
        case EFloat(v) {
            return true
        }
        case _ {
            return false
        }
    }
}


// ---- definite-return terminator analysis (exact replica of stage-0 check.c stmt_returns/block_returns)
// block_returns: a block returns on every path iff some statement does (the rest is then unreachable).
// clone_bools returns an independent copy of a bool array (a moved-state snapshot — Ember arrays alias on
// assignment, so a dataflow snapshot must deep-copy).
fn clone_bools(xs: [bool]) -> [bool] {
    var out: [bool] = []
    var i = 0
    loop {
        if i >= xs.len() {
            break
        }
        out.append(xs[i])
        i = i + 1
    }
    return out
}


// block_exits_loop / stmt_exits_loop report whether a statement (sequence) ALWAYS leaves the enclosing loop
// on every path — via `return` or a `break` that targets THIS loop. A body that always exits never reaches
// the back-edge, so a move inside it can't recur (OFI-074). `continue` and fall-through reach the back-edge,
// so they are NOT exits. A nested loop/for is opaque here (its `break` targets the inner loop).
fn block_exits_loop(body: [ps.Stmt]) -> bool {
    var i = 0
    loop {
        if i >= body.len() {
            break
        }
        if stmt_exits_loop(body[i]) {
            return true
        }
        i = i + 1
    }
    return false
}


fn stmt_exits_loop(s: ps.Stmt) -> bool {
    match s {
        case SReturn(value, line) {
            return true
        }
        case SBreak(line) {
            return true
        }
        case SBlock(body) {
            return block_exits_loop(body)
        }
        case SIf(cond, then_blk, els) {
            if els.len() == 0 {
                return false
            }
            return block_exits_loop(then_blk) && stmt_exits_loop(els[0])
        }
        case _ {
            return false
        }
    }
}


// block_diverges / stmt_diverges report whether a statement (sequence) does NOT fall through to the code
// after it on any path — via return, break, OR continue (each leaves the current straight-line flow). Used by
// the branch merge so a branch that breaks/continues (not just returns) doesn't contribute its moved-set to
// the join. A nested loop/for is opaque (its break/continue targets the inner loop).
fn block_diverges(body: [ps.Stmt]) -> bool {
    var i = 0
    loop {
        if i >= body.len() {
            break
        }
        if stmt_diverges(body[i]) {
            return true
        }
        i = i + 1
    }
    return false
}


fn stmt_diverges(s: ps.Stmt) -> bool {
    match s {
        case SReturn(value, line) {
            return true
        }
        case SBreak(line) {
            return true
        }
        case SContinue(line) {
            return true
        }
        case SBlock(body) {
            return block_diverges(body)
        }
        case SIf(cond, then_blk, els) {
            if els.len() == 0 {
                return false
            }
            return block_diverges(then_blk) && stmt_diverges(els[0])
        }
        case SLoop(body) {
            return loop_exit_break(body) == false
        }
        case _ {
            return false
        }
    }
}


fn block_returns(body: [ps.Stmt]) -> bool {
    var i = 0
    loop {
        if i >= body.len() {
            break
        }
        if stmt_returns(body[i]) {
            return true
        }
        i = i + 1
    }
    return false
}


fn stmt_returns(s: ps.Stmt) -> bool {
    match s {
        case SReturn(value, line) {
            return true
        }
        case SBlock(body) {
            return block_returns(body)
        }
        case SIf(cond, then_blk, els) {
            if els.len() == 0 {
                return false                         // no else → can fall through
            }
            return block_returns(then_blk) && stmt_returns(els[0])
        }
        case SMatch(value, cases) {
            if cases.len() == 0 {
                return false
            }
            var i = 0
            loop {
                if i >= cases.len() {
                    break
                }
                if block_returns(cases[i].body) == false {
                    return false
                }
                i = i + 1
            }
            return true                              // exhaustive (checker-enforced) and every arm returns
        }
        case SLoop(body) {
            return loop_exit_break(body) == false    // an infinite loop with no exiting break diverges
        }
        case _ {
            return false                             // let/assign/expr/for/spawn/nursery/break/continue
        }
    }
}


// loop_exit_break: does this loop body contain a break that exits THIS loop (not one inside a nested
// loop/for, whose break targets the inner loop)? Distinguishes an infinite loop from a fall-through one.
fn loop_exit_break(body: [ps.Stmt]) -> bool {
    var i = 0
    loop {
        if i >= body.len() {
            break
        }
        if stmt_exit_break(body[i]) {
            return true
        }
        i = i + 1
    }
    return false
}


fn stmt_exit_break(s: ps.Stmt) -> bool {
    match s {
        case SBreak(line) {
            return true
        }
        case SBlock(body) {
            return loop_exit_break(body)
        }
        case SNursery(body) {
            return loop_exit_break(body)
        }
        case SIf(cond, then_blk, els) {
            if loop_exit_break(then_blk) {
                return true
            }
            if els.len() == 0 {
                return false
            }
            return stmt_exit_break(els[0])
        }
        case SMatch(value, cases) {
            var i = 0
            loop {
                if i >= cases.len() {
                    break
                }
                if loop_exit_break(cases[i].body) {
                    return true
                }
                i = i + 1
            }
            return false
        }
        case _ {
            return false                             // a break inside a nested SLoop/SFor targets that loop
        }
    }
}


fn contains(xs: [string], v: string) -> bool {
    var i = 0
    loop {
        if i >= xs.len() {
            break
        }
        if xs[i] == v {
            return true
        }
        i = i + 1
    }
    return false
}


// gp_names extracts the names of a generic-parameter list (so they can shadow same-named types).
fn gp_names(gs: [ps.GenericParam]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i >= gs.len() {
            break
        }
        out.append(gs[i].name)
        i = i + 1
    }
    return out
}


// ty_tparam_index returns the generic-parameter index a type annotation names when it is a BARE unqualified
// type-param `T` matching one of `generics` (else -1) — so a generic field/payload `value: T` can be
// substituted with the construction's explicit type argument and its value type-checked.
fn ty_tparam_index(generics: [ps.GenericParam], t: ps.Ty) -> int {
    match t {
        case TyName(qual, name) {
            if qual != "" {
                return 0 - 1
            }
            var i = 0
            loop {
                if i >= generics.len() {
                    break
                }
                if generics[i].name == name {
                    return i
                }
                i = i + 1
            }
            return 0 - 1
        }
        case _ {
            return 0 - 1
        }
    }
}


// is_unbounded_tparam reports whether a value parameter's type is a bare generic type-param with NO interface
// bound (a `T`, or even `T: Copy` — Copy is not an interface, so it provides no methods). A method call on
// such a binding is an error (check.c:4073). A bounded `T: Ord`/`T: Hash` keeps its interface methods.
fn is_unbounded_tparam(generics: [ps.GenericParam], p: ps.Param) -> bool {
    if p.ty.len() != 1 {
        return false
    }
    match p.ty[0] {
        case TyName(qual, name) {
            if qual != "" {
                return false
            }
            var i = 0
            loop {
                if i >= generics.len() {
                    break
                }
                if generics[i].name == name {
                    return generics[i].bounds.len() == 0
                }
                i = i + 1
            }
            return false
        }
        case _ {
            return false
        }
    }
}


// tparam_index_of returns the generic-parameter index a value parameter's type refers to when that type is
// a BARE type-param `T` (so a call can bind T to the argument's type and check T's bounds), or -1 otherwise.
// Only a bare unqualified `TyName` matching a declared generic name qualifies — `[T]`, `Box<T>`, a concrete
// type, etc. return -1 (those need full unification, which the synthesize-only checker does not do).
fn tparam_index_of(generics: [ps.GenericParam], p: ps.Param) -> int {
    if p.ty.len() != 1 {
        return 0 - 1
    }
    match p.ty[0] {
        case TyName(qual, name) {
            if qual != "" {
                return 0 - 1
            }
            var i = 0
            loop {
                if i >= generics.len() {
                    break
                }
                if generics[i].name == name {
                    return i
                }
                i = i + 1
            }
            return 0 - 1
        }
        case _ {
            return 0 - 1
        }
    }
}


// gp_names2 = the names of two generic-parameter lists concatenated (a method sees its struct's params too).
fn gp_names2(outer: [ps.GenericParam], inner: [ps.GenericParam]) -> [string] {
    var out = gp_names(outer)
    var i = 0
    loop {
        if i >= inner.len() {
            break
        }
        out.append(inner[i].name)
        i = i + 1
    }
    return out
}


// assign_root_ident walks an assignment target through field (`o.f`) and element (`a[i]`) steps to its
// root, returning [name] if that root is a plain identifier, or [] otherwise (a call result, literal, …).
// Returned as a 0/1-length list (the file's optional-as-list idiom) since a struct out of a match is moved.
fn assign_root_ident(e: ps.Expr) -> [string] {
    match e {
        case EIdent(name) {
            return [name]
        }
        case EGet(object, fname) {
            return assign_root_ident(object.value)
        }
        case EIndex(object, index) {
            return assign_root_ident(object.value)
        }
        case _ {
            var none: [string] = []
            return none
        }
    }
}


// ty_name returns the (unqualified) name of a type annotation, or "" for array/fn types.
fn ty_name(t: ps.Ty) -> string {
    match t {
        case TyName(qual, name) {
            return name
        }
        case TyGeneric(qual, name, args) {
            return name
        }
        case TyArray(elem) {
            return ""
        }
        case TyFn(params, ret) {
            return ""
        }
    }
}


// ty_qual returns a type annotation's module qualifier ("" if unqualified). A qualified type names an
// imported struct/enum whose generic arity this module doesn't know — so generic-arity checks skip it.
fn ty_qual(t: ps.Ty) -> string {
    match t {
        case TyName(qual, name) {
            return qual
        }
        case TyGeneric(qual, name, args) {
            return qual
        }
        case TyArray(elem) {
            return ""
        }
        case TyFn(params, ret) {
            return ""
        }
    }
}


// ty_arg_count returns the number of TYPE arguments written in an annotation: 0 for a plain `Name` (and a
// non-generic form), or the count for `Name<A, B, …>`. Used to check a struct-literal's `<…>` against the
// struct's declared generic-parameter count.
fn ty_arg_count(t: ps.Ty) -> int {
    match t {
        case TyGeneric(qual, name, args) {
            return args.len()
        }
        case _ {
            return 0
        }
    }
}


// index_of returns the first index of `v` in `xs`, or -1 if absent (the struct/enum id = its index).
fn index_of(xs: [string], v: string) -> int {
    var i = 0
    loop {
        if i >= xs.len() {
            break
        }
        if xs[i] == v {
            return i
        }
        i = i + 1
    }
    return -1
}


// assignable reports whether a value of SemType `actual` is acceptable where `expected` is required
// (the core stage-0 type-compatibility predicate, used by arguments, struct fields, lets, and returns).
// The keystone of zero-false-rejects: it returns true whenever EITHER side is TY_INFER/TY_ERROR, so any
// type this in-progress checker doesn't model is assignable to anything and can never be flagged. It only
// returns false for two concrete, distinct, non-literal-adaptable types — exactly stage-0's rejections.
fn assignable(actual: int, expected: int, a_is_int_lit: bool, a_is_float_lit: bool) -> bool {
    if actual == TY_INFER || expected == TY_INFER {
        return true
    }
    if actual == TY_ERROR || expected == TY_ERROR {
        return true
    }
    if actual == expected {
        return true
    }
    if a_is_int_lit && is_integer_ty(expected) {
        return true                          // an unsuffixed int literal adopts any integer width
    }
    if a_is_float_lit && (expected == TY_F32 || expected == TY_FLOAT) {
        return true                          // a bare float literal adopts f32/f64
    }
    return false
}


// check parses + checks a source string and returns whether it was REJECTED (true = a diagnostic was
// raised). M3a verdict parity; the diagnostic text + positions (M3c) follow.
fn check(src: string) -> bool {
    let decls = ps.parse(src)
    var fns: [string] = []
    var structs: [string] = []
    var enums: [string] = ["Option", "Result"]                    // always-in-scope prelude enums
    var variants: [string] = ["Some", "None", "Ok", "Err"]        // ...and their variants
    var globals: [string] = []
    var aliases: [string] = []
    var fn_names: [string] = []
    var fn_arity: [int] = []
    var fn_ret: [int] = []
    var fn_pstart: [int] = []
    var fn_ptype: [int] = []
    var fn_pqual: [int] = []
    var fn_ptparam: [int] = []
    var fn_extern: [bool] = []
    var fg_name: [string] = []
    var fg_param: [int] = []
    var fg_bound: [string] = []
    var struct_garity: [int] = []
    var sg_struct: [int] = []
    var sg_param: [int] = []
    var sg_bound: [string] = []
    var simpl_struct: [int] = []
    var simpl_iface: [string] = []
    var newtypes: [string] = []
    var sf_owner: [int] = []
    var sf_tparam: [int] = []
    var sf_name: [string] = []
    var sf_type: [int] = []
    var sm_owner: [int] = []
    var sm_name: [string] = []
    var sm_arity: [int] = []
    var sm_pstart: [int] = []
    var sm_ptype: [int] = []
    var sm_mutself: [bool] = []
    var sm_moveself: [bool] = []
    var sm_ret: [int] = []
    var ev_enum: [int] = []
    var ev_name: [string] = []
    var ev_arity: [int] = []
    var ifaces: [string] = []
    var im_iface: [int] = []
    var im_name: [string] = []
    var im_arity: [int] = []
    var im_ret: [int] = []
    var tparams: [string] = []
    var locals: [Local] = []
    var diags: [string] = []
    var c = Checker{ fns: fns, structs: structs, enums: enums, variants: variants, globals: globals, aliases: aliases, fn_names: fn_names, fn_arity: fn_arity, fn_ret: fn_ret, fn_pstart: fn_pstart, fn_ptype: fn_ptype, fn_pqual: fn_pqual, fn_ptparam: fn_ptparam, fn_extern: fn_extern, fg_name: fg_name, fg_param: fg_param, fg_bound: fg_bound, struct_garity: struct_garity, sg_struct: sg_struct, sg_param: sg_param, sg_bound: sg_bound, simpl_struct: simpl_struct, simpl_iface: simpl_iface, newtypes: newtypes, sf_owner: sf_owner, sf_tparam: sf_tparam, sf_name: sf_name, sf_type: sf_type, sm_owner: sm_owner, sm_name: sm_name, sm_arity: sm_arity, sm_pstart: sm_pstart, sm_ptype: sm_ptype, sm_mutself: sm_mutself, sm_moveself: sm_moveself, sm_ret: sm_ret, ev_enum: ev_enum, ev_name: ev_name, ev_arity: ev_arity, ifaces: ifaces, im_iface: im_iface, im_name: im_name, im_arity: im_arity, im_ret: im_ret, tparams: tparams, current_return: TY_UNIT, self_is_var: false, loop_depth: 0, nursery_depth: 0, locals: locals, local_moved: [], local_consumed: [], loop_break_consumed: [], loop_saw_break: false, local_unbounded_tp: [], scope_depth: 0, diags: diags }
    c.register(decls)                    // pass 1: NAMES (so forward references resolve)
    c.register_types(decls)              // pass 1b: signatures, fields, variants (needs names registered)
    c.check_all(decls)                   // pass 2: bodies
    return c.diags.len() > 0
}
