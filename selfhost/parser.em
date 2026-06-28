// selfhost/parser.em — the Ember parser, written in Ember (Stage 2 / M2 of the self-hosting bootstrap,
// docs/design/self-hosting.md). It consumes the self-hosted lexer's `[Token]` and builds an AST whose
// `--emit=ast`-format dump (src/ast_print.c) is diffed byte-for-byte against `emberc --emit=ast` over the
// corpus (tests/run-selfhost.sh). The dump driver is selfhost/parse_dump.em.
//
// Imports the lexer as a library and MATCHES its Tk variants (never constructs them, so OFI-156 does not
// apply); binary/unary operators are stored as the lexer's Tk and printed via lx.kind_name, reusing the
// single source of operator names. Everything is one module so the AST node variants are constructed and
// matched only here.
//
// The AST mirrors include/ast.h but carries only the SYNTACTIC fields a parser sets; ast_print is lossy
// (it omits positions, contracts, lambda bodies, named-arg names, rc/resource flags, refinement
// predicates) — we parse those to consume tokens correctly but the printer drops them to match stage 0.
// Recursion uses Box<T> for a required single child and [T] for lists / optionals (length 0 or 1).

import "lexer" as lx


struct Box<T> {
    value: T
    line: int          // source line of the wrapped node's first token (0 for types — codegen ignores)
}


// ---- Types -------------------------------------------------------------------------------------------

enum Ty {
    TyName(qual: string, name: string)              // qual "" if unqualified
    TyGeneric(qual: string, name: string, args: [Ty])
    TyArray(elem: Box<Ty>)
    TyFn(params: [Ty], ret: [Ty])                   // ret: [] = unit return
}


// ---- Expressions -------------------------------------------------------------------------------------

struct StrPart {
    text: string                                    // a literal run (used when hole is empty)
    hole: [Expr]                                    // length 1 = an interpolation hole, 0 = a text run
}


enum Expr {
    EInt(v: int)
    EFloat(v: float)
    EBool(v: bool)
    EStr(parts: [StrPart])
    EIdent(name: string)
    EUnary(op: lx.Tk, operand: Box<Expr>)
    EBinary(op: lx.Tk, left: Box<Expr>, right: Box<Expr>)
    ECall(callee: Box<Expr>, args: [Expr])
    EGet(object: Box<Expr>, name: string)
    EIndex(object: Box<Expr>, index: Box<Expr>)
    EArray(elems: [Expr], lines: [int])             // lines[i] = element i's start line (codegen line attribution)
    EStructLit(ty: Box<Ty>, fields: [SLitField])
    ETry(operand: Box<Expr>)
    ERange(lo: Box<Expr>, hi: Box<Expr>)
    ELambda(params: [Param])                         // body parsed but not printed (lossy)
    EError
}


struct SLitField {
    name: string
    value: Expr
}


// ---- Statements --------------------------------------------------------------------------------------

struct Param {
    qual: int                                       // 0 none, 1 mut, 2 move
    is_self: bool
    name: string
    ty: [Ty]                                        // [] when self or inferred
}


enum Stmt {
    SLet(is_var: bool, name: string, ty: [Ty], value: Box<Expr>)
    SReturn(value: [Box<Expr>], line: int)           // boxed value carries its line; `line` = the keyword's (bare return)
    SExpr(expr: Box<Expr>)
    SAssign(target: Box<Expr>, value: Box<Expr>)
    SIf(cond: Box<Expr>, then_blk: [Stmt], els: [Stmt])   // els: [] none, [SBlock]/[SIf] otherwise
    SFor(vname: string, index_var: string, iter: Box<Expr>, body: [Stmt])   // index_var "" unless `for (i, x)`
    SLoop(body: [Stmt])
    SBreak(line: int)                                // line: the keyword's line (codegen attributes the JUMP)
    SContinue(line: int)
    SMatch(value: Box<Expr>, cases: [Case])
    SSpawn(call: Box<Expr>)
    SNursery(body: [Stmt])
    SBlock(body: [Stmt])
}


struct Pattern {
    type_name: string                               // "" if unqualified
    variant: string
    bindings: [string]
    wildcard: bool
}


struct Case {
    pattern: Pattern
    body: [Stmt]
}


// ---- Declarations ------------------------------------------------------------------------------------

struct GenericParam {
    name: string
    bounds: [string]
}


struct Field {
    name: string
    ty: Ty
}


struct Variant {
    name: string
    fields: [Field]
}


struct FnDecl {
    name: string
    generics: [GenericParam]
    params: [Param]
    ret: [Ty]                                       // [] = unit
    has_body: bool
    body: [Stmt]
}


enum Decl {
    DFn(f: FnDecl)
    DStruct(name: string, generics: [GenericParam], impls: [string], fields: [Field], methods: [FnDecl])
    DEnum(name: string, generics: [GenericParam], impls: [string], variants: [Variant])
    DInterface(name: string, generics: [GenericParam], methods: [FnDecl])
    DImport(path: string, alias: string)
    DLet(is_var: bool, name: string, ty: [Ty], value: Box<Expr>)
    DExtern(abi: string, fns: [FnDecl])
    DType(name: string, base: Box<Ty>)
}


// ---- Printer: reproduces src/ast_print.c byte-for-byte (2-space indent, positions omitted) -----------

fn ind(depth: int) -> string {
    var s = ""
    var i = 0
    loop {
        if i >= depth {
            break
        }
        s = s + "  "
        i = i + 1
    }
    return s
}


fn ty_str(t: Ty) -> string {
    match t {
        case TyName(q, n) {
            return n                                 // ast_print drops the module qualifier (lx.Tk -> Tk)
        }
        case TyGeneric(q, n, args) {
            var s = n + "<"
            var i = 0
            loop {
                if i >= args.len() {
                    break
                }
                if i > 0 {
                    s = s + ", "
                }
                s = s + ty_str(args[i])
                i = i + 1
            }
            return s + ">"
        }
        case TyArray(elem) {
            return "[" + ty_str(elem.value) + "]"
        }
        case TyFn(params, ret) {
            var s = "fn("
            var i = 0
            loop {
                if i >= params.len() {
                    break
                }
                if i > 0 {
                    s = s + ", "
                }
                s = s + ty_str(params[i])
                i = i + 1
            }
            s = s + ")"
            if ret.len() > 0 {
                s = s + " -> " + ty_str(ret[0])
            }
            return s
        }
    }
}


fn p_expr(e: Expr, depth: int) {
    let pad = ind(depth)
    match e {
        case EInt(v) {
            println("{pad}Int {v}")
        }
        case EFloat(v) {
            println("{pad}Float {v}")
        }
        case EBool(v) {
            if v {
                println("{pad}Bool true")
            } else {
                println("{pad}Bool false")
            }
        }
        case EIdent(n) {
            println("{pad}Ident {n}")
        }
        case EStr(parts) {
            if parts.len() == 1 && parts[0].hole.len() == 0 {
                println("{pad}String \"{parts[0].text}\"")
            } else {
                println("{pad}String (interpolated, {parts.len()} parts)")
                var i = 0
                loop {
                    if i >= parts.len() {
                        break
                    }
                    if parts[i].hole.len() == 1 {
                        println("{ind(depth + 1)}hole:")
                        p_expr(parts[i].hole[0], depth + 2)
                    } else {
                        println("{ind(depth + 1)}text \"{parts[i].text}\"")
                    }
                    i = i + 1
                }
            }
        }
        case EUnary(op, operand) {
            println("{pad}Unary {lx.kind_name(op)}")
            p_expr(operand.value, depth + 1)
        }
        case EBinary(op, l, r) {
            println("{pad}Binary {lx.kind_name(op)}")
            p_expr(l.value, depth + 1)
            p_expr(r.value, depth + 1)
        }
        case ECall(callee, args) {
            println("{pad}Call")
            println("{ind(depth + 1)}callee:")
            p_expr(callee.value, depth + 2)
            if args.len() > 0 {
                println("{ind(depth + 1)}args:")
                var i = 0
                loop {
                    if i >= args.len() {
                        break
                    }
                    p_expr(args[i], depth + 2)
                    i = i + 1
                }
            }
        }
        case EGet(object, name) {
            println("{pad}Get .{name}")
            p_expr(object.value, depth + 1)
        }
        case EIndex(object, index) {
            println("{pad}Index")
            p_expr(object.value, depth + 1)
            p_expr(index.value, depth + 1)
        }
        case EArray(elems, lines) {
            println("{pad}Array ({elems.len()})")
            var i = 0
            loop {
                if i >= elems.len() {
                    break
                }
                p_expr(elems[i], depth + 1)
                i = i + 1
            }
        }
        case EStructLit(ty, fields) {
            println("{pad}StructLit {ty_str(ty.value)}")
            var i = 0
            loop {
                if i >= fields.len() {
                    break
                }
                println("{ind(depth + 1)}{fields[i].name}:")
                p_expr(fields[i].value, depth + 2)
                i = i + 1
            }
        }
        case ETry(operand) {
            println("{pad}Try")
            p_expr(operand.value, depth + 1)
        }
        case ERange(lo, hi) {
            println("{pad}Range")
            p_expr(lo.value, depth + 1)
            p_expr(hi.value, depth + 1)
        }
        case ELambda(params) {
            var s = "{pad}Lambda("
            var i = 0
            loop {
                if i >= params.len() {
                    break
                }
                if i > 0 {
                    s = s + ", "
                }
                s = s + params[i].name
                i = i + 1
            }
            println(s + ")")
        }
        case EError {
            println("{pad}<error-expr>")
        }
    }
}


fn p_pattern(p: Pattern) -> string {
    if p.wildcard {
        return "_"
    }
    var s = ""
    if p.type_name != "" {
        s = p.type_name + "."
    }
    s = s + p.variant
    if p.bindings.len() > 0 {
        s = s + "("
        var i = 0
        loop {
            if i >= p.bindings.len() {
                break
            }
            if i > 0 {
                s = s + ", "
            }
            s = s + p.bindings[i]
            i = i + 1
        }
        s = s + ")"
    }
    return s
}


fn p_block(b: [Stmt], depth: int) {
    var i = 0
    loop {
        if i >= b.len() {
            break
        }
        p_stmt(b[i], depth)
        i = i + 1
    }
}


fn p_stmt(s: Stmt, depth: int) {
    let pad = ind(depth)
    match s {
        case SLet(is_var, name, ty, value) {
            var head = "{pad}Let {name}"
            if is_var {
                head = "{pad}Var {name}"
            }
            if ty.len() > 0 {
                head = head + ": " + ty_str(ty[0])
            }
            println(head)
            p_expr(value.value, depth + 1)
        }
        case SReturn(value, line) {
            println("{pad}Return")
            if value.len() > 0 {
                p_expr(value[0].value, depth + 1)
            } else {
                println("{ind(depth + 1)}(unit)")
            }
        }
        case SExpr(expr) {
            println("{pad}ExprStmt")
            p_expr(expr.value, depth + 1)
        }
        case SAssign(target, value) {
            println("{pad}Assign")
            println("{ind(depth + 1)}target:")
            p_expr(target.value, depth + 2)
            println("{ind(depth + 1)}value:")
            p_expr(value.value, depth + 2)
        }
        case SIf(cond, then_blk, els) {
            println("{pad}If")
            println("{ind(depth + 1)}cond:")
            p_expr(cond.value, depth + 2)
            println("{ind(depth + 1)}then:")
            p_block(then_blk, depth + 2)
            if els.len() > 0 {
                println("{ind(depth + 1)}else:")
                p_stmt(els[0], depth + 2)
            }
        }
        case SFor(vname, index_var, iter, body) {
            println("{pad}For {vname}")
            println("{ind(depth + 1)}iter:")
            p_expr(iter.value, depth + 2)
            println("{ind(depth + 1)}body:")
            p_block(body, depth + 2)
        }
        case SLoop(body) {
            println("{pad}Loop")
            p_block(body, depth + 1)
        }
        case SBreak(line) {
            println("{pad}Break")
        }
        case SContinue(line) {
            println("{pad}Continue")
        }
        case SMatch(value, cases) {
            println("{pad}Match")
            println("{ind(depth + 1)}value:")
            p_expr(value.value, depth + 2)
            var i = 0
            loop {
                if i >= cases.len() {
                    break
                }
                println("{ind(depth + 1)}case {p_pattern(cases[i].pattern)}")
                p_block(cases[i].body, depth + 2)
                i = i + 1
            }
        }
        case SSpawn(call) {
            println("{pad}Spawn")
            p_expr(call.value, depth + 1)
        }
        case SNursery(body) {
            println("{pad}Nursery")
            p_block(body, depth + 1)
        }
        case SBlock(body) {
            println("{pad}Block")
            p_block(body, depth + 1)
        }
    }
}


fn p_generics(gs: [GenericParam], depth: int) {
    if gs.len() == 0 {
        return
    }
    var s = "{ind(depth)}generics:"
    var i = 0
    loop {
        if i >= gs.len() {
            break
        }
        s = s + " " + gs[i].name
        var j = 0
        loop {
            if j >= gs[i].bounds.len() {
                break
            }
            if j == 0 {
                s = s + ": " + gs[i].bounds[j]
            } else {
                s = s + " + " + gs[i].bounds[j]
            }
            j = j + 1
        }
        i = i + 1
    }
    println(s)
}


fn p_fn(f: FnDecl, depth: int) {
    println("{ind(depth)}Fn {f.name}")
    p_generics(f.generics, depth + 1)
    println("{ind(depth + 1)}params:")
    var i = 0
    loop {
        if i >= f.params.len() {
            break
        }
        var line = ind(depth + 2)
        if f.params[i].qual == 1 {
            line = line + "mut "
        } else if f.params[i].qual == 2 {
            line = line + "move "
        }
        if f.params[i].is_self {
            line = line + "self"
        } else {
            line = line + f.params[i].name + ": " + ty_str(f.params[i].ty[0])
        }
        println(line)
        i = i + 1
    }
    if f.ret.len() > 0 {
        println("{ind(depth + 1)}returns: {ty_str(f.ret[0])}")
    }
    if f.has_body {
        println("{ind(depth + 1)}body:")
        p_block(f.body, depth + 2)
    } else {
        println("{ind(depth + 1)}(signature)")
    }
}


fn p_decl(d: Decl, depth: int) {
    let pad = ind(depth)
    match d {
        case DFn(f) {
            p_fn(f, depth)
        }
        case DStruct(name, generics, impls, fields, methods) {
            println("{pad}Struct {name}")
            p_generics(generics, depth + 1)
            if impls.len() > 0 {
                var s = "{ind(depth + 1)}implements:"
                var i = 0
                loop {
                    if i >= impls.len() {
                        break
                    }
                    s = s + " " + impls[i]
                    i = i + 1
                }
                println(s)
            }
            var fi = 0
            loop {
                if fi >= fields.len() {
                    break
                }
                println("{ind(depth + 1)}field {fields[fi].name}: {ty_str(fields[fi].ty)}")
                fi = fi + 1
            }
            var mi = 0
            loop {
                if mi >= methods.len() {
                    break
                }
                p_fn(methods[mi], depth + 1)
                mi = mi + 1
            }
        }
        case DEnum(name, generics, impls, variants) {
            println("{pad}Enum {name}")
            p_generics(generics, depth + 1)
            if impls.len() > 0 {
                var s = "{ind(depth + 1)}implements:"
                var i = 0
                loop {
                    if i >= impls.len() {
                        break
                    }
                    s = s + " " + impls[i]
                    i = i + 1
                }
                println(s)
            }
            var vi = 0
            loop {
                if vi >= variants.len() {
                    break
                }
                var line = "{ind(depth + 1)}variant {variants[vi].name}"
                if variants[vi].fields.len() > 0 {
                    line = line + "("
                    var j = 0
                    loop {
                        if j >= variants[vi].fields.len() {
                            break
                        }
                        if j > 0 {
                            line = line + ", "
                        }
                        line = line + variants[vi].fields[j].name + ": " + ty_str(variants[vi].fields[j].ty)
                        j = j + 1
                    }
                    line = line + ")"
                }
                println(line)
                vi = vi + 1
            }
        }
        case DInterface(name, generics, methods) {
            println("{pad}Interface {name}")
            p_generics(generics, depth + 1)
            var mi = 0
            loop {
                if mi >= methods.len() {
                    break
                }
                p_fn(methods[mi], depth + 1)
                mi = mi + 1
            }
        }
        case DImport(path, alias) {
            println("{pad}Import \"{path}\" as {alias}")
        }
        case DLet(is_var, name, ty, value) {
            var head = "{pad}Let {name}"
            if is_var {
                head = "{pad}Var {name}"
            }
            if ty.len() > 0 {
                head = head + ": " + ty_str(ty[0])
            }
            println(head)
            p_expr(value.value, depth + 1)
        }
        case DExtern(abi, fns) {
            println("{pad}Extern \"{abi}\"")
            var i = 0
            loop {
                if i >= fns.len() {
                    break
                }
                p_fn(fns[i], depth + 1)
                i = i + 1
            }
        }
        case DType(name, base) {
            println("{pad}Type {name} = {ty_str(base.value)}")
        }
    }
}


fn dump(decls: [Decl]) {
    println("Program")
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        p_decl(decls[i], 1)
        i = i + 1
    }
}


// ---- Parser: recursive descent + precedence climbing over the lexer's [Token] -----------------------

// parse_int_lit reads the leading decimal digits of an integer lexeme (dropping any iN/uN width suffix).
// It uses WRAPPING arithmetic so an out-of-int64-range literal (a u64 like 9223372036854775808, or u64
// max) wraps to its signed reinterpretation — exactly what stage-0's strtoll-based parse stores, so the
// AST dump matches (`Int -9223372036854775808`). The default `* +` would trap on overflow.
fn parse_int_lit(text: string) -> int {
    let bs = text.bytes()
    var v = 0
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        let c = int(bs[i])
        if c < 48 || c > 57 {
            break
        }
        v = wrapping_add(wrapping_mul(v, 10), c - 48)
        i = i + 1
    }
    return v
}


// binary_prec mirrors src/parser.c: 10 levels, shift (8) BELOW additive (9), all left-associative.
fn binary_prec(k: lx.Tk) -> int {
    match k {
        case TOr { return 1 }
        case TAnd { return 2 }
        case TPipe { return 3 }
        case TCaret { return 4 }
        case TAmp { return 5 }
        case TEq { return 6 }
        case TNeq { return 6 }
        case TLt { return 7 }
        case TLe { return 7 }
        case TGt { return 7 }
        case TGe { return 7 }
        case TShl { return 8 }
        case TShr { return 8 }
        case TPlus { return 9 }
        case TMinus { return 9 }
        case TStar { return 10 }
        case TSlash { return 10 }
        case TPercent { return 10 }
        case _ { return 0 }
    }
}


// binop_class groups a binary operator token by how it types its result, for the checker (which holds a
// `lx.Tk` op it cannot `match` on its own without re-importing the lexer's variants): 1 = `+` (numeric add
// or string concat), 2 = the other numeric arithmetic (`- * / %`), 3 = a comparison (result bool),
// 4 = a logical `&& ||` (result bool), 5 = a bitwise/shift op (result = operand type), 0 = anything else.
fn binop_class(k: lx.Tk) -> int {
    match k {
        case TPlus { return 1 }
        case TMinus { return 2 }
        case TStar { return 2 }
        case TSlash { return 2 }
        case TPercent { return 2 }
        case TEq { return 3 }
        case TNeq { return 3 }
        case TLt { return 3 }
        case TLe { return 3 }
        case TGt { return 3 }
        case TGe { return 3 }
        case TAnd { return 4 }
        case TOr { return 4 }
        case TPipe { return 5 }
        case TCaret { return 5 }
        case TAmp { return 5 }
        case TShl { return 5 }
        case TShr { return 5 }
        case _ { return 0 }
    }
}


// binop_id gives a stable per-operator id (the codegen maps it to an opcode; the parser owns the lexer's
// Tk variants, which the codegen can't match). 1..18 cover every binary operator; 0 = not one.
fn binop_id(k: lx.Tk) -> int {
    match k {
        case TPlus { return 1 }
        case TMinus { return 2 }
        case TStar { return 3 }
        case TSlash { return 4 }
        case TPercent { return 5 }
        case TLt { return 6 }
        case TLe { return 7 }
        case TGt { return 8 }
        case TGe { return 9 }
        case TEq { return 10 }
        case TNeq { return 11 }
        case TAnd { return 12 }
        case TOr { return 13 }
        case TAmp { return 14 }
        case TPipe { return 15 }
        case TCaret { return 16 }
        case TShl { return 17 }
        case TShr { return 18 }
        case _ { return 0 }
    }
}


// unop_id maps a prefix unary operator to a small id (1 minus, 2 bang/not, 3 tilde/bitnot), else 0.
fn unop_id(k: lx.Tk) -> int {
    match k {
        case TMinus { return 1 }
        case TBang { return 2 }
        case TTilde { return 3 }
        case _ { return 0 }
    }
}


// decode_string_inner decodes escape sequences in a string's INNER bytes (quotes already stripped),
// matching the parser's build_string_parts: \n \t \r \0 -> the control char; anything else after a
// backslash (\\ \" \{ \} and any other) copies the next char literally.
fn decode_string_inner(s: string) -> string {
    let bs = s.bytes()
    var out = ""
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        let c = int(bs[i])
        if c == 92 && i + 1 < bs.len() {
            let n = int(bs[i + 1])
            if n == 110 {
                out = out + from_char_code(10)
            } else if n == 116 {
                out = out + from_char_code(9)
            } else if n == 114 {
                out = out + from_char_code(13)
            } else if n == 48 {
                out = out + from_char_code(0)
            } else {
                out = out + byte_slice(s, i + 1, i + 2)
            }
            i = i + 2
        } else {
            out = out + byte_slice(s, i, i + 1)
            i = i + 1
        }
    }
    return out
}


// Token-kind tags. The parser cannot construct or `==` the lexer's imported Tk variants (only `match`
// them), so token checks go through a small integer tag: tk_tag MATCHES the kind into an int, and the
// TAG_* constants name the ones the parser tests. Kinds not tested return 0. Keep the two in sync.
let TAG_EOF: int = 1
let TAG_NEWLINE: int = 2
let TAG_IDENT: int = 3
let TAG_STRUCT: int = 4
let TAG_FN: int = 5
let TAG_COLON: int = 6
let TAG_LBRACE: int = 7
let TAG_RBRACE: int = 8
let TAG_LPAREN: int = 9
let TAG_RPAREN: int = 10
let TAG_LBRACKET: int = 11
let TAG_RBRACKET: int = 12
let TAG_COMMA: int = 13
let TAG_DOT: int = 14
let TAG_DOTDOT: int = 15
let TAG_LT: int = 16
let TAG_GT: int = 17
let TAG_PLUS: int = 18
let TAG_ARROW: int = 19
let TAG_ASSIGN: int = 20
let TAG_WHERE: int = 21
let TAG_REQUIRES: int = 22
let TAG_ENSURES: int = 23
let TAG_IMPLEMENTS: int = 24
let TAG_MUT: int = 25
let TAG_MOVE: int = 26
let TAG_SELF: int = 27
let TAG_ELSE: int = 28
let TAG_IF: int = 29
let TAG_QUESTION: int = 30
let TAG_PIPE: int = 31
let TAG_SHR: int = 32


fn tk_tag(k: lx.Tk) -> int {
    match k {
        case TEof { return 1 }
        case TNewline { return 2 }
        case TIdent { return 3 }
        case TStruct { return 4 }
        case TFn { return 5 }
        case TColon { return 6 }
        case TLBrace { return 7 }
        case TRBrace { return 8 }
        case TLParen { return 9 }
        case TRParen { return 10 }
        case TLBracket { return 11 }
        case TRBracket { return 12 }
        case TComma { return 13 }
        case TDot { return 14 }
        case TDotDot { return 15 }
        case TLt { return 16 }
        case TGt { return 17 }
        case TPlus { return 18 }
        case TArrow { return 19 }
        case TAssign { return 20 }
        case TWhere { return 21 }
        case TRequires { return 22 }
        case TEnsures { return 23 }
        case TImplements { return 24 }
        case TMut { return 25 }
        case TMove { return 26 }
        case TSelf { return 27 }
        case TElse { return 28 }
        case TIf { return 29 }
        case TQuestion { return 30 }
        case TPipe { return 31 }
        case TShr { return 32 }
        case _ { return 0 }
    }
}


// type_arg_ok reports whether a token may appear inside a type-argument list `<...>` — used to soundly
// disambiguate a generic struct literal `Name<...>{` from a less-than comparison (no expression begins
// with `{`, so an angle group of only type-legal tokens immediately followed by `{` must be a literal).
fn type_arg_ok(tag: int) -> bool {
    return tag == TAG_IDENT || tag == TAG_DOT || tag == TAG_COMMA || tag == TAG_LBRACKET || tag == TAG_RBRACKET || tag == TAG_FN || tag == TAG_LPAREN || tag == TAG_RPAREN || tag == TAG_ARROW || tag == TAG_LT || tag == TAG_GT || tag == TAG_SHR
}


struct Parser {
    toks: [lx.Token]
    pos: int
    src: string            // the source (for a strtod-style float over-read past the lexeme)
    no_struct: bool        // suppress `Name { … }` as a struct literal in if/for/match headers
    pending_gt: int        // a `>>` consumed as one generic close leaves a virtual `>` here (stage-0 splits the token)


    fn peek(self) -> lx.Token {
        if self.pos >= self.toks.len() {
            return self.toks[self.toks.len() - 1]
        }
        return self.toks[self.pos]
    }


    fn peek_kind(self) -> lx.Tk {
        return self.peek().kind
    }


    fn peek2_kind(self) -> lx.Tk {
        if self.pos + 1 >= self.toks.len() {
            return self.toks[self.toks.len() - 1].kind
        }
        return self.toks[self.pos + 1].kind
    }


    fn advance(mut self) -> lx.Token {
        let t = self.peek()
        if self.pos < self.toks.len() - 1 {
            self.pos = self.pos + 1
        }
        return t
    }


    fn is_eof(self) -> bool {
        match self.peek_kind() {
            case TEof { return true }
            case _ { return false }
        }
    }


    fn at(self, want: int) -> bool {
        return tk_tag(self.peek_kind()) == want
    }


    fn skip_newlines(mut self) {
        loop {
            if self.at(TAG_NEWLINE) {
                let _ = self.advance()
            } else {
                break
            }
        }
    }


    // expect consumes a token whose tag is `want`, returning its lexeme; on a mismatch it does not
    // advance (the well-formed corpus never triggers this). Used where a specific delimiter is required.
    fn expect(mut self, want: int) -> string {
        if self.at(want) {
            return self.advance().text
        }
        return ""
    }


    fn tag_at(self, off: int) -> int {
        if off >= self.toks.len() {
            return 0
        }
        return tk_tag(self.toks[off].kind)
    }


    // at_generic_close / close_generic handle the shared `>>` lexeme: a `>>` that closes a generic level
    // is consumed once and leaves a virtual `>` (pending_gt) for the enclosing level (stage-0 splits the
    // token in expect_type_close).
    fn at_generic_close(self) -> bool {
        if self.pending_gt > 0 {
            return true
        }
        return self.at(TAG_GT) || self.at(TAG_SHR)
    }


    fn close_generic(mut self) {
        if self.pending_gt > 0 {
            self.pending_gt = self.pending_gt - 1
            return
        }
        if self.at(TAG_SHR) {
            let _ = self.advance()
            self.pending_gt = self.pending_gt + 1
        } else {
            let _ = self.expect(TAG_GT)
        }
    }


    // generic_lit_ahead reports whether token `off` (a `<`) begins a balanced angle group of type-legal
    // tokens immediately followed by `{` — i.e. a generic struct literal `Name<...>{`, not a comparison.
    fn generic_lit_ahead(self, off: int) -> bool {
        var depth = 0
        var i = off
        let n = self.toks.len()
        loop {
            if i >= n {
                return false
            }
            let tag = tk_tag(self.toks[i].kind)
            if tag == TAG_LT {
                depth = depth + 1
                i = i + 1
            } else if tag == TAG_GT {
                depth = depth - 1
                i = i + 1
                if depth == 0 {
                    break
                }
            } else if tag == TAG_SHR {
                depth = depth - 2
                i = i + 1
                if depth <= 0 {
                    break
                }
            } else if type_arg_ok(tag) {
                i = i + 1
            } else {
                return false
            }
        }
        return self.tag_at(i) == TAG_LBRACE
    }


    fn parse_type_args(mut self) -> [Ty] {
        let _ = self.advance()                      // <
        var args: [Ty] = []
        loop {
            if self.at_generic_close() || self.is_eof() {
                break
            }
            args.append(self.parse_type())
            if self.at(TAG_COMMA) {
                let _ = self.advance()
            } else {
                break
            }
        }
        self.close_generic()
        return args
    }


    fn parse_program(mut self) -> [Decl] {
        var decls: [Decl] = []
        self.skip_newlines()
        loop {
            if self.is_eof() {
                break
            }
            decls.append(self.parse_decl())
            self.skip_newlines()
        }
        return decls
    }


    fn parse_decl(mut self) -> Decl {
        // rc/resource are contextual modifiers before `struct`.
        if self.at(TAG_IDENT) && self.at2(TAG_STRUCT) {
            let w = self.peek().text
            if w == "rc" || w == "resource" {
                let _ = self.advance()
                return self.parse_struct()
            }
        }
        match self.peek_kind() {
            case TFn { return DFn(self.parse_fn(true)) }
            case TStruct { return self.parse_struct() }
            case TEnum { return self.parse_enum() }
            case TInterface { return self.parse_interface() }
            case TImport { return self.parse_import() }
            case TExtern { return self.parse_extern() }
            case TType { return self.parse_type_decl() }
            case TLet { return self.parse_global_let(false) }
            case TVar { return self.parse_global_let(true) }
            case _ {
                let _ = self.advance()
                return DImport("", "")
            }
        }
    }


    fn at2(self, want: int) -> bool {
        return tk_tag(self.peek2_kind()) == want
    }


    fn parse_import(mut self) -> Decl {
        let _ = self.advance()                      // import
        let path = strip_quotes(self.advance().text)
        let _ = self.advance()                      // as
        let alias = self.advance().text
        return DImport(path, alias)
    }


    fn parse_type_decl(mut self) -> Decl {
        let _ = self.advance()                      // type
        let name = self.advance().text
        let _ = self.advance()                      // =
        let base = self.parse_type()
        // optional `where Expr` refinement (parsed to consume, not printed)
        if self.at(TAG_WHERE) {
            let _ = self.advance()
            let _ = self.parse_expr()
        }
        return DType(name, Box<Ty>{ value: base, line: 0 })
    }


    fn parse_global_let(mut self, is_var: bool) -> Decl {
        let _ = self.advance()                      // let|var
        let name = self.advance().text
        var ty: [Ty] = []
        if self.at(TAG_COLON) {
            let _ = self.advance()
            ty.append(self.parse_type())
        }
        let _ = self.advance()                      // =
        let vstart = self.peek().line
        let value = self.parse_expr()
        return DLet(is_var, name, ty, Box<Expr>{ value: value, line: vstart })
    }


    fn parse_generics(mut self) -> [GenericParam] {
        var gs: [GenericParam] = []
        if self.at(TAG_LT) == false {
            return gs
        }
        let _ = self.advance()                      // <
        loop {
            if self.at(TAG_GT) || self.is_eof() {
                break
            }
            let name = self.advance().text
            var bounds: [string] = []
            if self.at(TAG_COLON) {
                let _ = self.advance()
                loop {
                    let b = self.advance().text
                    if b != "Copy" {
                        bounds.append(b)
                    }
                    if self.at(TAG_PLUS) {
                        let _ = self.advance()
                    } else {
                        break
                    }
                }
            }
            gs.append(GenericParam{ name: name, bounds: bounds })
            if self.at(TAG_COMMA) {
                let _ = self.advance()
            } else {
                break
            }
        }
        let _ = self.expect(TAG_GT)
        return gs
    }


    fn parse_type(mut self) -> Ty {
        if self.at(TAG_LBRACKET) {
            let _ = self.advance()
            let elem = self.parse_type()
            let _ = self.expect(TAG_RBRACKET)
            return TyArray(Box<Ty>{ value: elem, line: 0 })
        }
        if self.at(TAG_FN) {
            let _ = self.advance()
            let _ = self.expect(TAG_LPAREN)
            var params: [Ty] = []
            loop {
                if self.at(TAG_RPAREN) || self.is_eof() {
                    break
                }
                params.append(self.parse_type())
                if self.at(TAG_COMMA) {
                    let _ = self.advance()
                } else {
                    break
                }
            }
            let _ = self.expect(TAG_RPAREN)
            var ret: [Ty] = []
            if self.at(TAG_ARROW) {
                let _ = self.advance()
                ret.append(self.parse_type())
            }
            return TyFn(params, ret)
        }
        var qual = ""
        var name = self.advance().text
        if self.at(TAG_DOT) {
            let _ = self.advance()
            qual = name
            name = self.advance().text
        }
        if self.at(TAG_LT) {
            return TyGeneric(qual, name, self.parse_type_args())
        }
        return TyName(qual, name)
    }


    fn parse_params(mut self) -> [Param] {
        var params: [Param] = []
        let _ = self.expect(TAG_LPAREN)
        loop {
            self.skip_newlines()
            if self.at(TAG_RPAREN) || self.is_eof() {
                break
            }
            var qual = 0
            if self.at(TAG_MUT) {
                qual = 1
                let _ = self.advance()
            } else if self.at(TAG_MOVE) {
                qual = 2
                let _ = self.advance()
            }
            if self.at(TAG_SELF) {
                let _ = self.advance()
                params.append(Param{ qual: qual, is_self: true, name: "", ty: [] })
            } else {
                let pname = self.advance().text
                let _ = self.expect(TAG_COLON)
                let pty = self.parse_type()
                params.append(Param{ qual: qual, is_self: false, name: pname, ty: [pty] })
            }
            if self.at(TAG_COMMA) {
                let _ = self.advance()
            } else {
                break
            }
        }
        self.skip_newlines()
        let _ = self.expect(TAG_RPAREN)
        return params
    }


    fn parse_fn(mut self, with_body: bool) -> FnDecl {
        let _ = self.advance()                      // fn
        let name = self.advance().text
        let generics = self.parse_generics()
        let params = self.parse_params()
        var ret: [Ty] = []
        if self.at(TAG_ARROW) {
            let _ = self.advance()
            ret.append(self.parse_type())
        }
        if with_body == false {
            return FnDecl{ name: name, generics: generics, params: params, ret: ret, has_body: false, body: [] }
        }
        // requires/ensures contract clauses (parsed to consume tokens, not stored/printed)
        loop {
            self.skip_newlines()
            if self.at(TAG_REQUIRES) || self.at(TAG_ENSURES) {
                let _ = self.advance()
                let _ = self.parse_expr()
            } else {
                break
            }
        }
        let body = self.parse_block()
        return FnDecl{ name: name, generics: generics, params: params, ret: ret, has_body: true, body: body }
    }


    fn parse_struct(mut self) -> Decl {
        let _ = self.advance()                      // struct
        let name = self.advance().text
        let generics = self.parse_generics()
        var impls: [string] = []
        if self.at(TAG_IMPLEMENTS) {
            let _ = self.advance()
            loop {
                impls.append(self.advance().text)
                if self.at(TAG_COMMA) {
                    let _ = self.advance()
                } else {
                    break
                }
            }
        }
        let _ = self.expect(TAG_LBRACE)
        var fields: [Field] = []
        var methods: [FnDecl] = []
        loop {
            self.skip_newlines()
            if self.at(TAG_RBRACE) || self.is_eof() {
                break
            }
            if self.at(TAG_FN) {
                methods.append(self.parse_fn(true))
            } else {
                let fname = self.advance().text
                let _ = self.expect(TAG_COLON)
                let fty = self.parse_type()
                fields.append(Field{ name: fname, ty: fty })
            }
        }
        let _ = self.expect(TAG_RBRACE)
        return DStruct(name, generics, impls, fields, methods)
    }


    fn parse_enum(mut self) -> Decl {
        let _ = self.advance()                      // enum
        let name = self.advance().text
        let generics = self.parse_generics()
        var impls: [string] = []
        if self.at(TAG_IMPLEMENTS) {
            let _ = self.advance()
            loop {
                impls.append(self.advance().text)
                if self.at(TAG_COMMA) {
                    let _ = self.advance()
                } else {
                    break
                }
            }
        }
        let _ = self.expect(TAG_LBRACE)
        var variants: [Variant] = []
        loop {
            self.skip_newlines()
            if self.at(TAG_RBRACE) || self.is_eof() {
                break
            }
            let vname = self.advance().text
            var vfields: [Field] = []
            if self.at(TAG_LPAREN) {
                let _ = self.advance()
                loop {
                    if self.at(TAG_RPAREN) || self.is_eof() {
                        break
                    }
                    let fname = self.advance().text
                    let _ = self.expect(TAG_COLON)
                    let fty = self.parse_type()
                    vfields.append(Field{ name: fname, ty: fty })
                    if self.at(TAG_COMMA) {
                        let _ = self.advance()
                    } else {
                        break
                    }
                }
                let _ = self.expect(TAG_RPAREN)
            }
            variants.append(Variant{ name: vname, fields: vfields })
        }
        let _ = self.expect(TAG_RBRACE)
        return DEnum(name, generics, impls, variants)
    }


    fn parse_interface(mut self) -> Decl {
        let _ = self.advance()                      // interface
        let name = self.advance().text
        let generics = self.parse_generics()
        let _ = self.expect(TAG_LBRACE)
        var methods: [FnDecl] = []
        loop {
            self.skip_newlines()
            if self.at(TAG_RBRACE) || self.is_eof() {
                break
            }
            methods.append(self.parse_fn(false))
        }
        let _ = self.expect(TAG_RBRACE)
        return DInterface(name, generics, methods)
    }


    fn parse_extern(mut self) -> Decl {
        let _ = self.advance()                      // extern
        let abi = strip_quotes(self.advance().text)
        let _ = self.expect(TAG_LBRACE)
        var fns: [FnDecl] = []
        loop {
            self.skip_newlines()
            if self.at(TAG_RBRACE) || self.is_eof() {
                break
            }
            fns.append(self.parse_fn(false))
        }
        let _ = self.expect(TAG_RBRACE)
        return DExtern(abi, fns)
    }


    fn parse_block(mut self) -> [Stmt] {
        let _ = self.expect(TAG_LBRACE)
        var body: [Stmt] = []
        loop {
            self.skip_newlines()
            if self.at(TAG_RBRACE) || self.is_eof() {
                break
            }
            body.append(self.parse_stmt())
        }
        let _ = self.expect(TAG_RBRACE)
        return body
    }


    fn parse_stmt(mut self) -> Stmt {
        match self.peek_kind() {
            case TLet { return self.parse_let(false) }
            case TVar { return self.parse_let(true) }
            case TReturn { return self.parse_return() }
            case TIf { return self.parse_if() }
            case TFor { return self.parse_for() }
            case TLoop {
                let _ = self.advance()
                return SLoop(self.parse_block())
            }
            case TBreak {
                let ln = self.peek().line
                let _ = self.advance()
                return SBreak(ln)
            }
            case TContinue {
                let ln = self.peek().line
                let _ = self.advance()
                return SContinue(ln)
            }
            case TMatch { return self.parse_match() }
            case TSpawn {
                let _ = self.advance()
                let ss = self.peek().line
                return SSpawn(Box<Expr>{ value: self.parse_expr(), line: ss })
            }
            case TNursery {
                let _ = self.advance()
                return SNursery(self.parse_block())
            }
            case TLBrace { return SBlock(self.parse_block()) }
            case _ {
                let estart = self.peek().line
                let e = self.parse_expr()
                if self.at(TAG_ASSIGN) {
                    let _ = self.advance()
                    let vstart = self.peek().line
                    let v = self.parse_expr()
                    return SAssign(Box<Expr>{ value: e, line: estart }, Box<Expr>{ value: v, line: vstart })
                }
                return SExpr(Box<Expr>{ value: e, line: estart })
            }
        }
    }


    fn parse_let(mut self, is_var: bool) -> Stmt {
        let _ = self.advance()                      // let|var
        let name = self.advance().text
        var ty: [Ty] = []
        if self.at(TAG_COLON) {
            let _ = self.advance()
            ty.append(self.parse_type())
        }
        let _ = self.expect(TAG_ASSIGN)
        let vstart = self.peek().line
        let value = self.parse_expr()
        return SLet(is_var, name, ty, Box<Expr>{ value: value, line: vstart })
    }


    fn parse_return(mut self) -> Stmt {
        let rline = self.peek().line                // the `return` keyword's line (a bare return has no expr)
        let _ = self.advance()                      // return
        if self.at(TAG_NEWLINE) || self.at(TAG_RBRACE) || self.is_eof() {
            var none: [Box<Expr>] = []
            return SReturn(none, rline)
        }
        let rstart = self.peek().line
        return SReturn([Box<Expr>{ value: self.parse_expr(), line: rstart }], rline)
    }


    fn parse_if(mut self) -> Stmt {
        let _ = self.advance()                      // if
        let cstart = self.peek().line
        let cond = self.parse_cond()
        let then_blk = self.parse_block()
        var els: [Stmt] = []
        self.skip_newlines()
        if self.at(TAG_ELSE) {
            let _ = self.advance()
            if self.at(TAG_IF) {
                els.append(self.parse_if())
            } else {
                els.append(SBlock(self.parse_block()))
            }
        }
        return SIf(Box<Expr>{ value: cond, line: cstart }, then_blk, els)
    }


    fn parse_for(mut self) -> Stmt {
        let _ = self.advance()                      // for
        var var_name = ""
        var idx_var = ""
        if self.at(TAG_LPAREN) {
            // for (i, x) in ... — index + element; ast_print shows only the element, but the checker
            // needs the index name in scope, so we keep it (printer ignores it).
            let _ = self.advance()
            idx_var = self.advance().text           // index name
            let _ = self.expect(TAG_COMMA)
            var_name = self.advance().text          // element name
            let _ = self.expect(TAG_RPAREN)
        } else {
            var_name = self.advance().text
        }
        let _ = self.advance()                      // in
        let istart = self.peek().line
        let iter = self.parse_cond()
        let body = self.parse_block()
        return SFor(var_name, idx_var, Box<Expr>{ value: iter, line: istart }, body)
    }


    fn parse_match(mut self) -> Stmt {
        let _ = self.advance()                      // match
        let vstart = self.peek().line
        let value = self.parse_cond()
        let _ = self.expect(TAG_LBRACE)
        var cases: [Case] = []
        loop {
            self.skip_newlines()
            if self.at(TAG_RBRACE) || self.is_eof() {
                break
            }
            let _ = self.advance()                  // case
            let pat = self.parse_pattern()
            let body = self.parse_block()
            cases.append(Case{ pattern: pat, body: body })
        }
        let _ = self.expect(TAG_RBRACE)
        return SMatch(Box<Expr>{ value: value, line: vstart }, cases)
    }


    fn parse_pattern(mut self) -> Pattern {
        let first = self.advance().text
        if first == "_" {
            return Pattern{ type_name: "", variant: "_", bindings: [], wildcard: true }
        }
        var type_name = ""
        var variant = first
        if self.at(TAG_DOT) {
            let _ = self.advance()
            type_name = first
            variant = self.advance().text
        }
        var bindings: [string] = []
        if self.at(TAG_LPAREN) {
            let _ = self.advance()
            loop {
                if self.at(TAG_RPAREN) || self.is_eof() {
                    break
                }
                bindings.append(self.advance().text)
                if self.at(TAG_COMMA) {
                    let _ = self.advance()
                } else {
                    break
                }
            }
            let _ = self.expect(TAG_RPAREN)
        }
        return Pattern{ type_name: type_name, variant: variant, bindings: bindings, wildcard: false }
    }


    // parse_cond parses an expression with struct-literals suppressed (the `{` is the following block),
    // matching the no_struct flag stage-0 sets in if/for/match headers. (First cut: struct literals are
    // only recognised via the explicit Name<...>{ / Name{ forms in parse_primary, so a bare `Name {` in a
    // header is naturally read as ident + block here because parse_primary only treats `{` as a literal
    // when it directly follows a type — handled when struct-lit support lands. For now parse_cond == parse_expr.)
    fn parse_cond(mut self) -> Expr {
        let saved = self.no_struct
        self.no_struct = true
        let e = self.parse_expr()
        self.no_struct = saved
        return e
    }


    fn parse_expr(mut self) -> Expr {
        let estart = self.peek().line
        let e = self.parse_binary(1)
        if self.at(TAG_DOTDOT) {
            let _ = self.advance()
            let hstart = self.peek().line
            let hi = self.parse_binary(1)
            return ERange(Box<Expr>{ value: e, line: estart }, Box<Expr>{ value: hi, line: hstart })
        }
        return e
    }


    fn parse_binary(mut self, min_prec: int) -> Expr {
        let lstart = self.peek().line
        var left = self.parse_unary()
        loop {
            let prec = binary_prec(self.peek_kind())
            if prec == 0 || prec < min_prec {
                break
            }
            let op = self.advance().kind
            let rstart = self.peek().line
            let right = self.parse_binary(prec + 1)
            left = EBinary(op, Box<Expr>{ value: left, line: lstart }, Box<Expr>{ value: right, line: rstart })
        }
        return left
    }


    fn parse_unary(mut self) -> Expr {
        match self.peek_kind() {
            case TBang { let op = self.advance().kind  let os = self.peek().line  return EUnary(op, Box<Expr>{ value: self.parse_unary(), line: os }) }
            case TMinus { let op = self.advance().kind  let os = self.peek().line  return EUnary(op, Box<Expr>{ value: self.parse_unary(), line: os }) }
            case TTilde { let op = self.advance().kind  let os = self.peek().line  return EUnary(op, Box<Expr>{ value: self.parse_unary(), line: os }) }
            case _ { return self.parse_postfix() }
        }
    }


    fn parse_postfix(mut self) -> Expr {
        let start = self.peek().line                        // base line; postfix steps inherit it (stage-0)
        var e = self.parse_primary()
        loop {
            match self.peek_kind() {
                case TDot {
                    let _ = self.advance()
                    let name = self.advance().text
                    e = EGet(Box<Expr>{ value: e, line: start }, name)
                }
                case TLParen {
                    let args = self.parse_args()
                    e = ECall(Box<Expr>{ value: e, line: start }, args)
                }
                case TLBracket {
                    let _ = self.advance()
                    let idxstart = self.peek().line
                    let idx = self.parse_expr()
                    let _ = self.expect(TAG_RBRACKET)
                    e = EIndex(Box<Expr>{ value: e, line: start }, Box<Expr>{ value: idx, line: idxstart })
                }
                case TQuestion {
                    let _ = self.advance()
                    e = ETry(Box<Expr>{ value: e, line: start })
                }
                case _ {
                    break
                }
            }
        }
        return e
    }


    fn parse_args(mut self) -> [Expr] {
        let _ = self.expect(TAG_LPAREN)
        let saved = self.no_struct
        self.no_struct = false
        var args: [Expr] = []
        loop {
            self.skip_newlines()
            if self.at(TAG_RPAREN) || self.is_eof() {
                break
            }
            // named arg `name:` — consume the name and colon, keep only the value (names not printed)
            if self.at(TAG_IDENT) && self.at2(TAG_COLON) {
                let _ = self.advance()
                let _ = self.advance()
            }
            args.append(self.parse_expr())
            self.skip_newlines()
            if self.at(TAG_COMMA) {
                let _ = self.advance()
            } else {
                break
            }
        }
        self.skip_newlines()
        self.no_struct = saved
        let _ = self.expect(TAG_RPAREN)
        return args
    }


    fn parse_primary(mut self) -> Expr {
        match self.peek_kind() {
            case TInt {
                let t = self.advance()
                return EInt(parse_int_lit(t.text))
            }
            case TFloat {
                let t = self.advance()
                // stage-0 does strtod(token-start), which OVER-READS the raw source past the lexeme — so a
                // contiguous exponent like `1.5e3` (lexed FLOAT "1.5" + IDENT "e3") evaluates to 1500.
                // parse_float is strtod-based, so feeding it the source from the float's byte offset
                // reproduces that over-read exactly (it stops at the first non-float byte).
                return EFloat(parse_float(byte_slice(self.src, t.byte, self.src.len())))
            }
            case TTrue {
                let _ = self.advance()
                return EBool(true)
            }
            case TFalse {
                let _ = self.advance()
                return EBool(false)
            }
            case TString {
                let t = self.advance()
                return EStr(build_string_parts(t.text, t.line))
            }
            case TIdent {
                let name = self.advance().text
                if self.no_struct == false {
                    if self.at(TAG_DOT) && self.at2(TAG_IDENT) {
                        let after2 = self.tag_at(self.pos + 2)
                        if after2 == TAG_LBRACE {
                            let _ = self.advance()      // .
                            let tname = self.advance().text
                            return self.parse_struct_lit(TyName(name, tname))
                        }
                        if after2 == TAG_LT && self.generic_lit_ahead(self.pos + 2) {
                            let _ = self.advance()      // .
                            let tname = self.advance().text
                            let args = self.parse_type_args()
                            return self.parse_struct_lit(TyGeneric(name, tname, args))
                        }
                    }
                    if self.at(TAG_LT) && self.generic_lit_ahead(self.pos) {
                        let args = self.parse_type_args()
                        return self.parse_struct_lit(TyGeneric("", name, args))
                    }
                    if self.at(TAG_LBRACE) {
                        return self.parse_struct_lit(TyName("", name))
                    }
                }
                return EIdent(name)
            }
            case TSelf {
                let _ = self.advance()
                return EIdent("self")
            }
            case TPipe {
                return self.parse_lambda()
            }
            case TLParen {
                let _ = self.advance()
                let saved = self.no_struct
                self.no_struct = false
                let e = self.parse_expr()
                self.no_struct = saved
                let _ = self.expect(TAG_RPAREN)
                return e
            }
            case TLBracket {
                let _ = self.advance()
                let saved = self.no_struct
                self.no_struct = false
                var elems: [Expr] = []
                var elines: [int] = []
                loop {
                    self.skip_newlines()
                    if self.at(TAG_RBRACKET) || self.is_eof() {
                        break
                    }
                    elines.append(self.peek().line)         // each element's start line (codegen attributes its bytes)
                    elems.append(self.parse_expr())
                    self.skip_newlines()
                    if self.at(TAG_COMMA) {
                        let _ = self.advance()
                    } else {
                        break
                    }
                }
                self.skip_newlines()
                self.no_struct = saved
                let _ = self.expect(TAG_RBRACKET)
                return EArray(elems, elines)
            }
            case _ {
                let _ = self.advance()
                return EError
            }
        }
    }


    fn parse_struct_lit(mut self, ty: Ty) -> Expr {
        let _ = self.expect(TAG_LBRACE)
        let saved = self.no_struct
        self.no_struct = false
        var fields: [SLitField] = []
        loop {
            self.skip_newlines()
            if self.at(TAG_RBRACE) || self.is_eof() {
                break
            }
            let fname = self.advance().text
            let _ = self.expect(TAG_COLON)
            let fval = self.parse_expr()
            fields.append(SLitField{ name: fname, value: fval })
            self.skip_newlines()
            if self.at(TAG_COMMA) {
                let _ = self.advance()
            } else {
                break
            }
        }
        self.skip_newlines()
        self.no_struct = saved
        let _ = self.expect(TAG_RBRACE)
        return EStructLit(Box<Ty>{ value: ty, line: 0 }, fields)
    }


    fn parse_lambda(mut self) -> Expr {
        let _ = self.advance()                      // opening |
        var params: [Param] = []
        loop {
            if self.at(TAG_PIPE) || self.is_eof() {
                break
            }
            let pname = self.advance().text
            var pty: [Ty] = []
            if self.at(TAG_COLON) {
                let _ = self.advance()
                pty.append(self.parse_type())
            }
            params.append(Param{ qual: 0, is_self: false, name: pname, ty: pty })
            if self.at(TAG_COMMA) {
                let _ = self.advance()
            } else {
                break
            }
        }
        let _ = self.expect(TAG_PIPE)               // closing |
        if self.at(TAG_LBRACE) {
            let _ = self.parse_block()
        } else {
            let _ = self.parse_expr()
        }
        return ELambda(params)
    }
}


// strip_quotes removes the first and last byte of a "..." string lexeme.
fn strip_quotes(raw: string) -> string {
    if raw.len() < 2 {
        return ""
    }
    return byte_slice(raw, 1, raw.len() - 1)
}


// parse is the entry point: a source string -> the list of top-level declarations.
fn parse(src: string) -> [Decl] {
    var p = Parser{ toks: lx.lex(src), pos: 0, src: src, no_struct: false, pending_gt: 0 }
    return p.parse_program()
}


// parse_hole re-lexes + parses an interpolation hole's source as a standalone expression — exactly what
// stage-0's build_string_parts does (a fresh lexer_scan per hole), so nested strings and escapes inside
// holes are handled by the same machinery.
fn parse_hole(src: string, base_line: int) -> Expr {
    // The hole is re-lexed STANDALONE, so its tokens would carry line 1; stage-0 offsets them onto the
    // enclosing string's line (src/parser.c: `tok.line = hl + (tok.line - 1)`). Reproduce that by prepending
    // `base_line - 1` newlines before lexing, so the hole's expression nodes capture their true file line
    // (which the bytecode line column — and tooling — depend on).
    var padded = src
    var k = 1
    loop {
        if k >= base_line {
            break
        }
        padded = from_char_code(10) + padded
        k = k + 1
    }
    var p = Parser{ toks: lx.lex(padded), pos: 0, src: padded, no_struct: false, pending_gt: 0 }
    p.skip_newlines()
    return p.parse_expr()
}


// build_string_parts splits a raw "..." string lexeme into literal-text and interpolation-hole parts,
// decoding escapes in the text runs and re-parsing each hole — mirroring src/parser.c build_string_parts.
fn build_string_parts(raw: string, base_line: int) -> [StrPart] {
    let inner = strip_quotes(raw)
    let bs = inner.bytes()
    let n = bs.len()
    var parts: [StrPart] = []
    var text = ""
    var i = 0
    loop {
        if i >= n {
            break
        }
        let c = int(bs[i])
        if c == 92 && i + 1 < n {
            let nx = int(bs[i + 1])
            if nx == 110 {
                text = text + from_char_code(10)
            } else if nx == 116 {
                text = text + from_char_code(9)
            } else if nx == 114 {
                text = text + from_char_code(13)
            } else if nx == 48 {
                text = text + from_char_code(0)
            } else {
                text = text + byte_slice(inner, i + 1, i + 2)
            }
            i = i + 2
        } else if c == 123 {
            if text != "" {
                parts.append(StrPart{ text: text, hole: [] })
                text = ""
            }
            var depth = 1
            let hole_start = i + 1
            var j = i + 1
            loop {
                if j >= n {
                    break
                }
                let d = int(bs[j])
                if d == 92 && j + 1 < n {
                    j = j + 2
                } else if d == 34 {
                    j = j + 1
                    loop {
                        if j >= n {
                            break
                        }
                        let e = int(bs[j])
                        if e == 92 && j + 1 < n {
                            j = j + 2
                        } else if e == 34 {
                            j = j + 1
                            break
                        } else {
                            j = j + 1
                        }
                    }
                } else if d == 123 {
                    depth = depth + 1
                    j = j + 1
                } else if d == 125 {
                    depth = depth - 1
                    if depth == 0 {
                        break
                    }
                    j = j + 1
                } else {
                    j = j + 1
                }
            }
            // the hole's true line = the string's line + literal newlines inside the string before it
            // (stage-0 computes this `hl` by walking raw[0..i]); almost always 0 (strings are single-line).
            var nlc = 0
            var nk = 0
            loop {
                if nk >= i {
                    break
                }
                if int(bs[nk]) == 10 {
                    nlc = nlc + 1
                }
                nk = nk + 1
            }
            parts.append(StrPart{ text: "", hole: [parse_hole(byte_slice(inner, hole_start, j), base_line + nlc)] })
            i = j + 1
        } else {
            text = text + byte_slice(inner, i, i + 1)
            i = i + 1
        }
    }
    if text != "" {
        parts.append(StrPart{ text: text, hole: [] })
    }
    if parts.len() == 0 {
        parts.append(StrPart{ text: "", hole: [] })
    }
    return parts
}
