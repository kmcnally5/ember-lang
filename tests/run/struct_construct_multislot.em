// struct_construct_multislot.em — value-types 3b.4c: constructing an all-scalar struct in a
// context that takes it as a value — a `let` binding or a `return` — builds it MULTI-SLOT: the
// field values stay on the stack and become the binding's / return's slots, with NO heap box
// (the constructor `make` below disassembles to just RETURN_STRUCT, and `let p = Pt{…}` emits
// no NEW_STRUCT). Other uses of a literal (a field access on it, an argument, a discard) still
// box it transparently. A double-free would corrupt the sum; a leak is checked out-of-suite by
// RSS staying flat over millions of constructions.
struct Pt {
    x: int
    y: int
}


fn make(n: int) -> Pt {
    return Pt { x: n, y: n + 1 }     // construct straight into the return — no box
}


fn sum(p: Pt) -> int {
    return p.x + p.y
}


fn main() -> int {
    let a = Pt { x: 3, y: 4 }        // construct straight into the binding — no box
    let b = make(10)                 // constructor result bound directly (Pt{10,11})
    let viaArg = sum(Pt { x: 1, y: 6 })       // literal as an argument (boxed → unpacked) = 7
    let viaField = (Pt { x: 5, y: 9 }).x      // literal used as a field object (boxed) = 5
    return a.x + a.y + b.x + b.y + viaArg + viaField  // 3+4 + 10+11 + 7 + 5 = 40
}
