// Native backend (M2) differential test: enums + match. Boxed (heap, refcounted)
// variant construction (zero-field Origin and payload Circle/Rect), match dispatch on
// the variant tag, positional field bindings (borrows), exhaustive cases.

enum Shape {
    Circle(radius: float)
    Rect(width: float, height: float)
    Origin
}

fn area(s: Shape) -> float {
    match s {
        case Circle(r)  { return r * r * 3.0 }
        case Rect(w, h) { return w * h }
        case Origin     { return 0.0 }
    }
    return -1.0
}

fn main() -> float {
    let c = Circle(2.0)
    let r = Rect(3.0, 4.0)
    let o = Origin
    return area(c) + area(r) + area(o)
}
