// nested_struct_multislot.em — value-types 3b.5-B: a struct whose fields are scalars or
// inline-able nested structs is itself a MULTI-SLOT value — held on the stack as its leaf
// slots, no heap box. So a whole nested struct is a copy type: `var dup = ln` COPIES (the
// source stays usable, mutating the copy doesn't touch it), it passes to a function by value
// (a multi-slot parameter), and is returned by value (a multi-slot return). Leaf access reads
// a slot directly (`ln.a.x`); a whole nested field (`ln.a`) is its slot sub-range. A double
// free would corrupt the sum; a leak is checked out-of-suite by RSS staying flat.
struct Pt {
    x: int
    y: int
}


struct Line {
    a: Pt
    b: Pt
}


fn len2(ln: Line) -> int {
    let dx = ln.b.x - ln.a.x
    let dy = ln.b.y - ln.a.y
    return dx * dx + dy * dy
}


fn shift(ln: Line, d: int) -> Line {
    return Line { a: Pt { x: ln.a.x + d, y: ln.a.y }, b: Pt { x: ln.b.x + d, y: ln.b.y } }
}


fn main() -> int {
    let ln = Line { a: Pt { x: 0, y: 0 }, b: Pt { x: 3, y: 4 } }
    var dup = ln                  // COPY (3b.5-B) — ln stays usable
    dup.a.x = 100                 // mutate the copy only
    let viaParam = len2(ln)       // 25 — nested struct passed by value
    let s = shift(ln, 10)         // {a:{10,0}, b:{13,4}} — nested struct returned by value
    return viaParam + ln.b.x + dup.a.x + s.b.x  // 25 + 3 + 100 + 13 = 141
}
