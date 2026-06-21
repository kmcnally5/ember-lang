// Native backend (M3d) differential test: dynamic dispatch through `dyn` interfaces.
// A struct implementing an interface is UPCAST to an interface value — a boxed {receiver,
// vtable} pair (the receiver boxed via the value-struct<->box bridge, the vtable an enum
// record of the impl's method fn-indices). A method call reads the method's fn-index from
// the vtable and dispatches through the generated em_invoke trampoline, which unboxes the
// struct receiver. Covers heterogeneous collections and multiple implementers.
interface Shape {
    fn area(self) -> float
    fn name(self) -> string
}

struct Circle implements Shape {
    radius: float

    fn area(self) -> float {
        return 3.14 * self.radius * self.radius
    }

    fn name(self) -> string {
        return "circle"
    }
}

struct Rect implements Shape {
    w: float
    h: float

    fn area(self) -> float {
        return self.w * self.h
    }

    fn name(self) -> string {
        return "rect"
    }
}

fn describe(s: Shape) {
    println("{s.name()} area {s.area()}")
}

fn main() -> int {
    describe(Circle { radius: 2.0 })
    describe(Rect { w: 3.0, h: 4.0 })

    let shapes: [Shape] = [Circle { radius: 1.0 }, Rect { w: 2.0, h: 5.0 }, Circle { radius: 3.0 }]
    var count = 0
    for s in shapes {
        println("{s.name()} = {s.area()}")
        count = count + 1
    }
    return count
}
