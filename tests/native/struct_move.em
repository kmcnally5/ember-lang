// Native backend (M2) differential test: struct MOVES. A value-type struct lowers to a
// real C struct, so `let q = p` and a `move` parameter are plain C value copies — no
// heap, no aliasing, no double-free. This crashed under the earlier boxed representation
// (two aliases freeing one heap object); the C-struct representation fixes it.

struct Point {
    x: int
    y: int
}


fn consume(move p: Point) -> int {
    return p.x + p.y
}


fn main() -> int {
    let p = Point { x: 3, y: 4 }
    let q = p                  // move p into q (C value copy)
    return consume(q)          // move q into consume (C value copy)
}
