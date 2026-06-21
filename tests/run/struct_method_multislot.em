// struct_method_multislot.em — value-types 3b.4d: a method on a NON-generic struct takes its
// explicit all-scalar struct parameters and RETURNS an all-scalar struct MULTI-SLOT, exactly
// like a free function — explicit struct args push their field slots, the return moves its
// slots into the caller (OP_RETURN_STRUCT), and `let q = p.m(...)` binds them directly. The
// receiver `self` stays boxed for now (box-on-use of the multi-slot local). A method that
// implements an interface keeps the boxed convention (it may be dispatched through a witness in
// bounded generic code) — covered by bounded_generic.em. A double-free would corrupt the sum.
struct Pt {
    x: int
    y: int


    fn add(self, o: Pt) -> Pt {
        return Pt { x: self.x + o.x, y: self.y + o.y }
    }


    fn scaled(self, k: int) -> Pt {
        return Pt { x: self.x * k, y: self.y * k }
    }


    fn sum(self) -> int {
        return self.x + self.y
    }
}


fn main() -> int {
    let a = Pt { x: 1, y: 2 }
    let b = Pt { x: 10, y: 20 }
    let c = a.add(b)                       // struct return bound directly (Pt{11,22})
    let d = a.add(Pt { x: 100, y: 200 })   // construction arg straight to a multi-slot param
    let e = a.scaled(3).add(b)             // chained: scaled returns Pt, then .add(b)
    return c.sum() + d.sum() + e.sum()     // 33 + 303 + 39 = 375
}
