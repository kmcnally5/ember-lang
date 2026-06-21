struct Pt implements Hash, Eq {
    x: int
    fn hash(self) -> int { return self.x }
    fn eq(self, other: Pt) -> bool { return self.x == other.x }
}
struct Holder<K: Hash + Eq, V> {
    k: K
    v: V
    fn matches(self, other: K) -> bool { return self.k.eq(other) }
}
fn main() -> int {
    let hi: Holder<int, int> = Holder<int, int> { k: 42, v: 1 }
    let hp: Holder<Pt, int> = Holder<Pt, int> { k: Pt { x: 5 }, v: 2 }
    var n = 0
    if hi.matches(42) { n = n + 1 }            // int key eq -> +1
    if hi.matches(99) { n = n + 100 }          // no
    if hp.matches(Pt { x: 5 }) { n = n + 10 }  // user-struct key eq -> +10
    if hp.matches(Pt { x: 9 }) { n = n + 1000 }// no
    return n                                    // 11
}
