// error_mutate_let.em — a field cannot be mutated through an immutable `let`.
struct Point { x: int  y: int }
fn main() -> int {
    let p = Point { x: 1, y: 2 }
    p.x = 9
    return p.x
}
