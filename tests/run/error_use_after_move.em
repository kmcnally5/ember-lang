// error_use_after_move.em — using a binding after its value has been moved.
struct Point { x: int  y: int }
fn main() -> int {
    var p = Point { x: 1, y: 2 }
    let q = p
    return p.x          // p was moved into q
}
