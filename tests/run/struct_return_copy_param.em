// struct_return_copy_param.em — OFI-028: an all-scalar struct is a COPY type, so a plain
// (borrow) parameter of one may be RETURNED by value. Reading the param whole copies it out
// (box-on-use), so no reference escapes the function — unlike a boxed unique-owner struct or
// an array, where returning a borrow would alias the caller's value (still rejected). The
// source binding stays usable after the return (value semantics). Returns are still boxed
// today; when 3b.4b makes them multi-slot this test guards that the value still copies out.
struct Pt {
    x: int
    y: int
}


fn echo(p: Pt) -> Pt {
    return p                       // copy-type borrow returned by value
}


fn pick(a: Pt, b: Pt, first: bool) -> Pt {
    if first {
        return a                   // returned from one branch
    }
    return b                       // ...or the other
}


fn main() -> int {
    let a = Pt { x: 3, y: 4 }
    let c = echo(a)                            // Pt{3,4}
    let d = pick(a, Pt { x: 9, y: 1 }, false)  // Pt{9,1}
    return c.x + c.y + d.x + d.y + a.x         // 3+4 + 9+1 + 3 (a still usable) = 20
}
