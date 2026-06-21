// Native backend (M5) differential test: a generic struct used through its erased
// methods. Because the native backend erases generics (one method body over a uniform
// boxed Value), a monomorphized instance like Box<int> is BOXED, not given a value-type
// rep — otherwise its em_s would clash with the method's Value self. This exercises
// construction, a method returning a fresh instance, a method returning a field, and
// two different instantiations (int and string) sharing the one body.
struct Box<T> {
    value: T

    fn get(self) -> T { return self.value }
    fn replaced(self, n: T) -> Box<T> { return Box<T> { value: n } }
}

fn main() -> int {
    let b = Box<int> { value: 3 }
    let b2 = b.replaced(8)
    println("b2 = {b2.get()}")             // 8
    let s = Box<string> { value: "x" }
    println("s = {s.get()}")               // x
    return b.get() + b2.get()              // 3 + 8 = 11
}
