// field_mutation.em — mutation through a `var` binding and a `mut` parameter.
// A `mut` parameter is a mutable borrow: the change is visible to the caller
// (structs are heap objects — reference semantics, the borrow-model runtime).
struct Point { x: int  y: int }
fn bump_x(mut p: Point) -> int {
    p.x = p.x + 1
    return p.x
}
fn main() -> int {
    var p = Point { x: 10, y: 2 }
    p.x = p.x + 5          // 15 via a var binding
    return bump_x(p)       // 16 via a mut borrow
}
