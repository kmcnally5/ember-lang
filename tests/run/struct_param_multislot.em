// struct_param_multislot.em — value-types 3b.4: a plain all-scalar struct PARAMETER of a
// non-generic free function is passed MULTI-SLOT (its N field slots on the stack, no heap
// box). Field access in the callee reads a slot directly; a whole-value read boxes on use
// (value semantics — the source stays usable). The caller pushes the slots three ways: a
// multi-slot local/param copies its slots in place (no allocation), and any other struct
// value (a construction) is materialised boxed then exploded. `requires` reads a field of a
// multi-slot param in the precondition. A double-free would corrupt the sum; a leak is
// checked out-of-suite by RSS staying flat.
struct Pt {
    x: int
    y: int
}


fn manhattan(p: Pt) -> int {
    return p.x + p.y
}


fn weighted(a: Pt, k: int, b: Pt) -> int {
    return a.x * k + b.y
}


fn relay(p: Pt) -> int {
    return manhattan(p)            // a multi-slot param relayed to another multi-slot param
}


fn copyback(p: Pt) -> int {
    let q = p                      // box-on-use of param p; q is a fresh multi-slot local
    return q.x + q.y + p.x         // p stays usable after the copy (value semantics)
}


fn safe_div(p: Pt) -> int
    requires p.y != 0
{
    return p.x / p.y
}


fn main() -> int {
    let a = Pt { x: 3, y: 4 }
    let r1 = manhattan(a)                       // 7   direct push of a multi-slot local
    let r2 = manhattan(Pt { x: 10, y: 20 })     // 30  box+unbox of a construction
    let r3 = weighted(a, 2, Pt { x: 1, y: 5 })  // 11  mixed struct + scalar + struct args
    let r4 = relay(a)                           // 7   param forwarded across a call
    let r5 = copyback(a)                        // 10  3 + 4 + 3
    let r6 = safe_div(Pt { x: 20, y: 5 })       // 4   contract reads a multi-slot field
    return r1 + r2 + r3 + r4 + r5 + r6          // 7+30+11+7+10+4 = 69
}
