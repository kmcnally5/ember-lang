// nested_struct.em — a struct field whose type is another struct. These are stored BOXED
// today (the parent holds a pointer to each nested struct); construction, leaf field access
// (`ln.a.x`), passing/returning a nested-struct value, arrays of them, and methods on them
// all work. (Inlining the nested fields as value types — so a whole nested field can be copied
// out, `let p = ln.a` — is a later value-types step; today that is a partial move and is
// rejected, so this test reads leaves and passes whole values into constructions/calls.)
struct Pt {
    x: int
    y: int
}


struct Line {
    a: Pt
    b: Pt


    fn dx(self) -> int {
        return self.b.x - self.a.x
    }
}


fn midx(ln: Line) -> int {
    return (ln.a.x + ln.b.x) / 2
}


fn make_line(p: Pt) -> Line {
    return Line { a: p, b: Pt { x: p.x + 4, y: p.y } }
}


fn main() -> int {
    let ln = make_line(Pt { x: 2, y: 9 })              // a={2,9}, b={6,9}
    let base = ln.dx() + midx(ln) + ln.a.y             // 4 + 4 + 9 = 17
    let arr = [make_line(Pt { x: 0, y: 0 }),           // array of nested-field structs
               make_line(Pt { x: 5, y: 5 })]
    return base + arr[1].b.x                            // 17 + 9 = 26
}
