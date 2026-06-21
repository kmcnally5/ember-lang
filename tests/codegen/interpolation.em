// interpolation.em — string interpolation: holes hold full expressions, rendered
// to string and concatenated. int, field access, and arithmetic all work.
struct Point { x: int  y: int }
fn main() -> string {
    let name = "Ember"
    let p = Point { x: 3, y: 4 }
    let n = 7
    return "Hi {name}: {p.x} + {p.y} = {p.x + p.y}, n={n}"
}
