// generic_method.em — methods on a generic struct. Box<T> compiles once (erased);
// the method signature substitutes T from the receiver's instantiation.
struct Box<T> {
    value: T

    fn get(self) -> T { return self.value }
    fn replaced(self, n: T) -> Box<T> { return Box<T> { value: n } }
}
fn main() -> int {
    let b = Box<int> { value: 3 }
    let b2 = b.replaced(8)
    println(b2.get())                 // 8
    let s = Box<string> { value: "x" }
    println(s.get())                  // x
    return b.get()                    // 3
}
