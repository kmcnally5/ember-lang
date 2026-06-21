// modlib/geom.em — a library exporting a struct type and constructor/accessor
// functions. Imported by use_types.em, which names the type qualified (geom.Point).
struct Point { x: int  y: int }
fn make(x: int, y: int) -> Point { return Point { x: x, y: y } }
fn sum(p: Point) -> int { return p.x + p.y }
