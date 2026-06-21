// Native backend (M2b) differential test: struct construction, field reads (borrow
// + fresh-temporary), struct passed by borrow and returned by move, and scope-exit
// drops. The harness runs this on the VM and as a compiled binary; output must match.

struct Point {
    x: int
    y: int
}


fn mk(a: int, b: int) -> Point {
    return Point { x: a, y: b }
}


fn dist2(p: Point) -> int {
    return p.x * p.x + p.y * p.y
}


fn main() -> int {
    let p = Point { x: 3, y: 4 }      // boxed construction (fields in declared order)
    let d = dist2(p)                   // pass by borrow — caller keeps + drops p
    let q = mk(6, 8)                   // struct returned by move (no drop in mk)
    let e = dist2(q)
    return d + e + mk(1, 2).x          // fresh-temporary field read drops the temp
}
