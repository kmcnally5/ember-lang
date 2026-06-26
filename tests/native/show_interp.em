// OFI-139: a value type that provides `fn show(self) -> string` (the Show contract) is
// rendered directly by string interpolation — the checker desugars `"{value}"` to
// `"{value.show()}"`. Detection is structural, so no `implements Show` is needed to
// interpolate a concrete struct; an interface value dispatches through its vtable.
//
// OFI-146: a desugared `.show()` (and any owned-temp string hole) must not leak — this
// runs on BOTH the VM and the native binary, whose stdout must match (the drift guard).

struct Point {
    x: int
    y: int

    fn show(self) -> string {
        return "({self.x}, {self.y})"
    }
}


struct Money {
    cents: int

    fn show(self) -> string {
        return "${self.cents / 100}.{self.cents % 100}"
    }
}


interface Animal {
    fn legs(self) -> int
    fn show(self) -> string
}


struct Cat implements Animal {
    fn legs(self) -> int { return 4 }
    fn show(self) -> string { return "cat" }
}


struct Bee implements Animal {
    fn legs(self) -> int { return 6 }
    fn show(self) -> string { return "bee" }
}


// describe takes the interface VALUE — `{a}` renders via dynamic dispatch on the vtable.
fn describe(a: Animal) -> string {
    return "{a} has {a.legs()} legs"
}


fn main() {
    // Concrete struct: a named binding (borrowed receiver).
    let p = Point { x: 3, y: 7 }
    println("p = {p}")

    // Concrete struct: a fresh owned-temp receiver (must be dropped, not leaked).
    println("origin = {Point { x: 0, y: 0 }}")

    // Multiple holes of mixed kinds in one literal.
    let m = Money { cents: 1995 }
    println("{m} for point {p} ({p.x + p.y} units), ok={true}")

    // Interface value through dynamic dispatch, including inside a loop.
    let zoo: [Animal] = [Cat { }, Bee { }]
    for a in zoo {
        println(describe(a))
    }
}
