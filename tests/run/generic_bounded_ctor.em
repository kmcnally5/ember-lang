// generic_bounded_ctor.em — OFI-045: a generic CONSTRUCTOR function over a bounded type
// parameter. `new_bag<K: Hash + Eq + Copy>()` constructs `Bag<K>`, whose bound (Hash + Eq)
// is a subset of K's declared bounds — so K satisfies it. Before the fix the checker
// rejected `Bag<K>` here ("type argument does not satisfy the struct's generic bound"),
// blocking generic constructors like a `Set::new()` / `Map::new()`.
struct Bag<K: Hash + Eq + Copy> {
    items: [K]
    count: int

    fn add(mut self, x: K) {
        self.items.append(x)
        self.count = self.count + 1
    }
}


fn new_bag<K: Hash + Eq + Copy>() -> Bag<K> {
    return Bag<K> { items: [], count: 0 }
}


fn main() -> int {
    var b: Bag<int> = new_bag()
    b.add(10)
    b.add(20)
    b.add(30)
    return b.count               // expect 3
}
