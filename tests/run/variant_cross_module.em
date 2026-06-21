// variant_cross_module.em — OFI-073 soundness regression. After variant names became module-scoped
// (two modules may share a variant name), codegen must build/dispatch the variant the CHECKER chose,
// not re-resolve by global name (which would pick a same-named variant of the WRONG enum, with a
// different tag/arity → payload corruption). std/highlight's `Kind` enum has zero-field `Str`,
// `Number`, `Type`, `Comment` variants; the enum below reuses those names with DIFFERENT arities and
// tag positions. Construct + match each and read the payload back — if codegen mis-resolved by name,
// the arity mismatch would corrupt the value or crash. (Also runs as a tests/native dual-run, so the
// VM and the compiled binary must agree.)
import "std/highlight" as hl

enum Node {
    Comment
    Str(s: string)
    Number(n: int)
    Type(name: string, size: int)
}


fn describe(x: Node) -> string {
    match x {
        case Comment            { return "comment" }
        case Str(s)             { return "str:{s}" }
        case Number(n)          { return "num:{n}" }
        case Type(name, size)   { return "type:{name}/{size}" }
    }
    return "?"
}


fn main() -> int {
    let a = Str("hi")
    let b = Number(42)
    let c = Type("widget", 16)
    let d = Comment
    println("a={describe(a)}")
    println("b={describe(b)}")
    println("c={describe(c)}")
    println("d={describe(d)}")

    // round-trip through an array of the enum (storage path) to be sure the tag/payload survive
    var xs: [Node] = []
    xs.append(Number(1))
    xs.append(Str("two"))
    xs.append(Type("t", 3))
    var total = 0
    var i = 0
    loop {
        if i == xs.len() {
            break
        }
        match xs[i] {
            case Number(n)        { total = total + n }
            case Type(name, size) { total = total + size }
            case Str(s)           { total = total + s.len() }
            case Comment          {}
        }
        i = i + 1
    }
    println("total={total}")
    return 0
}
