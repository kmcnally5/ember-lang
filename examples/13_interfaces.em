// 13_interfaces.em — dynamic dispatch. An `interface` used as a VALUE type lets values
// of different concrete types share one static type and dispatch their methods at run
// time. This is polymorphism WITHOUT inheritance — the Go/Rust model, not the Java one.
//
// Conformance is still nominal and checked (a struct says `implements`, the compiler
// verifies it). What's new here: a struct upcasts to the interface implicitly wherever
// the interface type is expected, and a method call on an interface value is resolved
// through the value's vtable — so a `[Shape]` can hold a mix of concrete shapes.

interface Shape {
    fn area(self) -> float
    fn kind(self) -> string
}


struct Circle implements Shape {
    radius: float
    fn area(self) -> float { return 3.14159 * self.radius * self.radius }
    fn kind(self) -> string { return "circle" }
}


struct Rect implements Shape {
    w: float
    h: float
    fn area(self) -> float { return self.w * self.h }
    fn kind(self) -> string { return "rect" }
}


struct Triangle implements Shape {
    base:   float
    height: float
    fn area(self) -> float { return 0.5 * self.base * self.height }
    fn kind(self) -> string { return "triangle" }
}


// Takes any Shape — the parameter is dispatched dynamically. One function serves every
// implementer, present or future, with no shared base class.
fn report(s: Shape) {
    println("{s.kind()} has area {s.area()}")
}


fn main() {
    // A heterogeneous collection: three different concrete types, one element type.
    let shapes: [Shape] = [
        Circle { radius: 2.0 },
        Rect { w: 3.0, h: 4.0 },
        Triangle { base: 6.0, height: 2.0 }
    ]

    var total = 0.0
    for s in shapes {
        report(s)                 // dynamic dispatch through the interface value
        total = total + s.area()
    }

    println("total area: {total}")
}
