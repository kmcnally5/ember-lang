// struct_return_multislot.em — value-types 3b.4b: a non-generic free function returning an
// all-scalar struct returns it MULTI-SLOT — its N field slots are moved into the caller's
// frame (OP_RETURN_STRUCT), no heap box. Forwarding a local/param (`return p`) pushes its
// slots directly (no box); a construction is boxed then exploded; `let q = f()` binds the
// returned slots directly (no box→unbox round-trip). Other consumers (field access, an
// argument, discard) re-box the result so they behave exactly as before. A double-free would
// corrupt the sum; a leak is checked out-of-suite by RSS staying flat.
struct Pt {
    x: int
    y: int
}


fn forward(p: Pt) -> Pt {
    return p                          // forward a param: push its slots, no box
}


fn choose(a: Pt, b: Pt, first: bool) -> Pt {
    if first {
        return a
    }
    return b                         // forward one of two params
}


fn make(n: int) -> Pt {
    return Pt { x: n, y: n + 1 }      // construction return
}


fn main() -> int {
    let p = make(10)                  // let-bind a multi-slot return directly (Pt{10,11})
    let q = forward(p)                // forward; p stays usable
    let r = choose(p, q, false)       // q -> Pt{10,11}
    let viaField = make(100).x        // result used as a field object (re-boxed) -> 100
    let viaArg = forward(make(5)).y   // make -> forward -> .y -> 6
    return p.x + p.y + q.x + r.y + viaField + viaArg  // 10+11 + 10 + 11 + 100 + 6 = 148
}
