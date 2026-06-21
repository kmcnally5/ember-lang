// Native backend (M2b) differential test: nested (inline) struct fields — an
// all-scalar struct stored INLINE in another. Construction moves the nested bytes in;
// reading an inline field materialises a fresh value COPY that is then dropped.

struct Point {
    x: int
    y: int
}


struct Line {
    a: Point
    b: Point
}


fn main() -> int {
    let line = Line { a: Point { x: 1, y: 2 }, b: Point { x: 3, y: 4 } }
    return line.a.x + line.b.y + line.a.y
}
