// ownership_move_param.em — a `move` parameter takes ownership, so the function
// may return it; the caller's binding is consumed by the call.
struct Point { x: int  y: int }
fn into_x(move p: Point) -> Point {
    return p
}
fn main() -> int {
    let p = Point { x: 9, y: 0 }
    let q = into_x(p)        // p moved into the call
    return q.x
}
