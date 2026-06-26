// OFI-140: an enum variant may be CONSTRUCTED with named payload fields — `Rect(w: 4.0, h: 3.0)` —
// mirroring struct-literal syntax (the declared field names were previously inert at the call site).
// Named args may be given in ANY order; the checker reorders them into declared order, so codegen is
// identical to a positional build. Positional construction is unchanged. Runs on BOTH backends (VM ==
// native). The Rect case is asymmetric (w != h, printed separately) so the REORDER is actually proven.

enum Shape {
    Circle(radius: float)
    Rect(w: float, h: float)
}


fn describe(s: Shape) -> string {
    match s {
        case Circle(r) { return "circle r={r}" }
        case Rect(w, h) { return "rect w={w} h={h}" }   // distinct fields prove the reorder
    }
}


fn main() {
    let a = Circle(radius: 2.0)           // named
    let b = Rect(w: 4.0, h: 3.0)          // named, declared order
    let c = Rect(h: 3.0, w: 4.0)          // named, REVERSED — must still bind w=4, h=3
    let d = Rect(7.0, 9.0)                // positional, unchanged
    println(describe(a))
    println(describe(b))
    println(describe(c))
    println(describe(d))

    // Generic enum, named construction + the prelude Option.
    let e: Option<int> = Some(value: 42)
    match e { case Some(v) { println("some {v}") } case None { println("none") } }

    // ENUM-NAME-qualified named construction — `Enum.Variant(name: value)` (the adversarial-review case):
    // resolves through the local enum name, not just an import alias.
    let f = Shape.Circle(radius: 6.0)
    let g: Option<int> = Option.Some(value: 7)
    println(describe(f))
    match g { case Some(v) { println("qual {v}") } case None {} }
}
