// struct_nested.em — struct-typed fields and chained field access. l.end.x = 3.
struct Point { x: int  y: int }
struct Line { start: Point  end: Point }
fn main() -> int {
    let l = Line { start: Point { x: 0, y: 0 }, end: Point { x: 3, y: 4 } }
    return l.end.x
}
