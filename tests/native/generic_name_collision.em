// generic_name_collision.em — OFI-053 differential test: a user struct named like a
// generic type parameter (`T`, `V`) must NOT collide with the parameter in the native
// backend's by-name type resolution. The erased method param/return is a boxed Value,
// not the same-named user struct. Before the fix this mis-typed the C signatures and
// produced a `cc` error; the VM was always correct, so the binary must now match it.
struct T { n: int }
struct V { tag: int }

struct Box<T> {
    item: T

    fn set(mut self, item: T) { self.item = item }

    fn get(self) -> T { return self.item }
}

struct Pair<K, V> {
    a: K
    b: V

    fn second(self) -> V { return self.b }
}

fn main() -> int {
    var box = Box<int> { item: 0 }
    box.set(42)
    let pair = Pair<int, string> { a: 1, b: "hi" }
    println(pair.second())       // hi
    return box.get()             // 42
}
