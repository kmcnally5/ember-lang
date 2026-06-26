// refinement_method_self.em — OFI-150: a refined construction INSIDE a method (where `self` is
// the receiver). The `where` predicate's `self` must bind to the CONSTRUCTED value, not the
// receiver — in BOTH the checker (the one-time predicate check, which earlier reported a bogus
// "redeclaration of a variable in the same scope" because it declared `self` over the receiver)
// AND codegen — and the receiver `self` must remain intact after the construction.
type Pct = int where 0 <= self && self <= 100


struct Widget {
    v: int

    fn doubled_pct(self) -> int {
        let p = Pct(self.v)        // predicate's self = self.v, not the Widget receiver
        return int(p) + self.v     // receiver self still usable afterward
    }
}


fn main() -> int {
    let w = Widget { v: 40 }
    println(w.doubled_pct())       // 80
    return 0
}
