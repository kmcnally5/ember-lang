// 04_generics.em — generics and interfaces.
// Definition-site checked, interface-bounded (our locked decision). The compiler chooses
// representation by build profile: erased in debug (fast builds), monomorphized in release
// (zero cost). You write it ONE way; you never think about representation.

// An interface (nominal — you declare that a type implements it). Pairs cleanly with the
// `<T: Ord>` bound below. No sigil soup, no lifetime noise — LLM-legible.
interface Ord {
    fn compare(self, other: Self) -> int   // <0, 0, >0
}

// A type declares conformance with `implements` (nominal — Ember does not infer
// it structurally). The compiler will check the methods are present.
struct Version implements Ord {
    number: int

    fn compare(self, other: Version) -> int {
        return self.number - other.number
    }
}

// A generic container. `<T>` is the only ceremony. Note the ownership keywords on `self`:
//   - read by default (push only reads existing items to append)
//   - `mut self` means this method may mutate the receiver.
struct Stack<T> {
    items: [T]

    fn push(mut self, item: T) {
        self.items.append(item)
    }

    fn pop(mut self) -> Option<T> {
        if self.items.len() == 0 { return None }
        return Some(self.items.remove_last())
    }
}

// A generic free function with an interface bound. Checked ONCE, here, against `Ord` —
// not re-checked at every call site (no C++ template-error walls of text).
fn max<T: Ord>(move a: T, move b: T) -> T {
    if a.compare(b) >= 0 { return a }
    return b
}

fn main() {
    var s = Stack<int> { items: [] }
    s.push(1)
    s.push(2)
    match s.pop() {
        case Some(x) { println("popped {x}") }
        case None    { println("empty") }
    }
}
