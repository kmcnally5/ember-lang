// Native backend differential test: value-struct<->boxed bridge cases surfaced by the
// code review — an interface upcast in a `let` initializer (the binding is a boxed Value,
// not an em_s), a generic function with a CONCRETE value-struct parameter and return (kept
// boxed by the erased convention, boxed in / unboxed out), and a closure taking a value
// struct (boxed across the indirect call).
interface Shape {
    fn area(self) -> int
}

struct Sq implements Shape {
    side: int

    fn area(self) -> int {
        return self.side * self.side
    }
}

struct Point {
    x: int
    y: int
}

fn wrap<T>(move p: Point, move a: T) -> Point {
    return p
}

fn apply(f: fn(Point) -> int, p: Point) -> int {
    return f(p)
}

fn main() -> int {
    let s: Shape = Sq { side: 4 }          // interface upcast in a let initializer
    let r = wrap(Point { x: 2, y: 5 }, 99) // generic fn, concrete struct param + return
    let g: fn(Point) -> int = |q| q.x + q.y
    let sum = apply(g, Point { x: 3, y: 6 })
    println("area {s.area()}")
    println("wrap {r.x + r.y}")
    println("closure {sum}")
    return s.area() + r.x + r.y + sum
}
