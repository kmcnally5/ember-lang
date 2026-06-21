// struct_param.em — pass a struct to a function and return one. 2 + 5 = 7.
struct Point { x: int  y: int }
fn sum(p: Point) -> int { return p.x + p.y }
fn make() -> Point { return Point { x: 2, y: 5 } }
fn main() -> int { return sum(make()) }
