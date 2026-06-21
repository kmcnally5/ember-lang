// dynamic_dispatch.em — interfaces used as VALUE types (dynamic dispatch). A struct
// that `implements` an interface upcasts to it implicitly wherever the interface type is
// expected; a method call on an interface value dispatches through the value's vtable at
// run time. Exercises every widening site (binding, argument, return, struct field,
// `[Iface]` array element) plus a heterogeneous collection — the headline use case.
interface Shape {
    fn area(self) -> int
    fn name(self) -> string
}


struct Circle implements Shape {
    r: int
    fn area(self) -> int { return self.r * self.r * 3 }
    fn name(self) -> string { return "circle" }
}


struct Square implements Shape {
    side: int
    fn area(self) -> int { return self.side * self.side }
    fn name(self) -> string { return "square" }
}


// An interface-typed PARAMETER: any Shape works, dispatched dynamically.
fn measure(s: Shape) -> int {
    return s.area()
}


// An interface RETURN type: the concrete struct upcasts on the way out.
fn make(kind: int) -> Shape {
    if kind == 0 { return Circle { r: 3 } }
    return Square { side: 4 }
}


// An interface-typed FIELD.
struct Scene {
    hero: Shape
}


fn main() -> int {
    // Binding-site upcast.
    let c: Shape = Circle { r: 2 }
    var total = measure(c)                 // 12

    // Return-site upcast, then dispatch on the result.
    total = total + make(0).area()         // Circle r=3 -> 27
    total = total + make(1).area()         // Square side=4 -> 16

    // Field-site upcast + dispatch through the field.
    let scene = Scene { hero: Square { side: 5 } }
    total = total + scene.hero.area()      // 25

    // Heterogeneous collection: different concrete types behind one interface.
    let shapes: [Shape] = [Circle { r: 1 }, Square { side: 3 }, Circle { r: 2 }]
    for sh in shapes {
        total = total + sh.area()          // 3 + 9 + 12 = 24
    }
    // A non-area method to prove multi-method vtables dispatch correctly.
    if shapes[0].name() == "circle" { total = total + 1000 }

    return total   // 12 + 27 + 16 + 25 + 24 + 1000 = 1104
}
