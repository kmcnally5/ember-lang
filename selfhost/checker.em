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
    newtypes: [string]         // newtype names (a newtype value must stay lenient, NOT resolve to a struct)
    sf_owner: [int]            // struct-field table: owning struct index (parallel to `structs`)
    sf_name: [string]          // ...field name
    sf_type: [int]             // ...field SemType (TY_INFER for any non-primitive)
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
    locals: [Local]
    local_moved: [bool]        // MUTABLE move state, parallel to `locals` (element-struct writeback isn't
                               // self-compilable yet — OFI-061 — so the moved flag lives in a scalar array)
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
                    if self.locals[slot].owned && self.local_moved[slot] == false && self.is_boxed_move(slot) {
                        self.local_moved[slot] = true
                    }
                }
            }
            case _ {
            }
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
                    self.fns.append(f.name)
                    self.fn_names.append(f.name)
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
                        }
                        p = p + 1
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
                                self.fn_ptype.append(self.param_type(fns[e].params[ep]))
                                self.fn_pqual.append(fns[e].params[ep].qual)
                            }
                            ep = ep + 1
                        }
                        e = e + 1
                    }
                }
                case DStruct(name, generics, impls, fields, methods) {
                    let sid = index_of(self.structs, name)
                    self.tparams = gp_names(generics)        // the struct's own type-params shadow types
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
        self.scope_depth = 0
        self.self_is_var = false
        self.loop_depth = 0
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
        var i = 0
        loop {
            if i >= n {
                break
            }
            kept.append(Local{ name: self.locals[i].name, depth: self.locals[i].depth, ty: self.locals[i].ty, is_var: self.locals[i].is_var, owned: self.locals[i].owned, mvparam: self.locals[i].mvparam })
            keptm.append(self.local_moved[i])           // a move on an OUTER local persists past an inner scope
            i = i + 1
        }
        self.locals = kept
        self.local_moved = keptm
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
                if ty.len() > 0 {
                    let bt = self.annotation_type(ty[0])
                    if assignable(vt, bt, is_int_literal(value.value), is_float_literal(value.value)) == false {
                        self.error("binding annotation does not match the value's type")
                    }
                    self.declare(name, bt, is_var, true, false)     // an annotated binding carries its declared type
                } else {
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
                }
            }
            case SExpr(expr) {
                self.check_expr(expr.value)
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
                // Move dataflow: each branch is checked from the SAME pre-state, then their moved-sets are
                // merged (OR) — reachability-gated (a diverging branch's moves don't reach the join).
                let pre = clone_bools(self.local_moved)
                self.check_block(then_blk)
                let then_state = clone_bools(self.local_moved)
                let then_div = block_diverges(then_blk)
                self.local_moved = clone_bools(pre)              // restore: the else path starts fresh
                if els.len() > 0 {
                    self.check_stmt(els[0])
                    let else_div = stmt_diverges(els[0])
                    if then_div {
                        if else_div == false {
                            // only else reaches the join — keep the else state (current)
                        } else {
                            self.local_moved = clone_bools(pre)  // both diverge: join unreachable
                        }
                    } else if else_div {
                        self.local_moved = clone_bools(then_state)   // only then reaches
                    } else {
                        self.merge_moved(then_state)             // both reach: OR the moved-sets
                    }
                } else {
                    if then_div == false {
                        self.local_moved = clone_bools(then_state)   // then fall-through (⊇ pre); implicit else = pre
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
                self.truncate_locals(saved)
                self.loop_depth = self.loop_depth - 1
                self.scope_depth = self.scope_depth - 1
            }
            case SLoop(body) {
                self.loop_depth = self.loop_depth + 1
                let pre = clone_bools(self.local_moved)
                let loop_base = self.locals.len()
                self.check_block(body)
                if block_exits_loop(body) == false {     // the body can reach the back-edge
                    self.check_loop_backedge(pre, loop_base)
                }
                self.local_moved = clone_bools(pre)      // loop-internal moves don't persist out (lenient)
                self.loop_depth = self.loop_depth - 1
            }
            case SBreak(line) {
                if self.loop_depth == 0 {
                    self.error("'break' outside of a loop")
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
                self.check_expr(call.value)
            }
            case SNursery(body) {
                self.check_block(body)
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
                        self.check_expr(parts[i].hole[0])
                    }
                    i = i + 1
                }
                return TY_STRING
            }
            case EIdent(name) {
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
                var i = 0
                loop {
                    if i >= elems.len() {
                        break
                    }
                    self.check_expr(elems[i])
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
                        if assignable(vt, self.sf_type[row], is_int_literal(fields[i].value), is_float_literal(fields[i].value)) == false {
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
    var newtypes: [string] = []
    var sf_owner: [int] = []
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
    var c = Checker{ fns: fns, structs: structs, enums: enums, variants: variants, globals: globals, aliases: aliases, fn_names: fn_names, fn_arity: fn_arity, fn_ret: fn_ret, fn_pstart: fn_pstart, fn_ptype: fn_ptype, fn_pqual: fn_pqual, newtypes: newtypes, sf_owner: sf_owner, sf_name: sf_name, sf_type: sf_type, sm_owner: sm_owner, sm_name: sm_name, sm_arity: sm_arity, sm_pstart: sm_pstart, sm_ptype: sm_ptype, sm_mutself: sm_mutself, sm_moveself: sm_moveself, sm_ret: sm_ret, ev_enum: ev_enum, ev_name: ev_name, ev_arity: ev_arity, ifaces: ifaces, im_iface: im_iface, im_name: im_name, im_arity: im_arity, im_ret: im_ret, tparams: tparams, current_return: TY_UNIT, self_is_var: false, loop_depth: 0, locals: locals, local_moved: [], scope_depth: 0, diags: diags }
    c.register(decls)                    // pass 1: NAMES (so forward references resolve)
    c.register_types(decls)              // pass 1b: signatures, fields, variants (needs names registered)
    c.check_all(decls)                   // pass 2: bodies
    return c.diags.len() > 0
}
