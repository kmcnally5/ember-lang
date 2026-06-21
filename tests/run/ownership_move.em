// ownership_move.em — a move type (struct) transfers on `let q = p`; p is then
// moved-out and q owns the value. Reading q is fine.
struct Point { x: int  y: int }
fn main() -> int {
    let p = Point { x: 7, y: 2 }
    let q = p            // moves p into q
    return q.x           // q owns it
}
