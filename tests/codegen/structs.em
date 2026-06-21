// struct_fields.em — construct a struct and read its fields. 3 + 4 = 7.
struct Point {
    x: int
    y: int
}
fn main() -> int {
    let p = Point { x: 3, y: 4 }
    return p.x + p.y
}
