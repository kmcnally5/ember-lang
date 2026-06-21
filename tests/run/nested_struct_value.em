// nested_struct_value.em — value-types 3b.5: an all-scalar nested struct field is stored INLINE
// (its packed bytes embed in the parent's buffer, no separate heap object). That makes a whole
// nested field a VALUE: it can be read out by copy (`let p = c.b` — OFI-031, previously a partial
// move error), the copy is independent of the parent (mutating the parent afterward doesn't touch
// it), and a nested assignment path (`c.b.a.v = …`) writes back through the inline fields. A
// double-free would corrupt the sum; a leak is checked out-of-suite by RSS staying flat.
struct A {
    v: int
}


struct B {
    a: A
    w: int
}


struct C {
    b: B
    z: int
}


fn main() -> int {
    var c = C { b: B { a: A { v: 1 }, w: 2 }, z: 3 }
    c.b.a.v = 10                 // 3-level write-back through inline fields
    c.b.w = 20
    c.z = 30
    let copy = c.b               // copy a whole nested struct out (OFI-031): B{a:{10}, w:20}
    c.b.a.v = 99                 // mutate c AFTER the copy — copy must be unaffected
    return c.b.a.v + c.b.w + c.z + copy.a.v + copy.w  // 99 + 20 + 30 + 10 + 20 = 179
}
