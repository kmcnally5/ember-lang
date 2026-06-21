// enum_match.em — construct a data variant, match it, bind its fields.
// area(Rect(3,4)) takes the Rect case: w*h = 12.
enum Shape {
    Circle(r: int)
    Rect(w: int, h: int)
    Origin
}
fn area(s: Shape) -> int {
    match s {
        case Circle(r) { return r * r * 3 }
        case Rect(w, h) { return w * h }
        case Origin { return 0 }
    }
    return -1
}
fn main() -> int {
    return area(Rect(3, 4))
}
