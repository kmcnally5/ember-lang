// selfhost/cgen_c.em — the M5 self-hosted C-EMIT backend (AST → C), mirroring src/cgen_c.c. It is the
// 5th and final component of stage-0 ported to Ember: completing it makes the self-hosted compiler a full
// mirror of stage-0 (lexer → parser → checker → bytecode → C-emit), able to produce native binaries the
// same way (`emberc -o`), and is the path to the kernel's bare-metal codegen. Verified byte-identical to
// stage-0 `emberc --emit=c` via tools/ccdiff.sh — the same differential methodology as every other stage.
//
// Built incrementally (like the bytecode codegen.em was): M5a = the program SCAFFOLD + scalar bodies, then
// strings, structs, control flow, etc. The driver is selfhost/cgen_c_dump.em.

import "parser" as ps
import "lexer" as lx


// build_fn_names lists every body-bearing function (struct methods as `Struct.method`, then free fns) in
// DECLARATION order — the em_fn_N numbering, so a call resolves to the right `em_fn_<index>`.
fn build_fn_names(decls: [ps.Decl]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(f.name)
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(name + "." + methods[mi].name)
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// ty_scalar_kind maps a numeric type annotation to its C width-kind (0 i64 … 9 f64), or -1 for any
// non-scalar (string/struct/array/etc). M5a handles the i64 (`int`/`i64`) subset; sized/float follow.
fn ty_scalar_kind(t: ps.Ty) -> int {
    match t {
        case TyName(qual, name) {
            if qual != "" {
                return 0 - 1
            }
            if name == "int" || name == "i64" {
                return 0
            }
            return 0 - 1
        }
        case _ {
            return 0 - 1
        }
    }
}


// is_array_ty reports whether a type annotation is an array `[T]`.
fn is_array_ty(t: ps.Ty) -> bool {
    match t {
        case TyArray(elem) {
            return true
        }
        case _ {
            return false
        }
    }
}


// elem_ty_of returns the element type of an array annotation `[T]` (or the type itself if not an array).
fn elem_ty_of(t: ps.Ty) -> ps.Ty {
    match t {
        case TyArray(elem) {
            return elem.value
        }
        case _ {
            return t
        }
    }
}


// array_elem_kind_ty maps an element TYPE to its runtime ArrayElemKind byte (value.h AEK_*): BOXED 0,
// i8..i64 1..4, u8..u64 5..8, f32 9, f64 10, bool 11. A string/struct/array element is BOXED (0).
fn array_elem_kind_ty(t: ps.Ty) -> int {
    match t {
        case TyName(qual, name) {
            if qual != "" {
                return 0
            }
            if name == "i8" { return 1 }
            if name == "i16" { return 2 }
            if name == "i32" { return 3 }
            if name == "int" || name == "i64" { return 4 }
            if name == "u8" { return 5 }
            if name == "u16" { return 6 }
            if name == "u32" { return 7 }
            if name == "u64" { return 8 }
            if name == "f32" { return 9 }
            if name == "f64" { return 10 }
            if name == "bool" { return 11 }
            return 0
        }
        case _ {
            return 0
        }
    }
}


// ret_scalar_kind is a function's return-type width-kind (-1 if it returns a non-scalar / nothing).
fn ret_scalar_kind(f: ps.FnDecl) -> int {
    if f.ret.len() == 0 {
        return 0 - 1
    }
    return ty_scalar_kind(f.ret[0])
}


// build_fn_ret_kinds is the return width-kind of every body-bearing fn, parallel to build_fn_names.
fn build_fn_ret_kinds(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(ret_scalar_kind(f))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(ret_scalar_kind(methods[mi]))
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// c_escape renders a string's bytes as the contents of a C string literal (no surrounding quotes),
// mirroring cgen_c.c:emit_c_string_literal: `"`/`\` are backslash-escaped, newline/tab/CR use their named
// escapes, printable ASCII passes through, and any other byte is a 3-digit octal escape.
fn c_escape(s: string) -> string {
    let bs = s.bytes()
    var out = ""
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        let c = int(bs[i])
        if c == 34 || c == 92 {
            out = out + "\\" + from_char_code(c)        // " or \
        } else if c == 10 {
            out = out + "\\n"
        } else if c == 9 {
            out = out + "\\t"
        } else if c == 13 {
            out = out + "\\r"
        } else if c >= 32 && c < 127 {
            out = out + from_char_code(c)
        } else {
            out = out + "\\" + from_char_code(48 + (c / 64)) + from_char_code(48 + ((c / 8) % 8)) + from_char_code(48 + (c % 8))
        }
        i = i + 1
    }
    return out
}


// build_fn_ret_str marks each body-bearing fn (parallel to build_fn_names) that returns a `string`, so a
// `let g = f()` of a string-returning call is tracked as an owned (droppable) binding.
fn build_fn_ret_str(decls: [ps.Decl]) -> [bool] {
    var out: [bool] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(f.ret.len() > 0 && is_string_ty(f.ret[0]))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(methods[mi].ret.len() > 0 && is_string_ty(methods[mi].ret[0]))
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// build_fn_ret_array marks each body-bearing fn (parallel to build_fn_names) that returns an array `[T]`,
// so a `let xs = f()` of an array-returning call is tracked as an owned (droppable) array binding.
fn build_fn_ret_array(decls: [ps.Decl]) -> [bool] {
    var out: [bool] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(f.ret.len() > 0 && is_array_ty(f.ret[0]))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(methods[mi].ret.len() > 0 && is_array_ty(methods[mi].ret[0]))
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// ret_elem_kind is the ELEMENT scalar width-kind of a fn's array return type `[T]` (so `f()[i]` is a scalar),
// or -1 if it does not return an array / the element is non-scalar.
fn ret_elem_kind(ret: [ps.Ty]) -> int {
    if ret.len() > 0 && is_array_ty(ret[0]) {
        return ty_scalar_kind(elem_ty_of(ret[0]))
    }
    return 0 - 1
}


// build_fn_ret_elem_kinds is the array-element scalar kind of every body-bearing fn (parallel to build_fn_names).
fn build_fn_ret_elem_kinds(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(ret_elem_kind(f.ret))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(ret_elem_kind(methods[mi].ret))
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// scalar_ctype maps a width-kind to its C storage type (mirrors cgen_c.c:scalar_ctype; M5a uses 0 = i64).
fn scalar_ctype(kind: int) -> string {
    if kind == 0 {
        return "int64_t"
    }
    if kind == 1 {
        return "int8_t"
    }
    if kind == 2 {
        return "int16_t"
    }
    if kind == 3 {
        return "int32_t"
    }
    if kind == 4 {
        return "uint8_t"
    }
    if kind == 5 {
        return "uint16_t"
    }
    if kind == 6 {
        return "uint32_t"
    }
    if kind == 7 {
        return "uint64_t"
    }
    if kind == 8 {
        return "float"
    }
    if kind == 9 {
        return "double"
    }
    return "int64_t"
}


// fn_param_list renders a function's C parameter list: `void` for no value params, else `Value a0, Value
// a1, …` (one per non-self parameter; a method's receiver is the leading `Value a0`).
// param_value_sid returns the VALUE-struct sid of C parameter position `pi` of `f` (self is a0 when present,
// typed as the owning struct `owner_sid`), or -1 if that parameter is not a value struct. Drives the C type.
fn param_value_sid(f: ps.FnDecl, has_self: bool, stab: StructTab, owner_sid: int, pi: int) -> int {
    var ci = 0
    if has_self {
        if ci == pi {
            if owner_sid >= 0 && stab.is_value(owner_sid) {
                return owner_sid
            }
            return 0 - 1
        }
        ci = 1
    }
    var p = 0
    loop {
        if p >= f.params.len() {
            break
        }
        if f.params[p].is_self == false {
            if ci == pi {
                if f.params[p].ty.len() > 0 {
                    let s = ty_struct_sid(f.params[p].ty[0], stab.names)
                    if s >= 0 && stab.is_value(s) {
                        return s
                    }
                }
                return 0 - 1
            }
            ci = ci + 1
        }
        p = p + 1
    }
    return 0 - 1
}


// fn_ret_value_struct returns the VALUE-struct sid `f` returns (a `em_s<sid>` C return type), or -1.
fn fn_ret_value_struct(f: ps.FnDecl, stab: StructTab) -> int {
    if f.ret.len() > 0 {
        let sid = ty_struct_sid(f.ret[0], stab.names)
        if sid >= 0 && stab.is_value(sid) {
            return sid
        }
    }
    return 0 - 1
}


// fn_ret_ctype is `f`'s C return type: `em_s<sid>` for a value-struct return, else `Value`.
fn fn_ret_ctype(f: ps.FnDecl, stab: StructTab) -> string {
    let sid = fn_ret_value_struct(f, stab)
    if sid >= 0 {
        return "em_s{sid}"
    }
    return "Value"
}


// fn_param_list renders `f`'s C parameter list. A value-struct parameter is `em_s<sid> a<i>` (passed by
// value), everything else is `Value a<i>`; a method's `self` is the leading a0, typed as its owning struct.
fn fn_param_list(f: ps.FnDecl, has_self: bool, stab: StructTab, owner_sid: int) -> string {
    let n = value_arity(f, has_self)
    if n == 0 {
        return "void"
    }
    var s = ""
    var i = 0
    loop {
        if i >= n {
            break
        }
        if i > 0 {
            s = s + ", "
        }
        let psid = param_value_sid(f, has_self, stab, owner_sid, i)
        if psid >= 0 {
            s = s + "em_s{psid} a{i}"
        } else {
            s = s + "Value a{i}"
        }
        i = i + 1
    }
    return s
}


// ---- the struct table (mirrors src/cgen_c.c's StructLayout, computed from the AST — the self-hosted
// backend has no checker, so it classifies every declared struct itself, like codegen.em's build_structs).
// A struct is a VALUE-TYPE (a real C `em_s<sid>`, value semantics, no drop) iff it is recursively all-scalar
// and not an rc/resource struct; otherwise it is BOXED (an ObjStruct Value). Fields are a flat table keyed
// by a running index, f_owner mapping each field back to its struct sid (sids are declaration order).
struct StructTab {
    names: [string]            // sid -> struct name
    kinds: [int]               // sid -> 0 plain, 1 rc, 2 resource
    f_owner: [int]             // flat field -> owning struct sid
    f_name: [string]           // flat field -> field name (declared order within its struct)
    f_aek: [int]               // flat field -> its ArrayElemKind byte (the metadata `knd`)
    f_scalar: [bool]           // flat field -> is it a scalar type? (drives is_value / storage)
    f_struct: [int]            // flat field -> nested struct sid (or -1); the metadata `fst`
    f_array: [bool]            // flat field -> is it an array `[T]`? (so `s.field.len()` / `s.field[i]` resolve)
    f_elem: [int]              // ...for an array field: its ELEMENT scalar kind (so `s.field[i]` is a scalar), else -1


    fn sid_of(self, name: string) -> int {
        var i = 0
        loop {
            if i >= self.names.len() {
                break
            }
            if self.names[i] == name {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    fn field_count(self, sid: int) -> int {
        var n = 0
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid {
                n = n + 1
            }
            i = i + 1
        }
        return n
    }


    // flat_index returns the flat-table index of struct `sid`'s `idx`-th (declared-order) field, or -1.
    fn flat_index(self, sid: int, idx: int) -> int {
        var seen = 0
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid {
                if seen == idx {
                    return i
                }
                seen = seen + 1
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_is_array reports whether field `fname` of struct `sid` is an array (so `s.field.len()` resolves).
    fn field_is_array(self, sid: int, fname: string) -> bool {
        let flat = self.field_flat(sid, fname)
        if flat < 0 {
            return false
        }
        return self.f_array[flat]
    }


    // field_is_refcounted reports whether field `fname` of struct `sid` is a REFCOUNTED single Value — a
    // string or an enum (a boxed, non-array, non-struct field) — so passing it to a call MOVES it in
    // (own_into_slot), like a string/enum binding. A scalar / array / struct field is passed as-is.
    fn field_is_refcounted(self, sid: int, fname: string) -> bool {
        let flat = self.field_flat(sid, fname)
        if flat < 0 {
            return false
        }
        return self.f_scalar[flat] == false && self.f_array[flat] == false && self.f_struct[flat] < 0
    }


    // field_scalar_kind returns the C width-kind of a SCALAR field `fname` of struct `sid` (so `let x =
    // s.field` types as a C scalar), or -1 for a non-scalar field.
    fn field_scalar_kind(self, sid: int, fname: string) -> int {
        let flat = self.field_flat(sid, fname)
        if flat < 0 || self.f_scalar[flat] == false {
            return 0 - 1
        }
        return aek_to_scalar_kind(self.f_aek[flat])
    }


    // field_elem returns the ELEMENT scalar kind of array field `fname` of struct `sid` (or -1).
    fn field_elem(self, sid: int, fname: string) -> int {
        let flat = self.field_flat(sid, fname)
        if flat < 0 {
            return 0 - 1
        }
        return self.f_elem[flat]
    }


    // field_flat returns the flat-table index of field `fname` within struct `sid` (or -1).
    fn field_flat(self, sid: int, fname: string) -> int {
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid && self.f_name[i] == fname {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_index returns the DECLARED-order index of field `fname` within struct `sid` (or -1).
    fn field_index(self, sid: int, fname: string) -> int {
        var idx = 0
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid {
                if self.f_name[i] == fname {
                    return idx
                }
                idx = idx + 1
            }
            i = i + 1
        }
        return 0 - 1
    }


    // is_value reports whether struct `sid` is a VALUE-TYPE (a C em_s struct): recursively all-scalar (only
    // scalars / nested value structs), and not an rc / resource struct. Mirrors cgen_c.c:is_value_struct.
    fn is_value(self, sid: int) -> bool {
        if sid < 0 || sid >= self.names.len() {
            return false
        }
        if self.kinds[sid] != 0 {
            return false               // an rc / resource struct is BOXED, never a C value-type
        }
        var seen = false
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid {
                seen = true
                if self.f_scalar[i] == false {
                    // a non-scalar field is value-ok ONLY if it is a nested VALUE struct
                    let nested_value = self.f_struct[i] >= 0 && self.is_value(self.f_struct[i])
                    if nested_value == false {
                        return false
                    }
                }
            }
            i = i + 1
        }
        return seen
    }


    // field_aek returns the runtime ArrayElemKind byte of flat field `flat`: a nested VALUE-struct field is
    // AEK_INLINE_STRUCT (12); everything else keeps its scalar/boxed AEK.
    fn field_aek(self, flat: int) -> int {
        if self.f_struct[flat] >= 0 && self.is_value(self.f_struct[flat]) {
            return 12
        }
        return self.f_aek[flat]
    }


    // field_size / total_size compute the PACKED byte size of a field and of a whole struct: a nested value-
    // struct field occupies its struct's total_size (packed inline), a scalar its size_of_aek.
    fn field_size(self, flat: int) -> int {
        if self.f_struct[flat] >= 0 && self.is_value(self.f_struct[flat]) {
            return self.total_size(self.f_struct[flat])
        }
        return size_of_aek(self.f_aek[flat])
    }


    fn total_size(self, sid: int) -> int {
        var total = 0
        let fc = self.field_count(sid)
        var f = 0
        loop {
            if f >= fc {
                break
            }
            total = total + self.field_size(self.flat_index(sid, f))
            f = f + 1
        }
        return total
    }
}


// ty_struct_sid resolves a type annotation to a declared struct's sid (by name), or -1 if it is not a
// (bare, unqualified) struct type. `names` is the sid-ordered struct-name list.
fn ty_struct_sid(t: ps.Ty, names: [string]) -> int {
    match t {
        case TyName(qual, name) {
            if qual != "" {
                return 0 - 1
            }
            var i = 0
            loop {
                if i >= names.len() {
                    break
                }
                if names[i] == name {
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


// aek_to_scalar_kind maps an ArrayElemKind byte (i8..f64) to its C width-kind (0 i64 … 9 f64), or -1 for a
// non-scalar (boxed) kind. The inverse of the scalar side of array_elem_kind_ty. (bool → i64 kind 0.)
fn aek_to_scalar_kind(aek: int) -> int {
    if aek == 4 {
        return 0                       // i64 / int
    }
    if aek == 1 {
        return 1                       // i8
    }
    if aek == 2 {
        return 2                       // i16
    }
    if aek == 3 {
        return 3                       // i32
    }
    if aek == 5 {
        return 4                       // u8
    }
    if aek == 6 {
        return 5                       // u16
    }
    if aek == 7 {
        return 6                       // u32
    }
    if aek == 8 {
        return 7                       // u64
    }
    if aek == 9 {
        return 8                       // f32
    }
    if aek == 10 {
        return 9                       // f64
    }
    if aek == 11 {
        return 0                       // bool — stored as an i64 scalar
    }
    return 0 - 1                        // AEK_BOXED / inline-struct — not a scalar
}


// size_of_aek is the PACKED byte size of a struct field of ArrayElemKind `aek` (the runtime data buffer;
// fields are packed with NO alignment padding — offsets are a running sum). A boxed field is pointer-sized.
fn size_of_aek(aek: int) -> int {
    if aek == 1 {
        return 1                       // i8
    }
    if aek == 2 {
        return 2                       // i16
    }
    if aek == 3 {
        return 4                       // i32
    }
    if aek == 4 {
        return 8                       // i64
    }
    if aek == 5 {
        return 1                       // u8
    }
    if aek == 6 {
        return 2                       // u16
    }
    if aek == 7 {
        return 4                       // u32
    }
    if aek == 8 {
        return 8                       // u64
    }
    if aek == 9 {
        return 4                       // f32
    }
    if aek == 10 {
        return 8                       // f64
    }
    if aek == 11 {
        return 1                       // bool
    }
    return 16                          // AEK_BOXED — a full 16-byte Value (a heap field of a boxed struct)
}


// build_struct_tab classifies every declared struct from the AST (names + a flat field table).
fn build_struct_tab(decls: [ps.Decl]) -> StructTab {
    // Pass 1: collect struct names + kinds (so a field typed as a later-declared struct still resolves).
    var names: [string] = []
    var kinds: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                names.append(name)
                kinds.append(kind)
            }
            case _ {
            }
        }
        i = i + 1
    }
    // Pass 2: the flat field table (classification needs all struct names known).
    var fo: [int] = []
    var fnm: [string] = []
    var fa: [int] = []
    var fsc: [bool] = []
    var fsd: [int] = []
    var far: [bool] = []
    var fel: [int] = []
    var sid = 0
    var j = 0
    loop {
        if j >= decls.len() {
            break
        }
        match decls[j] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var fi = 0
                loop {
                    if fi >= fields.len() {
                        break
                    }
                    let fty = fields[fi].ty
                    fo.append(sid)
                    fnm.append(fields[fi].name)
                    fsd.append(ty_struct_sid(fty, names))
                    let aek = array_elem_kind_ty(fty)   // 0 for string/array/struct (boxed), 1..11 for a scalar
                    fa.append(aek)
                    fsc.append(aek != 0)
                    let is_a = is_array_ty(fty)
                    far.append(is_a)
                    if is_a {
                        fel.append(ty_scalar_kind(elem_ty_of(fty)))
                    } else {
                        fel.append(0 - 1)
                    }
                    fi = fi + 1
                }
                sid = sid + 1
            }
            case _ {
            }
        }
        j = j + 1
    }
    return StructTab { names: names, kinds: kinds, f_owner: fo, f_name: fnm, f_aek: fa, f_scalar: fsc, f_struct: fsd, f_array: far, f_elem: fel }
}


// ---- the enum table (enums are BOXED runtime values `em_enum(enum_id, tag, fcount, fields…)` — no C type
// and no metadata preamble; the table just resolves a variant NAME to its enum id + tag + payload arity,
// computed from the DEnum decls, mirroring codegen.em's build_enums). ----------------------------------
struct EnumTab {
    names: [string]            // enum id -> name (declaration order)
    v_owner: [int]             // flat variant table -> owning enum id
    v_name: [string]           // ...variant name
    v_tag: [int]               // ...tag (index within its enum)
    v_arity: [int]             // ...payload field count


    // variant_flat returns the flat-table index of variant `name` (-1 if `name` is not a known variant).
    fn variant_flat(self, name: string) -> int {
        var i = 0
        loop {
            if i >= self.v_name.len() {
                break
            }
            if self.v_name[i] == name {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    fn is_variant(self, name: string) -> bool {
        return self.variant_flat(name) >= 0
    }
}


// build_enum_tab collects every enum's variants from the AST (enum ids + per-enum variant tags).
fn build_enum_tab(decls: [ps.Decl]) -> EnumTab {
    var names: [string] = []
    var vo: [int] = []
    var vn: [string] = []
    var vt: [int] = []
    var va: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DEnum(name, generics, impls, variants) {
                let id = names.len()
                names.append(name)
                var vi = 0
                loop {
                    if vi >= variants.len() {
                        break
                    }
                    vo.append(id)
                    vn.append(variants[vi].name)
                    vt.append(vi)
                    va.append(variants[vi].fields.len())
                    vi = vi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return EnumTab { names: names, v_owner: vo, v_name: vn, v_tag: vt, v_arity: va }
}


// build_fn_ret_structs is the struct sid (VALUE or BOXED) each body-bearing fn returns (parallel to
// build_fn_names), so a `let p = mk()` of a struct-returning call resolves its type (an em_s for a value
// struct / a boxed ObjStruct otherwise). The is_value gate is applied at the use site (struct_sid_of /
// boxed_sid_of), not here.
fn build_fn_ret_structs(decls: [ps.Decl], stab: StructTab) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(fn_ret_struct_id(f, stab))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(fn_ret_struct_id(methods[mi], stab))
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// fn_ret_struct_id is the struct sid (value OR boxed) `f` returns, or -1 if it does not return a struct.
fn fn_ret_struct_id(f: ps.FnDecl, stab: StructTab) -> int {
    if f.ret.len() > 0 {
        return ty_struct_sid(f.ret[0], stab.names)
    }
    return 0 - 1
}


// build_fn_ret_enum marks each body-bearing fn (parallel to build_fn_names) that returns an ENUM type, so a
// `let o = f()` of an enum-returning call is tracked as an OWNED (droppable, move-into-call) binding.
fn build_fn_ret_enum(decls: [ps.Decl], en: EnumTab) -> [bool] {
    var out: [bool] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(f.ret.len() > 0 && is_enum_ty(f.ret[0], en))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(methods[mi].ret.len() > 0 && is_enum_ty(methods[mi].ret[0], en))
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// ---- the C-emit generator state (mirrors src/cgen_c.c's CgcGen) -------------------------------------
// next_var is the per-function `v%d` temp counter (retain temps + scalar `let` bindings share it). The
// scope maps an in-scope binding NAME to its C expression (`a0` for a param, `v3` for a `let`) and its
// scalar width-kind (0 i64 … 9 f64, or -1 for a Value/struct binding). fn_names lets a call resolve to
// `em_fn_<index>`. Built per increment, like the bytecode codegen.em was.
struct CgcGen {
    next_var: int
    sc_name: [string]          // binding name
    sc_cname: [string]         // ...its C expression (a param `aN`, or a `let` temp `vN`)
    sc_kind: [int]             // ...its scalar TYPE width-kind (for `let` inference), or -1 for a non-scalar
    sc_unboxed: [bool]         // ...is the STORAGE an unboxed C scalar (a scalar `let` vN, re-box on read)?
                               // a param is a Value (a0, read as-is) even when its TYPE is a scalar.
    sc_drop: [bool]            // ...is this binding an OWNED heap value (a string/array local) dropped at exit?
    sc_array: [bool]           // ...is this binding an ARRAY? (passed to a call by BORROW, not moved like a string)
    sc_elem_kind: [int]        // ...for an array binding: its ELEMENT scalar width-kind (so `arr[i]` is a scalar), else -1
    sc_elem_struct: [int]      // ...for a STRUCT-array binding: its element struct sid (so `arr[i]` / `arr[i].f` resolve), else -1
    sc_struct: [int]           // ...for a VALUE-STRUCT binding: its struct sid (so `p.f` / storage type resolve), else -1
    indent: int                // current C indentation depth (1 = the function-body level, 4 spaces each)
    st: StructTab              // the declared-struct table (value/boxed classification + field resolution)
    en: EnumTab                // the declared-enum table (variant -> enum id / tag / payload arity)
    fn_names: [string]         // every body-bearing fn in em_fn_N order (free fns + `Struct.method`)
    fn_ret_kind: [int]         // ...each fn's return width-kind (for a `let x = f()` scalar binding)
    fn_ret_str: [bool]         // ...does each fn return a string (a `let x = f()` owned binding)?
    fn_ret_array: [bool]       // ...does each fn return an array (a `let x = f()` owned array binding)?
    fn_ret_elem_kind: [int]    // ...for an array-returning fn: its element scalar kind (so `f()[i]` is a scalar), else -1
    fn_ret_struct: [int]       // ...for a value-struct-returning fn: the struct sid (so `let p = f()` is an em_s), else -1
    fn_ret_enum: [bool]        // ...does each fn return an enum (a `let o = f()` OWNED refcounted binding)?


    fn fresh_var(mut self) -> int {
        let v = self.next_var
        self.next_var = self.next_var + 1
        return v
    }


    fn push(mut self, name: string, cname: string, kind: int, unboxed: bool, drop: bool, is_arr: bool, elem_kind: int) {
        self.sc_name.append(name)
        self.sc_cname.append(cname)
        self.sc_kind.append(kind)
        self.sc_unboxed.append(unboxed)
        self.sc_drop.append(drop)
        self.sc_array.append(is_arr)
        self.sc_elem_kind.append(elem_kind)
        self.sc_elem_struct.append(0 - 1)     // default: not a struct-array binding (set_last_elem_struct overrides)
        self.sc_struct.append(0 - 1)          // default: not a struct binding (set_last_struct overrides)
    }


    // set_last_struct records the struct sid of the most-recently pushed binding (a value-struct local),
    // so `p.field` reads and the binding's C storage type resolve. Called right after push for a struct let.
    fn set_last_struct(mut self, sid: int) {
        self.sc_struct[self.sc_struct.len() - 1] = sid
    }


    // set_last_elem_struct records the ELEMENT struct sid of the most-recently pushed STRUCT-array binding,
    // so `arr[i]` types as a boxed struct and `arr[i].field` resolves. Called right after push.
    fn set_last_elem_struct(mut self, sid: int) {
        self.sc_elem_struct[self.sc_elem_struct.len() - 1] = sid
    }


    // lookup_struct returns the value-struct sid of binding `name` (-1 if not a value-struct binding).
    fn lookup_struct(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_struct[i]
            }
            i = i - 1
        }
        return 0 - 1
    }


    // lookup_elem_struct returns the ELEMENT struct sid of struct-array binding `name` (-1 if none).
    fn lookup_elem_struct(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_elem_struct[i]
            }
            i = i - 1
        }
        return 0 - 1
    }


    // lookup_elem_kind returns array binding `name`'s ELEMENT scalar width-kind (-1 if not an array / unknown).
    fn lookup_elem_kind(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_elem_kind[i]
            }
            i = i - 1
        }
        return 0 - 1
    }


    fn lookup_array(self, name: string) -> bool {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_array[i]
            }
            i = i - 1
        }
        return false
    }


    // ind returns the current indentation (4 spaces per level).
    fn ind(self) -> string {
        var s = ""
        var i = 0
        loop {
            if i >= self.indent {
                break
            }
            s = s + "    "
            i = i + 1
        }
        return s
    }


    // scope_has_drops reports whether any in-scope binding is an owned heap value needing a drop at exit.
    fn scope_has_drops(self) -> bool {
        var i = 0
        loop {
            if i >= self.sc_drop.len() {
                break
            }
            if self.sc_drop[i] {
                return true
            }
            i = i + 1
        }
        return false
    }


    // emit_drops prints `drop_value(&g_em, <cname>);` for every owned binding in [from, len), innermost
    // (latest) first — the order the runtime releases scope-exit owners (cgen_c.c:emit_drops). `from` = 0
    // at a function exit; a block/loop passes its scope mark to drop only what the block declared.
    fn emit_drops(self, from: int) {
        var i = self.sc_drop.len() - 1
        loop {
            if i < from {
                break
            }
            if self.sc_drop[i] {
                println("{self.ind()}drop_value(&g_em, {self.sc_cname[i]});")
            }
            i = i - 1
        }
    }


    // truncate_scope drops scope entries past `mark` (a block's locals leave scope at its `}`). Rebuilds the
    // parallel arrays (Ember has no array pop), mirroring cgen_c.c's `g->scope_len = mark`.
    fn truncate_scope(mut self, mark: int) {
        var nn: [string] = []
        var nc: [string] = []
        var nk: [int] = []
        var nu: [bool] = []
        var nd: [bool] = []
        var na: [bool] = []
        var ne: [int] = []
        var nes: [int] = []
        var ns: [int] = []
        var i = 0
        loop {
            if i >= mark {
                break
            }
            nn.append(self.sc_name[i])
            nc.append(self.sc_cname[i])
            nk.append(self.sc_kind[i])
            nu.append(self.sc_unboxed[i])
            nd.append(self.sc_drop[i])
            na.append(self.sc_array[i])
            ne.append(self.sc_elem_kind[i])
            nes.append(self.sc_elem_struct[i])
            ns.append(self.sc_struct[i])
            i = i + 1
        }
        self.sc_elem_struct = nes
        self.sc_name = nn
        self.sc_cname = nc
        self.sc_kind = nk
        self.sc_unboxed = nu
        self.sc_drop = nd
        self.sc_array = na
        self.sc_elem_kind = ne
        self.sc_struct = ns
    }


    fn lookup_unboxed(self, name: string) -> bool {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_unboxed[i]
            }
            i = i - 1
        }
        return false
    }


    // lookup_cname / lookup_kind resolve the nearest in-scope binding `name` (-1 kind / "" cname if none).
    fn lookup_cname(self, name: string) -> string {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_cname[i]
            }
            i = i - 1
        }
        return ""
    }


    fn lookup_kind(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_kind[i]
            }
            i = i - 1
        }
        return 0 - 1
    }


    fn fn_index(self, name: string) -> int {
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
        return 0 - 1
    }


    // ---- expression emission (M5a: int scalars — literals, idents, binops, user calls) --------------
    // emit_expr returns the C expression text for `e`. An in-scope SCALAR binding is re-boxed
    // `INT_VAL((int64_t)vN)`; a Value binding/param is its C name as-is.
    fn emit_expr(mut self, e: ps.Expr) -> string {
        match e {
            case EInt(v) {
                return "INT_VAL({v}LL)"
            }
            case EBool(b) {
                // A bool literal is an INT_VAL(0/1) — the runtime has no distinct bool tag (cgen_c.c:EXPR_BOOL).
                if b {
                    return "INT_VAL(1)"
                }
                return "INT_VAL(0)"
            }
            case EIdent(name) {
                if self.en.is_variant(name) && self.lookup_cname(name) == "" {
                    var no_args: [ps.Expr] = []
                    return self.emit_enum_ctor(name, no_args)   // a bare (zero-payload) enum variant `Dot`
                }
                let cn = self.lookup_cname(name)
                if self.lookup_unboxed(name) {
                    return "INT_VAL((int64_t){cn})"      // an unboxed scalar `let` boxes back to a Value
                }
                return cn                                // a param / Value binding is read as-is
            }
            case EBinary(op, l, r) {
                return self.emit_binary(op, l.value, r.value)
            }
            case ECall(callee, args) {
                return self.emit_call(callee.value, args)
            }
            case EStr(parts) {
                return self.emit_str(parts)
            }
            case EArray(elems, lines) {
                // A non-empty array literal → em_array(&g_em, n, elem_kind, e0, e1, …). The element kind is
                // inferred from the first element (codegen.em's rule); each element is emitted in source order
                // (a left-to-right loop, so any side-effecting element keeps a deterministic var number — the
                // OFI-166 eval-order discipline). An empty `[]` is lowered by the binding site (it needs the
                // annotation for its element kind); a bare `[]` here defaults to a boxed empty array.
                if elems.len() == 0 {
                    return "em_array(&g_em, 0, 0)"
                }
                let ek = self.elem_kind_of_expr(elems[0])
                var s = "em_array(&g_em, {elems.len()}, {ek}"
                var i = 0
                loop {
                    if i >= elems.len() {
                        break
                    }
                    let el = self.emit_expr(elems[i])      // a scalar element is emitted as its Value (em_array consumes it)
                    s = s + ", " + el
                    i = i + 1
                }
                return s + ")"
            }
            case EIndex(object, index) {
                // An index read `arr[i]` → em_index(&g_em, arr, i) (bounds-checked; returns the element
                // WITHOUT retaining — the array keeps ownership). Object then index in source order (OFI-166).
                let o = self.emit_expr(object.value)
                let ix = self.emit_expr(index.value)
                return "em_index(&g_em, {o}, {ix})"
            }
            case EStructLit(ty, fields) {
                return self.emit_struct_lit(ty.value, fields)
            }
            case EGet(object, name) {
                // A VALUE-struct field read is a direct C member access `<obj>.f<idx>` (no heap, no ownership).
                // A BOXED-struct field read is `em_enum_field(&g_em, <obj>, <idx>)` — a BORROW (the struct
                // still owns the field; a consuming op retains it, see emit_concat_operand).
                let vsid = self.struct_sid_of(object.value)
                if vsid >= 0 {
                    let fidx = self.st.field_index(vsid, name)
                    if fidx >= 0 {
                        return "{self.emit_expr(object.value)}.f{fidx}"
                    }
                }
                let bsid = self.boxed_sid_of(object.value)
                if bsid >= 0 {
                    let fidx = self.st.field_index(bsid, name)
                    if fidx >= 0 {
                        return "em_enum_field(&g_em, {self.emit_expr(object.value)}, {fidx})"
                    }
                }
                return "INT_VAL(0)"
            }
            case _ {
                return "INT_VAL(0)"
            }
        }
    }


    // struct_sid_any returns the struct sid (VALUE or BOXED) an expression produces, or -1: a struct literal,
    // a struct binding, a struct-returning call / method, or a nested struct field read. The two public
    // accessors gate it by is_value. Mirrors cgen_c.c:struct_sid_of (value) / the boxed-receiver paths.
    fn struct_sid_any(self, e: ps.Expr) -> int {
        match e {
            case EStructLit(ty, fields) {
                return ty_struct_sid(ty.value, self.st.names)
            }
            case EIdent(name) {
                return self.lookup_struct(name)
            }
            case EIndex(object, index) {
                // an element read of a STRUCT array `arr[i]` → the array's element struct sid (a boxed clone).
                match object.value {
                    case EIdent(aname) {
                        return self.lookup_elem_struct(aname)
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_struct[fi]
                        }
                    }
                    case EGet(object, mname) {
                        let rsid = self.struct_sid_any(object.value)
                        if rsid >= 0 {
                            let fi = self.fn_index("{self.st.names[rsid]}.{mname}")
                            if fi >= 0 {
                                return self.fn_ret_struct[fi]
                            }
                        }
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case EGet(object, name) {
                let osid = self.struct_sid_any(object.value)
                if osid >= 0 {
                    let fidx = self.st.field_index(osid, name)
                    if fidx >= 0 {
                        return self.st.f_struct[self.st.flat_index(osid, fidx)]   // nested field's struct sid (or -1)
                    }
                }
                return 0 - 1
            }
            case _ {
                return 0 - 1
            }
        }
    }


    // struct_sid_of is the VALUE-struct sid an expression produces (an em_s: value semantics, `.fN` reads).
    fn struct_sid_of(self, e: ps.Expr) -> int {
        let s = self.struct_sid_any(e)
        if s >= 0 && self.st.is_value(s) {
            return s
        }
        return 0 - 1
    }


    // boxed_sid_of is the BOXED-struct sid an expression produces (a heap ObjStruct: em_struct / em_enum_field
    // field access, owned local / borrow param — like an array).
    fn boxed_sid_of(self, e: ps.Expr) -> int {
        let s = self.struct_sid_any(e)
        if s >= 0 && self.st.is_value(s) == false {
            return s
        }
        return 0 - 1
    }


    // slit_index returns the position in a struct literal's field list of declared field `fname` (or -1) —
    // the literal may list fields in any order, but the compound literal must place them in DECLARED order.
    fn slit_index(self, fields: [ps.SLitField], fname: string) -> int {
        var i = 0
        loop {
            if i >= fields.len() {
                break
            }
            if fields[i].name == fname {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    // emit_struct_lit renders a struct construction. A VALUE struct is a C compound literal
    // `((em_s<sid>){ f0, f1, … })` in DECLARED field order (fields emitted left-to-right — OFI-166).
    // A boxed struct (em_struct) is a later increment (M5e.2).
    fn emit_struct_lit(mut self, ty: ps.Ty, fields: [ps.SLitField]) -> string {
        let sid = ty_struct_sid(ty, self.st.names)
        if sid < 0 {
            return "INT_VAL(0)"
        }
        let fc = self.st.field_count(sid)
        if self.st.is_value(sid) {
            // VALUE struct → a C compound literal `((em_s<sid>){ f0, f1, … })` in DECLARED field order.
            var s = "((em_s{sid})\{ "
            var f = 0
            loop {
                if f >= fc {
                    break
                }
                if f > 0 {
                    s = s + ", "
                }
                let fname = self.st.f_name[self.st.flat_index(sid, f)]
                let fpos = self.slit_index(fields, fname)
                if fpos >= 0 {
                    s = s + self.emit_expr(fields[fpos].value)
                }
                f = f + 1
            }
            return s + " \})"
        }
        // BOXED struct → em_struct(&g_em, <sid>, <fcount>, f0, f1, …) — a heap ObjStruct whose fields are
        // dropped by drop_value. Fields in DECLARED order; a field value is CONSUMED (an owned binding is
        // MOVED in via emit_call_arg, a scalar / fresh temp passed as-is).
        var s = "em_struct(&g_em, {sid}, {fc}"
        var f = 0
        loop {
            if f >= fc {
                break
            }
            let fname = self.st.f_name[self.st.flat_index(sid, f)]
            let fpos = self.slit_index(fields, fname)
            if fpos >= 0 {
                s = s + ", " + self.emit_call_arg(fields[fpos].value)
            }
            f = f + 1
        }
        return s + ")"
    }


    // emit_enum_ctor renders an enum-variant construction (a bare `Dot` or a payload `Circle(4)`) →
    // `em_enum(&g_em, <enum_id>, <tag>, <arity>, payload…)`. The payload values are emitted in source order
    // (a left-to-right loop — OFI-166). A fresh em_enum is an OWNED refcounted value.
    fn emit_enum_ctor(mut self, name: string, args: [ps.Expr]) -> string {
        let flat = self.en.variant_flat(name)
        let eid = self.en.v_owner[flat]
        let tag = self.en.v_tag[flat]
        let arity = self.en.v_arity[flat]
        var s = "em_enum(&g_em, {eid}, {tag}, {arity}"
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            s = s + ", " + self.emit_expr(args[i])      // a scalar payload (owned payloads: a later increment)
            i = i + 1
        }
        return s + ")"
    }


    // is_enum_expr reports whether an expression CONSTRUCTS an enum value (a bare variant, or a variant with
    // payload) — an OWNED refcounted value, dropped at scope exit / moved into a call like a string.
    fn is_enum_expr(self, e: ps.Expr) -> bool {
        match e {
            case EIdent(name) {
                return self.en.is_variant(name) && self.lookup_cname(name) == ""
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        if self.en.is_variant(name) {
                            return true                       // a payload variant construction `Circle(4)`
                        }
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_enum[fi]       // an enum-returning free-function call `wrap(7)`
                        }
                    }
                    case _ {
                    }
                }
                return false
            }
            case _ {
                return false
            }
        }
    }


    // emit_str renders a string literal. A single literal run (no interpolation) is an interned, cached
    // `em_str` via a function-local static, retained on read (cgen_c.c). Interpolation (holes) is deferred.
    fn emit_str(mut self, parts: [ps.StrPart]) -> string {
        if parts.len() == 1 && parts[0].hole.len() == 0 {
            let bytes = c_escape(parts[0].text)
            let blen = parts[0].text.bytes().len()
            return "(\{ static Value _li; static char _ls; if (!_ls) \{ _ls = 1; _li = em_str(&g_em, \"{bytes}\", {blen}); \} if (IS_OBJ(_li)) OBJ_RETAIN(AS_OBJ(_li)); _li; \})"
        }
        if parts.len() == 0 {
            return "(\{ static Value _li; static char _ls; if (!_ls) \{ _ls = 1; _li = em_str(&g_em, \"\", 0); \} if (IS_OBJ(_li)) OBJ_RETAIN(AS_OBJ(_li)); _li; \})"
        }
        return "INT_VAL(0)"            // interpolation (holes) — deferred to the interp increment
    }


    // emit_binary mirrors cgen_c.c:emit_binary — each operator maps to an em_* runtime call; em_add /
    // em_eq_op / em_neq_op take the runtime ctx (`&g_em`) and RETAIN a borrowed operand (they consume),
    // every other op reads its operands directly. The numeric ops carry the width as a trailing num_kind
    // (0 = i64 for the int subset).
    fn emit_binary(mut self, op: lx.Tk, l: ps.Expr, r: ps.Expr) -> string {
        let bid = ps.binop_id(op)
        // The two operands are emitted into LOCALS first, in source (left-to-right) order. Each emit_
        // bumps the shared `next_var`, and we must NOT depend on the C compiler's UNSPECIFIED operand
        // evaluation order — gcc evaluates a `+`/call's operands right-to-left where clang and the VM go
        // left-to-right, which would otherwise SWAP the retain-temp v-numbers (a VM/native divergence the
        // ccdiff differential caught on Linux gcc). Sequencing them as statements forces the order. OFI-166.
        // short-circuit && / || — a truthy test, not an em_ call (binop_id 12 && / 13 ||)
        if bid == 12 || bid == 13 {
            var c = "&&"
            if bid == 13 {
                c = "||"
            }
            let lc = self.emit_expr(l)
            let rc = self.emit_expr(r)
            return "INT_VAL((em_truthy({lc}) {c} em_truthy({rc})) ? 1 : 0)"
        }
        let cf = binop_cfn(bid)
        let ctx = binop_wants_ctx(bid)
        var opl = ""
        var opr = ""
        if ctx {
            // `+` (bid 1) CONSUMES its operands (an owned operand is moved in); `==` / `!=` (10/11) only
            // COMPARE (borrow), so an owned operand is retained, not moved — it is read again later.
            let consuming = bid == 1
            opl = self.emit_concat_operand(l, consuming)
            opr = self.emit_concat_operand(r, consuming)
        } else {
            opl = self.emit_expr(l)
            opr = self.emit_expr(r)
        }
        var s = "{cf}("
        if ctx {
            s = s + "&g_em, "
        }
        s = s + opl + ", " + opr
        if binop_has_nk(bid) {
            s = s + ", 0"                                // num_kind 0 (i64) for the int subset
        }
        return s + ")"
    }


    // emit_concat_operand renders an operand of a CONSUMING op (em_add/eq/neq — they drop both operands),
    // or a returned value. An OWNED binding read is MOVED out (own_into_slot — it transfers ownership);
    // a BORROWED binding read (a non-owned scalar/Value ident) is wrapped in the retain dance so the
    // owner's reference stays balanced; anything else (a literal/call/computed temp) is emitted as-is.
    // retain_dance wraps a BORROWED heap operand in `({ Value vN = <e>; if (IS_OBJ(vN)) OBJ_RETAIN(…); vN; })`
    // so a consuming op (em_add) balances and the owner keeps its reference. The IS_OBJ guard makes it a
    // no-op for scalar operands. vN is taken BEFORE emitting <e>, so it precedes any inner temp (OFI-166).
    fn retain_dance(mut self, e: ps.Expr) -> string {
        let v = self.fresh_var()
        return "(\{ Value v{v} = {self.emit_expr(e)}; if (IS_OBJ(v{v})) OBJ_RETAIN(AS_OBJ(v{v})); v{v}; \})"
    }


    // move_binding renders an OWNED binding being moved OUT (a return / a consumed concat operand). A
    // unique-owner ARRAY is moved by NIL-ing its slot — `({ Value vN = cn; cn = INT_VAL(0); vN; })` — so its
    // scope-exit drop becomes a no-op (a retain would deep-CLONE it; arrays aren't refcounted). A refcounted
    // STRING is owned into the new slot via own_into_slot (a retain), and its scope-exit drop balances it.
    // (cgen_c.c: moves_local==1 for the array, moves_local==2 for the string.)
    fn move_binding(mut self, name: string) -> string {
        let cn = self.lookup_cname(name)
        if self.lookup_array(name) {
            let m = self.fresh_var()
            return "(\{ Value v{m} = {cn}; {cn} = INT_VAL(0); v{m}; \})"
        }
        return "own_into_slot(&g_em, {cn})"
    }


    fn emit_concat_operand(mut self, e: ps.Expr, consuming: bool) -> string {
        match e {
            case EIdent(name) {
                if self.lookup_drop(name) {
                    if consuming {
                        return self.move_binding(name)   // `+` consumes → move the owned binding out
                    }
                    return self.retain_dance(e)          // `==`/`!=` only compare → retain (still used later)
                }
                return self.retain_dance(e)
            }
            case EIndex(object, index) {
                // an array-element read `arr[i]` is a BORROW (em_index returns it un-retained) → retain it,
                // so the consuming op balances and the array keeps ownership (cgen_c.c:emit_concat_operand).
                return self.retain_dance(e)
            }
            case EGet(object, name) {
                // A field read that is a BORROW yields a value the consuming op would over-release → retain it.
                // (1) `self.field` — self is the borrowed method receiver (a by-value struct param / let field
                // is an owned COPY, NOT retained). (2) a BOXED-struct field read (em_enum_field borrows — the
                // struct owns the field). A value-struct scalar field makes the IS_OBJ retain a no-op.
                let bsid = self.boxed_sid_of(object.value)
                if bsid >= 0 && consuming && self.st.field_is_refcounted(bsid, name) {
                    // a refcounted (string / enum) field CONSUMED by `+` is owned into the concat (own_into_slot,
                    // moves_local==2) and then the consuming op's balance-retain wraps it (cgen_c.c).
                    let v = self.fresh_var()
                    return "(\{ Value v{v} = own_into_slot(&g_em, {self.emit_expr(e)}); if (IS_OBJ(v{v})) OBJ_RETAIN(AS_OBJ(v{v})); v{v}; \})"
                }
                if self.is_self_field(object.value) || bsid >= 0 {
                    return self.retain_dance(e)
                }
            }
            case _ {
            }
        }
        return self.emit_expr(e)
    }


    // is_self_field reports whether `object` is the borrowed method receiver `self` (a value-struct binding),
    // so a field read off it is a borrow. (mut/move self — a consuming receiver — is a later increment.)
    fn is_self_field(self, object: ps.Expr) -> bool {
        match object {
            case EIdent(oname) {
                return oname == "self" && self.lookup_struct(oname) >= 0
            }
            case _ {
                return false
            }
        }
    }


    // emit_call_arg renders a user-call argument: the callee takes OWNERSHIP, so an owned binding is MOVED
    // in via own_into_slot; a non-owned binding / literal / temp is passed AS-IS (no retain — unlike a
    // consuming em_add operand, a plain call does not need the owner's reference balanced separately).
    fn emit_call_arg(mut self, e: ps.Expr) -> string {
        match e {
            case EIdent(name) {
                // An owned STRING / ENUM binding is MOVED in (own_into_slot). An owned ARRAY or BOXED-STRUCT
                // binding is passed as a BORROW (the callee's param is a borrow — the owner keeps it and drops
                // it at its own scope exit).
                let sid = self.lookup_struct(name)
                let is_boxed_struct = sid >= 0 && self.st.is_value(sid) == false
                if self.lookup_drop(name) && self.lookup_array(name) == false && is_boxed_struct == false {
                    return "own_into_slot(&g_em, {self.lookup_cname(name)})"
                }
            }
            case EGet(object, name) {
                // A REFCOUNTED (string / enum) struct field read passed to a call is MOVED in (own_into_slot
                // retains the field for the callee's consume; the struct keeps its own reference). A scalar /
                // array / struct field is passed as-is (a borrow).
                let sid = self.struct_sid_any(object.value)
                if sid >= 0 && self.st.field_is_refcounted(sid, name) {
                    return "own_into_slot(&g_em, {self.emit_expr(e)})"
                }
            }
            case _ {
            }
        }
        return self.emit_expr(e)
    }


    // arg_is_owning_temp reports whether a call argument is a FRESH owned heap temporary passed by borrow —
    // the caller must drop it after the call, or it leaks (the checker's drop_mask). M5d: an array literal
    // `[…]` (a binding read is a borrow its owner drops; a moved string is consumed, not a borrowed temp).
    fn arg_is_owning_temp(self, e: ps.Expr) -> bool {
        match e {
            case EArray(elems, lines) {
                return true
            }
            case EStructLit(ty, fields) {
                // a BOXED struct literal passed by borrow is a fresh owned heap temp → caller drops it after
                // the call (a value struct has no heap, so it is NOT an owning temp).
                let sid = ty_struct_sid(ty.value, self.st.names)
                return sid >= 0 && self.st.is_value(sid) == false
            }
            case _ {
                return false
            }
        }
    }


    // emit_call emits a user free-function call `f(args)` → `em_fn_<index>(<args>)`, or a built-in array
    // method (`arr.len()` → em_array_len, `arr.append(x)` → em_array_append) when the callee is `recv.m`.
    fn emit_call(mut self, callee: ps.Expr, args: [ps.Expr]) -> string {
        match callee {
            case EIdent(name) {
                let ck = numeric_typename_kind(name)
                if ck >= 0 && args.len() == 1 {
                    return "em_conv({self.emit_expr(args[0])}, {ck})"   // a numeric-width conversion `int(x)`
                }
                if self.en.is_variant(name) {
                    return self.emit_enum_ctor(name, args)   // an enum-variant construction `Circle(4)`
                }
                let nid = native_id_for_name(name)
                if is_em_native_id(nid) {
                    // a native runtime builtin (byte_slice, read_file, math, …) → em_native(&g_em, <id>, <argc>,
                    // (Value[]){ args }); its args are read as BORROWS. (print/println keep em_print/em_println.)
                    if args.len() == 0 {
                        return "em_native(&g_em, {nid}, 0, 0)"
                    }
                    var s = "em_native(&g_em, {nid}, {args.len()}, (Value[])\{ "
                    var i = 0
                    loop {
                        if i >= args.len() {
                            break
                        }
                        if i > 0 {
                            s = s + ", "
                        }
                        s = s + self.emit_expr(args[i])
                        i = i + 1
                    }
                    return s + " \})"
                }
                let fi = self.fn_index(name)
                if fi >= 0 {
                    // If any argument is an owning temporary (an array literal), hoist EVERY argument into a
                    // `c%d` local (left-to-right), call, drop the masked temps, then yield the result — a
                    // statement-expression so it stays usable in expression position (cgen_c.c:emit_call).
                    var any_temp = false
                    var ti = 0
                    loop {
                        if ti >= args.len() {
                            break
                        }
                        if self.arg_is_owning_temp(args[ti]) {
                            any_temp = true
                        }
                        ti = ti + 1
                    }
                    if any_temp {
                        let rid = self.fresh_var()                  // result id, taken BEFORE the arg ids
                        var argids: [int] = []
                        var s = "(\{ "
                        var i = 0
                        loop {
                            if i >= args.len() {
                                break
                            }
                            let aid = self.fresh_var()
                            argids.append(aid)
                            s = s + "Value c{aid} = {self.emit_call_arg(args[i])}; "
                            i = i + 1
                        }
                        s = s + "Value c{rid} = em_fn_{fi}("
                        var j = 0
                        loop {
                            if j >= argids.len() {
                                break
                            }
                            if j > 0 {
                                s = s + ", "
                            }
                            s = s + "c{argids[j]}"
                            j = j + 1
                        }
                        s = s + "); "
                        var k = 0
                        loop {
                            if k >= args.len() {
                                break
                            }
                            if self.arg_is_owning_temp(args[k]) {
                                s = s + "drop_value(&g_em, c{argids[k]}); "
                            }
                            k = k + 1
                        }
                        return s + "c{rid}; \})"
                    }
                    var s = "em_fn_{fi}("
                    var i = 0
                    loop {
                        if i >= args.len() {
                            break
                        }
                        if i > 0 {
                            s = s + ", "
                        }
                        s = s + self.emit_call_arg(args[i])
                        i = i + 1
                    }
                    return s + ")"
                }
            }
            case EGet(object, mname) {
                // A built-in STRING method (a string receiver — a param / literal / owned local). `.len()`
                // is em_str_len (NO ctx); `.bytes()`/`.chars()` return fresh OWNED arrays (em_str_bytes → [u8],
                // em_str_chars → [string]); `.split(sep)` → [string]. The receiver is a BORROW (read as-is;
                // a temp-receiver drop is a later increment). (cgen_c.c string-method ops.)
                if self.is_string_expr(object.value) {
                    if mname == "len" {
                        return "em_str_len({self.emit_expr(object.value)})"
                    }
                    if mname == "bytes" {
                        return "em_str_bytes(&g_em, {self.emit_expr(object.value)})"
                    }
                    if mname == "chars" {
                        return "em_str_chars(&g_em, {self.emit_expr(object.value)})"
                    }
                    if mname == "split" {
                        let recv = self.emit_expr(object.value)
                        let sep = self.emit_expr(args[0])
                        return "em_str_split(&g_em, {recv}, {sep})"
                    }
                }
                // A built-in array method. `.len()` returns the length scalar; `.append(x)` grows the array.
                if self.is_array_expr(object.value) {
                    if mname == "len" {
                        // A FRESH temporary receiver (an array literal / call result) is measured, then
                        // dropped so it can't leak; a binding/index receiver is a borrow its owner drops.
                        if self.recv_is_temp(object.value) {
                            let t = self.fresh_var()
                            let m = self.fresh_var()
                            let r = self.emit_expr(object.value)
                            return "(\{ Value v{t} = {r}; Value v{m} = em_array_len(v{t}); drop_value(&g_em, v{t}); v{m}; \})"
                        }
                        return "em_array_len({self.emit_expr(object.value)})"
                    }
                    if mname == "append" {
                        let recv = self.emit_expr(object.value)
                        let el = self.emit_expr(args[0])      // element in source order, after the receiver (OFI-166)
                        return "em_array_append(&g_em, {recv}, {el})"
                    }
                }
                // A struct method call `recv.m(args)` → em_fn_<K>(recv, args…): self is arg 0, the method's
                // fn-index resolves via the `Struct.method` name. A VALUE-struct self is passed by value (an
                // em_s); a BOXED-struct self is passed as its borrowed Value (a heap pointer — mutations via
                // em_set_field reach the caller's object). (cgen_c.c method path.)
                let rsid = self.struct_sid_any(object.value)
                if rsid >= 0 {
                    let fi = self.fn_index("{self.st.names[rsid]}.{mname}")
                    if fi >= 0 {
                        var s = "em_fn_{fi}(" + self.emit_expr(object.value)   // self (em_s value / boxed Value)
                        var i = 0
                        loop {
                            if i >= args.len() {
                                break
                            }
                            s = s + ", " + self.emit_call_arg(args[i])
                            i = i + 1
                        }
                        return s + ")"
                    }
                }
            }
            case _ {
            }
        }
        return "INT_VAL(0)"
    }


    // recv_is_temp reports whether a method receiver is a FRESH owned temporary (an array literal or a call
    // result) — which the caller must drop after a borrowing method — rather than a borrow (a binding /
    // index read the owner drops). Mirrors cgen_c.c:recv_is_borrow (negated).
    fn recv_is_temp(self, e: ps.Expr) -> bool {
        match e {
            case EArray(elems, lines) {
                return true
            }
            case ECall(callee, args) {
                return true
            }
            case _ {
                return false
            }
        }
    }


    // scalar_kind_of statically classifies an expression's numeric width-kind (0 i64 … for the M5a int
    // subset), or -1 if it is not a known scalar (a string/struct/Value). Drives the `let` storage choice.
    fn scalar_kind_of(self, e: ps.Expr) -> int {
        match e {
            case EInt(v) {
                return 0
            }
            case EBinary(op, l, r) {
                let bid = ps.binop_id(op)
                // `+` is STRING concat (not a scalar) when either operand is a string, else int addition.
                if bid == 1 {
                    if self.is_string_expr(l.value) || self.is_string_expr(r.value) {
                        return 0 - 1
                    }
                    return 0
                }
                // other arithmetic / bitwise / shift produce a numeric value; compares/logic produce a bool
                if bid >= 2 && bid <= 5 {
                    return 0
                }
                if bid >= 14 && bid <= 18 {
                    return 0
                }
                return 0 - 1
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let ck = numeric_typename_kind(name)
                        if ck >= 0 {
                            return ck                     // a numeric conversion `let a = i32(n)` → a sized scalar
                        }
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_kind[fi]
                        }
                    }
                    case EGet(object, mname) {
                        // `arr.len()` / `s.len()` returns an int scalar (kind 0 = i64).
                        if mname == "len" {
                            if self.is_array_expr(object.value) || self.is_string_expr(object.value) {
                                return 0
                            }
                        }
                        // a struct method call `p.method()` returning a scalar (`let n = p.norm1()` / a boxed
                        // `let a = lx.advance()`).
                        let rsid = self.struct_sid_any(object.value)
                        if rsid >= 0 {
                            let fi = self.fn_index("{self.st.names[rsid]}.{mname}")
                            if fi >= 0 {
                                return self.fn_ret_kind[fi]
                            }
                        }
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case EIndex(object, index) {
                // `arr[i]` of a scalar-element array is that element's scalar kind (a boxed element → -1).
                return self.index_elem_kind(object.value)
            }
            case EGet(object, name) {
                // `let x = s.field` of a SCALAR struct field types as that field's C scalar (a boxed / array /
                // struct field → -1, a Value binding); a struct-array field's `.len()` is handled via ECall.
                let sid = self.struct_sid_any(object.value)
                if sid >= 0 {
                    return self.st.field_scalar_kind(sid, name)
                }
                return 0 - 1
            }
            case EIdent(name) {
                return self.lookup_kind(name)
            }
            case _ {
                return 0 - 1
            }
        }
    }


    // value_elem_kind infers the ELEMENT scalar kind of an UN-annotated array initialiser: a literal from
    // its first element (a float → f64=9, a string/array element → boxed -1, otherwise i64=0), an
    // array-returning call from its return element kind, an array binding alias from the source's kind.
    fn value_elem_kind(self, value: ps.Expr) -> int {
        match value {
            case EArray(elems, lines) {
                if elems.len() == 0 {
                    return 0 - 1
                }
                if self.is_string_expr(elems[0]) || self.is_array_expr(elems[0]) {
                    return 0 - 1
                }
                match elems[0] {
                    case EFloat(v) {
                        return 9
                    }
                    case _ {
                        return 0
                    }
                }
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_elem_kind[fi]
                        }
                    }
                    case EGet(object, mname) {
                        if self.is_string_expr(object.value) && mname == "bytes" {
                            return 4                      // `s.bytes()` → [u8]; u8 is element scalar kind 4
                        }
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case EIdent(name) {
                return self.lookup_elem_kind(name)
            }
            case _ {
                return 0 - 1
            }
        }
    }


    // index_elem_kind returns the scalar width-kind of an indexed array's ELEMENT (or -1 for a non-scalar /
    // unknown element): an array BINDING carries its element kind, an array-returning CALL its return kind.
    fn index_elem_kind(self, object: ps.Expr) -> int {
        match object {
            case EIdent(name) {
                return self.lookup_elem_kind(name)
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_elem_kind[fi]
                        }
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case _ {
                return 0 - 1
            }
        }
    }


    // emit_stmt prints the C for one statement (4-space indented inside a function body).
    fn lookup_drop(self, name: string) -> bool {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_drop[i]
            }
            i = i - 1
        }
        return false
    }


    // is_string_expr reports whether an expression produces a STRING (an owned heap value, dropped at
    // scope exit). M5b: a string literal, an owned string binding, and a string concatenation.
    fn is_string_expr(self, e: ps.Expr) -> bool {
        match e {
            case EStr(parts) {
                return true
            }
            case EIdent(name) {
                return self.lookup_drop(name) && self.lookup_array(name) == false   // owned, and NOT an array
            }
            case EBinary(op, l, r) {
                if ps.binop_id(op) == 1 {
                    return self.is_string_expr(l.value) || self.is_string_expr(r.value)
                }
                return false
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_str[fi]
                        }
                        if native_ret_kind(name) == 0 - 3 {
                            return true                  // a string-returning native builtin (byte_slice, read_file, …)
                        }
                    }
                    case EGet(object, mname) {
                        // a string-returning METHOD call `let v = recv.method(…)`.
                        let sid = self.struct_sid_any(object.value)
                        if sid >= 0 {
                            let fi = self.fn_index("{self.st.names[sid]}.{mname}")
                            if fi >= 0 {
                                return self.fn_ret_str[fi]
                            }
                        }
                    }
                    case _ {
                    }
                }
                return false
            }
            case _ {
                return false
            }
        }
    }


    // is_array_expr reports whether an expression produces an ARRAY value: a literal, an array binding, or
    // a call to an array-returning function (`let xs = make()` — an owned array local, dropped at exit).
    fn is_array_expr(self, e: ps.Expr) -> bool {
        match e {
            case EArray(elems, lines) {
                return true
            }
            case EIdent(name) {
                return self.lookup_array(name)
            }
            case EGet(object, name) {
                // a struct's ARRAY field `s.toks` (so `s.toks.len()` / `s.toks[i]` resolve)
                let sid = self.struct_sid_any(object.value)
                return sid >= 0 && self.st.field_is_array(sid, name)
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_array[fi]
                        }
                        if native_ret_kind(name) == 0 - 2 {
                            return true                  // an array-returning native builtin (args)
                        }
                    }
                    case EGet(object, mname) {
                        // a string→array method `s.bytes()` / `s.chars()` / `s.split(sep)` (an owned array).
                        if self.is_string_expr(object.value) {
                            return mname == "bytes" || mname == "chars" || mname == "split"
                        }
                    }
                    case _ {
                    }
                }
                return false
            }
            case _ {
                return false
            }
        }
    }


    // elem_kind_of_expr infers a non-empty array literal's ArrayElemKind (value.h AEK_*) from its first
    // element's form — mirroring codegen.em's elem_kind_of so both backends agree with stage-0's checker:
    // a string/array (boxed) element → 0, a float → f64=10, a bool → 11, otherwise i64=4 (int / arithmetic).
    fn elem_kind_of_expr(self, e: ps.Expr) -> int {
        if self.is_string_expr(e) || self.is_array_expr(e) {
            return 0
        }
        match e {
            case EStr(parts) {
                return 0
            }
            case EFloat(v) {
                return 10
            }
            case EBool(b) {
                return 11
            }
            case _ {
                return 4
            }
        }
    }


    // emit_block_raw emits a statement list WITHOUT managing scope (the caller — e.g. a for-loop that
    // pushed its loop variable before the body — handles the drops/truncate itself).
    fn emit_block_raw(mut self, body: [ps.Stmt]) {
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.emit_stmt(body[i])
            i = i + 1
        }
    }


    // emit_block_stmts emits a scoped block (an if/loop/bare-block body): its owned locals are dropped at
    // the block's normal exit and leave scope (cgen_c.c:emit_block_scoped).
    fn emit_block_stmts(mut self, body: [ps.Stmt]) {
        let mark = self.sc_name.len()
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.emit_stmt(body[i])
            i = i + 1
        }
        self.emit_drops(mark)
        self.truncate_scope(mark)
    }


    // emit_if renders `if (em_truthy(<cond>)) { … }` with an optional `else { … }` / `else if …` chain.
    // `leading` is the prefix before `if` — the indent for a top-level if, "" when chained after `} else `.
    fn emit_if(mut self, cond: ps.Expr, then_blk: [ps.Stmt], els: [ps.Stmt], leading: string) {
        let c = self.emit_expr(cond)
        println("{leading}if (em_truthy({c})) \{")
        self.indent = self.indent + 1
        self.emit_block_stmts(then_blk)
        self.indent = self.indent - 1
        if els.len() > 0 {
            match els[0] {
                case SBlock(body) {
                    println("{self.ind()}\} else \{")
                    self.indent = self.indent + 1
                    self.emit_block_stmts(body)
                    self.indent = self.indent - 1
                    println("{self.ind()}\}")
                }
                case SIf(econd, ethen, eels) {
                    print("{self.ind()}\} else ")
                    self.emit_if(econd.value, ethen, eels, "")
                }
                case _ {
                    println("{self.ind()}\}")
                }
            }
        } else {
            println("{self.ind()}\}")
        }
    }


    fn emit_stmt(mut self, s: ps.Stmt) {
        match s {
            case SReturn(value, line) {
                if self.scope_has_drops() {
                    // Evaluate the value into a temp, drop the function's owned locals/params, then return it.
                    // The value goes through emit_concat_operand (own a moved binding / retain a borrow).
                    let r = self.fresh_var()
                    var rv = "INT_VAL(0)"
                    if value.len() > 0 {
                        rv = self.emit_concat_operand(value[0].value, true)
                    }
                    println("{self.ind()}\{ Value v{r} = {rv};")
                    self.indent = self.indent + 1
                    self.emit_drops(0)
                    println("{self.ind()}return v{r};")
                    self.indent = self.indent - 1
                    println("{self.ind()}\}")
                } else {
                    if value.len() > 0 {
                        println("{self.ind()}return {self.emit_expr(value[0].value)};")
                    } else {
                        println("{self.ind()}return INT_VAL(0);")    // a bare return yields unit (0), like the VM
                    }
                }
            }
            case SLet(is_var, name, ty, value) {
                // The binding's C variable number is taken BEFORE the initialiser (so a `let` is vN and the
                // initialiser's retain temps follow as v(N+1)…). A scalar binding lowers to a typed C scalar
                // unboxed from the Value (`int64_t vN = (int64_t)AS_INT(<rhs>)`); a string binding is an
                // owned Value (dropped at scope exit). (cgen_c.c:STMT_LET.)
                let id = self.fresh_var()
                let ssid = self.struct_sid_of(value.value)
                let kind = self.scalar_kind_of(value.value)
                if ssid >= 0 {
                    // A VALUE-struct binding: stored as the C `em_s<sid>` aggregate (value semantics, no drop).
                    println("{self.ind()}em_s{ssid} v{id} = {self.emit_expr(value.value)};")
                    self.push(name, "v{id}", 0 - 1, false, false, false, 0 - 1)
                    self.set_last_struct(ssid)
                } else if kind >= 0 {
                    let ct = scalar_ctype(kind)
                    println("{self.ind()}{ct} v{id} = ({ct})AS_INT({self.emit_expr(value.value)});")
                    self.push(name, "v{id}", kind, true, false, false, 0 - 1)        // unboxed C scalar storage
                } else {
                    let arr = self.is_array_expr(value.value)
                    let bsid = self.boxed_sid_of(value.value)                            // a BOXED struct local (owned, like an array)
                    let owned = self.is_string_expr(value.value) || arr || self.is_enum_expr(value.value) || bsid >= 0   // string / array / enum / boxed-struct local is owned/dropped
                    // An owned array local carries its ELEMENT scalar kind so a later `xs[i]` types as a scalar —
                    // from the `[T]` annotation if present, else inferred from the initialiser.
                    var elem_sk = 0 - 1
                    if arr {
                        if ty.len() > 0 {
                            elem_sk = ty_scalar_kind(elem_ty_of(ty[0]))
                        } else {
                            elem_sk = self.value_elem_kind(value.value)
                        }
                    }
                    // An empty array literal `[]` carries no element kind in the literal — take it from the
                    // `[T]` annotation (em_array(&g_em, 0, <elem_kind>)), mirroring the checker's context typing.
                    var done = false
                    match value.value {
                        case EArray(elems, lines) {
                            if elems.len() == 0 && ty.len() > 0 {
                                // An empty array of STRUCTS is em_struct_array(&g_em, <sid>, 0) (the element
                                // struct's inline layout); any other empty array is em_array(&g_em, 0, <kind>).
                                let esid = ty_struct_sid(elem_ty_of(ty[0]), self.st.names)
                                if esid >= 0 {
                                    println("{self.ind()}Value v{id} = em_struct_array(&g_em, {esid}, 0);")
                                } else {
                                    let ek = array_elem_kind_ty(elem_ty_of(ty[0]))
                                    println("{self.ind()}Value v{id} = em_array(&g_em, 0, {ek});")
                                }
                                done = true
                            }
                        }
                        case _ {
                        }
                    }
                    if done == false {
                        println("{self.ind()}Value v{id} = {self.emit_concat_operand(value.value, true)};")
                    }
                    self.push(name, "v{id}", 0 - 1, false, owned, arr, elem_sk)
                    if bsid >= 0 {
                        self.set_last_struct(bsid)          // track the boxed-struct sid so `c.field` resolves
                    }
                    if arr && ty.len() > 0 {
                        let esid = ty_struct_sid(elem_ty_of(ty[0]), self.st.names)
                        if esid >= 0 {
                            self.set_last_elem_struct(esid)   // a `[Struct]` array: `ts[i]` types as a boxed struct
                        }
                    }
                }
            }
            case SIf(cond, then_blk, els) {
                self.emit_if(cond.value, then_blk, els, self.ind())
            }
            case SLoop(body) {
                println("{self.ind()}for (;;) \{")
                self.indent = self.indent + 1
                self.emit_block_stmts(body)
                self.indent = self.indent - 1
                println("{self.ind()}\}")
            }
            case SFor(vname, index_var, iter, body) {
                // Both forms wrap in a `{ }` block. Range `for i in lo..hi`: declare lo/hi as int64_t `t`
                // temps, loop the index `t`, bind the loop var as a fresh Value each pass. Array `for x in
                // xs`: evaluate the array once into a `v`, loop over `em_array_len`, bind each element via
                // `em_index`. Per-pass owned body locals are dropped (cgen_c.c:STMT_FOR). The `t` and `v`
                // names SHARE the one counter; only the loop variable(s) are pushed into the binding scope.
                match iter.value {
                    case ERange(lo, hi) {
                        let lo_t = self.fresh_var()
                        let hi_t = self.fresh_var()
                        let ix = self.fresh_var()
                        println("{self.ind()}\{")
                        self.indent = self.indent + 1
                        println("{self.ind()}int64_t t{lo_t} = AS_INT({self.emit_expr(lo.value)});")
                        println("{self.ind()}int64_t t{hi_t} = AS_INT({self.emit_expr(hi.value)});")
                        println("{self.ind()}for (int64_t t{ix} = t{lo_t}; t{ix} < t{hi_t}; t{ix}++) \{")
                        self.indent = self.indent + 1
                        let vid = self.fresh_var()
                        println("{self.ind()}Value v{vid} = INT_VAL(t{ix});")
                        let mark = self.sc_name.len()
                        self.push(vname, "v{vid}", 0 - 1, false, false, false, 0 - 1)
                        self.emit_block_raw(body)
                        self.emit_drops(mark)
                        self.truncate_scope(mark)
                        self.indent = self.indent - 1
                        println("{self.ind()}\}")
                        self.indent = self.indent - 1
                        println("{self.ind()}\}")
                    }
                    case _ {
                        let av = self.fresh_var()
                        let nv = self.fresh_var()
                        let ix = self.fresh_var()
                        println("{self.ind()}\{")
                        self.indent = self.indent + 1
                        println("{self.ind()}Value v{av} = {self.emit_expr(iter.value)};")
                        println("{self.ind()}int64_t t{nv} = AS_INT(em_array_len(v{av}));")
                        println("{self.ind()}for (int64_t t{ix} = 0; t{ix} < t{nv}; t{ix}++) \{")
                        self.indent = self.indent + 1
                        let xv = self.fresh_var()
                        println("{self.ind()}Value v{xv} = em_index(&g_em, v{av}, INT_VAL(t{ix}));")
                        let mark = self.sc_name.len()
                        if index_var != "" {
                            let iv = self.fresh_var()
                            println("{self.ind()}Value v{iv} = INT_VAL(t{ix});")
                            self.push(index_var, "v{iv}", 0 - 1, false, false, false, 0 - 1)
                        }
                        self.push(vname, "v{xv}", 0 - 1, false, false, false, 0 - 1)
                        self.emit_block_raw(body)
                        self.emit_drops(mark)
                        self.truncate_scope(mark)
                        self.indent = self.indent - 1
                        println("{self.ind()}\}")
                        // A FRESH temporary iterable (an array literal or a call result) is dropped after the
                        // loop; a named binding / field is a borrow the owner drops (cgen_c.c:STMT_FOR).
                        match iter.value {
                            case EArray(elems, lines) {
                                println("{self.ind()}drop_value(&g_em, v{av});")
                            }
                            case ECall(callee, cargs) {
                                println("{self.ind()}drop_value(&g_em, v{av});")
                            }
                            case _ {
                            }
                        }
                        self.indent = self.indent - 1
                        println("{self.ind()}\}")
                    }
                }
            }
            case SBreak(line) {
                println("{self.ind()}break;")
            }
            case SContinue(line) {
                println("{self.ind()}continue;")
            }
            case SBlock(body) {
                println("{self.ind()}\{")
                self.indent = self.indent + 1
                self.emit_block_stmts(body)
                self.indent = self.indent - 1
                println("{self.ind()}\}")
            }
            case SMatch(value, cases) {
                // `match scrut { case V(binds) { … } … }` → evaluate the scrutinee once (a borrow of the owner),
                // read its tag, then an if / else-if chain on the variant tag. A case's payload fields are bound
                // POSITIONALLY via em_enum_field (a borrow — the enum owns them); a `case _` is the `else`.
                // (cgen_c.c match lowering. Scrutinee-is-an-owning-temp drop is a later increment.)
                let sv = self.fresh_var()
                let tv = self.fresh_var()
                println("{self.ind()}\{")
                self.indent = self.indent + 1
                println("{self.ind()}Value v{sv} = {self.emit_expr(value.value)};")
                println("{self.ind()}int v{tv} = em_tag(v{sv});")
                var ci = 0
                var first = true
                loop {
                    if ci >= cases.len() {
                        break
                    }
                    if cases[ci].pattern.wildcard {
                        if first {
                            println("{self.ind()}if (1) \{")
                        } else {
                            println("{self.ind()}\} else \{")
                        }
                    } else {
                        let tag = self.en.v_tag[self.en.variant_flat(cases[ci].pattern.variant)]
                        if first {
                            println("{self.ind()}if (v{tv} == {tag}) \{")
                        } else {
                            println("{self.ind()}\} else if (v{tv} == {tag}) \{")
                        }
                    }
                    self.indent = self.indent + 1
                    let mark = self.sc_name.len()
                    var bi = 0
                    loop {
                        if bi >= cases[ci].pattern.bindings.len() {
                            break
                        }
                        let bv = self.fresh_var()
                        println("{self.ind()}Value v{bv} = em_enum_field(&g_em, v{sv}, {bi});")
                        self.push(cases[ci].pattern.bindings[bi], "v{bv}", 0 - 1, false, false, false, 0 - 1)   // a borrowed payload field
                        bi = bi + 1
                    }
                    self.emit_block_raw(cases[ci].body)
                    self.emit_drops(mark)
                    self.truncate_scope(mark)
                    self.indent = self.indent - 1
                    first = false
                    ci = ci + 1
                }
                if first == false {
                    println("{self.ind()}\}")
                }
                self.indent = self.indent - 1
                println("{self.ind()}\}")
            }
            case SAssign(target, value) {
                // Assignment to a `var`. A scalar → `vN = (ctype)AS_INT(<rhs>);` (re-stored at width). An
                // OWNED binding (array/string) → evaluate the new value, DROP the old, then store (so the
                // replaced value can't leak — cgen_c.c:STMT_ASSIGN). A plain Value var → a direct store.
                match target.value {
                    case EIdent(name) {
                        let k = self.lookup_kind(name)
                        let cn = self.lookup_cname(name)
                        if self.lookup_unboxed(name) {
                            let ct = scalar_ctype(k)
                            println("{self.ind()}{cn} = ({ct})AS_INT({self.emit_expr(value.value)});")
                        } else if self.lookup_drop(name) {
                            let t = self.fresh_var()
                            println("{self.ind()}\{ Value v{t} = {self.emit_expr(value.value)};")
                            self.indent = self.indent + 1
                            println("{self.ind()}drop_value(&g_em, {cn});")
                            println("{self.ind()}{cn} = v{t};")
                            self.indent = self.indent - 1
                            println("{self.ind()}\}")
                        } else {
                            println("{self.ind()}{cn} = {self.emit_expr(value.value)};")
                        }
                    }
                    case EIndex(object, index) {
                        // Element mutation `arr[i] = v` → em_set_index (bounds-checked; drops the old element,
                        // moves the new value in). Object/index/value emitted in source order (OFI-166).
                        let o = self.emit_expr(object.value)
                        let ix = self.emit_expr(index.value)
                        let val = self.emit_expr(value.value)
                        println("{self.ind()}em_set_index(&g_em, {o}, {ix}, {val});")
                    }
                    case EGet(object, name) {
                        // Field mutation `recv.f = v` on a BOXED struct → em_set_field (drops the overwritten
                        // field, moves the new value in). A VALUE-struct field write (a C member assign) is a
                        // later increment. Receiver then value in source order (OFI-166).
                        let bsid = self.boxed_sid_of(object.value)
                        if bsid >= 0 {
                            let fidx = self.st.field_index(bsid, name)
                            let o = self.emit_expr(object.value)
                            let val = self.emit_call_arg(value.value)
                            println("{self.ind()}em_set_field(&g_em, {o}, {fidx}, {val});")
                        }
                    }
                    case _ {
                    }
                }
            }
            case SExpr(expr) {
                // A bare expression statement. M5b: a builtin call (`println(x)`) whose result is discarded
                // → `(void)(em_<name>(&g_em, <args>));`. The args are borrowed (read as-is).
                match expr.value {
                    case ECall(callee, args) {
                        match callee.value {
                            case EIdent(name) {
                                let nat = native_cfn(name)
                                if nat != "" {
                                    var s = "{self.ind()}(void)({nat}(&g_em"
                                    var i = 0
                                    loop {
                                        if i >= args.len() {
                                            break
                                        }
                                        s = s + ", " + self.emit_expr(args[i])
                                        i = i + 1
                                    }
                                    println(s + "));")
                                }
                            }
                            case EGet(object, mname) {
                                // A built-in array-method statement (`arr.append(x)`). The result is a borrow
                                // of the array (em_array_append returns it un-retained), so discarding it does
                                // not leak — `(void)(…)`, mirroring stage-0's STMT_EXPR without release_temp.
                                if self.is_array_expr(object.value) {
                                    println("{self.ind()}(void)({self.emit_call(callee.value, args)});")
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
}


// native_cfn maps a builtin name to its em_* runtime C function (M5b: the print family), or "" if not one.
fn native_cfn(name: string) -> string {
    if name == "println" {
        return "em_println"
    }
    if name == "print" {
        return "em_print"
    }
    return ""
}


// binop_cfn maps a binop id (ps.binop_id: 1 + / 2 - / 3 * / 4 / / 5 % / 6 < / 7 <= / 8 > / 9 >= / 10 == /
// 11 != / 14 & / 15 | / 16 ^ / 17 << / 18 >>) to its em_* runtime C function.
fn binop_cfn(bid: int) -> string {
    if bid == 1 { return "em_add" }
    if bid == 2 { return "em_sub" }
    if bid == 3 { return "em_mul" }
    if bid == 4 { return "em_div" }
    if bid == 5 { return "em_mod" }
    if bid == 6 { return "em_lt" }
    if bid == 7 { return "em_le" }
    if bid == 8 { return "em_gt" }
    if bid == 9 { return "em_ge" }
    if bid == 10 { return "em_eq_op" }
    if bid == 11 { return "em_neq_op" }
    if bid == 14 { return "em_bitand" }
    if bid == 15 { return "em_bitor" }
    if bid == 16 { return "em_bitxor" }
    if bid == 17 { return "em_shl" }
    if bid == 18 { return "em_shr" }
    return "em_add"
}


// binop_wants_ctx: em_add (1) / em_eq_op (10) / em_neq_op (11) take `&g_em` and retain their consumed operands.
fn binop_wants_ctx(bid: int) -> bool {
    return bid == 1 || bid == 10 || bid == 11
}


// binop_has_nk: arithmetic (1–5), ordered compares (6–9), and shifts (17–18) carry a trailing num_kind;
// equality (10–11) and bitwise (14–16) do not.
fn binop_has_nk(bid: int) -> bool {
    return (bid >= 1 && bid <= 9) || bid == 17 || bid == 18
}


// emit_fn_body prints a single function's C definition: `static Value em_fn_N(params) { … }` with the
// implicit trailing `return INT_VAL(0);` stage-0 always emits. The params are pushed into scope as the
// Value bindings a0, a1, … (a method's `self` is the leading a0). (C braces escaped `\{`/`\}`.)
fn is_string_ty(ty: ps.Ty) -> bool {
    match ty {
        case TyName(qual, name) {
            return qual == "" && name == "string"
        }
        case _ {
            return false
        }
    }
}


// native_id_for_name maps a built-in free-function name to its NATIVE_* id (the em_native dispatcher operand),
// mirroring codegen.em / src/builtin.c. Returns -1 for a non-builtin. Core (default-build) builtins only.
fn native_id_for_name(name: string) -> int {
    if name == "print" {
        return 0
    }
    if name == "println" {
        return 1
    }
    if name == "read_line" {
        return 2
    }
    if name == "read_file" {
        return 3
    }
    if name == "write_file" {
        return 4
    }
    if name == "char_code" {
        return 5
    }
    if name == "from_char_code" {
        return 6
    }
    if name == "parse_float" {
        return 7
    }
    if name == "sqrt" {
        return 8
    }
    if name == "pow" {
        return 9
    }
    if name == "abs" {
        return 10
    }
    if name == "floor" {
        return 11
    }
    if name == "ceil" {
        return 12
    }
    if name == "round" {
        return 13
    }
    if name == "random" {
        return 14
    }
    if name == "hash" {
        return 15
    }
    if name == "concat" {
        return 16
    }
    if name == "args" {
        return 17
    }
    if name == "env" {
        return 18
    }
    if name == "exit" {
        return 19
    }
    if name == "byte_slice" {
        return 22
    }
    return 0 - 1
}


// is_em_native_id reports whether a native id goes through the em_native dispatcher (the READ_LINE..EXIT band
// plus byte_slice; print/println keep their own em_print/em_println path, and 20/21 are witness-only).
fn is_em_native_id(nid: int) -> bool {
    return (nid >= 2 && nid <= 19) || nid == 22
}


// native_ret_kind classifies a native builtin's OWNED return: -3 a string, -2 an array, -1 scalar/unit
// (not droppable), -4 = not a builtin. Drives owned-binding tracking for `let x = byte_slice(…)`.
fn native_ret_kind(name: string) -> int {
    if name == "read_line" || name == "read_file" || name == "env" || name == "from_char_code" || name == "byte_slice" || name == "concat" {
        return 0 - 3
    }
    if name == "args" {
        return 0 - 2
    }
    if native_id_for_name(name) >= 0 {
        return 0 - 1
    }
    return 0 - 4
}


// numeric_typename_kind returns the em_conv target-kind for a numeric type-name used as a CONVERSION call
// (`int(x)`, `i32(x)`, `u8(x)`, `f64(x)`), or -1 if `name` is not a numeric typename (mirrors codegen.em).
fn numeric_typename_kind(name: string) -> int {
    if name == "int" || name == "i64" {
        return 0
    }
    if name == "i8" {
        return 1
    }
    if name == "i16" {
        return 2
    }
    if name == "i32" {
        return 3
    }
    if name == "u8" {
        return 4
    }
    if name == "u16" {
        return 5
    }
    if name == "u32" {
        return 6
    }
    if name == "u64" {
        return 7
    }
    if name == "f32" {
        return 8
    }
    if name == "f64" {
        return 9
    }
    return 0 - 1
}


// is_enum_ty reports whether a type annotation names a declared enum (an OWNED refcounted value — an enum
// param / local / return is dropped at scope exit and moved into a call, exactly like a string).
fn is_enum_ty(ty: ps.Ty, en: EnumTab) -> bool {
    match ty {
        case TyName(qual, name) {
            if qual != "" {
                return false
            }
            var i = 0
            loop {
                if i >= en.names.len() {
                    break
                }
                if en.names[i] == name {
                    return true
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


fn emit_fn_body(f: ps.FnDecl, idx: int, has_self: bool, owner_sid: int, st: StructTab, en: EnumTab, fn_names: [string], fn_ret_kind: [int], fn_ret_str: [bool], fn_ret_array: [bool], fn_ret_elem_kind: [int], fn_ret_struct: [int], fn_ret_enum: [bool]) {
    var g = CgcGen{ next_var: 0, sc_name: [], sc_cname: [], sc_kind: [], sc_unboxed: [], sc_drop: [], sc_array: [], sc_elem_kind: [], sc_elem_struct: [], sc_struct: [], indent: 1, st: st, en: en, fn_names: fn_names, fn_ret_kind: fn_ret_kind, fn_ret_str: fn_ret_str, fn_ret_array: fn_ret_array, fn_ret_elem_kind: fn_ret_elem_kind, fn_ret_struct: fn_ret_struct, fn_ret_enum: fn_ret_enum }
    var ai = 0
    if has_self {
        g.push("self", "a0", 0 - 1, false, false, false, 0 - 1)
        if owner_sid >= 0 {
            g.set_last_struct(owner_sid)          // `self` is the owning struct (value → a0.fN, boxed → em_enum_field)
        }
        ai = 1
    }
    var p = 0
    loop {
        if p >= f.params.len() {
            break
        }
        if f.params[p].is_self == false {
            // a param's TYPE scalar-kind (so `let x = a` infers a scalar) — but its STORAGE is the Value aN.
            // A string param is an OWNED value, dropped at every exit; a value-struct param is an em_s.
            var pk = 0 - 1
            var owned = false
            var is_arr = false
            var ek = 0 - 1
            var psid = 0 - 1
            var pesid = 0 - 1
            if f.params[p].ty.len() > 0 {
                pk = ty_scalar_kind(f.params[p].ty[0])
                owned = is_string_ty(f.params[p].ty[0]) || is_enum_ty(f.params[p].ty[0], en)   // string / enum param is OWNED
                is_arr = is_array_ty(f.params[p].ty[0])   // an array param is a BORROW (not dropped at exit)
                if is_arr {
                    ek = ty_scalar_kind(elem_ty_of(f.params[p].ty[0]))   // its element scalar kind, so `a[i]` is a scalar
                    pesid = ty_struct_sid(elem_ty_of(f.params[p].ty[0]), st.names)   // a `[Struct]` param: `a[i]` is a boxed struct
                }
                psid = ty_struct_sid(f.params[p].ty[0], st.names)   // value OR boxed struct sid this param carries
            }
            g.push(f.params[p].name, "a{ai}", pk, false, owned, is_arr, ek)
            if psid >= 0 {
                g.set_last_struct(psid)           // value param → read via aN.fM; boxed param → a borrowed Value
            }
            if pesid >= 0 {
                g.set_last_elem_struct(pesid)     // struct-array param → `a[i]` types as a boxed struct
            }
            ai = ai + 1
        }
        p = p + 1
    }
    println("static {fn_ret_ctype(f, st)} em_fn_{idx}({fn_param_list(f, has_self, st, owner_sid)}) \{")
    var i = 0
    loop {
        if i >= f.body.len() {
            break
        }
        g.emit_stmt(f.body[i])
        i = i + 1
    }
    // the implicit trailing return — preceded by the owned-binding drops on the fall-through path. A value-
    // struct-returning fn yields a zero-initialised `(em_s<sid>){0}` (the C return type must match).
    if g.scope_has_drops() {
        g.emit_drops(0)
    }
    let rsid = fn_ret_value_struct(f, st)
    if rsid >= 0 {
        println("    return (em_s{rsid})\{0\};")
    } else {
        println("    return INT_VAL(0);")
    }
    println("\}")
}


// ---- program-level emission: the scaffold mirroring src/cgen_c.c's whole-module output ----------------
// Functions are numbered em_fn_0, em_fn_1, … over body-bearing free functions + struct methods in
// DECLARATION order (the same order stage-0 numbers em_fn_N / the bytecode CALL indices). An array element
// struct (a method) can't be moved out into an intermediate list, so emit_program iterates `decls` directly
// — once per section (forward decls / em_invoke / bodies) — keeping a shared per-fn counter.

// value_arity counts a function's value parameters (a method's `self` counts as the leading slot).
fn value_arity(f: ps.FnDecl, has_self: bool) -> int {
    var n = 0
    if has_self {
        n = 1
    }
    var p = 0
    loop {
        if p >= f.params.len() {
            break
        }
        if f.params[p].is_self == false {
            n = n + 1
        }
        p = p + 1
    }
    return n
}


// invoke_args renders the `slots[0], slots[1], …` argument list for an em_invoke case of the given arity.
fn invoke_args(arity: int) -> string {
    var argl = ""
    var a = 0
    loop {
        if a >= arity {
            break
        }
        if a > 0 {
            argl = argl + ", "
        }
        argl = argl + "slots[{a}]"
        a = a + 1
    }
    return argl
}


// emit_invoke_case prints the em_invoke dispatcher case for fn `idx` (the indirect-call trampoline). Each
// value-struct PARAMETER slot is unboxed into an em_s temp (em_unbox_struct); em_fn_idx is called; a value-
// struct RESULT is boxed back to a Value (em_box_struct). A purely Value-signature fn is unchanged
// (`Value _r = em_fn_idx(slots…); return _r;`). Mirrors cgen_c.c's em_invoke.
fn emit_invoke_case(f: ps.FnDecl, idx: int, has_self: bool, stab: StructTab, owner_sid: int) {
    println("        case {idx}: \{")
    let n = value_arity(f, has_self)
    var i = 0
    loop {
        if i >= n {
            break
        }
        let psid = param_value_sid(f, has_self, stab, owner_sid, i)
        if psid >= 0 {
            println("            em_s{psid} p{i}; em_unbox_struct(ctx, {psid}, slots[{i}], (Value*)&p{i}, {stab.field_count(psid)});")
        }
        i = i + 1
    }
    var args = ""
    var j = 0
    loop {
        if j >= n {
            break
        }
        if j > 0 {
            args = args + ", "
        }
        let psid = param_value_sid(f, has_self, stab, owner_sid, j)
        if psid >= 0 {
            args = args + "p{j}"
        } else {
            args = args + "slots[{j}]"
        }
        j = j + 1
    }
    let rsid = fn_ret_value_struct(f, stab)
    if rsid >= 0 {
        println("            em_s{rsid} r = em_fn_{idx}({args});")
        println("            return em_box_struct(ctx, {rsid}, (Value*)&r, {stab.field_count(rsid)});")
    } else {
        println("            Value _r = em_fn_{idx}({args});")
        println("            return _r;")
    }
    println("        \}")
}


// fn_count returns the number of body-bearing functions (free + methods) — for trailing-blank-line logic.
fn fn_count(decls: [ps.Decl]) -> int {
    var n = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    n = n + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        n = n + 1
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return n
}


// main_index returns the em_fn_N index of the entry `main` free function (the C `main` calls it), or -1.
fn main_index(decls: [ps.Decl]) -> int {
    var idx = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    if f.name == "main" {
                        return idx
                    }
                    idx = idx + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        idx = idx + 1
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return 0                            // no `main` (a standalone module compile): stage-0's plan defaults to em_fn_0
}


// emit_struct_preamble emits the C struct block, byte-identical to stage-0: (1) a `typedef struct {…} em_sN;`
// for every VALUE-type struct (a nested value-struct field is `em_s<m> f<i>`, a scalar is `Value f<i>`);
// (2) per-struct packed-layout metadata arrays `em_sN_off/knd/fst[]` for EVERY struct (offsets are a running
// sum of size_of_aek — no alignment padding); (3) the `em_structs[]` StructType table the runtime reads for
// boxing/field-access/drop. Nothing is emitted when there are no declared structs.
fn emit_struct_preamble(tab: StructTab) {
    let n = tab.names.len()
    if n == 0 {
        return
    }
    // (1) typedefs — EVERY struct gets a `typedef struct {…} em_s<sid>;` (a value struct IS this C type; a
    // boxed struct's typedef mirrors its field count for the em_box/unbox_struct bridge). A nested value-
    // struct field is an inline `em_s<m> f<i>`; a scalar or boxed field is a `Value f<i>`. Flat structs
    // reference no other struct, so sid order is already topological for M5e.1/.2 (nesting adds ordering).
    var sid = 0
    loop {
        if sid >= n {
            break
        }
        println("typedef struct \{")
        let fc = tab.field_count(sid)
        var f = 0
        loop {
            if f >= fc {
                break
            }
            let flat = tab.flat_index(sid, f)
            if tab.f_struct[flat] >= 0 && tab.is_value(tab.f_struct[flat]) {
                println("    em_s{tab.f_struct[flat]} f{f};")
            } else {
                println("    Value f{f};")
            }
            f = f + 1
        }
        if fc == 0 {
            println("    Value _unit;")           // C forbids an empty struct
        }
        println("\} em_s{sid};")
        println("")
        sid = sid + 1
    }
    // (2) packed-layout metadata arrays (offset / kind / field_struct), for EVERY struct in sid order.
    var s2 = 0
    loop {
        if s2 >= n {
            break
        }
        let fc = tab.field_count(s2)
        var offs = ""
        var knds = ""
        var fsts = ""
        var off = 0
        var f = 0
        loop {
            if f >= fc {
                break
            }
            let flat = tab.flat_index(s2, f)
            if f > 0 {
                offs = offs + ", "
                knds = knds + ", "
                fsts = fsts + ", "
            }
            offs = offs + "{off}"
            knds = knds + "{tab.field_aek(flat)}"
            fsts = fsts + "{tab.f_struct[flat]}"
            off = off + tab.field_size(flat)
            f = f + 1
        }
        println("static int em_s{s2}_off[] = \{{offs}\};")
        println("static int em_s{s2}_knd[] = \{{knds}\};")
        println("static int em_s{s2}_fst[] = \{{fsts}\};")
        s2 = s2 + 1
    }
    // (3) the StructType table (one row per struct, sid order). drop_fn is -1 until a generated drop is wired
    // (boxed owned-field structs, a later increment); is_rc / is_resource follow the declared `kind`.
    println("static const StructType em_structs[{n}] = \{")
    var s3 = 0
    loop {
        if s3 >= n {
            break
        }
        let fc = tab.field_count(s3)
        let total = tab.total_size(s3)
        var is_rc = 0
        if tab.kinds[s3] == 1 {
            is_rc = 1
        }
        var is_res = 0
        if tab.kinds[s3] == 2 {
            is_res = 1
        }
        println("    \{ .field_count = {fc}, .total_size = {total}, .is_rc = {is_rc}, .is_resource = {is_res}, .drop_fn = -1, .offset = em_s{s3}_off, .kind = em_s{s3}_knd, .field_struct = em_s{s3}_fst \},")
        s3 = s3 + 1
    }
    println("\};")
}


// emit_program writes the whole C translation unit for the merged module declarations, byte-identical to
// stage-0 `emberc --emit=c`. It iterates `decls` once per section, keeping a shared em_fn_N counter.
fn emit_program(decls: [ps.Decl], filename: string) {
    let total = fn_count(decls)
    let fn_names = build_fn_names(decls)
    let fn_ret_kind = build_fn_ret_kinds(decls)
    let fn_ret_str = build_fn_ret_str(decls)
    let fn_ret_array = build_fn_ret_array(decls)
    let fn_ret_elem_kind = build_fn_ret_elem_kinds(decls)
    let stab = build_struct_tab(decls)
    let etab = build_enum_tab(decls)
    let fn_ret_struct = build_fn_ret_structs(decls, stab)
    let fn_ret_enum = build_fn_ret_enum(decls, etab)
    println("// Generated by `emberc --emit=c` from {filename}. Do not edit.")
    println("// The bytecode VM is the reference semantics; tests/native diffs the two.")
    println("#include \"ember_rt.h\"")
    println("")
    emit_struct_preamble(stab)                 // struct typedefs + runtime metadata (nothing if no structs)
    println("static EmberRt g_em;")
    println("")
    // forward declarations, in em_fn_N order
    var fwd = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    println("static {fn_ret_ctype(f, stab)} em_fn_{fwd}({fn_param_list(f, false, stab, 0 - 1)});")
                    fwd = fwd + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                let owner = stab.sid_of(name)
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        println("static {fn_ret_ctype(methods[mi], stab)} em_fn_{fwd}({fn_param_list(methods[mi], true, stab, owner)});")
                        fwd = fwd + 1
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    println("")
    // the em_invoke dispatcher
    println("Value em_invoke(EmberRt *ctx, int fn_index, Value *slots) \{")
    println("    (void)ctx; (void)slots;")
    println("    switch (fn_index) \{")
    var inv = 0
    var j = 0
    loop {
        if j >= decls.len() {
            break
        }
        match decls[j] {
            case DFn(f) {
                if f.has_body {
                    emit_invoke_case(f, inv, false, stab, 0 - 1)
                    inv = inv + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                let owner = stab.sid_of(name)
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        emit_invoke_case(methods[mi], inv, true, stab, owner)
                        inv = inv + 1
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        j = j + 1
    }
    println("        default: break;")
    println("    \}")
    println("    em_panic(\"em_invoke: not a callable function\");")
    println("    return INT_VAL(0);")
    println("\}")
    println("")
    // the function bodies
    var b = 0
    var k = 0
    loop {
        if k >= decls.len() {
            break
        }
        match decls[k] {
            case DFn(f) {
                if f.has_body {
                    emit_fn_body(f, b, false, 0 - 1, stab, etab, fn_names, fn_ret_kind, fn_ret_str, fn_ret_array, fn_ret_elem_kind, fn_ret_struct, fn_ret_enum)
                    b = b + 1
                    if b < total {
                        println("")
                    }
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                let owner = stab.sid_of(name)
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        emit_fn_body(methods[mi], b, true, owner, stab, etab, fn_names, fn_ret_kind, fn_ret_str, fn_ret_array, fn_ret_elem_kind, fn_ret_struct, fn_ret_enum)
                        b = b + 1
                        if b < total {
                            println("")
                        }
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        k = k + 1
    }
    println("")
    // the C main wrapper, invoking the Ember `main`
    let mi = main_index(decls)
    println("int main(int argc, char **argv) \{")
    println("    em_argc = argc - 1; em_argv = argv + 1;")
    if stab.names.len() > 0 {
        println("    g_em.structs = em_structs;")
        println("    g_em.struct_count = {stab.names.len()};")
    } else {
        println("    g_em.structs = 0;")
        println("    g_em.struct_count = 0;")
    }
    println("    g_em.invoke = em_invoke;")
    println("    Value r = em_fn_{mi}();")
    println("    if (IS_INT(r)) printf(\"=> %lld\\n\", (long long)AS_INT(r));")
    println("    else if (IS_FLOAT(r)) printf(\"=> %g\\n\", AS_FLOAT(r));")
    println("    else if (IS_STRING(r)) printf(\"=> %s\\n\", AS_CSTRING(r));")
    println("    else printf(\"=> <obj>\\n\");")
    println("    rt_free_objects(&g_em);")
    println("    return 0;")
    println("\}")
}
