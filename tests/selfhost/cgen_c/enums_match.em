// M5f fixture for the self-hosted C-emit backend: ENUMS + MATCH. An enum value is a BOXED refcounted
// runtime value with no C type and no metadata preamble — a variant construction is `em_enum(&g_em,
// <enum_id>, <tag>, <arity>, payload…)` (a bare `Dot`, or a payload `Circle(4)`); an enum param / local /
// return is OWNED (dropped at scope exit, moved into a call via own_into_slot, exactly like a string). A
// `match scrut { case V(binds) { … } }` statement evaluates the scrutinee once (a borrow of the owner),
// reads its tag (`em_tag`), and lowers to an if / else-if chain on the tag; a case's payload fields bind
// POSITIONALLY via `em_enum_field` (a borrow — the enum owns them); a `case _` is the trailing `else`.
// Exercises bare + scalar + string + multi-field variants, wildcard, match that assigns a `var`, nested
// match, enum params / returns, and enum-returning calls. Byte-identical to stage-0 `emberc --emit=c`
// (gated, Stage 6 of make selfhost). Owned-payload USE (a string/enum payload flowing out), generic enums
// (Option/Result), and an owning-temp scrutinee are later increments.
enum Shape {
    Dot
    Circle(r: int)
    Rect(w: int, h: int)
}


enum Tok {
    End
    Num(v: int)
    Name(s: string)
}


fn area(s: Shape) -> int {
    match s {
        case Dot { return 0 }
        case Circle(r) { return 3 * r * r }
        case Rect(w, h) { return w * h }
    }
    return 0 - 1
}


fn tok_kind(t: Tok) -> int {
    var k = 0
    match t {
        case End { k = 1 }
        case Num(v) { k = 2 }
        case _ { k = 3 }
    }
    return k
}


fn classify(t: Tok) -> int {
    match t {
        case Num(v) { return v }
        case _ { return 0 - 1 }
    }
    return 0 - 2
}


fn bigger(a: int) -> Shape {
    if a > 0 {
        return Circle(a)
    }
    return Dot
}


fn main() -> int {
    let r = Rect(3, 5)
    let c = bigger(4)
    let t = Num(42)
    let nm = Name("id")
    return area(r) + area(c) + area(Dot) + classify(t) + tok_kind(t) + tok_kind(nm) + area(bigger(2))
}
