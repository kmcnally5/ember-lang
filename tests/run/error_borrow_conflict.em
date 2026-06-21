// error_borrow_conflict.em — the same value cannot be passed to a `mut` parameter
// and simultaneously aliased by another argument (mutable XOR shared).
struct Point { x: int  y: int }
fn combine(mut a: Point, b: Point) -> int {
    a.x = b.x
    return a.x
}
fn main() -> int {
    var p = Point { x: 1, y: 2 }
    return combine(p, p)
}
