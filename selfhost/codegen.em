// selfhost/codegen.em — the Ember bytecode backend (Stage 4 / M4 of the self-hosting bootstrap,
// docs/design/self-hosting.md). It consumes the self-hosted parser's AST and emits bytecode whose
// disassembly is BYTE-IDENTICAL to stage-0 `emberc --emit=bytecode` over the corpus (the M4 differential,
// the same shape as the lexer's --emit=tokens and the parser's --emit=ast).
//
// This is built in stages. The FOUNDATION here is design-free: the opcode table (include/opcode.h), the
// Chunk (a bytecode buffer + constant/string pools + per-byte line numbers), the operand codec (LEB128 +
// fixed-width big-endian, mirroring opcode.h), and the disassembler (src/chunk.c chunk_disassemble — the
// exact text the differential compares). The codegen proper (AST -> Chunk) grows on top of this.

import "parser" as ps


// ---- operand kinds (opcode.h OperandKind) ---------------------------------------------------------
let OPK_U8: int = 0
let OPK_U16: int = 1
let OPK_U24: int = 2
let OPK_OFF16: int = 3
let OPK_IDX: int = 4


// ---- named opcodes the disassembler / codegen reference directly (byte = position in op_names) -----
let OP_CONST: int = 0
let OP_STRING: int = 1
let OP_TRUE: int = 2
let OP_FALSE: int = 3
let OP_POP: int = 4
let OP_GET_LOCAL: int = 6
let OP_SET_LOCAL: int = 7
let OP_SUB: int = 9
let OP_WRAP_ADD: int = 21
let OP_WRAP_SUB: int = 22
let OP_WRAP_MUL: int = 23
let OP_NEG: int = 13
let OP_NOT: int = 14
let OP_BITNOT: int = 18
let OP_JUMP: int = 30
let OP_JUMP_IF_FALSE: int = 31
let OP_LOOP: int = 32
let OP_FOR_RANGE: int = 33
let OP_FOR_ARRAY: int = 34
let OP_CALL: int = 35
let OP_CALL_NATIVE: int = 36
let OP_CONV: int = 72
let OP_EQ: int = 24
let OP_NEW_STRUCT: int = 43
let OP_NEW_ENUM: int = 44
let OP_GET_FIELD: int = 45
let OP_GET_TAG: int = 54
let OP_GET_FIELD_OWNED: int = 46
let OP_DROP_UNDER: int = 47
let OP_PICK: int = 48
let OP_NEW_STRUCT_ARRAY: int = 49
let OP_UNBOX_STRUCT: int = 50
let OP_BOX_STRUCT: int = 52
let OP_SET_FIELD: int = 53
let OP_NEW_ARRAY: int = 55
let OP_INDEX: int = 56
let OP_SET_INDEX: int = 57
let OP_ARRAY_LEN: int = 58
let OP_ARRAY_APPEND: int = 59
let OP_STR_LEN: int = 64
let OP_STR_BYTES: int = 67
let OP_TO_STRING: int = 74
let OP_DROP: int = 84
let OP_INCREF: int = 85
let OP_RETURN_STRUCT: int = 87
let OP_RETURN: int = 88
let OP_CONCAT: int = 89


// ty_is_scalar reports whether a type is a scalar (so a struct of only scalars is multi-slot, not boxed).
fn ty_is_scalar(ty: ps.Ty) -> bool {
    match ty {
        case TyName(qual, name) {
            if qual != "" {
                return false
            }
            return name == "int" || name == "i64" || name == "i8" || name == "i16" || name == "i32" || name == "u8" || name == "u16" || name == "u32" || name == "u64" || name == "bool" || name == "float" || name == "f64" || name == "f32"
        }
        case _ {
            return false
        }
    }
}


// ty_is_array reports whether a type annotation is an array `[T]` (a move type, owned-droppable).
fn ty_is_array(ty: ps.Ty) -> bool {
    match ty {
        case TyArray(elem) {
            return true
        }
        case _ {
            return false
        }
    }
}


// ty_is_string reports whether a type is `string` (a refcounted field that must INCREF when consumed).
fn ty_is_string(ty: ps.Ty) -> bool {
    match ty {
        case TyName(qual, name) {
            return qual == "" && name == "string"
        }
        case _ {
            return false
        }
    }
}


// StructTable holds every struct's layout (id = declaration order) so codegen can decide representation
// (all-scalar = multi-slot, else boxed), order construction fields, and resolve field indices.
struct StructTable {
    names: [string]            // struct id -> name
    f_owner: [int]             // flat field table: owning struct id
    f_name: [string]           // ...field name (in declaration order)
    f_scalar: [bool]           // ...is the field a scalar type?
    f_string: [bool]           // ...is the field a string (refcounted)?
    f_array: [bool]            // ...is the field an array `[T]`?
    f_struct: [int]            // ...struct id of the field's type if it is a struct, else -1
    f_elem: [int]              // ...for an array field: its element type code (struct sid / -3 str / -4 enum / -1)
    f_arrkind: [int]           // ...for an array field: its NEW_ARRAY element kind byte (AEK_*), else -1
    f_enum: [bool]             // ...is the field a known enum (a refcounted single Value — inline-packable)?
}


fn build_structs(decls: [ps.Decl]) -> StructTable {
    // Pass 1: collect every struct name so a field whose type is a struct declared LATER still resolves, and
    // every enum name so an array field `[SomeEnum]` classifies its element as refcounted (-4).
    var names: [string] = []
    var enames: [string] = []
    var n = 0
    loop {
        if n >= decls.len() {
            break
        }
        match decls[n] {
            case DStruct(name, generics, impls, fields, methods) {
                names.append(name)
            }
            case DEnum(name, generics, impls, variants) {
                enames.append(name)
            }
            case _ {
            }
        }
        n = n + 1
    }
    enames.append("Option")
    enames.append("Result")
    // Pass 2: build the flat field table (classification needs all names known).
    var fo: [int] = []
    var fn_: [string] = []
    var fsc: [bool] = []
    var fst: [bool] = []
    var far: [bool] = []
    var fsd: [int] = []
    var fel: [int] = []
    var fak: [int] = []
    var fen: [bool] = []
    var id = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods) {
                var fi = 0
                loop {
                    if fi >= fields.len() {
                        break
                    }
                    let fty = fields[fi].ty
                    fo.append(id)
                    fn_.append(fields[fi].name)
                    fsc.append(ty_is_scalar(fty))
                    fst.append(ty_is_string(fty))
                    far.append(ty_is_array(fty))
                    fsd.append(ty_struct_id(fty, names))
                    fen.append(ty_enum_id(fty, enames) >= 0)
                    if ty_is_array(fty) {
                        fel.append(elem_type_code(elem_ty_of(fty), names, enames))
                        fak.append(array_elem_kind_from_ty(elem_ty_of(fty)))
                    } else {
                        fel.append(0 - 1)
                        fak.append(0 - 1)
                    }
                    fi = fi + 1
                }
                id = id + 1
            }
            case _ {
            }
        }
        i = i + 1
    }
    return StructTable { names: names, f_owner: fo, f_name: fn_, f_scalar: fsc, f_string: fst, f_array: far, f_struct: fsd, f_elem: fel, f_arrkind: fak, f_enum: fen }
}


// ty_struct_id returns the struct id of a `[Ty]`-less type that names a known struct (a non-scalar,
// non-string `TyName`), or -1. Used to classify a struct field whose type is itself a struct.
fn ty_struct_id(ty: ps.Ty, names: [string]) -> int {
    if ty_is_scalar(ty) || ty_is_string(ty) {
        return -1
    }
    match ty {
        case TyName(qual, name) {
            return cg_index_of(names, name)
        }
        case _ {
            return -1
        }
    }
}


// ty_struct_id_g is the generic-aware struct-id lookup for a BINDING/value type: like ty_struct_id but a
// generic struct (`Box<Ty>`) resolves to its BASE struct id (field layout is the base; the instance id only
// rides a NEW_STRUCT operand). Used to classify a `case V(x: Box<Ty>)` binding so `x.value` resolves AND its
// refcounted field read INCREFs. NOT used for struct-FIELD classification, where a generic field must stay
// "refcounted single Value" (st_fstruct = -1) so reads of it INCREF.
fn ty_struct_id_g(ty: ps.Ty, names: [string]) -> int {
    match ty {
        case TyGeneric(qual, name, args) {
            return cg_index_of(names, name)
        }
        case _ {
            return ty_struct_id(ty, names)
        }
    }
}


// ty_enum_id returns the enum id a type names (a `TyName` or generic `Option<…>`/`Result<…>` whose base is a
// known enum), else -1. The qualifier is ignored (merged module enums share one table by name).
fn ty_enum_id(ty: ps.Ty, enum_names: [string]) -> int {
    match ty {
        case TyName(qual, name) {
            return cg_index_of(enum_names, name)
        }
        case TyGeneric(qual, name, args) {
            return cg_index_of(enum_names, name)
        }
        case _ {
            return -1
        }
    }
}


// elem_type_code classifies an array's ELEMENT type `[T]` -> `T` for per-slot tracking, the single source of
// truth shared by array params, array `let`s, and `case V(arr)` bindings: a struct element -> its sid (>=0),
// a string -> -3, an enum/refcounted single-Value element -> -4, anything else (scalar) -> -1. The -4 code
// makes `arr[i]` of an enum array INCREF when read into a new owner, like a string element.
fn elem_type_code(elem_ty: ps.Ty, struct_names: [string], enum_names: [string]) -> int {
    let sid = ty_struct_id_g(elem_ty, struct_names)   // generic-aware: a `[Box<Expr>]` element resolves to base Box
    if sid >= 0 {
        return sid
    }
    if ty_is_string(elem_ty) {
        return 0 - 3
    }
    if ty_enum_id(elem_ty, enum_names) >= 0 {
        return 0 - 4
    }
    return 0 - 1
}


// EnumTable holds every enum's variants so codegen can resolve a variant name to (enum_id, tag, arity) for
// NEW_ENUM construction and match dispatch. User enums are numbered in declaration order (0..U-1, matching
// the checker), then the prelude Option (id U) and Result (id U+1) are appended — the self-hosted parser
// never sees the implicit prelude enum decls, so codegen injects them to keep enum ids byte-identical.
struct EnumTable {
    e_names: [string]          // enum id -> name
    v_owner: [int]             // flat variant table: owning enum id
    v_name: [string]           // ...variant name
    v_tag: [int]               // ...tag (index within its enum)
    v_arity: [int]             // ...payload field count
    vf_var: [int]              // flat payload-field table: owning flat-variant index
    vf_string: [bool]          // ...is the field a string (refcounted)?
    vf_struct: [int]           // ...struct id of the field's type if a struct, else -1
    vf_array: [bool]           // ...is the field an array `[T]`?
    vf_elem: [int]             // ...for an array field: its element type code (struct sid / -3 str / -4 enum / -1)
    vf_enum: [bool]            // ...is the field an enum (a refcounted single Value — INCREF on consume)?
    vf_kind: [int]             // ...for a scalar field: its numeric/render kind (int=0, f32=8, f64=9, bool=10, …)
}


// build_enums numbers user enums in declaration order then appends the prelude Option/Result, and classifies
// every variant's payload FIELD types (so a `case V(x)` binding gets the right INCREF/field-access discipline:
// a string binding INCREFs on consume, a struct binding resolves `.field`, an array binding resolves `[i]`).
// Generic payloads (`Option<T>`/`Result<T>`'s erased `T`) are left unclassified — their concrete refcounting
// needs scrutinee type inference (a known gap; see OFI-163).
fn build_enums(decls: [ps.Decl], structs: StructTable) -> EnumTable {
    // Pre-pass: collect every user enum name (plus the prelude Option/Result) so an array field `[SomeEnum]`
    // whose element enum is declared LATER still classifies as a refcounted element (-4).
    var enames: [string] = []
    var pn = 0
    loop {
        if pn >= decls.len() {
            break
        }
        match decls[pn] {
            case DEnum(name, generics, impls, variants) {
                enames.append(name)
            }
            case _ {
            }
        }
        pn = pn + 1
    }
    enames.append("Option")
    enames.append("Result")
    var en: [string] = []
    var vo: [int] = []
    var vn: [string] = []
    var vt: [int] = []
    var va: [int] = []
    var fv: [int] = []
    var fs: [bool] = []
    var fd: [int] = []
    var fa: [bool] = []
    var fe: [int] = []
    var fn2: [bool] = []
    var fk: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DEnum(name, generics, impls, variants) {
                let id = en.len()
                en.append(name)
                var vi = 0
                loop {
                    if vi >= variants.len() {
                        break
                    }
                    let vflat = vo.len()
                    vo.append(id)
                    vn.append(variants[vi].name)
                    vt.append(vi)
                    va.append(variants[vi].fields.len())
                    var fi = 0
                    loop {
                        if fi >= variants[vi].fields.len() {
                            break
                        }
                        let fty = variants[vi].fields[fi].ty
                        fv.append(vflat)
                        fs.append(ty_is_string(fty))
                        fd.append(ty_struct_id_g(fty, structs.names))   // generic-aware: a Box<T> binding resolves to base Box
                        fa.append(ty_is_array(fty))
                        fn2.append(ty_enum_id(fty, enames) >= 0)
                        fk.append(ty_scalar_kind(fty))                  // scalar render/num kind (float=9, bool=10, …)
                        if ty_is_array(fty) {
                            fe.append(elem_type_code(elem_ty_of(fty), structs.names, enames))
                        } else {
                            fe.append(0 - 1)
                        }
                        fi = fi + 1
                    }
                    vi = vi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    // Append the prelude enums the parser never sees, at the ids that continue after the user enums
    // (Option before Result; Some/Ok = tag 0, None/Err = tag 1 — confirmed against stage-0).
    let opt = en.len()
    en.append("Option")
    vo.append(opt)
    vn.append("Some")
    vt.append(0)
    va.append(1)
    vo.append(opt)
    vn.append("None")
    vt.append(1)
    va.append(0)
    let res = en.len()
    en.append("Result")
    vo.append(res)
    vn.append("Ok")
    vt.append(0)
    va.append(1)
    vo.append(res)
    vn.append("Err")
    vt.append(1)
    va.append(1)
    // The prelude payloads (Some/Ok/Err's `T`/`E`) are generic — left out of the field table (OFI-163).
    return EnumTable { e_names: en, v_owner: vo, v_name: vn, v_tag: vt, v_arity: va, vf_var: fv, vf_string: fs, vf_struct: fd, vf_array: fa, vf_elem: fe, vf_enum: fn2, vf_kind: fk }
}


// variant_index_of returns the flat variant-table index for a variant name, or -1 if `name` is not a known
// variant. (Same-named variants across enums would need scrutinee-directed resolution — OFI-073; a
// program-wide unique-name lookup is sufficient for the corpus.)
fn variant_index_of(et: EnumTable, name: string) -> int {
    var i = 0
    loop {
        if i >= et.v_name.len() {
            break
        }
        if et.v_name[i] == name {
            return i
        }
        i = i + 1
    }
    return -1
}


// numeric_typename_kind returns the CONV target-kind for a numeric type-name used as a conversion call
// (`int(x)`, `i32(x)`, `u8(x)`, `f64(x)`), or -1 if `name` is not a numeric typename. Mirrors
// is_numeric_typename + the checker's target num_kind (NB: `float`/`bool` are NOT conversion typenames).
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


// wrapping_opcode maps a built-in wrapping-arithmetic name to its dedicated opcode (OFI-041), else -1. These
// are lowered inline as `<a> <b> WRAP_* <num_kind>` (NOT a CALL) — the two-operand wrapping ops src/codegen.c
// special-cases before the generic call.
fn wrapping_opcode(name: string) -> int {
    if name == "wrapping_add" {
        return 21
    }
    if name == "wrapping_sub" {
        return 22
    }
    if name == "wrapping_mul" {
        return 23
    }
    return 0 - 1
}


// native_id_for_name maps a built-in free-function name to its NATIVE_* id (a CALL_NATIVE operand), mirroring
// src/builtin.c. Returns -1 for a non-builtin (a user/variant call). Core (default-build) builtins only;
// graphics/network natives are added when those build flavours are differenced.
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
    return -1
}


// native_ret_kind classifies a builtin's OWNED return type the way expr_ret_kind does for user calls: -3 a
// string, -2 an array, -1 a scalar/float/unit (not droppable), or -4 = `name` is not a builtin at all.
fn native_ret_kind(name: string) -> int {
    if name == "read_line" || name == "read_file" || name == "env" || name == "from_char_code" || name == "byte_slice" || name == "concat" {
        return -3
    }
    if name == "args" {
        return -2
    }
    if native_id_for_name(name) >= 0 {
        return -1
    }
    return 0 - 4
}


// GlobalConsts holds every top-level `let` as a folded literal — stage-0 inlines a module-level constant at
// each reference (`return TY_INT` -> `CONST (= 2)`), so codegen must too. Top-level lets are literal-valued
// (the checker requires it), so the value is captured as kind + int/string/bool/float.
struct GlobalConsts {
    names: [string]
    kind: [int]                // 0 int, 1 string, 2 bool, 3 float, -1 unknown
    ival: [int]
    sval: [string]
    bval: [bool]
    fval: [float]
}


fn build_globals(decls: [ps.Decl]) -> GlobalConsts {
    var names: [string] = []
    var kind: [int] = []
    var iv: [int] = []
    var sv: [string] = []
    var bv: [bool] = []
    var fv: [float] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DLet(is_var, name, ty, value) {
                names.append(name)
                match value.value {
                    case EInt(v) {
                        kind.append(0)
                        iv.append(v)
                        sv.append("")
                        bv.append(false)
                        fv.append(0.0)
                    }
                    case EStr(parts) {
                        kind.append(1)
                        iv.append(0)
                        sv.append(const_str_of(parts))
                        bv.append(false)
                        fv.append(0.0)
                    }
                    case EBool(v) {
                        kind.append(2)
                        iv.append(0)
                        sv.append("")
                        bv.append(v)
                        fv.append(0.0)
                    }
                    case EFloat(v) {
                        kind.append(3)
                        iv.append(0)
                        sv.append("")
                        bv.append(false)
                        fv.append(v)
                    }
                    case _ {
                        kind.append(0 - 1)
                        iv.append(0)
                        sv.append("")
                        bv.append(false)
                        fv.append(0.0)
                    }
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return GlobalConsts { names: names, kind: kind, ival: iv, sval: sv, bval: bv, fval: fv }
}


// const_str_of joins a constant string literal's text parts (a const string carries no interpolation holes).
fn const_str_of(parts: [ps.StrPart]) -> string {
    var s = ""
    var i = 0
    loop {
        if i >= parts.len() {
            break
        }
        s = s + parts[i].text
        i = i + 1
    }
    return s
}


// ty_key renders a type to a canonical (qualifier-agnostic) string — the identity of a generic-struct
// INSTANCE: `Box<Ty>` and `Box<Expr>` are distinct keys; `Box<int>` used twice is one key.
fn ty_key(ty: ps.Ty) -> string {
    match ty {
        case TyName(qual, name) {
            return name
        }
        case TyGeneric(qual, name, args) {
            var s = name + "<"
            var i = 0
            loop {
                if i >= args.len() {
                    break
                }
                if i > 0 {
                    s = s + ","
                }
                s = s + ty_key(args[i])
                i = i + 1
            }
            return s + ">"
        }
        case TyArray(elem) {
            return "[" + ty_key(elem.value) + "]"
        }
        case TyFn(params, ret) {
            return "fn"
        }
    }
}


// InstColl collects generic-struct INSTANTIATIONS in stage-0's monomorphization order: a PRE-ORDER walk of
// every function body in declaration order, registering each `Box<X>{…}` construction the FIRST time it is
// seen (mirrors struct_instance_id / check.c — the struct literal registers BEFORE its field values are
// visited). `snames` are the declared struct names, so a generic ENUM (`Option<int>`) is skipped.
struct InstColl {
    keys: [string]
    snames: [string]


    fn register(mut self, ty: ps.Ty) {
        match ty {
            case TyGeneric(qual, name, args) {
                if cg_index_of(self.snames, name) >= 0 {
                    let k = ty_key(ty)
                    if cg_index_of(self.keys, k) < 0 {
                        self.keys.append(k)
                    }
                }
            }
            case _ {
            }
        }
    }


    fn walk_expr(mut self, e: ps.Expr) {
        match e {
            case EStructLit(ty, fields) {
                self.register(ty.value)
                var i = 0
                loop {
                    if i >= fields.len() {
                        break
                    }
                    self.walk_expr(fields[i].value)
                    i = i + 1
                }
            }
            case ECall(callee, args) {
                self.walk_expr(callee.value)
                var i = 0
                loop {
                    if i >= args.len() {
                        break
                    }
                    self.walk_expr(args[i])
                    i = i + 1
                }
            }
            case EBinary(op, l, r) {
                self.walk_expr(l.value)
                self.walk_expr(r.value)
            }
            case EGet(object, name) {
                self.walk_expr(object.value)
            }
            case EIndex(object, index) {
                self.walk_expr(object.value)
                self.walk_expr(index.value)
            }
            case EArray(elems, lines) {
                var i = 0
                loop {
                    if i >= elems.len() {
                        break
                    }
                    self.walk_expr(elems[i])
                    i = i + 1
                }
            }
            case EStr(parts) {
                var i = 0
                loop {
                    if i >= parts.len() {
                        break
                    }
                    if parts[i].hole.len() > 0 {
                        self.walk_expr(parts[i].hole[0])
                    }
                    i = i + 1
                }
            }
            case ERange(lo, hi) {
                self.walk_expr(lo.value)
                self.walk_expr(hi.value)
            }
            case _ {
            }
        }
    }


    fn walk_body(mut self, body: [ps.Stmt]) {
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.walk_stmt(body[i])
            i = i + 1
        }
    }


    fn walk_stmt(mut self, s: ps.Stmt) {
        match s {
            case SLet(v, n, ty, value) {
                self.walk_expr(value.value)
            }
            case SReturn(value, line) {
                if value.len() > 0 {
                    self.walk_expr(value[0].value)
                }
            }
            case SExpr(expr) {
                self.walk_expr(expr.value)
            }
            case SAssign(target, value) {
                self.walk_expr(target.value)
                self.walk_expr(value.value)
            }
            case SIf(cond, then_blk, els) {
                self.walk_expr(cond.value)
                self.walk_body(then_blk)
                self.walk_body(els)
            }
            case SMatch(value, cases) {
                self.walk_expr(value.value)
                var i = 0
                loop {
                    if i >= cases.len() {
                        break
                    }
                    self.walk_body(cases[i].body)
                    i = i + 1
                }
            }
            case SLoop(body) {
                self.walk_body(body)
            }
            case SFor(vn, iv, iter, body) {
                self.walk_expr(iter.value)
                self.walk_body(body)
            }
            case SBlock(body) {
                self.walk_body(body)
            }
            case _ {
            }
        }
    }
}


// build_struct_instances returns the generic-struct INSTANCE keys in stage-0's monomorphization order — each
// instance's runtime struct id is `declared_struct_count + its index here` (appended after the declared
// structs, which include the generic base `Box<T>` itself).
fn build_struct_instances(decls: [ps.Decl], snames: [string]) -> [string] {
    var c = InstColl { keys: [], snames: snames }
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    c.walk_body(f.body)
                }
            }
            case DStruct(name, generics, impls, fields, methods) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        c.walk_body(methods[mi].body)
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return clone_strs(c.keys)
}


// string_method_op maps a built-in string method to its single opcode (`.len()` -> STR_LEN,
// `.bytes()` -> STR_BYTES), or -1 if not a built-in single-opcode string method.
fn string_method_op(mname: string) -> int {
    if mname == "len" {
        return OP_STR_LEN
    }
    if mname == "bytes" {
        return OP_STR_BYTES
    }
    return 0 - 1
}


fn is_array_lit(e: ps.Expr) -> bool {
    match e {
        case EArray(elems, lines) {
            return true
        }
        case _ {
            return false
        }
    }
}


// is_owning_temp reports whether an expression produces an OWNING TEMPORARY (a fresh owned value the caller
// must release) rather than a borrowed place — a call result or a struct construction, or a field extracted
// from one. A field READ of an owning temp uses GET_FIELD_OWNED (extract + drop the receiver box), where a
// borrowed place (a local) uses plain GET_FIELD.
fn is_owning_temp(e: ps.Expr) -> bool {
    match e {
        case ECall(callee, args) {
            return true
        }
        case EStructLit(ty, fields) {
            return true
        }
        case EIndex(object, index) {
            return true                          // `arr[i]` materialises a fresh owned element copy
        }
        case EGet(object, name) {
            return is_owning_temp(object.value)
        }
        case _ {
            return false
        }
    }
}


// is_call_expr reports whether an expression is a call. A call that returns an all-scalar struct leaves it
// MULTI-SLOT (RETURN_STRUCT spread), so a consumer needing one boxed value (a method receiver, a struct
// field value) must BOX_STRUCT the raw return slots first.
fn is_call_expr(e: ps.Expr) -> bool {
    match e {
        case ECall(callee, args) {
            return true
        }
        case _ {
            return false
        }
    }
}


// array_lit_is_empty reports whether an expression is the EMPTY array literal `[]` (which carries no element
// to infer the ArrayElemKind from, so the kind must come from the declared `[T]` type instead).
fn array_lit_is_empty(e: ps.Expr) -> bool {
    match e {
        case EArray(elems, lines) {
            return elems.len() == 0
        }
        case _ {
            return false
        }
    }
}


// elem_ty_of unwraps an array type `[T]` to its element `T`; a non-array type is returned unchanged.
fn elem_ty_of(ty: ps.Ty) -> ps.Ty {
    match ty {
        case TyArray(elem) {
            return elem.value
        }
        case _ {
            return ty
        }
    }
}


// ty_scalar_kind maps a SCALAR type name to its numeric/render kind (the checker's int_kind + bool=10):
// int/i64 -> 0, i8..u64 -> 1..7, f32 -> 8, float/f64 -> 9, bool -> 10. Non-scalar (or unknown) -> 0 (the
// default the codegen falls back to). Feeds the TO_STRING interpolation render kind (and, later, binary
// num_kind for sized/float arithmetic).
fn ty_scalar_kind(ty: ps.Ty) -> int {
    match ty {
        case TyName(qual, name) {
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
            if name == "float" || name == "f64" {
                return 9
            }
            if name == "bool" {
                return 10
            }
            return 0
        }
        case _ {
            return 0
        }
    }
}


// aek_to_render_kind maps an ArrayElemKind byte (value.h AEK_*) to the int_kind/render kind: an i64 array
// element renders as int (0), sized ints keep their kind, f32->8, f64->9, bool->10. Lets an interpolation
// hole `{arr[i]}` of a scalar array render with the element's width.
fn aek_to_render_kind(aek: int) -> int {
    if aek == 9 {
        return 8                             // AEK_F32 -> render f32
    }
    if aek == 10 {
        return 9                             // AEK_F64 -> render f64
    }
    if aek == 11 {
        return 10                            // AEK_BOOL -> render bool
    }
    if aek == 4 {
        return 0                             // AEK_I64 -> render int
    }
    if aek >= 1 && aek <= 3 {
        return aek                           // AEK_I8/I16/I32 -> render 1/2/3
    }
    if aek >= 5 && aek <= 8 {
        return aek - 1                       // AEK_U8..U64 -> render 4..7
    }
    return 0
}


// array_elem_kind_from_ty maps an element type `T` (of an array annotation `[T]`) to its runtime
// ArrayElemKind byte — the table the VM/native packed-array representation uses (see value.h AEK_*).
fn array_elem_kind_from_ty(ty: ps.Ty) -> int {
    match ty {
        case TyName(qual, name) {
            if qual != "" {
                return 0                         // a module-qualified (struct) element -> boxed
            }
            if name == "string" {
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
            if name == "int" || name == "i64" {
                return 4
            }
            if name == "u8" {
                return 5
            }
            if name == "u16" {
                return 6
            }
            if name == "u32" {
                return 7
            }
            if name == "u64" {
                return 8
            }
            if name == "f32" {
                return 9
            }
            if name == "float" || name == "f64" {
                return 10
            }
            if name == "bool" {
                return 11
            }
            return 0                             // a named (struct) element -> boxed
        }
        case _ {
            return 0                             // a nested array `[[T]]` element -> boxed
        }
    }
}


fn clone_ints(xs: [int]) -> [int] {
    var out: [int] = []
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


fn clone_floats(xs: [float]) -> [float] {
    var out: [float] = []
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


// binop_to_opcode maps a parser binop_id (1..18) to its arithmetic/comparison/bitwise opcode.
// (Logical &&/|| — ids 12/13 — short-circuit via jumps and are handled separately, not here.)
fn binop_to_opcode(id: int) -> int {
    if id == 1 { return 8 }          // +  ADD
    if id == 2 { return 9 }          // -  SUB
    if id == 3 { return 10 }         // *  MUL
    if id == 4 { return 11 }         // /  DIV
    if id == 5 { return 12 }         // %  MOD
    if id == 6 { return 26 }         // <  LT
    if id == 7 { return 27 }         // <= LE
    if id == 8 { return 28 }         // >  GT
    if id == 9 { return 29 }         // >= GE
    if id == 10 { return 24 }        // == EQ
    if id == 11 { return 25 }        // != NEQ
    if id == 14 { return 15 }        // &  BITAND
    if id == 15 { return 16 }        // |  BITOR
    if id == 16 { return 17 }        // ^  BITXOR
    if id == 17 { return 19 }        // << SHL
    if id == 18 { return 20 }        // >> SHR
    return -1
}


fn cg_index_of(xs: [string], v: string) -> int {
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


// op_names: the mnemonic of each opcode, in enum order (opcode.h EMBER_OPCODES). Index = the opcode byte.
fn op_names() -> [string] {
    return ["CONST", "STRING", "TRUE", "FALSE", "POP", "DUP", "GET_LOCAL", "SET_LOCAL", "ADD", "SUB",
        "MUL", "DIV", "MOD", "NEG", "NOT", "BITAND", "BITOR", "BITXOR", "BITNOT", "SHL", "SHR",
        "WRAP_ADD", "WRAP_SUB", "WRAP_MUL", "EQ", "NEQ", "LT", "LE", "GT", "GE", "JUMP", "JUMP_IF_FALSE",
        "LOOP", "FOR_RANGE", "FOR_ARRAY", "CALL", "CALL_NATIVE", "CALL_C", "CALL_INDIRECT", "MAKE_DYN",
        "CALL_DYN", "MAKE_CLOSURE", "CALL_CLOSURE", "NEW_STRUCT", "NEW_ENUM", "GET_FIELD",
        "GET_FIELD_OWNED", "DROP_UNDER", "PICK", "NEW_STRUCT_ARRAY", "UNBOX_STRUCT", "UNBOX_STRUCT_BORROW",
        "BOX_STRUCT", "SET_FIELD", "GET_TAG", "NEW_ARRAY", "INDEX", "SET_INDEX", "ARRAY_LEN",
        "ARRAY_APPEND", "ARRAY_POP", "ARRAY_REMOVE_AT", "SLICE", "SLICE_COPY", "STR_LEN", "STR_CHARS",
        "STR_CHAR_COUNT", "STR_BYTES", "STR_SPLIT", "STR_PARSE_INT", "INT_TO_FLOAT", "FLOAT_TO_INT",
        "CONV", "CLOCK", "TO_STRING", "NURSERY_BEGIN", "CONTRACT_CHECK", "SPAWN", "NURSERY_END",
        "CHANNEL_NEW", "SEND", "RECV", "TRY_RECV", "CLOSE", "DROP", "INCREF", "RELEASE", "RETURN_STRUCT",
        "RETURN", "CONCAT", "ROUTE_HOP"]
}


// The operand-kind spec per opcode, flat-encoded (generated from opcode.h's OPS rows): op_kstart[op] is
// the start index into op_kflat, op_kcount[op] the number of operands. Each op_kflat entry is an OPK_*.
fn op_kstart() -> [int] {
    return [0, 1, 2, 2, 2, 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 10, 10, 10, 11, 12, 13, 14, 15, 16, 16, 16,
        17, 18, 19, 20, 21, 22, 23, 26, 31, 33, 35, 37, 38, 38, 40, 42, 43, 45, 48, 49, 50, 50, 51, 53,
        54, 55, 56, 57, 57, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 62, 62, 62, 63, 63,
        64, 64, 65, 67, 67, 67, 67, 70, 73, 73, 74, 74, 74, 75, 75, 75]
}


fn op_kcount() -> [int] {
    return [1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1,
        1, 1, 3, 5, 2, 2, 2, 1, 0, 2, 2, 1, 2, 3, 1, 1, 0, 1, 2, 1, 1, 1, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 3, 0, 0, 1, 0, 1, 0, 1, 2, 0, 0, 0, 3, 3, 0, 1, 0, 0, 1, 0, 0, 0]
}


fn op_kflat() -> [int] {
    return [4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 4, 4, 3, 4, 4, 4, 4, 3,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 0, 4, 4, 4, 0,
        0, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]
}


// A Chunk is one function's compiled body: the bytecode bytes, a parallel per-byte source line, and the
// constant + string pools that CONST / STRING index. (A constant is an int or a float — parallel arrays
// keyed by const_is_float, since Ember has no heterogeneous list.)
struct Chunk {
    code: [int]                 // bytecode bytes (0..255)
    lines: [int]                // source line of the instruction starting at each byte (parallel to code)
    const_is_float: [bool]
    const_int: [int]
    const_float: [float]
    strings: [string]
    locals: [string]            // codegen scratch: slot -> binding name (the stack-slot table)
    local_str: [bool]           // ...is slot a string (CONCAT detection + INCREF on a consumed read)?
    local_drop: [bool]          // ...is slot a droppable owned value (string, or an owned boxed-struct let)?
    cur_line: int               // codegen scratch: line of the node currently being lowered
    fn_names: [string]          // codegen scratch: top-level fn names in definition order (CALL index)
    fn_ret_str: [bool]          // ...parallel: does fn #i return a string?
    fn_ret_arr: [bool]          // ...parallel: does fn #i return an array?
    fn_ret_elem: [int]          // ...parallel: for an array-returning fn #i, its element type code, else -1
    fn_ret_sid: [int]           // ...parallel: struct id fn #i returns (else -1)
    fn_ret_enum: [bool]         // ...parallel: does fn #i return an enum?
    cont_targets: [int]         // loop-context stack: each enclosing loop's continue target (its start)
    loop_bases: [int]           // ...and each loop's local count at body entry (break/continue unwind to it)
    break_jumps: [int]          // flat list of pending break-JUMP operand positions (per-loop slice)
    break_bases: [int]          // loop-context stack: each loop's start index into break_jumps
    slot_struct: [int]          // per slot: struct id if this is a struct binding's BASE slot, else -1
    slot_boxed: [bool]          // ...and is that struct binding BOXED (else multi-slot)?
    slot_array: [bool]          // ...is this slot an array binding (so `.len()`/`.append()` are array ops)?
    slot_elem: [int]            // ...for an array binding: its ELEMENT type code (struct sid, -3 string, else -1)
    slot_kind: [int]            // ...for a SCALAR binding: its numeric/render kind (int=0, sized 1..7, f32=8, f64=9, bool=10)
    cur_return_span: int        // >0 if this function returns an all-scalar struct (RETURN_STRUCT span)
    st_names: [string]          // the struct table (cloned): struct id -> name
    st_fowner: [int]            // ...flat field table: owning struct id
    st_fname: [string]          // ...field name
    st_fscalar: [bool]          // ...field scalar?
    st_fstring: [bool]          // ...field string (refcounted)?
    st_farray: [bool]           // ...field array `[T]`?
    st_fstruct: [int]           // ...field's struct id (else -1)
    st_felem: [int]             // ...for an array field: its element type code (struct sid / -3 / -4 / -1)
    st_farrkind: [int]          // ...for an array field: its NEW_ARRAY element kind byte (AEK_*), else -1
    st_fenum: [bool]            // ...is the field a known enum (a refcounted single Value)?
    inst_keys: [string]         // generic-struct INSTANCE keys (cloned): id = st_names.len() + index here
    et_names: [string]          // the enum table (cloned): enum id -> name
    ev_owner: [int]             // ...flat variant table: owning enum id
    ev_name: [string]           // ...variant name
    ev_tag: [int]               // ...variant tag
    ev_arity: [int]             // ...variant payload field count
    ev_fvar: [int]              // ...flat payload-field table: owning flat-variant index
    ev_fstring: [bool]          // ...is the payload field a string (refcounted)?
    ev_fstruct: [int]           // ...struct id of the payload field's type, else -1
    ev_farray: [bool]           // ...is the payload field an array?
    ev_felem: [int]             // ...for an array payload field: its element type code (sid / -3 / -4 / -1)
    ev_fenum: [bool]            // ...is the payload field an enum (refcounted single Value)?
    ev_fkind: [int]             // ...for a scalar payload field: its numeric/render kind (f32=8, f64=9, bool=10, …)
    gc_names: [string]          // the global-constant table (cloned): name -> folded literal
    gc_kind: [int]              // ...0 int, 1 string, 2 bool, 3 float
    gc_ival: [int]
    gc_sval: [string]
    gc_bval: [bool]
    gc_fval: [float]


    // variant_field_index returns the flat payload-field-table index of field position `b` of flat-variant
    // `vfi` (the b-th entry whose owner is `vfi`), or -1 if unclassified (a generic prelude payload, or an
    // imported variant not in this module's table). Lets a `case V(x0, x1)` binding read its field type.
    fn variant_field_index(self, vfi: int, b: int) -> int {
        var count = 0
        var i = 0
        loop {
            if i >= self.ev_fvar.len() {
                break
            }
            if self.ev_fvar[i] == vfi {
                if count == b {
                    return i
                }
                count = count + 1
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_elem_code returns the element type code of array field `fname` of struct `id` (struct sid / -3
    // string / -4 enum / -1 scalar), or -1 if not found. Lets `obj.arr[i]` resolve its element kind.
    fn field_elem_code(self, id: int, fname: string) -> int {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                return self.st_felem[i]
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_arr_kind returns the NEW_ARRAY element-kind byte (AEK_*) of array field `fname` of struct `id`,
    // or -1 if not found. Lets an EMPTY array `[]` written as a field value take the field's element kind
    // (otherwise the context-free `[]` defaults to int — wrong for `[Stmt]`/`[Expr]` boxed-element fields).
    fn field_arr_kind(self, id: int, fname: string) -> int {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                return self.st_farrkind[i]
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_is_string reports whether field `fname` of struct `id` is a string (refcounted) field.
    fn field_is_string(self, id: int, fname: string) -> bool {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                return self.st_fstring[i]
            }
            i = i + 1
        }
        return false
    }


    // field_is_refcounted reports whether field `fname` of struct `id` is a single REFCOUNTED Value (string,
    // enum, closure, type-param) — i.e. not a packed scalar, not an array, not a nested struct. Reading such a
    // field into a new owner INCREFs it (the same discipline as a string field).
    fn field_is_refcounted(self, id: int, fname: string) -> bool {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                return self.st_fscalar[i] == false && self.st_farray[i] == false && self.st_fstruct[i] < 0
            }
            i = i + 1
        }
        return false
    }


    // struct_id_of returns the struct id for `name`, or -1 if not a struct.
    fn struct_id_of(self, name: string) -> int {
        return cg_index_of(self.st_names, name)
    }


    // struct_all_scalar reports whether every field of struct `id` is a scalar (so it is multi-slot).
    fn struct_all_scalar(self, id: int) -> bool {
        var i = 0
        var seen = false
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id {
                seen = true
                if self.st_fscalar[i] == false {
                    return false
                }
            }
            i = i + 1
        }
        return seen
    }


    // struct_field_count returns the number of fields of struct `id`.
    fn struct_field_count(self, id: int) -> int {
        var n = 0
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id {
                n = n + 1
            }
            i = i + 1
        }
        return n
    }


    // struct_field_index returns the declaration-order index of field `fname` in struct `id`, or -1.
    fn struct_field_index(self, id: int, fname: string) -> int {
        var idx = 0
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id {
                if self.st_fname[i] == fname {
                    return idx
                }
                idx = idx + 1
            }
            i = i + 1
        }
        return -1
    }


    // struct_field_name_at returns the name of field `idx` (declaration order) of struct `id`.
    fn struct_field_name_at(self, id: int, idx: int) -> string {
        var seen = 0
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id {
                if seen == idx {
                    return self.st_fname[i]
                }
                seen = seen + 1
            }
            i = i + 1
        }
        return ""
    }


    fn emit(mut self, b: int) {
        self.code.append(b)
        self.lines.append(self.cur_line)
    }


    // emit_idx writes one unsigned LEB128 operand (opcode.h operand_write OPK_IDX).
    fn emit_idx(mut self, v: int) {
        var x = v
        loop {
            if x < 128 {
                break
            }
            self.emit((x & 127) | 128)
            x = x / 128
        }
        self.emit(x)
    }


    // add_const_int appends an int constant to the pool and returns its index (NO dedup — stage-0 keeps
    // one pool entry per emit_const, so e.g. `return 0` produces two value-0 entries).
    fn add_const_int(mut self, v: int) -> int {
        let idx = self.const_is_float.len()
        self.const_is_float.append(false)
        self.const_int.append(v)
        self.const_float.append(0.0)
        return idx
    }


    // add_const_float appends a float constant to the pool and returns its index (same no-dedup rule).
    fn add_const_float(mut self, v: float) -> int {
        let idx = self.const_is_float.len()
        self.const_is_float.append(true)
        self.const_int.append(0)
        self.const_float.append(v)
        return idx
    }


    fn add_string(mut self, s: string) -> int {
        let idx = self.strings.len()
        self.strings.append(s)
        return idx
    }


    // is_str_local_read reports whether `e` reads a string from a PLACE (a local, or a struct field) — the
    // borrowed-refcounted case that must INCREF when consumed (the place keeps its reference).
    fn is_str_local_read(self, e: ps.Expr) -> bool {
        let ec = self.index_elem_code(e)
        if ec == 0 - 3 || ec == 0 - 4 {
            return true                          // `arr[i]` of a [string]/[enum] array is a refcounted place read
        }
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot < 0 {
                    return false
                }
                // a string OR enum/closure local: an owned single-refcounted-Value local (droppable, not an
                // array, not a struct) read into a new owner INCREFs it
                return self.local_str[slot] || (self.local_drop[slot] && self.slot_array[slot] == false && self.slot_struct[slot] < 0)
            }
            case EGet(object, name) {
                // a REFCOUNTED field (string OR enum/closure) read off any struct-typed object (a local, OR
                // an owning temp like `arr[i]`) — reading it into a new owner INCREFs it
                let osid = self.expr_type_kind(object.value)
                if osid < 0 {
                    return false
                }
                return self.field_is_refcounted(osid, name)
            }
            case _ {
                return false
            }
        }
    }


    // move_local_slot returns the slot of an OWNED move-type local (an array or boxed struct `let`/`var`)
    // read by `e`, or -1. Consuming such a local MOVES it: the value goes to the consumer and the slot is
    // zeroed, so the function-exit DROP of that slot is a harmless no-op (it never double-frees).
    fn move_local_slot(self, e: ps.Expr) -> int {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot < 0 {
                    return -1
                }
                if self.local_str[slot] {
                    return -1                        // a string is refcounted -> INCREF, not moved
                }
                if self.local_drop[slot] && (self.slot_array[slot] || self.slot_boxed[slot]) {
                    return slot
                }
                return -1
            }
            case _ {
                return -1
            }
        }
    }


    // gen_consume lowers a value being CONSUMED (a return value, a CONCAT operand, a let/field/element
    // initialiser): a borrowed-string place-read is INCREF'd; an owned move-type local is MOVED (zero its
    // slot); an owned temporary (literal/concat/construction) needs neither.
    fn gen_consume(mut self, e: ps.Expr, line: int) {
        let inc = self.is_str_local_read(e)
        let mvslot = self.move_local_slot(e)
        let barr = self.is_borrowed_array_read(e)
        self.gen_expr(e, line)
        if inc {
            self.emit(OP_INCREF)
        } else if mvslot >= 0 {
            let zidx = self.add_const_int(0)
            self.emit(OP_CONST)                      // zero the moved slot: CONST 0; SET_LOCAL; POP
            self.emit_idx(zidx)
            self.emit(OP_SET_LOCAL)
            self.emit_idx(mvslot)
            self.emit(OP_POP)
        } else if barr {
            self.emit(OP_INCREF)                     // a BORROWED array (a borrow param) aliased into an OWNER
        }
    }


    // is_borrowed_array_read reports whether `e` reads a BORROWED array local (an array param — slot_array set,
    // not droppable). Consuming one into a new OWNER (a struct field, a return) keeps the borrow's reference,
    // so it INCREFs (an OWNED array `let` is MOVED instead — handled by move_local_slot).
    fn is_borrowed_array_read(self, e: ps.Expr) -> bool {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                return slot >= 0 && self.slot_array[slot] && self.local_drop[slot] == false
            }
            case _ {
                return false
            }
        }
    }


    // gen_global_const inlines the folded literal of top-level constant `gi` (the same value stage-0 inlines
    // at each reference): an int/float -> CONST, a string -> STRING, a bool -> TRUE/FALSE.
    fn gen_global_const(mut self, gi: int) {
        let k = self.gc_kind[gi]
        if k == 1 {
            let idx = self.add_string(self.gc_sval[gi])
            self.emit(OP_STRING)
            self.emit_idx(idx)
        } else if k == 2 {
            if self.gc_bval[gi] {
                self.emit(OP_TRUE)
            } else {
                self.emit(OP_FALSE)
            }
        } else if k == 3 {
            let idx = self.add_const_float(self.gc_fval[gi])
            self.emit(OP_CONST)
            self.emit_idx(idx)
        } else {
            let idx = self.add_const_int(self.gc_ival[gi])
            self.emit(OP_CONST)
            self.emit_idx(idx)
        }
    }


    // is_enum_ctor reports whether an expression constructs an enum value — a bare (zero-field) variant
    // referenced by name (and not shadowed by a local), or a payload variant `V(args)`.
    fn is_enum_ctor(self, e: ps.Expr) -> bool {
        match e {
            case EIdent(name) {
                return self.resolve_slot(name) < 0 && cg_index_of(self.ev_name, name) >= 0
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        return cg_index_of(self.ev_name, name) >= 0
                    }
                    case _ {
                        return false
                    }
                }
            }
            case _ {
                return false
            }
        }
    }


    // struct_value_info returns the struct id of a struct-literal value, or -1 if not a struct construction.
    fn struct_value_info(self, e: ps.Expr) -> int {
        match e {
            case EStructLit(ty, fields) {
                return self.type_struct_id(ty.value)
            }
            case _ {
                return -1
            }
        }
    }


    // expr_ret_kind classifies the OWNED type a `let`/`var` initialiser produces when it is a same-file
    // free-function call — the checker would carry this; codegen re-derives it from the fn-return tables so
    // that `let xs = make()` tracks `xs` as an owned-droppable array/struct/string (not a leaked scalar).
    // Encoded as a single int (NOT a value-struct return — that mis-compiles on the native backend from a
    // method, OFI-162): -1 = none/scalar, -2 = array, -3 = string, >= 0 = a struct id.
    // Cross-module / method-call returns aren't resolved here (idx == -1 -> -1/scalar, the safe default).
    fn expr_ret_kind(self, e: ps.Expr) -> int {
        match e {
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let nk = native_ret_kind(name)
                        if nk != 0 - 4 {
                            return nk                         // a builtin returning an owned object
                        }
                    }
                    case EGet(object, mname) {
                        if mname == "bytes" {
                            return -2                     // `s.bytes()` -> an owned byte array
                        }
                    }
                    case _ {
                    }
                }
                let idx = self.resolve_call_fn_index(callee.value)
                if idx >= 0 {
                    if self.fn_ret_arr[idx] {
                        return -2
                    }
                    if self.fn_ret_str[idx] {
                        return -3
                    }
                    return self.fn_ret_sid[idx]          // struct id, or -1 (scalar)
                }
            }
            case _ {
            }
        }
        return -1
    }


    // expr_ret_elem returns the ELEMENT type code of an array-returning call (`let xs = f()` then `xs[i]`):
    // a user fn from `fn_ret_elem`, `args()` -> [string] (-3), `s.bytes()` -> a scalar byte array (-1). -1
    // when not an array-returning call (or the element kind is unknown).
    fn expr_ret_elem(self, e: ps.Expr) -> int {
        match e {
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        if name == "args" {
                            return 0 - 3                  // args() -> [string]
                        }
                    }
                    case EGet(object, mname) {
                        if mname == "bytes" {
                            return 0 - 1                  // s.bytes() -> a scalar (u8) byte array
                        }
                    }
                    case _ {
                    }
                }
                let idx = self.resolve_call_fn_index(callee.value)
                if idx >= 0 {
                    return self.fn_ret_elem[idx]
                }
            }
            case _ {
            }
        }
        return 0 - 1
    }


    // resolve_call_fn_index returns the merged-fn-table index a call's callee names: a free function
    // (`f`), a struct method (`recv.m` where recv is a struct VALUE -> `Struct.m`), or a MODULE-QUALIFIED
    // free function (`mod.f` where `mod` is an import alias, not a value -> `f`). -1 if unresolved.
    fn resolve_call_fn_index(self, callee: ps.Expr) -> int {
        match callee {
            case EIdent(name) {
                return cg_index_of(self.fn_names, name)
            }
            case EGet(recv, mname) {
                let rsid = self.expr_type_kind(recv.value)
                if rsid >= 0 {
                    return cg_index_of(self.fn_names, self.st_names[rsid] + "." + mname)
                }
                return cg_index_of(self.fn_names, mname)   // a module-qualified free function
            }
            case _ {
                return -1
            }
        }
    }


    // call_returns_enum reports whether `e` is a call (free function, `self.method`, or a module-qualified
    // `mod.f`) that returns an enum, so a `let k = self.scan_token(...)` binding is an owned, droppable enum.
    fn call_returns_enum(self, e: ps.Expr) -> bool {
        match e {
            case ECall(callee, args) {
                let idx = self.resolve_call_fn_index(callee.value)
                return idx >= 0 && self.fn_ret_enum[idx]
            }
            case _ {
                return false
            }
        }
    }


    // field_type_kind classifies field `fname` of struct `id` as a type code (same encoding as
    // expr_type_kind: -2 array, -3 string, >= 0 struct id, -1 scalar).
    fn field_type_kind(self, id: int, fname: string) -> int {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                if self.st_farray[i] {
                    return -2
                }
                if self.st_fstring[i] {
                    return -3
                }
                return self.st_fstruct[i]        // struct id, or -1 (scalar)
            }
            i = i + 1
        }
        return -1
    }


    // expr_type_kind re-derives the static type of a method-call RECEIVER so a built-in `.len()`/`.append()`
    // on a non-identifier receiver (`acc.vals.len()`, `t.text.len()`, `make().len()`) dispatches like the
    // checker's array_op/string_op flags would. Encoding: -2 array, -3 string, >= 0 struct id, -1 scalar.
    fn expr_type_kind(self, e: ps.Expr) -> int {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot < 0 {
                    return -1
                }
                if self.local_str[slot] {
                    return -3
                }
                if self.slot_array[slot] {
                    return -2
                }
                return self.slot_struct[slot]    // struct id, or -1
            }
            case EGet(object, fname) {
                let osid = self.expr_type_kind(object.value)
                if osid >= 0 {
                    return self.field_type_kind(osid, fname)
                }
                return -1
            }
            case ECall(callee, args) {
                return self.expr_ret_kind(e)     // a call's return type (free-fn returns only)
            }
            case EIndex(object, index) {
                let ek = self.index_elem_code(e) // `arr[i]` has the array's element type
                if ek == 0 - 99 {
                    return -1
                }
                return ek
            }
            case _ {
                return -1
            }
        }
    }


    // gen_struct_fields pushes a struct literal's field values in DECLARATION order (reordering the
    // literal), each via gen_consume so a refcounted (string) field value that reads a local is INCREF'd.
    fn gen_struct_fields(mut self, sid: int, fields: [ps.SLitField], line: int) {
        let n = self.struct_field_count(sid)
        var fi = 0
        loop {
            if fi >= n {
                break
            }
            let fname = self.struct_field_name_at(sid, fi)
            var li = 0
            loop {
                if li >= fields.len() {
                    break
                }
                if fields[li].name == fname {
                    // A field holds a single value, never a multi-slot spread, so a struct field value is
                    // stored BOXED: a nested struct LITERAL is built via NEW_STRUCT (even when all-scalar),
                    // and a struct-returning CALL that lands its result MULTI-SLOT (an all-scalar return) is
                    // BOX_STRUCT'd. Any other value consumes normally (a string field INCREFs).
                    let fv = fields[li].value
                    if self.struct_value_info(fv) >= 0 {
                        self.gen_struct_construct(fv, line, true)
                    } else if array_lit_is_empty(fv) {
                        // an empty `[]` field value carries no element kind — take it from the FIELD's declared
                        // `[T]` (a boxed `[Stmt]`/`[Expr]` element is AEK 0, not the context-free int default).
                        self.cur_line = line
                        let esid = self.field_elem_code(sid, fname)
                        if esid >= 0 && self.struct_array_inline(esid) {
                            self.emit(OP_NEW_STRUCT_ARRAY)
                            self.emit_idx(0)
                            self.emit_idx(esid)
                        } else {
                            self.emit(OP_NEW_ARRAY)
                            self.emit_idx(0)
                            self.emit(self.field_arr_kind(sid, fname))
                        }
                    } else {
                        let rk = self.expr_ret_kind(fv)
                        if rk >= 0 {
                            self.gen_expr(fv, line)
                            if self.struct_all_scalar(rk) {
                                self.emit(OP_BOX_STRUCT)
                                self.emit_idx(rk)
                            }
                        } else {
                            self.gen_consume(fv, line)
                        }
                    }
                    break
                }
                li = li + 1
            }
            fi = fi + 1
        }
    }


    // gen_method_call emits `recv.method(args)`. A method takes a BOXED `self`, so a boxed receiver (self,
    // a boxed-struct local) is just pushed and CALL'd; a MULTI-SLOT receiver is first boxed (push its slots,
    // BOX_STRUCT), PICK'd (a copy for the call vs the owned temp to drop), then CALL'd and DROP_UNDER'd.
    fn gen_method_call(mut self, object: ps.Expr, mname: string, args: [ps.Expr], line: int) {
        match object {
            case EIdent(recv) {
                let slot = self.resolve_slot(recv)
                if slot < 0 {
                    // the receiver is not a value: a MODULE-QUALIFIED free-function call (`ps.parse(x)`) — the
                    // alias is inert and `mname` names a (merged) function, so emit a plain CALL by name.
                    let fi = cg_index_of(self.fn_names, mname)
                    if fi >= 0 {
                        let n = self.gen_call_args(args, line)
                        self.cur_line = line
                        self.emit(OP_CALL)
                        self.emit_idx(fi)
                        self.emit_idx(n)
                    }
                    return
                }
                if self.local_str[slot] {
                    // a built-in string method (`.len()` -> STR_LEN, `.bytes()` -> STR_BYTES) is one opcode.
                    let sop = string_method_op(mname)
                    if sop >= 0 {
                        self.cur_line = line
                        self.emit(OP_GET_LOCAL)
                        self.emit_idx(slot)
                        self.emit(sop)
                    }
                    return
                }
                if self.slot_array[slot] {
                    // built-in array methods compile to dedicated opcodes, not a CALL.
                    self.cur_line = line
                    self.emit(OP_GET_LOCAL)
                    self.emit_idx(slot)
                    if mname == "len" {
                        self.emit(OP_ARRAY_LEN)
                    } else if mname == "append" {
                        self.gen_append_value(args[0], line)
                        self.emit(OP_ARRAY_APPEND)
                    }
                    return
                }
                let sid = self.slot_struct[slot]
                if sid < 0 {
                    return
                }
                let midx = cg_index_of(self.fn_names, self.st_names[sid] + "." + mname)
                self.cur_line = line
                if self.slot_boxed[slot] {
                    self.emit(OP_GET_LOCAL)
                    self.emit_idx(slot)
                    let n = self.gen_call_args(args, line)
                    self.emit(OP_CALL)
                    self.emit_idx(midx)
                    self.emit_idx(1 + n)
                } else {
                    let span = self.struct_field_count(sid)
                    var s = 0
                    loop {
                        if s >= span {
                            break
                        }
                        self.emit(OP_GET_LOCAL)          // push each multi-slot field
                        self.emit_idx(slot + s)
                        s = s + 1
                    }
                    self.emit(OP_BOX_STRUCT)
                    self.emit_idx(sid)
                    self.emit(OP_PICK)
                    self.emit_idx(0)
                    let n = self.gen_call_args(args, line)
                    self.emit(OP_CALL)
                    self.emit_idx(midx)
                    self.emit_idx(1 + n)
                    self.emit(OP_DROP_UNDER)
                }
            }
            case _ {
                // A NON-identifier receiver (`acc.vals.len()`, `t.text.len()`, `make().method()`): evaluate
                // the receiver expression, then dispatch by its static type. Built-in string/array methods
                // compile to dedicated opcodes; a boxed-struct receiver is pushed and CALL'd as `self`.
                let tk = self.expr_type_kind(object)
                if tk == -3 {
                    let sop = string_method_op(mname)
                    if sop >= 0 {
                        self.cur_line = line
                        self.gen_expr(object, line)
                        self.emit(sop)
                    }
                } else if tk == -2 {
                    self.cur_line = line
                    self.gen_expr(object, line)
                    if mname == "len" {
                        self.emit(OP_ARRAY_LEN)
                    } else if mname == "append" {
                        self.gen_append_value(args[0], line)
                        self.emit(OP_ARRAY_APPEND)
                    }
                } else if tk >= 0 {
                    // A boxed-struct receiver that is an OWNING TEMP (a field read / call result increfs):
                    // PICK a copy for the call and DROP_UNDER the temp after — exactly the multi-slot path,
                    // minus the BOX_STRUCT (the value is already boxed).
                    let midx = cg_index_of(self.fn_names, self.st_names[tk] + "." + mname)
                    self.cur_line = line
                    self.gen_expr(object, line)
                    if is_call_expr(object) && self.struct_all_scalar(tk) {
                        self.emit(OP_BOX_STRUCT)         // a multi-slot struct returned by a call -> one box
                        self.emit_idx(tk)
                    }
                    self.emit(OP_PICK)
                    self.emit_idx(0)
                    let n = self.gen_call_args(args, line)
                    self.emit(OP_CALL)
                    self.emit_idx(midx)
                    self.emit_idx(1 + n)
                    self.emit(OP_DROP_UNDER)
                }
            }
        }
    }


    // gen_call_args pushes each argument and returns the TOTAL number of stack slots pushed — a multi-slot
    // (all-scalar) value-struct argument occupies one slot per field, so call arity counts slots not args.
    fn gen_call_args(mut self, args: [ps.Expr], line: int) -> int {
        var total = 0
        var a = 0
        loop {
            if a >= args.len() {
                break
            }
            total = total + self.gen_one_arg(args[a], line)
            a = a + 1
        }
        return total
    }


    fn gen_one_arg(mut self, e: ps.Expr, line: int) -> int {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    let sid = self.slot_struct[slot]
                    if sid >= 0 && self.slot_boxed[slot] == false {
                        let span = self.struct_field_count(sid)   // multi-slot struct: spread its field slots
                        var s = 0
                        loop {
                            if s >= span {
                                break
                            }
                            self.emit(OP_GET_LOCAL)
                            self.emit_idx(slot + s)
                            s = s + 1
                        }
                        return span
                    }
                }
            }
            case _ {
            }
        }
        if self.arg_needs_incref(e) {
            // a refcounted value passed to an owned param keeps the caller's reference -> INCREF (the callee
            // drops its copy). Covers a string/enum local AND a string PLACE read (field / `arr[i]` element).
            self.gen_expr(e, line)
            self.emit(OP_INCREF)
            return 1
        }
        self.gen_expr(e, line)
        return 1
    }


    // arg_needs_incref reports whether a call argument is a refcounted value whose owner the caller retains.
    fn arg_needs_incref(self, e: ps.Expr) -> bool {
        if self.is_str_local_read(e) {
            return true
        }
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                return slot >= 0 && self.local_drop[slot] && self.slot_array[slot] == false && self.slot_struct[slot] < 0
            }
            case _ {
                return false
            }
        }
    }


    // arg_is_owning_object reports whether a builtin call's argument is a FRESH owning-temp heap object (a
    // string literal/interpolation, a string concat, an array/struct literal, or a call returning an object).
    // A native adopts nothing, so such an arg must be kept + PICK'd + DROP_UNDER'd by the caller (the checker
    // records this as drop_mask; codegen re-derives it). A variable/scalar arg is a borrow — never masked.
    fn arg_is_owning_object(self, e: ps.Expr) -> bool {
        match e {
            case EStr(parts) {
                return true
            }
            case EArray(elems, lines) {
                return true
            }
            case EStructLit(ty, fields) {
                return true
            }
            case EBinary(op, l, r) {
                return ps.binop_id(op) == 1 && (self.expr_is_string(l.value) || self.expr_is_string(r.value))
            }
            case ECall(callee, args) {
                if self.is_enum_ctor(e) {
                    return true
                }
                return self.expr_ret_kind(e) != 0 - 1   // a user call returning string/array/struct
            }
            case _ {
                return false
            }
        }
    }


    // gen_builtin_call emits a native free-function call (CALL_NATIVE <nid> <argc>). Owning-temp object args
    // are kept below the arg region and passed as a borrow alias via PICK, then DROP_UNDER'd from under the
    // single result — the builtin analogue of the OFI-027 call drop discipline (mirrors src/codegen.c:1017).
    fn gen_builtin_call(mut self, nid: int, args: [ps.Expr], line: int) {
        // Only print/println/read_file/write_file (nids 0/1/3/4) require the caller to drop owning-temp
        // object args; every other native releases its args internally (check.c:4361), so no PICK dance.
        let does_mask = nid == 0 || nid == 1 || nid == 3 || nid == 4
        var masked: [bool] = []
        var keep = 0
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            let m = does_mask && self.arg_is_owning_object(args[i])
            masked.append(m)
            if m {
                keep = keep + 1
            }
            i = i + 1
        }
        if keep == 0 {
            var a = 0
            loop {
                if a >= args.len() {
                    break
                }
                self.gen_expr(args[a], line)
                a = a + 1
            }
            self.cur_line = line
            self.emit(OP_CALL_NATIVE)
            self.emit_idx(nid)
            self.emit_idx(args.len())
            return
        }
        var k = 0                                    // push every kept temp first (they sit below the args)
        loop {
            if k >= args.len() {
                break
            }
            if masked[k] {
                self.gen_expr(args[k], line)
            }
            k = k + 1
        }
        var built = 0
        var t_seen = 0
        var b = 0
        loop {
            if b >= args.len() {
                break
            }
            if masked[b] {
                self.emit(OP_PICK)                   // a borrow alias of the kept temp
                self.emit_idx(keep + built - 1 - t_seen)
                t_seen = t_seen + 1
            } else {
                self.gen_expr(args[b], line)
            }
            built = built + 1
            b = b + 1
        }
        self.cur_line = line
        self.emit(OP_CALL_NATIVE)
        self.emit_idx(nid)
        self.emit_idx(args.len())
        var dk = 0
        loop {
            if dk >= keep {
                break
            }
            self.emit(OP_DROP_UNDER)
            dk = dk + 1
        }
    }


    // user_arg_masked reports whether a user-function call argument is an OWNING-TEMP ARRAY (an array literal,
    // or a call returning an array) passed to a BORROW param — the caller retains the temp and must drop it
    // after the call. Strings/enums go to OWNED params (adopted, no drop); structs aren't masked here (the
    // corpus has no struct-temp user-call arg — they'd extend this when one appears).
    fn user_arg_masked(self, e: ps.Expr) -> bool {
        match e {
            case EArray(elems, lines) {
                return true
            }
            case ECall(callee, args) {
                if self.is_enum_ctor(e) {
                    return false
                }
                return self.expr_ret_kind(e) == 0 - 2   // a call returning an array
            }
            case _ {
                return false
            }
        }
    }


    // gen_user_call emits a free-function CALL, applying the owning-temp keep+drop discipline (PICK + DROP_UNDER,
    // like gen_builtin_call) to array-object args: each kept temp is pushed BELOW the args, PICK'd as a borrow
    // alias for the call, then DROP_UNDER'd from under the single result. Non-masked args go through gen_one_arg
    // (so a string/enum place-read still INCREFs and a multi-slot struct still spreads).
    fn gen_user_call(mut self, fn_idx: int, args: [ps.Expr], line: int) {
        var masked: [bool] = []
        var keep = 0
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            let m = self.user_arg_masked(args[i])
            masked.append(m)
            if m {
                keep = keep + 1
            }
            i = i + 1
        }
        if keep == 0 {
            let n = self.gen_call_args(args, line)
            self.cur_line = line
            self.emit(OP_CALL)
            self.emit_idx(fn_idx)
            self.emit_idx(n)
            return
        }
        var k = 0                                    // push every kept temp first (they sit below the args)
        loop {
            if k >= args.len() {
                break
            }
            if masked[k] {
                self.gen_expr(args[k], line)
            }
            k = k + 1
        }
        var argc = 0
        var built = 0
        var t_seen = 0
        var b = 0
        loop {
            if b >= args.len() {
                break
            }
            if masked[b] {
                self.emit(OP_PICK)                   // a borrow alias of the kept temp
                self.emit_idx(keep + built - 1 - t_seen)
                t_seen = t_seen + 1
                built = built + 1
                argc = argc + 1
            } else {
                let span = self.gen_one_arg(args[b], line)
                built = built + span
                argc = argc + span
            }
            b = b + 1
        }
        self.cur_line = line
        self.emit(OP_CALL)
        self.emit_idx(fn_idx)
        self.emit_idx(argc)
        var dk = 0
        loop {
            if dk >= keep {
                break
            }
            self.emit(OP_DROP_UNDER)
            dk = dk + 1
        }
    }


    // elem_is_boxed reports whether an array element expression is a BOXED value (AEK_BOXED=0): a string, an
    // array, a struct, or an enum (owned single-refcounted local / enum constructor / enum-returning call).
    // A scalar (int/sized/float/bool) is NOT boxed.
    fn elem_is_boxed(self, e: ps.Expr) -> bool {
        if self.expr_is_string(e) {
            return true
        }
        if self.struct_value_info(e) >= 0 {
            return true                          // a struct CONSTRUCTION (`Box<Expr>{…}`) -> a boxed element
        }
        let tk = self.expr_type_kind(e)
        if tk == 0 - 2 || tk == 0 - 3 || tk >= 0 {
            return true                          // array / string / struct
        }
        if self.is_enum_ctor(e) || self.call_returns_enum(e) {
            return true                          // a fresh enum value
        }
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                // an owned enum/closure local: droppable single refcounted Value (not str/array/struct)
                return slot >= 0 && self.local_drop[slot] && self.slot_array[slot] == false && self.slot_struct[slot] < 0 && self.local_str[slot] == false
            }
            case _ {
                return false
            }
        }
    }


    // elem_kind_of infers an array element's ArrayElemKind (value.h): a string/array/struct/enum element is
    // AEK_BOXED=0, a float is AEK_F64=10, a bool is AEK_BOOL=11, otherwise AEK_I64=4 (int / int arithmetic).
    // (Sized-int element arrays are not yet distinguished — they default into AEK_I64.)
    fn elem_kind_of(self, e: ps.Expr) -> int {
        if self.elem_is_boxed(e) {
            return 0
        }
        match e {
            case EFloat(v) {
                return 10
            }
            case EBool(v) {
                return 11
            }
            case _ {
                return 4
            }
        }
    }


    // gen_struct_construct lowers a struct literal as either multi-slot (push fields) or boxed (push fields
    // + NEW_STRUCT) — the caller chooses, since a `var`/mutated all-scalar struct is boxed though its TYPE
    // is all-scalar (so a field assignment can mutate it via SET_FIELD).
    fn gen_struct_construct(mut self, value: ps.Expr, line: int, boxed: bool) {
        match value {
            case EStructLit(ty, fields) {
                let sid = self.type_struct_id(ty.value)
                self.gen_struct_fields(sid, fields, line)
                if boxed {
                    self.emit(OP_NEW_STRUCT)
                    self.emit_idx(self.lit_struct_id(ty.value))
                    self.emit_idx(self.struct_field_count(sid))
                }
            }
            case _ {
                self.gen_expr(value, line)
            }
        }
    }


    // array_elem_type_code classifies an array's ELEMENT type `[T]` -> `T` for per-slot tracking: a struct
    // element returns its sid (>= 0), a string element -3, an enum/refcounted element -4, anything else -1.
    // Lets `let x = arr[i]` / `f(arr[i])` know x's type (boxed struct / string / enum / scalar) without a
    // separate type pass. Delegates to the shared free classifier so params + bindings agree.
    fn array_elem_type_code(self, elem_ty: ps.Ty) -> int {
        return elem_type_code(elem_ty, self.st_names, self.et_names)
    }


    // index_elem_code returns the ELEMENT type code of `arr[i]` when arr is an array local (slot_elem:
    // struct sid / -3 string / -1 scalar), or -99 if the expression is not an index of a known array.
    fn index_elem_code(self, e: ps.Expr) -> int {
        match e {
            case EIndex(object, index) {
                match object.value {
                    case EIdent(name) {
                        let slot = self.resolve_slot(name)
                        if slot >= 0 && self.slot_array[slot] {
                            return self.slot_elem[slot]
                        }
                    }
                    case EGet(inner, fname) {
                        // `obj.field[i]` — the element kind of the indexed struct FIELD array (e.g. self.toks[i]).
                        let osid = self.expr_type_kind(inner.value)
                        if osid >= 0 {
                            return self.field_elem_code(osid, fname)
                        }
                    }
                    case _ {
                    }
                }
            }
            case _ {
            }
        }
        return 0 - 99
    }


    // gen_append_value lowers an `arr.append(x)` element: a struct LITERAL is built BOXED (NEW_STRUCT) so
    // ARRAY_APPEND can pack its bytes into an inline struct array; any other value consumes normally.
    fn gen_append_value(mut self, arg: ps.Expr, line: int) {
        if self.struct_value_info(arg) >= 0 {
            self.gen_struct_construct(arg, line, true)
        } else {
            self.gen_consume(arg, line)
        }
    }


    // emit_empty_array lowers an empty array literal `[]` of element type `elem_ty`: an all-scalar struct
    // element packs INLINE (NEW_STRUCT_ARRAY <count> <sid>), every other element kind is boxed/scalar
    // (NEW_ARRAY <count> <kind>).
    // struct_array_inline reports whether an array may store struct `id` INLINE (NEW_STRUCT_ARRAY): every
    // field must be a packed scalar OR a 16-byte REFCOUNTED box (string/enum) — both shallow-copyable per
    // element. A field that is an array, a nested struct, OR a 16-byte NON-refcounted unique owner (a generic
    // type-param field like `Box<T>.value`) is NOT inline-packable (a shallow copy would alias/double-free) —
    // mirrors src/check.c:array_inline_struct_id (`sz==16 && !is_refcounted -> not inline`).
    fn struct_array_inline(self, id: int) -> bool {
        var i = 0
        var seen = false
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id {
                seen = true
                if self.st_farray[i] || self.st_fstruct[i] >= 0 {
                    return false
                }
                // a non-scalar, non-string, non-enum field is a generic type-param (`T`): 16-byte but not
                // refcounted -> a unique owner that can't be shallow-packed.
                if self.st_fscalar[i] == false && self.st_fstring[i] == false && self.st_fenum[i] == false {
                    return false
                }
            }
            i = i + 1
        }
        return seen
    }


    fn emit_empty_array(mut self, elem_ty: ps.Ty, line: int) {
        self.cur_line = line
        let esid = self.type_struct_id(elem_ty)
        if esid >= 0 && self.struct_array_inline(esid) {
            self.emit(OP_NEW_STRUCT_ARRAY)
            self.emit_idx(0)
            self.emit_idx(esid)
        } else {
            self.emit(OP_NEW_ARRAY)
            self.emit_idx(0)
            self.emit(array_elem_kind_from_ty(elem_ty))
        }
    }


    // gen_field_access emits a struct field read `obj.name`: an all-scalar (multi-slot) struct is
    // GET_LOCAL(base + index); a boxed struct is GET_LOCAL(base) then GET_FIELD(index). Returns true if
    // handled. (A `var`/mutated all-scalar struct is boxed too, but that case is deferred.)
    fn gen_field_access(mut self, object: ps.Expr, name: string) -> bool {
        match object {
            case EIdent(oname) {
                let slot = self.resolve_slot(oname)
                if slot < 0 {
                    return false
                }
                let sid = self.slot_struct[slot]
                if sid < 0 {
                    return false
                }
                if self.slot_boxed[slot] {
                    self.emit(OP_GET_LOCAL)
                    self.emit_idx(slot)
                    self.emit(OP_GET_FIELD)
                    self.emit_idx(self.struct_field_index(sid, name))
                } else {
                    self.emit(OP_GET_LOCAL)
                    self.emit_idx(slot + self.struct_field_index(sid, name))
                }
                return true
            }
            case _ {
                // A field read off a NON-identifier object (a call result, a construction): evaluate the
                // object, then extract the field. A boxed-struct owning temp uses GET_FIELD_OWNED (drops the
                // receiver box after extracting); a borrowed place uses GET_FIELD. (Multi-slot temps —
                // a flat-struct call result — are deferred to the nested-flattening work.)
                let tk = self.expr_type_kind(object)
                if tk >= 0 && self.struct_all_scalar(tk) == false {
                    let ln = self.cur_line
                    self.gen_expr(object, ln)
                    self.cur_line = ln
                    if self.is_owning_temp_obj(object) {
                        self.emit(OP_GET_FIELD_OWNED)
                    } else {
                        self.emit(OP_GET_FIELD)
                    }
                    self.emit_idx(self.struct_field_index(tk, name))
                    return true
                }
                return false
            }
        }
    }


    // is_owning_temp_obj reports whether a field-read OBJECT is a fresh owned struct TEMPORARY (so `.field`
    // uses GET_FIELD_OWNED, dropping the receiver box) vs a borrowed PLACE (plain GET_FIELD). Mirrors the
    // checker's is_owning_temp for the field-read object (src/check.c:2752): a call/construction is owning;
    // `arr[i]` is owning ONLY when the array stores INLINE structs (a boxed-element array like `[Param]`
    // yields a borrowed place — a fresh copy is NOT materialised); a nested `obj.field` is owning iff the
    // OBJECT it reads from is itself an owning temp (the deferred inline-nested case is rare).
    fn is_owning_temp_obj(self, e: ps.Expr) -> bool {
        match e {
            case ECall(callee, args) {
                return true
            }
            case EStructLit(ty, fields) {
                return true
            }
            case EIndex(object, index) {
                let ec = self.index_elem_code(e)
                return ec >= 0 && self.struct_array_inline(ec)
            }
            case EGet(object, name) {
                return self.is_owning_temp_obj(object.value)
            }
            case _ {
                return false
            }
        }
    }


    // emit_drops releases every owned refcounted local on a function-exit path (DROP <slot>, highest first).
    fn emit_drops(mut self) {
        var i = self.local_drop.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.local_drop[i] {
                self.emit(OP_DROP)
                self.emit_idx(i)
            }
            i = i - 1
        }
    }


    // expr_is_string reports whether an expression has string type (so `+` lowers to CONCAT not ADD).
    // Step 1 sees string literals/interpolation and `+`-chains of them; locals/calls come with type tracking.
    fn expr_is_string(self, e: ps.Expr) -> bool {
        match e {
            case EStr(parts) {
                return true
            }
            case EBinary(op, l, r) {
                if ps.binop_id(op) == 1 {
                    return self.expr_is_string(l.value) || self.expr_is_string(r.value)
                }
                return false
            }
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot < 0 {
                    let gi = cg_index_of(self.gc_names, name)   // a global string constant inlines to a string
                    return gi >= 0 && self.gc_kind[gi] == 1
                }
                return self.local_str[slot]
            }
            case EGet(object, name) {
                // a string field read off any struct-typed object (a local, OR an owning temp like `arr[i]`)
                let osid = self.expr_type_kind(object.value)
                if osid < 0 {
                    return false
                }
                return self.field_is_string(osid, name)
            }
            case _ {
                return false
            }
        }
    }


    // hole_is_str_temp reports whether an interpolation hole is a FRESH OWNED STRING (stage-0 `string_temp`):
    // a string-typed value that is an OWNING TEMP — a call returning a string, a string concat `a + b`, or a
    // nested interpolation. Such a hole already leaves an owned reference the fold's CONCAT consumes, so its
    // TO_STRING is SKIPPED (else the reference leaks). A borrowed string (local/field/element) is NOT a temp.
    fn hole_is_str_temp(self, e: ps.Expr) -> bool {
        match e {
            case EStr(parts) {
                return true
            }
            case ECall(callee, args) {
                return self.expr_type_kind(e) == 0 - 3   // a string-returning call (owning temp)
            }
            case EBinary(op, l, r) {
                return self.expr_is_string(e)            // a string concat -> a fresh owned string
            }
            case _ {
                return false
            }
        }
    }


    // scalar_kind_of returns the NUM_KIND of a numeric expression (the checker's int_kind: int=0, sized 1..7,
    // f32=8, f64=9 — bool is int_kind 0 here, NOT the render-kind 10). Drives a binary op's width operand. A
    // value whose kind the codegen can't infer (a field/call/index — pending st_fkind/fn-ret-kind) is 0 (int).
    fn scalar_kind_of(self, e: ps.Expr) -> int {
        match e {
            case EFloat(v) {
                return 9
            }
            case EInt(v) {
                return 0
            }
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    let k = self.slot_kind[slot]
                    if k == 10 {
                        return 0                     // bool: render-kind 10 but int_kind 0 for num_kind
                    }
                    return k
                }
                return 0
            }
            case EBinary(op, l, r) {
                return self.scalar_kind_of(l.value)  // arithmetic preserves its operand kind
            }
            case _ {
                return 0
            }
        }
    }


    // render_kind_of returns the TO_STRING render kind of an interpolation hole expression — the checker's
    // `render_kind` (int_kind + bool=10): a float literal/binding renders as f64=9, a bool as 10, an int (and
    // any value whose scalar kind the codegen can't infer) as 0. Mirrors check.c:5284.
    fn render_kind_of(self, e: ps.Expr) -> int {
        match e {
            case EFloat(v) {
                return 9
            }
            case EBool(v) {
                return 10
            }
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    return self.slot_kind[slot]
                }
                return 0
            }
            case EIndex(object, index) {
                // an element hole `{obj.farr[i]}` of a scalar FIELD array (e.g. `chunk.const_float[i]`):
                // render with the field's element kind (the array's AEK byte mapped to the render kind).
                match object.value {
                    case EGet(inner, fname) {
                        let osid = self.expr_type_kind(inner.value)
                        if osid >= 0 {
                            return aek_to_render_kind(self.field_arr_kind(osid, fname))
                        }
                    }
                    case _ {
                    }
                }
                return 0
            }
            case _ {
                return 0
            }
        }
    }


    fn resolve_slot(self, name: string) -> int {
        var i = self.locals.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.locals[i] == name {
                return i
            }
            i = i - 1
        }
        return -1
    }


    // type_struct_id returns the struct id named by a type annotation, or -1 if it is not a struct. The
    // qualifier is IGNORED (an imported `c.RGB` resolves to `RGB` — the merged module universe holds every
    // struct by name, exactly as type_enum_id resolves an imported enum).
    fn type_struct_id(self, ty: ps.Ty) -> int {
        match ty {
            case TyName(qual, name) {
                return self.struct_id_of(name)
            }
            case TyGeneric(qual, name, args) {
                return self.struct_id_of(name)   // a generic struct literal `Box<Ty>{…}` resolves to `Box`
            }
            case _ {
                return -1
            }
        }
    }


    // lit_struct_id returns the runtime struct id used as a NEW_STRUCT operand for a struct LITERAL of type
    // `ty`. A monomorphized generic instance (`Box<Expr>{…}`) gets its own id appended after the declared
    // structs (`struct_count + instance_index`, mirroring stage-0's struct_instance_id); a plain struct keeps
    // its declared id. The FIELD LAYOUT (count/order) is unchanged — only the box's type id differs.
    fn lit_struct_id(self, ty: ps.Ty) -> int {
        match ty {
            case TyGeneric(qual, name, args) {
                let base = self.struct_id_of(name)
                if base < 0 {
                    return base
                }
                let ii = cg_index_of(self.inst_keys, ty_key(ty))
                if ii < 0 {
                    return base
                }
                return self.st_names.len() + ii
            }
            case _ {
                return self.type_struct_id(ty)
            }
        }
    }


    // type_enum_id returns the enum id a type names (a user enum `Dir`, a generic `Option<…>`/`Result<…>`, or
    // an imported `ml.Lib` — the qualifier is ignored since merged module enums share one table by name),
    // else -1. An enum is a heap/move value, so an enum binding/param is owned and dropped at scope exit.
    fn type_enum_id(self, ty: ps.Ty) -> int {
        match ty {
            case TyName(qual, name) {
                return cg_index_of(self.et_names, name)
            }
            case TyGeneric(qual, name, args) {
                return cg_index_of(self.et_names, name)
            }
            case _ {
                return -1
            }
        }
    }


    // declare_binding adds a binding occupying `span` consecutive slots (a multi-slot all-scalar struct
    // uses filler slots after the base so slot == array index still holds). `droppable` marks an owned
    // refcounted value (a string, or an owned boxed-struct `let`) to DROP at function exit.
    fn declare_binding(mut self, name: string, span: int, struct_id: int, is_str: bool, droppable: bool, boxed: bool, is_array: bool) {
        self.locals.append(name)
        self.local_str.append(is_str)
        self.local_drop.append(droppable)
        self.slot_struct.append(struct_id)
        self.slot_boxed.append(boxed)
        self.slot_array.append(is_array)
        self.slot_elem.append(0 - 1)            // element type is set post-hoc for array bindings
        self.slot_kind.append(0)                // scalar kind set post-hoc; 0 (int) for non-float scalars
        var k = 1
        loop {
            if k >= span {
                break
            }
            self.locals.append("")
            self.local_str.append(false)
            self.local_drop.append(false)
            self.slot_struct.append(-1)
            self.slot_boxed.append(false)
            self.slot_array.append(false)
            self.slot_elem.append(0 - 1)
            self.slot_kind.append(0)
            k = k + 1
        }
    }


    // declare_param declares a parameter: an all-scalar struct is multi-slot; a boxed struct is one slot
    // (but still records its struct id for field access); a string is a droppable refcounted slot.
    fn declare_param(mut self, p: ps.Param) {
        if p.ty.len() == 0 {
            self.declare_binding(p.name, 1, -1, false, false, false, false)
            return
        }
        if ty_is_array(p.ty[0]) {
            self.declare_binding(p.name, 1, -1, false, false, false, true)   // array param: borrow, an array
            self.slot_elem[self.slot_elem.len() - 1] = self.array_elem_type_code(elem_ty_of(p.ty[0]))
            return
        }
        if self.type_enum_id(p.ty[0]) >= 0 {
            self.declare_binding(p.name, 1, -1, false, true, false, false)   // enum param: owned, droppable
            return
        }
        let sid = self.type_struct_id(p.ty[0])
        if sid >= 0 {
            // a plain (borrow) all-scalar struct param is multi-slot; a `mut`/`move` or refcounted-field one
            // is boxed. Either way a struct param is a BORROW — not dropped (unlike a string param).
            if p.qual == 0 && self.struct_all_scalar(sid) {
                self.declare_binding(p.name, self.struct_field_count(sid), sid, false, false, false, false)
            } else {
                self.declare_binding(p.name, 1, sid, false, false, true, false)
            }
        } else {
            let s = param_is_string(p)
            self.declare_binding(p.name, 1, -1, s, s, false, false)    // a string param IS owned/droppable
            if s == false {
                self.slot_kind[self.slot_kind.len() - 1] = ty_scalar_kind(p.ty[0])   // a float/bool param renders right
            }
        }
    }


    // return_struct_span is the slot count of an all-scalar-struct return type (so the trailing return and
    // a `return P{...}` use RETURN_STRUCT), or 0 for scalar/string/boxed returns (plain RETURN).
    fn return_struct_span(self, ret: [ps.Ty]) -> int {
        if ret.len() == 0 {
            return 0
        }
        let sid = self.type_struct_id(ret[0])
        if sid >= 0 && self.struct_all_scalar(sid) {
            return self.struct_field_count(sid)
        }
        return 0
    }


    // emit_jump writes a jump opcode + a 2-byte 0xffff placeholder, returning the operand position to patch.
    fn emit_jump(mut self, op: int) -> int {
        self.emit(op)
        self.emit(255)
        self.emit(255)
        return self.code.len() - 2
    }


    // patch_jump fills a forward jump's placeholder with the distance from just after it to here.
    fn patch_jump(mut self, pos: int) {
        let dist = self.code.len() - pos - 2
        self.code[pos] = dist / 256
        self.code[pos + 1] = dist % 256
    }


    // emit_loop writes an OP_LOOP whose operand is the backward distance to `loop_start`.
    fn emit_loop(mut self, loop_start: int) {
        self.emit(OP_LOOP)
        let dist = self.code.len() - loop_start + 2
        self.emit(dist / 256)
        self.emit(dist % 256)
    }


    // gen_block lowers a nested block: its statements, then the unwind of the block-scoped locals it
    // declared (one POP each for scalars — stage-0 cg_unwind), then truncates the slot table back.
    fn gen_block(mut self, body: [ps.Stmt]) {
        let saved = self.locals.len()
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.gen_stmt(body[i])
            i = i + 1
        }
        self.unwind_to(saved)
    }


    // unwind_to releases (DROP owned / POP borrowed) every local above `saved`, top-down, then truncates the
    // per-slot tables back to `saved` — the scope-exit discipline shared by blocks and match cases.
    fn unwind_to(mut self, saved: int) {
        self.emit_unwind(saved)
        self.truncate_to(saved)
    }


    // emit_unwind releases every local above `saved` (DROP owned + POP the slot, top-down) WITHOUT truncating
    // the tables — used by `break`/`continue`, which jump out of a still-live scope (the body's fall-through
    // unwinds the tables itself).
    fn emit_unwind(mut self, saved: int) {
        var n = self.locals.len() - 1
        loop {
            if n < saved {
                break
            }
            if self.local_drop[n] {
                self.emit(OP_DROP)               // an owned refcounted local: decref it, THEN pop the slot
                self.emit_idx(n)
            }
            self.emit(OP_POP)                    // clear the stack slot too
            n = n - 1
        }
    }


    // truncate_to drops the per-slot tables back to `saved` WITHOUT emitting any release (the caller already
    // emitted the stack cleanup) — the logical unwind stage-0 calls cg_unwind, used for the match subject.
    fn truncate_to(mut self, saved: int) {
        var kept: [string] = []
        var ksr: [bool] = []
        var kdr: [bool] = []
        var kss: [int] = []
        var ksb: [bool] = []
        var ksa: [bool] = []
        var kse: [int] = []
        var ksk: [int] = []
        var k = 0
        loop {
            if k >= saved {
                break
            }
            kept.append(self.locals[k])
            ksr.append(self.local_str[k])
            kdr.append(self.local_drop[k])
            kss.append(self.slot_struct[k])
            ksb.append(self.slot_boxed[k])
            ksa.append(self.slot_array[k])
            kse.append(self.slot_elem[k])
            ksk.append(self.slot_kind[k])
            k = k + 1
        }
        self.locals = kept
        self.local_str = ksr
        self.local_drop = kdr
        self.slot_struct = kss
        self.slot_boxed = ksb
        self.slot_array = ksa
        self.slot_elem = kse
        self.slot_kind = ksk
    }


    // pop_loop_ctx ends a loop's context: truncate break_jumps to `base`, drop the top cont/base entries.
    // patch_breaks resolves every pending break-JUMP at or above `base` to the current position (the loop
    // exit) — shared by `loop` and `for`.
    fn patch_breaks(mut self, base: int) {
        var bi = base
        loop {
            if bi >= self.break_jumps.len() {
                break
            }
            self.patch_jump(self.break_jumps[bi])
            bi = bi + 1
        }
    }


    fn pop_loop_ctx(mut self, base: int) {
        var kb: [int] = []
        var i = 0
        loop {
            if i >= base {
                break
            }
            kb.append(self.break_jumps[i])
            i = i + 1
        }
        self.break_jumps = kb
        var kc: [int] = []
        var j = 0
        loop {
            if j >= self.cont_targets.len() - 1 {
                break
            }
            kc.append(self.cont_targets[j])
            j = j + 1
        }
        self.cont_targets = kc
        var klb: [int] = []
        var p = 0
        loop {
            if p >= self.loop_bases.len() - 1 {
                break
            }
            klb.append(self.loop_bases[p])
            p = p + 1
        }
        self.loop_bases = klb
        var kbase: [int] = []
        var m = 0
        loop {
            if m >= self.break_bases.len() - 1 {
                break
            }
            kbase.append(self.break_bases[m])
            m = m + 1
        }
        self.break_bases = kbase
    }


    // gen_expr lowers an expression. `line` is its source line (from the Box that held it); cur_line is set
    // here so every byte the expression emits is attributed to it (stage-0 gen_expr sets current_line=e->line).
    fn gen_expr(mut self, e: ps.Expr, line: int) {
        self.cur_line = line
        match e {
            case EInt(v) {
                let idx = self.add_const_int(v)
                self.emit(OP_CONST)
                self.emit_idx(idx)
            }
            case EFloat(v) {
                let idx = self.add_const_float(v)
                self.emit(OP_CONST)
                self.emit_idx(idx)
            }
            case EBool(v) {
                if v {
                    self.emit(OP_TRUE)
                } else {
                    self.emit(OP_FALSE)
                }
            }
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    self.emit(OP_GET_LOCAL)
                    self.emit_idx(slot)
                } else {
                    // not a local: a bare (zero-field) enum variant -> NEW_ENUM, or a top-level constant
                    // referenced by name -> inline its folded literal value.
                    let vi = cg_index_of(self.ev_name, name)
                    if vi >= 0 {
                        self.emit(OP_NEW_ENUM)
                        self.emit_idx(self.ev_owner[vi])
                        self.emit_idx(self.ev_tag[vi])
                        self.emit_idx(0)
                    } else {
                        let gi = cg_index_of(self.gc_names, name)
                        if gi >= 0 {
                            self.gen_global_const(gi)
                        }
                    }
                }
            }
            case EStr(parts) {
                var i = 0
                loop {
                    if i >= parts.len() {
                        break
                    }
                    if parts[i].hole.len() == 1 {
                        let h = parts[i].hole[0]
                        self.gen_expr(h, line)
                        // An owning-temp STRING hole (a call/concat/interpolation result) already leaves an
                        // owned reference the fold's CONCAT consumes; the retaining TO_STRING would leak it
                        // (stage-0 `string_temp`, OFI-146). A borrowed string (local/field/element) or a
                        // non-string hole still renders/retains via TO_STRING.
                        if self.hole_is_str_temp(h) == false {
                            self.emit(OP_TO_STRING)
                            self.emit(self.render_kind_of(h))   // render kind: float=9, bool=10, else int=0
                        }
                    } else {
                        let idx = self.add_string(parts[i].text)
                        self.emit(OP_STRING)
                        self.emit_idx(idx)
                    }
                    if i > 0 {
                        self.emit(OP_CONCAT)         // left-fold the parts
                    }
                    i = i + 1
                }
            }
            case EUnary(op, operand) {
                // a prefix unary op: gen the operand, then NEG (minus) / NOT (!) / BITNOT (~). NEG and BITNOT
                // carry the operand's width kind (num_kind); NOT does not.
                self.gen_expr(operand.value, operand.line)
                let uid = ps.unop_id(op)
                if uid == 1 {
                    self.emit(OP_NEG)
                    self.emit(self.scalar_kind_of(operand.value))
                } else if uid == 2 {
                    self.emit(OP_NOT)
                } else if uid == 3 {
                    self.emit(OP_BITNOT)
                    self.emit(self.scalar_kind_of(operand.value))
                }
            }
            case EBinary(op, l, r) {
                let bid = ps.binop_id(op)
                if bid == 1 && (self.expr_is_string(l.value) || self.expr_is_string(r.value)) {
                    self.gen_consume(l.value, l.line)  // string concatenation -> the consuming OP_CONCAT
                    self.gen_consume(r.value, r.line)  // (a borrowed string-local operand is INCREF'd)
                    self.emit(OP_CONCAT)
                } else if bid == 12 {
                    // a && b: short-circuit. If a is false it stays on the stack AS the result; else pop it
                    // and the result is b.
                    self.gen_expr(l.value, l.line)
                    let jif = self.emit_jump(OP_JUMP_IF_FALSE)
                    self.emit(OP_POP)
                    self.gen_expr(r.value, r.line)
                    self.patch_jump(jif)
                } else if bid == 13 {
                    // a || b: short-circuit. If a is true it stays AS the result (jump past b); else pop it
                    // and the result is b.
                    self.gen_expr(l.value, l.line)
                    let jif = self.emit_jump(OP_JUMP_IF_FALSE)
                    let jend = self.emit_jump(OP_JUMP)
                    self.patch_jump(jif)
                    self.emit(OP_POP)
                    self.gen_expr(r.value, r.line)
                    self.patch_jump(jend)
                } else {
                    self.gen_expr(l.value, l.line)
                    self.gen_expr(r.value, r.line)   // the op emits at the right operand's line
                    let opc = binop_to_opcode(bid)
                    self.emit(opc)
                    if op_kcount()[opc] == 1 {
                        // num_kind = the operands' width (int=0, sized, f32=8, f64=9). Stage-0 uses the LEFT
                        // operand's int_kind; fall back to the right when the left is an untracked 0 (a literal
                        // typed on the other side), so `obj.f > 0.0` still gets the float kind.
                        var nk = self.scalar_kind_of(l.value)
                        if nk == 0 {
                            nk = self.scalar_kind_of(r.value)
                        }
                        self.emit(nk)
                    }
                }
            }
            case ECall(callee, args) {
                match callee.value {
                    case EGet(object, mname) {
                        self.gen_method_call(object.value, mname, args, line)
                    }
                    case EIdent(name) {
                        let ck = numeric_typename_kind(name)
                        if ck >= 0 && args.len() == 1 {
                            self.gen_expr(args[0], line)             // a numeric-width conversion: CONV <kind>
                            self.cur_line = line
                            self.emit(OP_CONV)
                            self.emit(ck)
                            return
                        }
                        let wop = wrapping_opcode(name)
                        if wop >= 0 && args.len() == 2 {
                            // built-in wrapping arithmetic `wrapping_add/sub/mul(a, b)` -> push both operands,
                            // then the WRAP_* opcode carrying the operand width kind (int=0; sized/float = M4b).
                            self.gen_expr(args[0], line)
                            self.gen_expr(args[1], line)
                            self.cur_line = line
                            self.emit(wop)
                            self.emit(0)
                            return
                        }
                        let nid = native_id_for_name(name)
                        if nid >= 0 {
                            self.gen_builtin_call(nid, args, line)   // a built-in: CALL_NATIVE, not CALL
                            return
                        }
                        let vi = cg_index_of(self.ev_name, name)
                        if vi >= 0 {
                            // a payload enum variant: push the payload args, then NEW_ENUM <eid> <tag> <arity>
                            var a = 0
                            loop {
                                if a >= args.len() {
                                    break
                                }
                                self.gen_consume(args[a], line)
                                a = a + 1
                            }
                            self.cur_line = line
                            self.emit(OP_NEW_ENUM)
                            self.emit_idx(self.ev_owner[vi])
                            self.emit_idx(self.ev_tag[vi])
                            self.emit_idx(self.ev_arity[vi])
                        } else {
                            // a free-function call: index by name, no self. An owning-temp ARRAY arg is kept +
                            // dropped around the call (PICK/DROP_UNDER); the simple no-mask case is unchanged.
                            self.gen_user_call(cg_index_of(self.fn_names, name), args, line)
                        }
                    }
                    case _ {
                    }
                }
            }
            case EStructLit(ty, fields) {
                let sid = self.type_struct_id(ty.value)
                if sid >= 0 {
                    self.gen_struct_fields(sid, fields, line)
                    if self.struct_all_scalar(sid) == false {
                        self.emit(OP_NEW_STRUCT)     // boxed: a refcounted-field struct boxes its fields
                        self.emit_idx(self.lit_struct_id(ty.value))
                        self.emit_idx(self.struct_field_count(sid))
                    }
                }
            }
            case EGet(object, name) {
                self.gen_field_access(object.value, name)
            }
            case EArray(elems, lines) {
                var ai = 0
                loop {
                    if ai >= elems.len() {
                        break
                    }
                    self.gen_consume(elems[ai], lines[ai])   // each element at its own source line (a string INCREFs)
                    ai = ai + 1
                }
                self.emit(OP_NEW_ARRAY)
                self.emit_idx(elems.len())
                var ek = 4
                if elems.len() > 0 {
                    ek = self.elem_kind_of(elems[0])
                }
                self.emit(ek)                           // the ArrayElemKind byte
            }
            case EIndex(object, index) {
                self.gen_expr(object.value, line)       // the array (a borrow)
                self.gen_expr(index.value, line)        // the index
                self.emit(OP_INDEX)
            }
            case _ {
            }
        }
    }


    fn gen_stmt(mut self, s: ps.Stmt) {
        match s {
            case SLet(is_var, name, ty, value) {
                if self.is_enum_ctor(value.value) || self.call_returns_enum(value.value) {
                    // an enum is a heap/move value -> the owned binding is dropped at every exit (a variant
                    // construction or an enum-returning call both land a fresh owned enum)
                    self.gen_expr(value.value, value.line)
                    self.declare_binding(name, 1, -1, false, true, false, false)
                    return
                }
                let eek = self.index_elem_code(value.value)
                if eek != 0 - 99 {
                    // `let t = arr[i]` — OP_INDEX materialises the element; the binding's type/drop follows the
                    // element kind (mirrors stage-0 STMT_LET): a string element INCREFs + drops; an all-scalar
                    // struct UNBOX_STRUCTs into multi-slot (no drop); a string-bearing struct is one boxed
                    // droppable slot; a scalar is a plain slot.
                    if eek == 0 - 3 {
                        self.gen_consume(value.value, value.line)   // INDEX; INCREF
                        self.declare_binding(name, 1, -1, true, true, false, false)
                    } else if eek == 0 - 4 {
                        self.gen_consume(value.value, value.line)   // INDEX; INCREF (enum element, refcounted)
                        self.declare_binding(name, 1, -1, false, true, false, false)   // owned enum: droppable, not a string
                    } else if eek >= 0 {
                        self.gen_expr(value.value, value.line)      // INDEX
                        if self.struct_all_scalar(eek) {
                            self.emit(OP_UNBOX_STRUCT)
                            self.emit_idx(eek)
                            self.declare_binding(name, self.struct_field_count(eek), eek, false, false, false, false)
                        } else {
                            self.declare_binding(name, 1, eek, false, true, true, false)
                        }
                    } else {
                        self.gen_expr(value.value, value.line)      // INDEX (scalar element)
                        self.declare_binding(name, 1, -1, false, false, false, false)
                    }
                    return
                }
                let sid = self.struct_value_info(value.value)
                if sid >= 0 {
                    if is_var == false && self.struct_all_scalar(sid) {
                        self.gen_struct_construct(value.value, value.line, false)   // multi-slot: span slots
                        self.declare_binding(name, self.struct_field_count(sid), sid, false, false, false, false)
                    } else {
                        self.gen_struct_construct(value.value, value.line, true)    // boxed: NEW_STRUCT
                        self.declare_binding(name, 1, sid, false, true, true, false)
                    }
                } else if is_array_lit(value.value) {
                    if ty.len() > 0 && array_lit_is_empty(value.value) {
                        // an empty `[]` has no element to infer the kind from; take it from the `[T]`
                        // annotation: an all-scalar struct element packs inline (NEW_STRUCT_ARRAY), else the
                        // element kind (e.g. `[string]` -> 0, not int).
                        self.emit_empty_array(elem_ty_of(ty[0]), value.line)
                    } else {
                        self.gen_expr(value.value, value.line)       // NEW_ARRAY -> one owned array slot
                    }
                    self.declare_binding(name, 1, -1, false, true, false, true)
                } else {
                    // An initialiser that is a same-file call to a function returning an owned type lands an
                    // owned-droppable value (array/struct/string) the checker would track; re-derive it here.
                    let rk = self.expr_ret_kind(value.value)
                    if rk == -2 {
                        self.gen_expr(value.value, value.line)       // CALL -> one owned array slot
                        self.declare_binding(name, 1, -1, false, true, false, true)
                        self.slot_elem[self.slot_elem.len() - 1] = self.expr_ret_elem(value.value)   // so `xs[i]` knows its element kind
                    } else if rk >= 0 && is_var == false && self.struct_all_scalar(rk) {
                        self.gen_expr(value.value, value.line)       // CALL -> RETURN_STRUCT span slots
                        self.declare_binding(name, self.struct_field_count(rk), rk, false, false, false, false)
                    } else if rk >= 0 && is_var == false {
                        self.gen_expr(value.value, value.line)       // CALL -> one owned boxed-struct slot
                        self.declare_binding(name, 1, rk, false, true, true, false)
                    } else if rk == -3 {
                        self.gen_expr(value.value, value.line)       // CALL -> one owned string slot (fresh)
                        self.declare_binding(name, 1, -1, true, true, false, false)
                    } else if self.expr_is_string(value.value) {
                        self.gen_consume(value.value, value.line)    // a string place-read INCREFs; owned/droppable
                        self.declare_binding(name, 1, -1, true, true, false, false)
                    } else if self.is_str_local_read(value.value) {
                        // a refcounted ENUM read from a place (`let op = self.advance().kind`, an enum field
                        // or an owned-enum local): aliasing an existing owner INCREFs (gen_consume), and the
                        // binding is an owned/droppable enum — but NOT a string.
                        self.gen_consume(value.value, value.line)
                        self.declare_binding(name, 1, -1, false, true, false, false)
                    } else {
                        self.gen_expr(value.value, value.line)       // a scalar initialiser stays on the stack
                        self.declare_binding(name, 1, -1, false, false, false, false)
                    }
                }
            }
            case SReturn(value, line) {
                if value.len() > 0 {
                    if self.cur_return_span > 0 {
                        self.gen_expr(value[0].value, value[0].line) // struct construction -> span slots
                        self.emit_drops()
                        self.emit(OP_RETURN_STRUCT)
                        self.emit_idx(self.cur_return_span)
                    } else {
                        self.gen_consume(value[0].value, value[0].line)  // incref a borrowed-string return
                        self.emit_drops()
                        self.emit(OP_RETURN)
                    }
                } else {
                    // a bare `return` in a void function still leaves the unit value (0) the VM RETURN pops,
                    // attributed to the `return` keyword's line
                    self.cur_line = line
                    let zidx = self.add_const_int(0)
                    self.emit(OP_CONST)
                    self.emit_idx(zidx)
                    self.emit_drops()
                    self.emit(OP_RETURN)
                }
            }
            case SExpr(expr) {
                self.gen_expr(expr.value, expr.line)
                self.emit(OP_POP)
            }
            case SAssign(target, value) {
                match target.value {
                    case EIdent(name) {
                        self.gen_consume(value.value, value.line)   // string→incref / move-local→move
                        let dslot = self.resolve_slot(name)
                        if dslot >= 0 && self.local_drop[dslot] {
                            self.emit(OP_DROP)        // release the old owned value before overwriting it
                            self.emit_idx(dslot)
                        }
                        self.emit(OP_SET_LOCAL)       // SET_LOCAL leaves the value; the statement POPs it
                        self.emit_idx(dslot)
                        self.emit(OP_POP)
                    }
                    case EGet(object, fname) {
                        // boxed struct field assignment `p.f = v`: GET_LOCAL p; <value>; SET_FIELD index.
                        match object.value {
                            case EIdent(oname) {
                                let slot = self.resolve_slot(oname)
                                if slot >= 0 {
                                    let sid = self.slot_struct[slot]
                                    if sid >= 0 && self.slot_boxed[slot] {
                                        self.cur_line = target.line
                                        self.emit(OP_GET_LOCAL)
                                        self.emit_idx(slot)
                                        self.gen_consume(value.value, value.line)   // field takes the value
                                        self.emit(OP_SET_FIELD)
                                        self.emit_idx(self.struct_field_index(sid, fname))
                                    }
                                }
                            }
                            case _ {
                            }
                        }
                    }
                    case EIndex(object, index) {
                        // array element assignment `a[i] = v`: GET_LOCAL a; <index>; <value>; SET_INDEX.
                        self.gen_expr(object.value, target.line)
                        self.gen_expr(index.value, target.line)
                        self.gen_consume(value.value, value.line)
                        self.emit(OP_SET_INDEX)
                    }
                    case _ {
                    }
                }
            }
            case SIf(cond, then_blk, els) {
                self.gen_expr(cond.value, cond.line)
                let else_jump = self.emit_jump(OP_JUMP_IF_FALSE)
                self.emit(OP_POP)                     // true path: discard the condition
                self.gen_block(then_blk)
                let end_jump = self.emit_jump(OP_JUMP)
                self.patch_jump(else_jump)
                self.emit(OP_POP)                     // false path: discard the condition
                if els.len() > 0 {
                    self.gen_stmt(els[0])
                }
                self.patch_jump(end_jump)
            }
            case SBlock(body) {
                self.gen_block(body)
            }
            case SMatch(value, cases) {
                // Evaluate the scrutinee once into an anonymous subject slot the case tests + payload bindings
                // read from. A subject that is a fresh OWNING temp (a call / construction) is dropped on the
                // fall-through and via early exits (OFI-118); a borrowed local/param subject is only POP'd.
                self.gen_expr(value.value, value.line)
                let subj_drop = self.is_owning_temp_obj(value.value)   // `arr[i]` of a boxed array is a borrow (POP), not owning
                let subject = self.locals.len()
                self.declare_binding("", 1, -1, false, subj_drop, false, false)
                var end_jumps: [int] = []
                var ci = 0
                loop {
                    if ci >= cases.len() {
                        break
                    }
                    if cases[ci].pattern.wildcard {
                        self.gen_block(cases[ci].body)           // catch-all: no tag test, body + unwind
                        if end_jumps.len() < 64 {
                            end_jumps.append(self.emit_jump(OP_JUMP))
                        }
                    } else {
                        let vi = cg_index_of(self.ev_name, cases[ci].pattern.variant)
                        // An imported enum's variant (e.g. matching `ps.Decl`) is not in this module's table
                        // yet — guard against OOB. Cross-module enum resolution (so the tag is correct) is the
                        // next milestone; for now a placeholder tag keeps codegen crash-free.
                        var vtag = 0
                        if vi >= 0 {
                            vtag = self.ev_tag[vi]
                        }
                        self.emit(OP_GET_LOCAL)
                        self.emit_idx(subject)
                        self.emit(OP_GET_TAG)
                        let tidx = self.add_const_int(vtag)
                        self.emit(OP_CONST)
                        self.emit_idx(tidx)
                        self.emit(OP_EQ)
                        let next = self.emit_jump(OP_JUMP_IF_FALSE)
                        self.emit(OP_POP)                        // matched (true path): drop the test copy
                        let bind_base = self.locals.len()
                        var b = 0
                        loop {
                            if b >= cases[ci].pattern.bindings.len() {
                                break
                            }
                            self.emit(OP_GET_LOCAL)              // each binding borrows a payload field
                            self.emit_idx(subject)
                            self.emit(OP_GET_FIELD)
                            self.emit_idx(b)
                            // A binding BORROWS the scrutinee's field (never dropped here — drop=false). Its
                            // type drives the discipline: a string binding INCREFs when consumed; a struct
                            // binding resolves `.field`; an array binding resolves `[i]`/`.len()`.
                            let fidx = self.variant_field_index(vi, b)
                            if fidx >= 0 && self.ev_fstring[fidx] {
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, -1, true, false, false, false)
                            } else if fidx >= 0 && self.ev_fstruct[fidx] >= 0 {
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, self.ev_fstruct[fidx], false, false, true, false)
                            } else if fidx >= 0 && self.ev_farray[fidx] {
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, -1, false, false, false, true)
                                self.slot_elem[self.slot_elem.len() - 1] = self.ev_felem[fidx]   // so `arr[i]` knows its element kind
                            } else if fidx >= 0 && self.ev_fenum[fidx] {
                                // an enum binding is a refcounted single Value: INCREF when consumed, but a
                                // BORROW (the scrutinee owns it) so never dropped here — is_str flags the former.
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, -1, true, false, false, false)
                            } else {
                                // a SCALAR payload binding (`case EFloat(v)`): record its numeric/render kind so
                                // an interpolation hole `{v}` renders with the right TO_STRING kind (float=9, …).
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, -1, false, false, false, false)
                                if fidx >= 0 {
                                    self.slot_kind[self.slot_kind.len() - 1] = self.ev_fkind[fidx]
                                }
                            }
                            b = b + 1
                        }
                        var si = 0
                        loop {
                            if si >= cases[ci].body.len() {
                                break
                            }
                            self.gen_stmt(cases[ci].body[si])
                            si = si + 1
                        }
                        self.unwind_to(bind_base)                // release+pop bindings & body locals
                        if end_jumps.len() < 64 {
                            end_jumps.append(self.emit_jump(OP_JUMP))
                        }
                        self.patch_jump(next)
                        self.emit(OP_POP)                        // not matched (false path): drop the test copy
                    }
                    ci = ci + 1
                }
                var ej = 0
                loop {
                    if ej >= end_jumps.len() {
                        break
                    }
                    self.patch_jump(end_jumps[ej])
                    ej = ej + 1
                }
                if subj_drop {
                    self.emit(OP_DROP)                           // release an owning-temp subject
                    self.emit_idx(subject)
                }
                self.emit(OP_POP)                               // pop the subject
                self.truncate_to(subject)                       // logical unwind (cleanup already emitted)
            }
            case SLoop(body) {
                let loop_start = self.code.len()
                self.cont_targets.append(loop_start)
                self.loop_bases.append(self.locals.len())
                self.break_bases.append(self.break_jumps.len())
                self.gen_block(body)
                self.emit_loop(loop_start)
                let base = self.break_bases[self.break_bases.len() - 1]
                var bi = base
                loop {
                    if bi >= self.break_jumps.len() {
                        break
                    }
                    self.patch_jump(self.break_jumps[bi])   // code.len() is now the loop-exit target
                    bi = bi + 1
                }
                self.pop_loop_ctx(base)
            }
            case SFor(vname, index_var, iter, body) {
                // Two fused forms (FOR_RANGE / FOR_ARRAY), each carrying its own exit offset. The loop slots
                // (index + bounds + the borrowed element) are declared before the fused op; the op pre-
                // increments the index (initialised to lo-1 / -1) so `continue` (a back-edge to the op) steps.
                let loop_base = self.locals.len()
                match iter.value {
                    case ERange(lo, hi) {
                        self.gen_expr(lo.value, lo.line)     // i = lo - 1
                        let one = self.add_const_int(1)
                        self.emit(OP_CONST)
                        self.emit_idx(one)
                        self.emit(OP_SUB)
                        self.emit(0)
                        let i_slot = self.locals.len()
                        self.declare_binding(vname, 1, -1, false, false, false, false)
                        self.gen_expr(hi.value, hi.line)     // the end bound
                        let end_slot = self.locals.len()
                        self.declare_binding("", 1, -1, false, false, false, false)
                        let start = self.code.len()
                        self.cont_targets.append(start)
                        self.loop_bases.append(self.locals.len())
                        self.break_bases.append(self.break_jumps.len())
                        self.emit(OP_FOR_RANGE)
                        self.emit_idx(i_slot)
                        self.emit_idx(end_slot)
                        self.emit(255)
                        self.emit(255)
                        let exit_jump = self.code.len() - 2
                        self.gen_block(body)
                        self.emit_loop(start)
                        self.patch_jump(exit_jump)
                        let base = self.break_bases[self.break_bases.len() - 1]
                        self.patch_breaks(base)
                        self.pop_loop_ctx(base)
                        self.emit(OP_POP)                    // hidden: end, then index
                        self.emit(OP_POP)
                        self.truncate_to(loop_base)
                    }
                    case _ {
                        self.gen_expr(iter.value, iter.line) // the array
                        let arr_slot = self.locals.len()
                        self.declare_binding("", 1, -1, false, false, false, false)
                        let neg1 = self.add_const_int(0 - 1)
                        self.emit(OP_CONST)
                        self.emit_idx(neg1)
                        let idx_slot = self.locals.len()
                        self.declare_binding(index_var, 1, -1, false, false, false, false)
                        self.emit(OP_GET_LOCAL)
                        self.emit_idx(arr_slot)
                        self.emit(OP_ARRAY_LEN)
                        let len_slot = self.locals.len()
                        self.declare_binding("", 1, -1, false, false, false, false)
                        let zero = self.add_const_int(0)
                        self.emit(OP_CONST)
                        self.emit_idx(zero)
                        let var_slot = self.locals.len()
                        self.declare_binding(vname, 1, -1, false, false, false, false)
                        let start = self.code.len()
                        self.cont_targets.append(start)
                        self.loop_bases.append(self.locals.len())
                        self.break_bases.append(self.break_jumps.len())
                        self.emit(OP_FOR_ARRAY)
                        self.emit_idx(arr_slot)
                        self.emit_idx(idx_slot)
                        self.emit_idx(len_slot)
                        self.emit_idx(var_slot)
                        self.emit(255)
                        self.emit(255)
                        let exit_jump = self.code.len() - 2
                        self.gen_block(body)
                        self.emit_loop(start)
                        self.patch_jump(exit_jump)
                        let base = self.break_bases[self.break_bases.len() - 1]
                        self.patch_breaks(base)
                        self.pop_loop_ctx(base)
                        self.emit(OP_POP)                    // hidden: var, len, index, array
                        self.emit(OP_POP)
                        self.emit(OP_POP)
                        self.emit(OP_POP)
                        self.truncate_to(loop_base)
                    }
                }
            }
            case SBreak(line) {
                self.cur_line = line
                self.emit_unwind(self.loop_bases[self.loop_bases.len() - 1])   // release body locals first
                let j = self.emit_jump(OP_JUMP)
                self.break_jumps.append(j)
            }
            case SContinue(line) {
                self.cur_line = line
                self.emit_unwind(self.loop_bases[self.loop_bases.len() - 1])   // release body locals first
                self.emit_loop(self.cont_targets[self.cont_targets.len() - 1])
            }
            case _ {
            }
        }
    }
}


// ---- the operand codec (opcode.h operand_read / operand_width) ------------------------------------
// op_width: the byte width of one operand of `kind` whose first byte is at `pos` (IDX is LEB128).
fn op_width(code: [int], pos: int, kind: int) -> int {
    if kind == OPK_U8 {
        return 1
    }
    if kind == OPK_U16 {
        return 2
    }
    if kind == OPK_OFF16 {
        return 2
    }
    if kind == OPK_U24 {
        return 3
    }
    var n = 1                                       // OPK_IDX: count LEB128 continuation bytes
    loop {
        if (code[pos + n - 1] & 128) == 0 {
            break
        }
        n = n + 1
    }
    return n
}


// op_value: decode one operand of `kind` at `pos` (fixed kinds big-endian; IDX unsigned LEB128).
fn op_value(code: [int], pos: int, kind: int) -> int {
    if kind == OPK_U8 {
        return code[pos]
    }
    if kind == OPK_U16 {
        return code[pos] * 256 + code[pos + 1]
    }
    if kind == OPK_OFF16 {
        return code[pos] * 256 + code[pos + 1]
    }
    if kind == OPK_U24 {
        return code[pos] * 65536 + code[pos + 1] * 256 + code[pos + 2]
    }
    var v = 0                                       // OPK_IDX
    var shift = 0
    var i = pos
    loop {
        let b = code[i]
        v = v | ((b & 127) << shift)
        shift = shift + 7
        i = i + 1
        if (b & 128) == 0 {
            break
        }
    }
    return v
}


// ---- text formatting helpers (reproduce the printf widths in src/chunk.c byte-for-byte) ------------
fn pad_zero4(n: int) -> string {                    // %04d: zero-pad to at least 4 digits
    var s = "{n}"
    loop {
        if s.len() >= 4 {
            break
        }
        s = "0" + s
    }
    return s
}


fn pad_left_sp(s: string, w: int) -> string {       // %4d: right-justify with spaces to width w
    var r = s
    loop {
        if r.len() >= w {
            break
        }
        r = " " + r
    }
    return r
}


fn pad_right_sp(s: string, w: int) -> string {      // %-8s: left-justify with spaces to width w
    var r = s
    loop {
        if r.len() >= w {
            break
        }
        r = r + " "
    }
    return r
}


// disassemble prints `chunk` in stage-0's exact `--emit=bytecode` format (src/chunk.c chunk_disassemble):
//   OFFSET(%04d) LINE(%4d or "|")  OPCODE(%-8s) [operands]   with CONST/STRING showing their pool value.
fn disassemble(chunk: Chunk) {
    let names = op_names()
    let kstart = op_kstart()
    let kcount = op_kcount()
    let kflat = op_kflat()
    var offset = 0
    var prev_line = 0
    var first = true
    loop {
        if offset >= chunk.code.len() {
            break
        }
        let op = chunk.code[offset]
        let line = chunk.lines[offset]
        var out = ""
        if first == false && line == prev_line {
            out = pad_zero4(offset) + "    |  " + pad_right_sp(names[op], 8)
        } else {
            out = pad_zero4(offset) + " " + pad_left_sp("{line}", 4) + "  " + pad_right_sp(names[op], 8)
        }
        prev_line = line
        first = false
        let kc = kcount[op]
        let ks = kstart[op]
        // First pass: total operand bytes (the jump base is the ip AFTER all operands).
        var total = 0
        var p = offset + 1
        var ki = 0
        loop {
            if ki >= kc {
                break
            }
            let w = op_width(chunk.code, p, kflat[ks + ki])
            total = total + w
            p = p + w
            ki = ki + 1
        }
        // Second pass: render each operand.
        var p2 = offset + 1
        var kj = 0
        loop {
            if kj >= kc {
                break
            }
            let kind = kflat[ks + kj]
            let v = op_value(chunk.code, p2, kind)
            if kind == OPK_OFF16 {
                let base = offset + 1 + total
                var target = base + v
                if op == OP_LOOP {
                    target = base - v
                }
                out = out + " {v} (-> " + pad_zero4(target) + ")"
            } else {
                out = out + " {v}"
            }
            p2 = p2 + op_width(chunk.code, p2, kind)
            kj = kj + 1
        }
        // CONST / STRING annotate the pool value they load.
        if op == OP_CONST {
            let index = op_value(chunk.code, offset + 1, OPK_IDX)
            if chunk.const_is_float[index] {
                out = out + "  (= {chunk.const_float[index]})"
            } else {
                out = out + "  (= {chunk.const_int[index]})"
            }
        } else if op == OP_STRING {
            let index = op_value(chunk.code, offset + 1, OPK_IDX)
            out = out + "  (= \"" + chunk.strings[index] + "\")"
        }
        println(out)
        offset = offset + 1 + total
    }
}


// clone_strs returns an owned copy of a string list (so a Chunk can hold the fn-name table without
// borrowing a value that would escape the function).
fn clone_strs(xs: [string]) -> [string] {
    var out: [string] = []
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


// RetInfo classifies a binding/return TYPE so codegen can track owned-droppable bindings whose init is a
// call (the checker would supply this; codegen re-derives it). Exactly one of str/arr/(sid>=0) holds, or
// none (a scalar).
struct RetInfo {
    str: bool                  // a string (refcounted)
    arr: bool                  // an array (move, owned-droppable)
    sid: int                   // a struct id (boxed, owned-droppable), else -1
    enm: bool                  // an enum (heap/move, owned-droppable)
    elem: int                  // for an ARRAY return: its element type code (struct sid / -3 / -4 / -1), else -1
}


// ret_info classifies a `[Ty]` return/annotation type.
fn ret_info(ret: [ps.Ty], structs: StructTable, enum_names: [string]) -> RetInfo {
    if ret.len() == 0 {
        return RetInfo { str: false, arr: false, sid: -1, enm: false, elem: -1 }
    }
    if ty_is_array(ret[0]) {
        return RetInfo { str: false, arr: true, sid: -1, enm: false, elem: elem_type_code(elem_ty_of(ret[0]), structs.names, enum_names) }
    }
    if ty_is_string(ret[0]) {
        return RetInfo { str: true, arr: false, sid: -1, enm: false, elem: -1 }
    }
    match ret[0] {
        case TyName(qual, name) {
            if cg_index_of(enum_names, name) >= 0 {
                return RetInfo { str: false, arr: false, sid: -1, enm: true, elem: -1 }
            }
            return RetInfo { str: false, arr: false, sid: cg_index_of(structs.names, name), enm: false, elem: -1 }
        }
        case TyGeneric(qual, name, args) {
            // a generic ENUM (`Option<…>`/`Result<…>`) is a move value; a generic STRUCT (`Box<Expr>`) returns
            // BOXED, bound by its BASE struct id (field layout is the base — the instance id only rides the
            // NEW_STRUCT operand at construction).
            if cg_index_of(enum_names, name) >= 0 {
                return RetInfo { str: false, arr: false, sid: -1, enm: true, elem: -1 }
            }
            return RetInfo { str: false, arr: false, sid: cg_index_of(structs.names, name), enm: false, elem: -1 }
        }
        case _ {
            return RetInfo { str: false, arr: false, sid: -1, enm: false, elem: -1 }
        }
    }
}


// FnRets holds every function's return classification, parallel to build_fn_names' order.
struct FnRets {
    str: [bool]
    arr: [bool]
    sid: [int]
    enm: [bool]
    elem: [int]
}


fn build_fn_rets(decls: [ps.Decl], structs: StructTable, enum_names: [string]) -> FnRets {
    var rs: [bool] = []
    var ra: [bool] = []
    var rsid: [int] = []
    var ren: [bool] = []
    var rel: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    let r = ret_info(methods[mi].ret, structs, enum_names)
                    rs.append(r.str)
                    ra.append(r.arr)
                    rsid.append(r.sid)
                    ren.append(r.enm)
                    rel.append(r.elem)
                    mi = mi + 1
                }
            }
            case DFn(f) {
                let r = ret_info(f.ret, structs, enum_names)
                rs.append(r.str)
                ra.append(r.arr)
                rsid.append(r.sid)
                ren.append(r.enm)
                rel.append(r.elem)
            }
            case _ {
            }
        }
        i = i + 1
    }
    return FnRets { str: rs, arr: ra, sid: rsid, enm: ren, elem: rel }
}


// build_fn_names collects every function's name in the order stage-0 assigns function indices (a CALL
// operand): walking decls in order, a struct's methods (named `Struct.method`) are numbered when the
// struct is reached, then free functions — interleaved exactly so the indices match.
fn build_fn_names(decls: [ps.Decl]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    out.append(name + "." + methods[mi].name)
                    mi = mi + 1
                }
            }
            case DFn(f) {
                out.append(f.name)
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// param_is_string reports whether a parameter is declared `string` (a refcounted, droppable binding).
fn param_is_string(p: ps.Param) -> bool {
    if p.ty.len() == 0 {
        return false
    }
    match p.ty[0] {
        case TyName(qual, name) {
            return qual == "" && name == "string"
        }
        case _ {
            return false
        }
    }
}


// compile_fn lowers one function body to a Chunk. Params occupy slots 0..arity-1; every function ends with
// the implicit trailing `CONST <0>; <drops>; RETURN` stage-0 appends (the drops release string locals).
fn compile_fn(f: ps.FnDecl, fn_names: [string], fn_rets: FnRets, structs: StructTable, enums: EnumTable, globals: GlobalConsts, instances: [string], self_struct_id: int) -> Chunk {
    var code: [int] = []
    var lines: [int] = []
    var cif: [bool] = []
    var ci: [int] = []
    var cf: [float] = []
    var strs: [string] = []
    var locals: [string] = []
    var lstr: [bool] = []
    var ldr: [bool] = []
    var sslot: [int] = []
    var sbox: [bool] = []
    var sarr: [bool] = []
    var selem: [int] = []
    var skind: [int] = []
    var conts: [int] = []
    var loopb: [int] = []
    var brkj: [int] = []
    var brkb: [int] = []
    var ch = Chunk { code: code, lines: lines, const_is_float: cif, const_int: ci, const_float: cf, strings: strs, locals: locals, local_str: lstr, local_drop: ldr, cur_line: 0, fn_names: clone_strs(fn_names), fn_ret_str: clone_bools(fn_rets.str), fn_ret_arr: clone_bools(fn_rets.arr), fn_ret_elem: clone_ints(fn_rets.elem), fn_ret_sid: clone_ints(fn_rets.sid), fn_ret_enum: clone_bools(fn_rets.enm), cont_targets: conts, loop_bases: loopb, break_jumps: brkj, break_bases: brkb, slot_struct: sslot, slot_boxed: sbox, slot_array: sarr, slot_elem: selem, slot_kind: skind, cur_return_span: 0, st_names: clone_strs(structs.names), st_fowner: clone_ints(structs.f_owner), st_fname: clone_strs(structs.f_name), st_fscalar: clone_bools(structs.f_scalar), st_fstring: clone_bools(structs.f_string), st_farray: clone_bools(structs.f_array), st_fstruct: clone_ints(structs.f_struct), st_felem: clone_ints(structs.f_elem), st_farrkind: clone_ints(structs.f_arrkind), st_fenum: clone_bools(structs.f_enum), inst_keys: clone_strs(instances), et_names: clone_strs(enums.e_names), ev_owner: clone_ints(enums.v_owner), ev_name: clone_strs(enums.v_name), ev_tag: clone_ints(enums.v_tag), ev_arity: clone_ints(enums.v_arity), ev_fvar: clone_ints(enums.vf_var), ev_fstring: clone_bools(enums.vf_string), ev_fstruct: clone_ints(enums.vf_struct), ev_farray: clone_bools(enums.vf_array), ev_felem: clone_ints(enums.vf_elem), ev_fenum: clone_bools(enums.vf_enum), ev_fkind: clone_ints(enums.vf_kind), gc_names: clone_strs(globals.names), gc_kind: clone_ints(globals.kind), gc_ival: clone_ints(globals.ival), gc_sval: clone_strs(globals.sval), gc_bval: clone_bools(globals.bval), gc_fval: clone_floats(globals.fval) }
    ch.cur_return_span = ch.return_struct_span(f.ret)
    if self_struct_id >= 0 {
        // a method receiver: `self` is a BOXED struct in slot 0 (so self.field is GET_FIELD even for an
        // all-scalar struct), and a BORROW — not dropped at exit.
        ch.declare_binding("self", 1, self_struct_id, false, false, true, false)
    }
    var p = 0
    loop {
        if p >= f.params.len() {
            break
        }
        if f.params[p].is_self == false {
            ch.declare_param(f.params[p])
        }
        p = p + 1
    }
    var i = 0
    loop {
        if i >= f.body.len() {
            break
        }
        ch.gen_stmt(f.body[i])
        i = i + 1
    }
    // Trailing implicit return: an all-scalar-struct-returning function pushes N zeros + RETURN_STRUCT N;
    // otherwise CONST <0> + drop string locals + RETURN.
    let rspan = ch.return_struct_span(f.ret)
    if rspan > 0 {
        var z = 0
        loop {
            if z >= rspan {
                break
            }
            let zidx = ch.add_const_int(0)
            ch.emit(OP_CONST)
            ch.emit_idx(zidx)
            z = z + 1
        }
        ch.emit(OP_RETURN_STRUCT)
        ch.emit_idx(rspan)
    } else {
        let idx = ch.add_const_int(0)
        ch.emit(OP_CONST)
        ch.emit_idx(idx)
        ch.emit_drops()
        ch.emit(OP_RETURN)
    }
    return ch
}
