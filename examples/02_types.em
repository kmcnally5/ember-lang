// 02_types.em — structs, enums, methods, pattern matching.
// Directly extends FROG's `struct Point { x, y }` and `enum Shape { Circle(r) ... }`,
// adding field types, typed variants, and explicit `self`.

struct Point {
    x: float
    y: float

    // Methods live in the struct body (FROG heritage). `self` is explicit — clearer for
    // humans and far easier for an LLM to reason about than an injected invisible receiver.
    fn distance(self, other: Point) -> float {
        let dx = self.x - other.x
        let dy = self.y - other.y
        return sqrt(dx * dx + dy * dy)
    }
}

// Sum type. Variants carry typed, named fields. Zero-field variants need no parens.
enum Shape {
    Circle(radius: float)
    Rect(width: float, height: float)
    Origin
}

fn area(s: Shape) -> float {
    // Pattern matching. Bindings (r, w, h) are scoped to their case body. First match wins,
    // no fallthrough. The compiler requires this match to be EXHAUSTIVE — forget a variant
    // and it won't build. (This is FROG's switch/case, made exhaustive by the static checker.)
    match s {
        case Circle(r)   { return 3.14159 * r * r }
        case Rect(w, h)  { return w * h }
        case Origin      { return 0.0 }
    }
}

fn main() {
    let a = Point { x: 0.0, y: 0.0 }       // struct literal — FROG's `Point { x: 1, y: 2 }`
    let b = Point { x: 3.0, y: 4.0 }
    println("distance: {a.distance(b)}")   // 5.0

    let shapes = [Circle(2.0), Rect(3.0, 4.0), Origin]
    for s in shapes {
        println("area: {area(s)}")
    }
}
