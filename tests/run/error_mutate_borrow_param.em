// error_mutate_borrow_param.em — a plain parameter is an immutable borrow; its
// fields cannot be mutated (it would need `mut`).
struct Point { x: int  y: int }
fn bad(p: Point) -> int {
    p.x = 9
    return p.x
}
fn main() -> int { return 0 }
